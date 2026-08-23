import Foundation
import simd

/// The tone engine's math, on the CPU. This file is the source of truth: the
/// GPU kernel in `GradeKernelSource` mirrors it operation for operation, and
/// the parity test in `GradeEngineTests` holds the two together.
///
/// Shape of the pipeline, per pixel, on scene-linear Display P3 with the
/// DNG's above-1.0 highlight headroom intact:
///
///   white balance (Bradford 3×3) → exposure (2^EV)
///     → local tone in log₂ luminance: shadows / highlights / clarity keyed
///       on an edge-aware neighbourhood BASE (guided filter, computed by the
///       kernel at quarter resolution) — this is what lets Shadows reach only
///       the dark regions and Highlights only the bright ones, at
///       Lightroom-class strengths, without inverting any global curve
///     → highlight recovery on the luminance, in linear (Reinhard above a
///       knee)
///     → the tone LUT on gamma-encoded luminance (contrast, shadows,
///       highlights-lift, whites, blacks — built monotone by construction)
///     → luminance-ratio application (hue-preserving), with the chroma of
///       hard-lifted deep shadows steered toward the neighbourhood chroma so
///       sensor colour noise doesn't render as saturated blotches
///     → clip-targeted highlight desaturation → vibrance + saturation → clamp.
///
/// The spatial inputs (base, neighbourhood chroma) are textures on the GPU;
/// `evaluate` takes them as explicit parameters so the parity tests can pin
/// the kernel to this file. Every local term vanishes at slider zero, so a
/// neutral render is untouched by all of this.
///
/// After the tone stage come the detail passes — texture (mid-frequency
/// band) and sharpen (capture acutance) — then vignette and the optional
/// dither. They are pure spatial high-pass work with no per-pixel CPU
/// mirror; on a flat field they are exact no-ops, which is how the
/// uniform-image parity test still covers the whole chain.
public enum ToneMath {
    // MARK: - Constants

    /// Display P3 (D65) luminance weights — the Y row of the P3→XYZ matrix.
    public static let lumaWeights = SIMD3<Float>(0.2289746, 0.6917385, 0.0792869)

    /// Sample count of the tone LUT over the encoded domain [0, 1].
    public static let lutSize = 257

    /// The encode gamma the region controls operate in. Lightroom's sliders
    /// feel perceptually uniform because the curve is shaped in a gamma-ish
    /// domain; pure linear makes shadows twitchy and highlights numb.
    static let encodeGamma: Float = 1.0 / 2.2

    // Calibration constants. Tuned against the Lightroom reference render of
    // frame-00001 (see the `lapse grade` regression rig); the derivative
    // bounds in `toneCurve` cap the bump amplitudes at 0.148 — beyond that a
    // full-strength slider stops being monotone.
    static let contrastStrength: Float = 0.9
    static let contrastPivot: Float = 0.46      // encoded 18% grey
    static let shadowsAmplitude: Float = 0.14
    static let highlightsLiftAmplitude: Float = 0.14
    static let whitesAmplitude: Float = 0.25
    static let blacksAmplitude: Float = 0.25
    /// Even at neutral, super-whites roll off gently instead of hard-clipping,
    /// so an untouched render still uses the DNG's headroom gracefully.
    static let recoveryBase: Float = 0.15
    static let desatStrength: Float = 0.5
    static let vibranceStrength: Float = 0.9
    static let saturationStrength: Float = 0.8
    // MARK: - Local tone constants
    //
    // The base-keyed stage. `base` is an edge-aware low-frequency estimate of
    // the post-WB/exposure log₂ luminance (guided filter at quarter
    // resolution); keying the tonal gain on the *neighbourhood* instead of the
    // pixel is what the monotonicity bound above cannot give a global curve:
    // two pixels with the same value move differently in different regions,
    // so Shadows can lift a dark courtyard by stops while a dark speck in the
    // sky stays put — and no transfer function ever inverts.

    /// EV moved in the deepest zones at shadows ±1. The encoded-domain bump
    /// stays on top for midtone shaping, so the total reach is
    /// Lightroom-class.
    static let shadowLocalEV: Float = 2.6
    /// Sigmoid centre/width (in stops below diffuse white) of the shadow
    /// weight over the base.
    static let shadowLocalPivot: Float = -3.0
    static let shadowLocalSoft: Float = 1.6
    /// The weight's toe: it rolls back off toward the sensor's noise floor,
    /// because a region ten-plus stops down holds no signal to reveal — the
    /// honest render of true black is black, and lifting it only paints the
    /// noise floor across the frame (measured on frame-00001's silhouettes:
    /// raw linear ≈ 0.0002, chance-blue).
    static let shadowToeLo: Float = -12
    static let shadowToeHi: Float = -8
    /// EV pulled out of bright zones at highlights −1 …
    static let highlightCutEV: Float = 2.0
    /// … and added at highlights +1 (asymmetric: boosting toward clip needs
    /// less travel than rescuing a sky).
    static let highlightLiftEV: Float = 1.2
    static let highlightLocalPivot: Float = -0.8
    static let highlightLocalSoft: Float = 0.9
    /// Clarity as detail gain: the log-domain residual (pixel − base) scaled
    /// by the slider, tanh-limited in stops so edges saturate the limiter
    /// instead of ringing.
    static let clarityDetailGain: Float = 0.9
    static let clarityTauStops: Float = 0.6
    /// Chroma protection: below these post-exposure luminances a hard lift
    /// steers the pixel's chroma toward the neighbourhood chroma — the
    /// sensor's colour noise has zero mean, so the neighbourhood is the
    /// honest colour of a lifted deep shadow.
    static let chromaProtectDeepY0: Float = 0.008
    static let chromaProtectDeepY1: Float = 0.035
    static let chromaProtectShadowScale: Float = 0.8
    static let chromaProtectBlacksScale: Float = 1.2
    /// The steering only trusts the neighbourhood chroma where the
    /// neighbourhood is tonally similar to the pixel (within this many
    /// stops); across an object edge the box average is a colour blend of
    /// both sides, and steering toward it would paint fringes — there the
    /// target falls back toward neutral instead.
    static let chromaSimilaritySpanStops: Float = 1.5
    /// And a neighbourhood sitting at the noise floor has no colour of its
    /// own to offer — below these levels the target fades to neutral too.
    static let chromaTrustFloorLo: Float = -11
    static let chromaTrustFloorHi: Float = -8
    /// The steering never fully replaces the pixel's chroma — small colourful
    /// detail (lichen on a wall, fairy lights) must survive a lifted shadow,
    /// so a quarter of the pixel's own colour always remains.
    static let chromaProtectMixCap: Float = 0.75

    // MARK: - Detail stage constants
    //
    // Two spatial passes after the tone stage, both on encoded luma with
    // tanh-limited high-pass terms (the same anti-halo idea as clarity).
    // Sharpen is the counterpart of Lightroom's always-on capture sharpening
    // (amount 40, radius 1.0); texture is the mid-frequency band between
    // sharpen's pixels and clarity's regions. Both default to 0, so neutral
    // renders are untouched.

    /// Sharpen Gaussian sigma as a fraction of the long edge — 1.0 px at the
    /// ultra-wide's 4032, scaling with resolution so preview and export agree.
    static let sharpenSigmaFraction: Float = 1.0 / 4032.0
    static let sharpenStrength: Float = 1.3
    static let sharpenTau: Float = 0.05
    /// Texture sigma — 8 px at 4032.
    static let textureSigmaFraction: Float = 0.002
    static let textureStrength: Float = 0.6
    static let textureTau: Float = 0.35
    /// Colour noise reduction: how far the slider can steer chroma toward
    /// the tonally-similar neighbourhood at full strength — and how far the
    /// neighbourhood itself widens (quarter-res Gaussian sigma) as the
    /// slider rises, because dark-scene chroma noise blobs reach
    /// cobblestone scale.
    static let colorNoiseStrength: Float = 0.9
    static let colorNoiseBlurSigmaMax: Float = 10
    /// Luminance noise reduction: bilateral spatial footprint (pixels) and
    /// the range gate in encoded luma — the base range catches quantisation
    /// grain, the scaled part opens with the slider.
    static let noiseSpatialSigma: Float = 1.4
    static let noiseSpatialRadius: Int = 3
    static let noiseRangeBase: Float = 0.015
    static let noiseRangeScale: Float = 0.1
    /// A strong lift widens the protected window upward: SNR is set at
    /// capture, so the deeper the lift reaches, the higher up the source
    /// axis the chroma stays noise-dominated.
    static let chromaProtectLiftWindowScale: Float = 0.5
    /// Positive vibrance is gated off the darkest *source* luminances —
    /// chroma SNR is fixed at capture, so a hard-lifted dusk shadow is still
    /// noise however bright it renders, and saturating it paints blotches.
    static let vibranceShadowGuardY0: Float = 0.012
    static let vibranceShadowGuardY1: Float = 0.1
    /// Guided-filter edge threshold, in stops² — luminance structure stronger
    /// than ~√ε per window survives into the base (so the lift respects it),
    /// texture below it stays in the detail layer.
    static let guidedFilterEpsilon: Float = 0.6
    /// Log-luma floor for the base computation; 2⁻¹⁴ is below every real
    /// scene value the decoders produce.
    static let baseLumaFloorLog2: Float = -14

    // MARK: - Base look

    /// The engine's hidden base curve, like Lightroom's: neutral must render
    /// the way DNG consumers render by default, not scene-linear-flat.
    /// Fitted by quantile-mapping the engine's linear render of the
    /// calibration frame onto ImageIO's default render of the same DNG
    /// (Apple's "boost" look), so an untouched project keeps the look it has
    /// always had. Encoded domain in, encoded domain out.
    static let baseCurvePoints: [SIMD2<Float>] = [
        SIMD2(0.000, 0.000),
        SIMD2(0.030, 0.022),
        SIMD2(0.075, 0.067),
        SIMD2(0.180, 0.208),
        SIMD2(0.271, 0.349),
        SIMD2(0.357, 0.490),
        SIMD2(0.573, 0.765),
        SIMD2(0.820, 0.933),
        SIMD2(0.898, 0.973),
        SIMD2(1.000, 1.000),
    ]

    /// Monotone cubic (Fritsch–Carlson tangents, harmonic mean) through the
    /// base-curve points. Monotone by construction; extended past 1.0 with
    /// the final segment's tangent so super-white residuals stay compressive.
    static func baseCurve(_ x: Float) -> Float {
        let points = baseCurvePoints
        let count = points.count
        if x <= 0 { return 0 }

        // Secants and monotone tangents.
        var secants = [Float](repeating: 0, count: count - 1)
        for i in 0..<(count - 1) {
            secants[i] = (points[i + 1].y - points[i].y) / (points[i + 1].x - points[i].x)
        }
        var tangents = [Float](repeating: 0, count: count)
        tangents[0] = secants[0]
        tangents[count - 1] = secants[count - 2]
        for i in 1..<(count - 1) {
            let a = secants[i - 1], b = secants[i]
            tangents[i] = (a * b <= 0) ? 0 : 2 * a * b / (a + b)
        }

        if x >= 1 {
            return 1 + (x - 1) * tangents[count - 1]
        }
        var segment = count - 2
        for i in 0..<(count - 1) where x < points[i + 1].x {
            segment = i
            break
        }
        let x0 = points[segment].x, x1 = points[segment + 1].x
        let y0 = points[segment].y, y1 = points[segment + 1].y
        let h = x1 - x0
        let t = (x - x0) / h
        let t2 = t * t, t3 = t2 * t
        return y0 * (2 * t3 - 3 * t2 + 1)
            + tangents[segment] * h * (t3 - 2 * t2 + t)
            + y1 * (-2 * t3 + 3 * t2)
            + tangents[segment + 1] * h * (t3 - t2)
    }

    // MARK: - Highlight recovery (linear domain)

    /// Reinhard compression above a knee. The knee drops and the blend
    /// strengthens as recovery rises, pulling the headroom (values up to ~4)
    /// smoothly under 1.0. C¹ at the knee: value and slope are continuous.
    public static func recoveredLuminance(_ y: Float, recovery: Float) -> Float {
        let r = min(max(recovery, 0), 1)
        let strength = max(r, recoveryBase)
        let knee = 0.95 - 0.6 * r
        guard y > knee else { return y }
        let u = (y - knee) / (1 - knee)
        let compressed = knee + (1 - knee) * u / (1 + u)
        return y + (compressed - y) * strength
    }

    // MARK: - Local tone (base-keyed)

    /// Weight of the shadows move at a given neighbourhood base (log₂ luma):
    /// ≈1 deep in the shadows, rolling to ≈0 by the midtones — and back
    /// toward 0 at the noise floor, where there is nothing to lift.
    public static func shadowWeight(baseLog2: Float) -> Float {
        let body = 1 / (1 + expf((baseLog2 - shadowLocalPivot) / shadowLocalSoft))
        return body * smoothstep(shadowToeLo, shadowToeHi, baseLog2)
    }

    /// Weight of the highlights move: ≈1 in the brightest zones, ≈0 by the
    /// midtones — the mirror of `shadowWeight`.
    public static func highlightWeight(baseLog2: Float) -> Float {
        1 / (1 + expf(-(baseLog2 - highlightLocalPivot) / highlightLocalSoft))
    }

    // MARK: - Tone curve / LUT

    /// The Bernstein-basis bumps: C∞, pinned to zero value *and* slope at both
    /// endpoints, so shadows/highlights never move black or white — that is
    /// whites'/blacks' job. Peak 1 at x = 1/3 and 2/3 respectively; the
    /// maximum slope magnitude of either is 6.75, which bounds the safe
    /// amplitude at 1/6.75 ≈ 0.148.
    static func shadowBump(_ x: Float) -> Float { 6.75 * x * (1 - x) * (1 - x) }
    static func highlightBump(_ x: Float) -> Float { 6.75 * x * x * (1 - x) }

    /// One sample of the tone curve over encoded luminance: the base look
    /// first, then the user's controls on top. Every stage is monotone within
    /// the amplitude bounds above, so the composition is monotone —
    /// `ToneMathTests` sweeps the parameter corners to hold it.
    static func toneCurve(_ x: Float, recipe: GradeRecipe) -> Float {
        let based = baseCurve(max(x, 0))
        let xc = min(based, 1)
        let residual = based - xc

        // Contrast: dual power around the pivot, continuous in value and
        // slope, endpoints pinned.
        let gamma = 1 + contrastStrength * min(max(recipe.contrast, -1), 1)
        let m = contrastPivot
        var y: Float
        if xc < m {
            y = m * powf(xc / m, gamma)
        } else {
            y = 1 - (1 - m) * powf((1 - xc) / (1 - m), gamma)
        }

        y += shadowsAmplitude * recipe.shadows * shadowBump(min(max(y, 0), 1))
        y += highlightsLiftAmplitude * recipe.highlights * highlightBump(min(max(y, 0), 1))
        let yc1 = min(max(y, 0), 1)
        y += whitesAmplitude * recipe.whites * yc1 * yc1 * yc1
        let yc2 = min(max(y, 0), 1)
        let inv = 1 - yc2
        y += blacksAmplitude * recipe.blacks * inv * inv * inv

        return max(y + residual, 0)
    }

    /// The tone curve sampled over [0, 1]. The kernel (and `evaluate`) sample
    /// it with linear interpolation and extrapolate above 1 with the end
    /// slope.
    public static func toneLUT(for recipe: GradeRecipe) -> [Float] {
        (0..<lutSize).map { i in
            toneCurve(Float(i) / Float(lutSize - 1), recipe: recipe)
        }
    }

    static func sampleLUT(_ lut: [Float], at x: Float) -> Float {
        let n = lut.count
        if x >= 1 {
            let endSlope = (lut[n - 1] - lut[n - 2]) * Float(n - 1)
            return lut[n - 1] + (x - 1) * endSlope
        }
        let clamped = max(x, 0)
        let position = clamped * Float(n - 1)
        let index = min(Int(position), n - 2)
        let fraction = position - Float(index)
        return lut[index] * (1 - fraction) + lut[index + 1] * fraction
    }

    // MARK: - Full per-pixel mirror

    static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The whole per-pixel pipeline, mirroring the GPU kernel exactly. Used by
    /// the parity tests and by nothing else — production pixels go through
    /// Metal.
    ///
    /// `baseLog2` is the neighbourhood base the kernel reads from its guided
    /// filter texture; `smoothed` is the neighbourhood-averaged post-WB
    /// linear RGB it reads for chroma protection. Both default to the pixel's
    /// own values — exactly what the spatial passes yield on a flat region,
    /// which is how the uniform-image parity test pins the full GPU path to
    /// this function.
    public static func evaluate(
        _ rgb: SIMD3<Float>,
        recipe: GradeRecipe,
        whiteBalance: simd_float3x3,
        lut: [Float],
        baseLog2: Float? = nil,
        smoothed: SIMD3<Float>? = nil
    ) -> SIMD3<Float> {
        var v = whiteBalance * rgb
        v = simd_max(v * exp2(recipe.exposure), SIMD3<Float>(repeating: 0))

        let y = max(simd_dot(v, lumaWeights), 1e-6)
        let l = log2(max(y, exp2(baseLumaFloorLog2)))
        let base = baseLog2 ?? l

        // Local stage: EV offsets keyed on the neighbourhood base. All three
        // terms are zero at slider zero, so neutral never touches this.
        var shadowLiftEV: Float = 0
        var y1 = y
        if recipe.shadows != 0 || recipe.highlights != 0 || recipe.clarity != 0 {
            shadowLiftEV = shadowLocalEV * recipe.shadows * shadowWeight(baseLog2: base)
            let highlightAmp = recipe.highlights >= 0 ? highlightLiftEV : highlightCutEV
            let highlightEV = highlightAmp * recipe.highlights * highlightWeight(baseLog2: base)
            let gc = min(max(powf(y, encodeGamma), 0), 1)
            let midweight = 4 * gc * (1 - gc)
            let detail = l - base
            let limited = clarityTauStops * tanhf(detail / clarityTauStops)
            let clarityEV = clarityDetailGain * recipe.clarity * midweight * limited
            y1 = y * exp2(shadowLiftEV + highlightEV + clarityEV)
        }

        let recovery = max(-recipe.highlights, 0)
        y1 = recoveredLuminance(y1, recovery: recovery)
        let g = powf(y1, encodeGamma)
        let mapped = sampleLUT(lut, at: g)
        let y2 = powf(max(mapped, 0), 1 / encodeGamma)

        // Hue-preserving application — except where a hard lift meets a deep,
        // noisy shadow: there the honest chroma is the neighbourhood's, not
        // the pixel's.
        var ratios = v / y
        if shadowLiftEV > 0 || recipe.blacks > 0 {
            let s = smoothed ?? v
            let sy = max(simd_dot(s, lumaWeights), 1e-6)
            let liftAmount = (exp2(max(shadowLiftEV, 0)) - 1) * chromaProtectShadowScale
                + max(recipe.blacks, 0) * chromaProtectBlacksScale
            let windowScale = exp2(max(shadowLiftEV, 0) * chromaProtectLiftWindowScale)
            let deep = 1 - smoothstep(
                chromaProtectDeepY0 * windowScale, chromaProtectDeepY1 * windowScale, y)
            let mixAmount = min(max(liftAmount, 0), chromaProtectMixCap) * deep
            let neighbourhoodLog = log2(max(sy, exp2(baseLumaFloorLog2)))
            let similarity = min(max(1 - abs(l - neighbourhoodLog) / chromaSimilaritySpanStops, 0), 1)
            let trust = similarity * smoothstep(chromaTrustFloorLo, chromaTrustFloorHi, neighbourhoodLog)
            // The no-trust fallback is the WHITE-BALANCED neutral, not display
            // grey — a warmed image must stay warm in its protected shadows,
            // or the lift renders them cold while the rest of the frame
            // carries the user's temperature move.
            let white = whiteBalance * SIMD3<Float>(repeating: 1)
            let neutralRatios = white / max(simd_dot(white, lumaWeights), 1e-6)
            let target = neutralRatios + (s / sy - neutralRatios) * trust
            ratios = ratios + (target - ratios) * mixAmount
        }
        // Colour noise reduction: the same neighbourhood chroma, as a control
        // rather than a lift-triggered guard — global, but gated by tonal
        // similarity so edges (and point lights) keep their own colour.
        if recipe.colorNoiseReduction > 0 {
            let s = smoothed ?? v
            let sy = max(simd_dot(s, lumaWeights), 1e-6)
            let neighbourhoodLog = log2(max(sy, exp2(baseLumaFloorLog2)))
            let similarity = min(max(1 - abs(l - neighbourhoodLog) / chromaSimilaritySpanStops, 0), 1)
            let amount = colorNoiseStrength * recipe.colorNoiseReduction * similarity
            ratios = ratios + (s / sy - ratios) * amount
        }
        var out = ratios * y2

        // Desaturation: a constant gentle floor near white (the neutral look,
        // unchanged), plus a clip-targeted term that only engages where a
        // channel actually runs past the display ceiling under recovery — so
        // pulling Highlights down keeps a sunset's colour instead of greying
        // it.
        var desat = desatStrength * recoveryBase * smoothstep(0.7, 1.0, y2)
        let maxPre = max(out.x, max(out.y, out.z))
        desat += desatStrength * recovery * smoothstep(1.0, 1.3, maxPre)
        desat = min(desat, 1)
        out = out + (SIMD3<Float>(repeating: y2) - out) * desat

        let maxChannel = max(out.x, max(out.y, out.z))
        let minChannel = min(out.x, min(out.y, out.z))
        let satMeasure = min(max((maxChannel - minChannel) / max(maxChannel, 1e-4), 0), 1)
        let luma = simd_dot(out, lumaWeights)
        var vibranceEffect = vibranceStrength * recipe.vibrance
        if vibranceEffect > 0 {
            vibranceEffect *= smoothstep(vibranceShadowGuardY0, vibranceShadowGuardY1, y)
        }
        let gain = (1 + saturationStrength * recipe.saturation)
            * (1 + vibranceEffect * (1 - satMeasure))
        out = SIMD3<Float>(repeating: luma) + (out - SIMD3<Float>(repeating: luma)) * gain

        out = simd_clamp(out, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
        if out.x.isNaN { out.x = 0 }
        if out.y.isNaN { out.y = 0 }
        if out.z.isNaN { out.z = 0 }
        return out
    }

    // MARK: - White balance

    /// CIE xy chromaticity of a Planckian (blackbody) illuminant, via the Kim
    /// et al. cubic spline approximations. Valid 1667–25000 K.
    static func planckianXY(kelvin: Double) -> SIMD2<Double> {
        let t = min(max(kelvin, 1667), 25000)
        let x: Double
        if t <= 4000 {
            x = -0.2661239e9 / (t * t * t) - 0.2343589e6 / (t * t) + 0.8776956e3 / t + 0.179910
        } else {
            x = -3.0258469e9 / (t * t * t) + 2.1070379e6 / (t * t) + 0.2226347e3 / t + 0.240390
        }
        let y: Double
        if t <= 2222 {
            y = -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
        } else if t <= 4000 {
            y = -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
        } else {
            y = 3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483
        }
        return SIMD2<Double>(x, y)
    }

    /// A white point in XYZ (Y = 1) for an illuminant temperature, with the
    /// tint slider as a green–magenta offset off the locus (positive tint =
    /// magenta = less green = lower y).
    static func whitePointXYZ(kelvin: Double, tint: Double) -> SIMD3<Double> {
        var xy = planckianXY(kelvin: kelvin)
        xy.y = min(max(xy.y - 0.05 * tint, 0.01), 0.9)
        return SIMD3<Double>(xy.x / xy.y, 1, (1 - xy.x - xy.y) / xy.y)
    }

    // Bradford chromatic adaptation.
    static let bradford = simd_double3x3(rows: [
        SIMD3<Double>(0.8951, 0.2664, -0.1614),
        SIMD3<Double>(-0.7502, 1.7135, 0.0367),
        SIMD3<Double>(0.0389, -0.0685, 1.0296),
    ])

    // Display P3 (D65) ↔ XYZ.
    static let p3ToXYZ = simd_double3x3(rows: [
        SIMD3<Double>(0.4865709, 0.2656677, 0.1982173),
        SIMD3<Double>(0.2289746, 0.6917385, 0.0792869),
        SIMD3<Double>(0.0000000, 0.0451134, 1.0439444),
    ])

    /// The 3×3 the kernel applies for the temperature/tint sliders, in
    /// Display P3. Semantics follow the app's existing white-balance control
    /// (and Lightroom's): the sliders *declare* the scene's illuminant, and
    /// the matrix adapts from that declared white to the as-shot white — so a
    /// positive mired offset (declared illuminant bluer... i.e. higher K)
    /// renders the image warmer.
    public static func whiteBalanceMatrix(recipe: GradeRecipe, reference: GradeReference) -> simd_float3x3 {
        guard recipe.temperatureMired != 0 || recipe.tint != 0 else {
            return matrix_identity_float3x3
        }
        let asShotK = min(max(reference.asShotTemperatureK, 1667), 25000)
        let asShotMired = 1e6 / asShotK
        // Positive offset → lower mired → higher declared Kelvin → warmer.
        let declaredMired = min(max(asShotMired - Double(recipe.temperatureMired), 40), 600)
        let declaredK = 1e6 / declaredMired

        let source = whitePointXYZ(kelvin: declaredK, tint: Double(recipe.tint))
        let destination = whitePointXYZ(kelvin: asShotK, tint: 0)

        let sourceCone = bradford * source
        let destinationCone = bradford * destination
        let scale = simd_double3x3(diagonal: SIMD3<Double>(
            destinationCone.x / sourceCone.x,
            destinationCone.y / sourceCone.y,
            destinationCone.z / sourceCone.z))
        let adapt = bradford.inverse * scale * bradford
        let full = p3ToXYZ.inverse * adapt * p3ToXYZ
        return simd_float3x3(
            SIMD3<Float>(full.columns.0),
            SIMD3<Float>(full.columns.1),
            SIMD3<Float>(full.columns.2))
    }
}

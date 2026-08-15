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
///     → highlight recovery on the luminance, in linear (Reinhard above a
///       knee — a per-pixel function of the pixel's own value, so halos are
///       impossible by construction)
///     → the tone LUT on gamma-encoded luminance (contrast, shadows,
///       highlights-lift, whites, blacks — built monotone by construction)
///     → luminance-ratio application (hue-preserving) with controlled
///       highlight desaturation
///     → vibrance + saturation → clamp.
///
/// Clarity and vignette are separate spatial passes in the kernel file; they
/// have no CPU mirror because they aren't per-pixel functions.
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
    /// The shadows slider's linear-domain half: a rolled-off gain that lifts
    /// deep shadows up to ~1 EV at +100 while leaving highlights alone —
    /// the encoded-domain bump alone is capped too low (by its monotonicity
    /// bound) to reach Lightroom-strength lifts.
    static let shadowLinearStrength: Float = 0.9
    static let shadowSigma: Float = 0.16

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
    public static func evaluate(
        _ rgb: SIMD3<Float>,
        recipe: GradeRecipe,
        whiteBalance: simd_float3x3,
        lut: [Float]
    ) -> SIMD3<Float> {
        var v = whiteBalance * rgb
        v = simd_max(v * exp2(recipe.exposure), SIMD3<Float>(repeating: 0))

        let y = max(simd_dot(v, lumaWeights), 1e-6)
        let recovery = max(-recipe.highlights, 0)
        var y1 = recoveredLuminance(y, recovery: recovery)
        if recipe.shadows != 0 {
            let gain = shadowLinearStrength * recipe.shadows
            y1 *= 1 + gain * shadowSigma / (shadowSigma + y1)
        }
        let g = powf(y1, encodeGamma)
        let mapped = sampleLUT(lut, at: g)
        let y2 = powf(max(mapped, 0), 1 / encodeGamma)

        var out = v * (y2 / y)
        let desat = desatStrength * max(recovery, recoveryBase) * smoothstep(0.7, 1.0, y2)
        out = out + (SIMD3<Float>(repeating: y2) - out) * desat

        let maxChannel = max(out.x, max(out.y, out.z))
        let minChannel = min(out.x, min(out.y, out.z))
        let satMeasure = min(max((maxChannel - minChannel) / max(maxChannel, 1e-4), 0), 1)
        let gain = (1 + saturationStrength * recipe.saturation)
            * (1 + vibranceStrength * recipe.vibrance * (1 - satMeasure))
        let luma = simd_dot(out, lumaWeights)
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

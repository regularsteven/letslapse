import Foundation

/// The tone engine's Metal source, compiled at runtime exactly like
/// `BlendKernels.metal`. Kept as a single Swift string — one source of truth,
/// no bundled twin to drift from. The math mirrors `ToneMath` operation for
/// operation (including every literal constant); the parity tests hold the
/// two together.
///
/// Passes, in encode order:
///   basePrep        — 4×4 box downsample of the post-WB/exposure image to a
///                     quarter-res RGB+log₂luma texture, plus the guided
///                     filter's first moments (l, l²).
///   blurPair2 (×2)  — separable Gaussian on two-channel textures: once for
///                     the moments, once for the guided coefficients.
///   guidedAB        — a = var/(var+ε), b = mean·(1−a).
///   guidedResolve   — base = mean(a)·l + mean(b): the edge-aware base layer.
///   gradeTone       — the whole per-pixel pipeline, sampling base +
///                     neighbourhood chroma.
///   applyLumaNoise  — frequency split on encoded luma: Gaussian base kept
///                     whole, soft-thresholded detail residual.
///   applyChromaNR   — spatial-only Gaussian on Cb/Cr, Y carried through.
///   applyVignette   — unchanged.
///   finalizeDither  — TPDF dither at 1/255, for 8-bit destinations only.
enum GradeKernelSource {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    constant float3 kLuma = float3(0.2289746, 0.6917385, 0.0792869);

    // Local-tone constants — mirror ToneMath exactly.
    constant float kShadowLocalEV = 2.6;
    constant float kShadowPivot = -3.0;
    constant float kShadowSoft = 1.6;
    constant float kShadowToeLo = -12.0;
    constant float kShadowToeHi = -8.0;
    constant float kHighlightPivot = -0.8;
    constant float kHighlightSoft = 0.9;
    constant float kClarityTau = 0.6;
    constant float kChromaDeepY0 = 0.008;
    constant float kChromaDeepY1 = 0.035;
    constant float kChromaShadowScale = 0.8;
    constant float kChromaBlacksScale = 1.2;
    constant float kChromaSimilaritySpan = 1.5;
    constant float kChromaTrustFloorLo = -11.0;
    constant float kChromaTrustFloorHi = -8.0;
    constant float kChromaLiftWindowScale = 0.5;
    constant float kChromaMixCap = 0.75;
    constant float kVibranceGuardY0 = 0.012;
    constant float kVibranceGuardY1 = 0.1;
    constant float kBaseLumaFloorLog2 = -14.0;
    constant float kSharpenEdgeThreshold = 0.08;
    constant float kFrequencySplitMaxThreshold = 0.12;
    constant float kFrequencySplitDetailReach = 0.8;
    constant float kFrequencySplitEdgeProtect = 0.9;
    constant float kFrequencySplitEdgeKnee = 0.08;

    // Chroma NR works in BT.709 YCbCr — the standard full-range matrix and its
    // exact inverse, so amount 0 round-trips to the value it started with.
    constant float3 kRec709Luma = float3(0.2126, 0.7152, 0.0722);
    constant float kCbScale = 1.0 / 1.8556;
    constant float kCrScale = 1.0 / 1.5748;
    constant float kCrToR = 1.5748;
    constant float kCbToG = -0.187324;
    constant float kCrToG = -0.468124;
    constant float kCbToB = 1.8556;
    /// The chroma Gaussian's sigma as a fraction of its tap radius — the
    /// window reaches 2σ, which is where the weights stop mattering.
    constant float kChromaNRSigmaScale = 0.5;

    struct GradeParams {
        float3x3 wb;             // white-balance matrix, Display P3
        float3 wbNeutral;        // luma-normalised wb * white — the warmed grey
        float exposureGain;      // 2^EV
        float kneeK;             // 0.95 - 0.6 * recovery
        float recoveryStrength;  // max(recovery, recoveryBase)
        float desatFloor;        // 0.5 * recoveryBase — the neutral look
        float clipDesat;         // 0.5 * recovery — engages only past clip
        float saturationGain;    // 1 + 0.8 * saturation
        float vibranceCoeff;     // 0.9 * vibrance
        float lutEndSlope;       // extrapolation slope above encoded 1.0
        uint  lutSize;
        float shadowEV;          // 2.6 * shadows
        float highlightEV;       // (h>=0 ? 1.2 : 2.0) * highlights
        float clarityGain;       // 0.9 * clarity
        float blacksLift;        // max(blacks, 0)
        uint  usesBase;          // any of shadows/highlights/clarity non-zero
        uint  chromaProtect;     // shadows > 0 || blacks > 0
        float colorNoise;        // 0.9 * colorNoiseReduction
    };

    static inline float lutSample(constant float *lut, uint n, float endSlope, float g)
    {
        if (g >= 1.0) {
            return lut[n - 1] + (g - 1.0) * endSlope;
        }
        float position = max(g, 0.0) * float(n - 1);
        uint index = min(uint(position), n - 2);
        float fraction = position - float(index);
        return mix(lut[index], lut[index + 1], fraction);
    }

    // Scene-linear in, display-referred [0,1] linear out. Tonal moves are
    // keyed on the guided-filter base — the neighbourhood, not the pixel —
    // so Shadows reaches only dark regions and Highlights only bright ones;
    // the edge-aware base is what keeps that halo-free.
    kernel void gradeTone(
        texture2d<float, access::read> source [[texture(0)]],
        texture2d<float, access::write> destination [[texture(1)]],
        texture2d<float, access::sample> baseTexture [[texture(2)]],
        texture2d<float, access::sample> quarter [[texture(3)]],
        constant GradeParams &p [[buffer(0)]],
        constant float *toneLUT [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
            return;
        }
        constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 uv = (float2(gid) + 0.5)
            / float2(destination.get_width(), destination.get_height());

        float3 v = p.wb * source.read(gid).rgb;
        v = max(v * p.exposureGain, 0.0);

        float y = max(dot(v, kLuma), 1e-6);
        float l = log2(max(y, exp2(kBaseLumaFloorLog2)));

        float shadowLiftEV = 0.0;
        float y1 = y;
        if (p.usesBase != 0) {
            float base = baseTexture.sample(linearSampler, uv).r;
            float shadowW = 1.0 / (1.0 + exp((base - kShadowPivot) / kShadowSoft));
            shadowW *= smoothstep(kShadowToeLo, kShadowToeHi, base);
            float highlightW = 1.0 / (1.0 + exp(-(base - kHighlightPivot) / kHighlightSoft));
            shadowLiftEV = p.shadowEV * shadowW;
            float highlightEV = p.highlightEV * highlightW;
            float gc = clamp(pow(y, 1.0 / 2.2), 0.0, 1.0);
            float midweight = 4.0 * gc * (1.0 - gc);
            float detail = l - base;
            float limited = kClarityTau * tanh(detail / kClarityTau);
            float clarityEV = p.clarityGain * midweight * limited;
            y1 = y * exp2(shadowLiftEV + highlightEV + clarityEV);
        }

        if (y1 > p.kneeK) {
            float u = (y1 - p.kneeK) / (1.0 - p.kneeK);
            float compressed = p.kneeK + (1.0 - p.kneeK) * u / (1.0 + u);
            y1 = y1 + (compressed - y1) * p.recoveryStrength;
        }
        float g = pow(y1, 1.0 / 2.2);
        float mapped = lutSample(toneLUT, p.lutSize, p.lutEndSlope, g);
        float y2 = pow(max(mapped, 0.0), 2.2);

        float3 ratios = v / y;
        if (p.chromaProtect != 0) {
            float3 s = quarter.sample(linearSampler, uv).rgb;
            float sy = max(dot(s, kLuma), 1e-6);
            float liftAmount = (exp2(max(shadowLiftEV, 0.0)) - 1.0) * kChromaShadowScale
                + p.blacksLift * kChromaBlacksScale;
            float windowScale = exp2(max(shadowLiftEV, 0.0) * kChromaLiftWindowScale);
            float deep = 1.0 - smoothstep(kChromaDeepY0 * windowScale, kChromaDeepY1 * windowScale, y);
            float mixAmount = clamp(liftAmount, 0.0, kChromaMixCap) * deep;
            float neighbourhoodLog = log2(max(sy, exp2(kBaseLumaFloorLog2)));
            float similarity = clamp(1.0 - abs(l - neighbourhoodLog) / kChromaSimilaritySpan, 0.0, 1.0);
            float trust = similarity * smoothstep(kChromaTrustFloorLo, kChromaTrustFloorHi, neighbourhoodLog);
            float3 target = mix(p.wbNeutral, s / sy, trust);
            ratios = mix(ratios, target, mixAmount);
        }
        if (p.colorNoise > 0.0) {
            float3 s = quarter.sample(linearSampler, uv).rgb;
            float sy = max(dot(s, kLuma), 1e-6);
            float neighbourhoodLog = log2(max(sy, exp2(kBaseLumaFloorLog2)));
            float similarity = clamp(1.0 - abs(l - neighbourhoodLog) / kChromaSimilaritySpan, 0.0, 1.0);
            ratios = mix(ratios, s / sy, p.colorNoise * similarity);
        }
        float3 outv = ratios * y2;

        float d = p.desatFloor * smoothstep(0.7, 1.0, y2);
        float maxPre = max(outv.r, max(outv.g, outv.b));
        d += p.clipDesat * smoothstep(1.0, 1.3, maxPre);
        d = min(d, 1.0);
        outv = mix(outv, float3(y2), d);

        float maxc = max(outv.r, max(outv.g, outv.b));
        float minc = min(outv.r, min(outv.g, outv.b));
        float satM = clamp((maxc - minc) / max(maxc, 1e-4), 0.0, 1.0);
        float L = dot(outv, kLuma);
        float vibranceEffect = p.vibranceCoeff;
        if (vibranceEffect > 0.0) {
            vibranceEffect *= smoothstep(kVibranceGuardY0, kVibranceGuardY1, y);
        }
        float gain = p.saturationGain * (1.0 + vibranceEffect * (1.0 - satM));
        outv = L + (outv - L) * gain;

        outv = clamp(outv, 0.0, 1.0);
        outv = select(outv, float3(0.0), isnan(outv));
        destination.write(float4(outv, 1.0), gid);
    }

    // Quarter-res prep: box-average the post-WB/exposure linear RGB (the
    // neighbourhood chroma for protection), carry log₂ luma in alpha, and
    // seed the guided filter's moments. One read of the full image feeds
    // everything spatial.
    kernel void basePrep(
        texture2d<float, access::read> source [[texture(0)]],
        texture2d<float, access::write> quarter [[texture(1)]],
        texture2d<float, access::write> moments [[texture(2)]],
        constant GradeParams &p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= quarter.get_width() || gid.y >= quarter.get_height()) {
            return;
        }
        uint2 limit = uint2(source.get_width() - 1, source.get_height() - 1);
        float3 sum = float3(0.0);
        for (uint dy = 0; dy < 4; dy++) {
            for (uint dx = 0; dx < 4; dx++) {
                uint2 coordinate = min(gid * 4 + uint2(dx, dy), limit);
                sum += source.read(coordinate).rgb;
            }
        }
        float3 v = max((p.wb * (sum * 0.0625)) * p.exposureGain, 0.0);
        float y = max(dot(v, kLuma), exp2(kBaseLumaFloorLog2));
        float l = log2(y);
        quarter.write(float4(v, l), gid);
        moments.write(float4(l, l * l, 0.0, 1.0), gid);
    }

    struct BlurParams {
        float sigma;    // Gaussian sigma, in quarter-res pixels
        int   radius;   // tap radius
    };

    static inline float2 blurTap2(
        texture2d<float, access::read> source, int2 coordinate, int2 limit)
    {
        int2 clamped = clamp(coordinate, int2(0), limit);
        return source.read(uint2(clamped)).rg;
    }

    kernel void blurHorizontal2(
        texture2d<float, access::read> source [[texture(0)]],
        texture2d<float, access::write> destination [[texture(1)]],
        constant BlurParams &p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
            return;
        }
        int2 limit = int2(source.get_width() - 1, source.get_height() - 1);
        float twoSigmaSq = 2.0 * p.sigma * p.sigma;
        float2 sum = float2(0.0);
        float weightSum = 0.0;
        for (int dx = -p.radius; dx <= p.radius; dx++) {
            float w = exp(-float(dx * dx) / twoSigmaSq);
            sum += w * blurTap2(source, int2(gid) + int2(dx, 0), limit);
            weightSum += w;
        }
        destination.write(float4(sum / weightSum, 0.0, 1.0), gid);
    }

    kernel void blurVertical2(
        texture2d<float, access::read> source [[texture(0)]],
        texture2d<float, access::write> destination [[texture(1)]],
        constant BlurParams &p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
            return;
        }
        int2 limit = int2(source.get_width() - 1, source.get_height() - 1);
        float twoSigmaSq = 2.0 * p.sigma * p.sigma;
        float2 sum = float2(0.0);
        float weightSum = 0.0;
        for (int dy = -p.radius; dy <= p.radius; dy++) {
            float w = exp(-float(dy * dy) / twoSigmaSq);
            sum += w * blurTap2(source, int2(gid) + int2(0, dy), limit);
            weightSum += w;
        }
        destination.write(float4(sum / weightSum, 0.0, 1.0), gid);
    }

    // Four-channel separable blur, for widening the neighbourhood-chroma
    // texture: colour noise in a pushed dark scene lives at every scale up to
    // whole cobblestones, so the smoothing footprint follows the slider.
    kernel void blurHorizontal4(
        texture2d<float, access::read> source [[texture(0)]],
        texture2d<float, access::write> destination [[texture(1)]],
        constant BlurParams &p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
            return;
        }
        int2 limit = int2(source.get_width() - 1, source.get_height() - 1);
        float twoSigmaSq = 2.0 * p.sigma * p.sigma;
        float4 sum = float4(0.0);
        float weightSum = 0.0;
        for (int dx = -p.radius; dx <= p.radius; dx++) {
            int2 clamped = clamp(int2(gid) + int2(dx, 0), int2(0), limit);
            float w = exp(-float(dx * dx) / twoSigmaSq);
            sum += w * source.read(uint2(clamped));
            weightSum += w;
        }
        destination.write(sum / weightSum, gid);
    }

    kernel void blurVertical4(
        texture2d<float, access::read> source [[texture(0)]],
        texture2d<float, access::write> destination [[texture(1)]],
        constant BlurParams &p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
            return;
        }
        int2 limit = int2(source.get_width() - 1, source.get_height() - 1);
        float twoSigmaSq = 2.0 * p.sigma * p.sigma;
        float4 sum = float4(0.0);
        float weightSum = 0.0;
        for (int dy = -p.radius; dy <= p.radius; dy++) {
            int2 clamped = clamp(int2(gid) + int2(0, dy), int2(0), limit);
            float w = exp(-float(dy * dy) / twoSigmaSq);
            sum += w * source.read(uint2(clamped));
            weightSum += w;
        }
        destination.write(sum / weightSum, gid);
    }

    struct GuidedParams {
        float epsilon;  // variance floor, stops²
    };

    // Guided-filter coefficients from the blurred moments: flat regions
    // (variance ≪ ε) take the local mean, strong edges (variance ≫ ε) keep
    // the signal — which is exactly "smooth the texture, respect the edges".
    kernel void guidedAB(
        texture2d<float, access::read> blurredMoments [[texture(0)]],
        texture2d<float, access::write> coefficients [[texture(1)]],
        constant GuidedParams &p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= coefficients.get_width() || gid.y >= coefficients.get_height()) {
            return;
        }
        float2 m = blurredMoments.read(gid).rg;
        float variance = max(m.g - m.r * m.r, 0.0);
        float a = variance / (variance + p.epsilon);
        float b = m.r * (1.0 - a);
        coefficients.write(float4(a, b, 0.0, 1.0), gid);
    }

    kernel void guidedResolve(
        texture2d<float, access::read> blurredCoefficients [[texture(0)]],
        texture2d<float, access::read> quarter [[texture(1)]],
        texture2d<float, access::write> baseTexture [[texture(2)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= baseTexture.get_width() || gid.y >= baseTexture.get_height()) {
            return;
        }
        float2 ab = blurredCoefficients.read(gid).rg;
        float l = quarter.read(gid).a;
        baseTexture.write(float4(ab.r * l + ab.g, 0.0, 0.0, 1.0), gid);
    }

    struct DetailParams {
        float amount;   // signed detail gain
        float tau;      // tanh limiter, encoded domain; luma NR reads it as
                        // the Detail slider raw (0…1 detail preservation)
        float sigma;    // Gaussian sigma at the blur's resolution
        float mask;     // sharpen only: how far the edge mask gates `amount`
        int   radius;   // tap radius
    };

    struct ColorNoiseParams {
        float amount;   // 0 = pass-through, 1 = take the neighbourhood mean
        int   radius;   // tap radius, already scaled to the render
    };

    // Half-resolution encoded luma of the graded image — the texture band's
    // blur source (the mid-frequency sibling of the guided base).
    kernel void detailLuma(
        texture2d<float, access::read> source [[texture(0)]],
        texture2d<float, access::write> destination [[texture(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
            return;
        }
        uint2 limit = uint2(source.get_width() - 1, source.get_height() - 1);
        float3 sum = float3(0.0);
        for (uint dy = 0; dy < 2; dy++) {
            for (uint dx = 0; dx < 2; dx++) {
                uint2 coordinate = min(gid * 2 + uint2(dx, dy), limit);
                sum += source.read(coordinate).rgb;
            }
        }
        float y = max(dot(sum * 0.25, kLuma), 0.0);
        destination.write(float4(pow(y, 1.0 / 2.2), 0.0, 0.0, 1.0), gid);
    }

    // Texture: mid-frequency luma detail against the blurred half-res base,
    // tanh-limited so edges saturate instead of haloing, mid-weighted so
    // black and white stay pinned. Negative amount smooths the band.
    kernel void applyTexture(
        texture2d<float, access::read> graded [[texture(0)]],
        texture2d<float, access::sample> blurred [[texture(1)]],
        texture2d<float, access::write> destination [[texture(2)]],
        constant DetailParams &p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
            return;
        }
        constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 uv = (float2(gid) + 0.5)
            / float2(destination.get_width(), destination.get_height());
        float3 v = graded.read(gid).rgb;
        float y = max(dot(v, kLuma), 1e-6);
        float g = pow(y, 1.0 / 2.2);
        float base = blurred.sample(linearSampler, uv).r;
        float limited = p.tau * tanh((g - base) / p.tau);
        float gc = clamp(g, 0.0, 1.0);
        float midweight = 4.0 * gc * (1.0 - gc);
        float g2 = g + p.amount * midweight * limited;
        float ratio = pow(max(g2, 0.0), 2.2) / y;
        float3 outv = clamp(v * ratio, 0.0, 1.0);
        outv = select(outv, float3(0.0), isnan(outv));
        destination.write(float4(outv, 1.0), gid);
    }

    // Luminance noise reduction: a frequency split on encoded luma.
    //
    // A bilateral — which is what this pass used to be — attacks every pixel
    // inside its range gate with the same force, so pushing it hard blurs
    // across whole structures and the picture goes to watercolour. The split
    // instead separates encoded luma into a spatial-only Gaussian *base* (the
    // coarse structure) and a *detail* residual (fine grain plus edges), and
    // only ever touches the detail. Coarse structure therefore survives at any
    // amount; what collapses is the fine layer, which is where grain lives.
    //
    // There is no range gate, and none is wanted. Edge selectivity mostly falls
    // out of the split for free: on an edge the local average is pulled toward
    // the blend of both sides, so `detail` is large there, clears the soft
    // threshold, and comes through nearly intact. What the split does NOT get
    // for free is the fine structure *riding on* an edge, whose residual is
    // small and gets shrunk like grain — so the threshold is additionally
    // modulated by the base layer's own gradient (see below).
    //
    // `amount` sets both how far the shrink is mixed in and how big the
    // threshold gets; `tau` carries the Detail sub-slider raw (0…1, 0.5
    // neutral) as detail *preservation* — higher keeps more of the fine layer,
    // matching what Lightroom's Detail slider does. `sigma`/`radius` arrive
    // already scaled to the render, so a preview smooths the same picture as
    // the export. Luma-ratio application leaves chroma to the colour-noise
    // control.
    kernel void applyLumaNoise(
        texture2d<float, access::read> graded [[texture(0)]],
        texture2d<float, access::write> destination [[texture(1)]],
        constant DetailParams &p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
            return;
        }
        int2 limit = int2(graded.get_width() - 1, graded.get_height() - 1);
        float3 v = graded.read(gid).rgb;
        float y = max(dot(v, kLuma), 1e-6);
        float g = pow(y, 1.0 / 2.2);
        float twoSigmaSq = 2.0 * p.sigma * p.sigma;
        float sum = 0.0;
        float weightSum = 0.0;
        float gxSum = 0.0;
        float gySum = 0.0;
        for (int dy = -p.radius; dy <= p.radius; dy++) {
            for (int dx = -p.radius; dx <= p.radius; dx++) {
                int2 coordinate = clamp(int2(gid) + int2(dx, dy), int2(0), limit);
                float yTap = max(dot(graded.read(uint2(coordinate)).rgb, kLuma), 0.0);
                float w = exp(-float(dx * dx + dy * dy) / twoSigmaSq);
                float gTap = pow(yTap, 1.0 / 2.2);
                sum += w * gTap;
                weightSum += w;
                // Derivative-of-Gaussian, accumulated from the taps the base
                // layer is already reading: ∂/∂x (w * g) = ((dx/σ²) w) * g, so
                // the base's own gradient costs two multiply-adds per tap and
                // not one extra texture read. Taking the gradient of the BASE
                // rather than of `g` is the point — the base is smooth, so
                // grain cannot fake an edge and turn its own denoising off.
                gxSum += w * float(dx) * gTap;
                gySum += w * float(dy) * gTap;
            }
        }
        float base = sum / weightSum;
        float detail = g - base;
        // Soft threshold (wavelet shrinkage): everything under the knee goes to
        // zero, everything over it keeps its excess, so the transition is
        // gradual rather than a hard gate that would leave its own texture.
        float keep = clamp(p.tau, 0.0, 1.0);
        float threshold = p.amount * kFrequencySplitMaxThreshold
            * (1.0 - kFrequencySplitDetailReach * keep);
        // Edge-aware threshold. The split already lets a *step* through — the
        // cross-edge average makes `detail` large there — but the fine
        // structure riding on and beside that step is small, and the shrink
        // subtracts from it exactly as if it were grain, which is where the
        // few percent of edge contrast went. So the knee itself backs off
        // where the base layer is steep: flat regions keep the full threshold
        // and denoise at full strength, edges keep a tenth of it and pass
        // their residuals through nearly intact.
        //
        // The magnitude is a per-pixel slope of the base, in encoded luma.
        // Smoothing spreads a step of height h over σ, so its peak slope is
        // about h/(σ√2π) — a hard edge lands around 0.08–0.2 and a soft one
        // around 0.02–0.04, which is what the knee is placed against.
        float invSigmaSq = 1.0 / max(p.sigma * p.sigma, 1e-6);
        float gx = gxSum * invSigmaSq / weightSum;
        float gy = gySum * invSigmaSq / weightSum;
        float baseMag = sqrt(gx * gx + gy * gy);
        float edgeWeight = smoothstep(0.0, kFrequencySplitEdgeKnee, baseMag)
            * kFrequencySplitEdgeProtect;
        threshold *= 1.0 - edgeWeight;
        float shrunk = sign(detail) * max(abs(detail) - threshold, 0.0);
        float g2 = base + mix(detail, shrunk, p.amount);
        float ratio = pow(max(g2, 0.0), 2.2) / y;
        float3 outv = clamp(v * ratio, 0.0, 1.0);
        outv = select(outv, float3(0.0), isnan(outv));
        destination.write(float4(outv, 1.0), gid);
    }

    // Chroma noise reduction: a spatial-only Gaussian on Cb/Cr, luma untouched.
    //
    // Colour noise is the mottle a pushed sensor paints over everything —
    // purple haze in the shadows, green/magenta speckle across flat surfaces —
    // and unlike luma grain it carries no structure worth protecting, so the
    // weights key on distance alone. A range gate here would be actively
    // wrong: the blotches ARE the large chroma excursions a bilateral would
    // preserve. Y comes through untouched, so every edge and every bit of fine
    // detail the luma passes shaped survives the pass unchanged.
    kernel void applyChromaNR(
        texture2d<float, access::read> graded [[texture(0)]],
        texture2d<float, access::write> destination [[texture(1)]],
        constant ColorNoiseParams &p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
            return;
        }
        float3 v = graded.read(gid).rgb;
        if (p.amount <= 0.0) {
            // Neutral costs nothing and rounds nothing — the pass-through is
            // the source bits, not a YCbCr round trip that lands near them.
            destination.write(float4(v, 1.0), gid);
            return;
        }
        int2 limit = int2(graded.get_width() - 1, graded.get_height() - 1);
        float sigma = max(float(p.radius) * kChromaNRSigmaScale, 0.5);
        float twoSigmaSq = 2.0 * sigma * sigma;
        float y = dot(v, kRec709Luma);
        float cb = (v.b - y) * kCbScale;
        float cr = (v.r - y) * kCrScale;
        float2 sum = float2(0.0);
        float weightSum = 0.0;
        for (int dy = -p.radius; dy <= p.radius; dy++) {
            for (int dx = -p.radius; dx <= p.radius; dx++) {
                int2 coordinate = clamp(int2(gid) + int2(dx, dy), int2(0), limit);
                float3 tap = graded.read(uint2(coordinate)).rgb;
                float yTap = dot(tap, kRec709Luma);
                float w = exp(-float(dx * dx + dy * dy) / twoSigmaSq);
                sum += w * float2((tap.b - yTap) * kCbScale, (tap.r - yTap) * kCrScale);
                weightSum += w;
            }
        }
        float2 mean = sum / weightSum;
        float cb2 = mix(mean.x, cb, 1.0 - p.amount);
        float cr2 = mix(mean.y, cr, 1.0 - p.amount);
        float3 outv = float3(
            y + kCrToR * cr2,
            y + kCbToG * cb2 + kCrToG * cr2,
            y + kCbToB * cb2);
        outv = clamp(outv, 0.0, 1.0);
        outv = select(outv, float3(0.0), isnan(outv));
        destination.write(float4(outv, 1.0), gid);
    }

    // Capture sharpening: small-radius unsharp on encoded luma, computed
    // inline (the radius never exceeds 3). The tanh limiter keeps strong
    // edges from ringing; luma-only application leaves chroma noise alone.
    //
    // `mask` is Lightroom's Masking: the local Sobel magnitude decides how
    // much of `amount` a pixel earns, so a sky or a flat wall — where all an
    // unsharp mask can do is amplify grain — keeps its smoothness while the
    // edges beside it sharpen fully. At mask 0 every pixel earns all of it,
    // which is the behaviour that shipped before the control existed.
    kernel void applySharpen(
        texture2d<float, access::read> graded [[texture(0)]],
        texture2d<float, access::write> destination [[texture(1)]],
        constant DetailParams &p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
            return;
        }
        int2 limit = int2(graded.get_width() - 1, graded.get_height() - 1);
        float twoSigmaSq = 2.0 * p.sigma * p.sigma;
        float sum = 0.0;
        float weightSum = 0.0;
        for (int dy = -p.radius; dy <= p.radius; dy++) {
            for (int dx = -p.radius; dx <= p.radius; dx++) {
                int2 coordinate = clamp(int2(gid) + int2(dx, dy), int2(0), limit);
                float w = exp(-float(dx * dx + dy * dy) / twoSigmaSq);
                float yTap = max(dot(graded.read(uint2(coordinate)).rgb, kLuma), 0.0);
                sum += w * pow(yTap, 1.0 / 2.2);
                weightSum += w;
            }
        }
        float3 v = graded.read(gid).rgb;
        float y = max(dot(v, kLuma), 1e-6);
        float g = pow(y, 1.0 / 2.2);
        float blurredLuma = sum / weightSum;
        float limited = p.tau * tanh((g - blurredLuma) / p.tau);
        float gain = p.amount;
        if (p.mask > 0.0) {
            // Sobel over the 3x3 neighbourhood, normalised so the magnitude
            // reads as the luma step across the pixel rather than as eight
            // summed taps — which is what makes the threshold a number
            // somebody can reason about.
            float gx = 0.0;
            float gy = 0.0;
            for (int dy = -1; dy <= 1; dy++) {
                for (int dx = -1; dx <= 1; dx++) {
                    int2 coordinate = clamp(int2(gid) + int2(dx, dy), int2(0), limit);
                    float yTap = max(dot(graded.read(uint2(coordinate)).rgb, kLuma), 0.0);
                    float gTap = pow(yTap, 1.0 / 2.2);
                    gx += gTap * float(dx) * (dy == 0 ? 2.0 : 1.0);
                    gy += gTap * float(dy) * (dx == 0 ? 2.0 : 1.0);
                }
            }
            float gradMag = length(float2(gx, gy)) * 0.25;
            float edge = smoothstep(0.0, kSharpenEdgeThreshold, gradMag);
            gain *= mix(1.0, edge, p.mask);
        }
        float g2 = g + gain * limited;
        float ratio = pow(max(g2, 0.0), 2.2) / y;
        float3 outv = clamp(v * ratio, 0.0, 1.0);
        outv = select(outv, float3(0.0), isnan(outv));
        destination.write(float4(outv, 1.0), gid);
    }

    struct VignetteParams {
        float strength;
    };

    kernel void applyVignette(
        texture2d<float, access::read> source [[texture(0)]],
        texture2d<float, access::write> destination [[texture(1)]],
        constant VignetteParams &p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
            return;
        }
        float2 size = float2(destination.get_width(), destination.get_height());
        float2 offset = float2(gid) + 0.5 - size * 0.5;
        float distanceNorm = length(offset) / (0.5 * length(size));
        float falloff = 1.0 - p.strength * smoothstep(0.3, 1.0, distanceNorm);
        float3 outv = source.read(gid).rgb * falloff;
        destination.write(float4(outv, 1.0), gid);
    }

    struct DitherParams {
        float amplitude;  // one destination LSB, e.g. 1/255
        uint  seed;
    };

    // TPDF dither for 8-bit destinations: the blend path dithers in its own
    // encode kernel; stills quantise in the CGImage conversion, so the noise
    // is added here, once, just before that. One value per pixel (not per
    // channel) — luminance dither breaks banding without adding chroma noise.
    kernel void finalizeDither(
        texture2d<float, access::read> source [[texture(0)]],
        texture2d<float, access::write> destination [[texture(1)]],
        constant DitherParams &p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
            return;
        }
        uint h = (gid.x * 1973u + gid.y * 9277u + p.seed * 26699u) | 1u;
        h ^= h >> 16; h *= 0x7feb352du;
        h ^= h >> 15; h *= 0x846ca68bu;
        h ^= h >> 16;
        float r1 = float(h & 0xFFFFu) / 65536.0;
        float r2 = float((h >> 16) & 0xFFFFu) / 65536.0;
        float noise = (r1 + r2 - 1.0) * p.amplitude;
        float3 outv = clamp(source.read(gid).rgb + noise, 0.0, 1.0);
        destination.write(float4(outv, 1.0), gid);
    }
    """

    /// The Adobe DCP hue/sat and look tables, as a decode-time pass.
    ///
    /// Kept as its own source string rather than folded into `source` above
    /// because it runs at a different point in the app: `source` is compiled
    /// once by `GradeCore` for the grade graph, while this pass belongs to the
    /// *decode* — `LinearFrameDecoder` applies it to the freshly decoded frame
    /// before any grading happens, so a DCP-decoded frame is just a frame by
    /// the time the grade engine sees it. Compiling the whole grade source a
    /// second time in the decoder to reach one kernel would be the alternative.
    ///
    /// ## What this pass is for
    ///
    /// The other three decode paths differ only in *which 3×3 goes where*. A
    /// 3×3 is one linear map applied identically to every pixel, so none of
    /// them can move a hue differently in the shadows than in the highlights —
    /// and that difference is exactly the gap against Lightroom. Adobe's
    /// profiles carry it as two sampled 3-D tables in HSV, which is what this
    /// kernel evaluates.
    ///
    /// ## Working space
    ///
    /// The tables are defined on ProPhoto RGB, not on XYZ. That distinction is
    /// load-bearing rather than pedantic: hue and saturation are RGB-relative
    /// quantities, and taking `max`/`min` across XYZ's X, Y and Z — which are
    /// not colour primaries and are not even the same kind of quantity as each
    /// other — produces an angle with no relation to the one Adobe sampled.
    /// So the pass converts P3 → XYZ(D50) → ProPhoto, works there, and
    /// converts back.
    static let dcpSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct DCPParams {
        float3x3 toWorking;     // linear P3 -> ProPhoto RGB (through XYZ D50)
        float3x3 fromWorking;   // and back
        uint3 hueSatDims;       // [hue, sat, value] divisions
        uint3 lookDims;
        uint  hasHueSat;
        uint  hasLook;
    };

    // dng_sdk's RGB->HSV: hue runs 0..6 rather than 0..1 or 0..360, because
    // that is the scale the profile's degree-valued hue shifts are converted
    // onto (degrees / 60).
    static inline float3 dcpRGBtoHSV(float3 rgb)
    {
        float mx = max(rgb.r, max(rgb.g, rgb.b));
        float mn = min(rgb.r, min(rgb.g, rgb.b));
        float range = mx - mn;
        float v = mx;
        float s = (mx > 0.0f) ? (range / mx) : 0.0f;
        float h = 0.0f;
        if (range > 0.0f) {
            if (mx == rgb.r)      { h = (rgb.g - rgb.b) / range; }
            else if (mx == rgb.g) { h = 2.0f + (rgb.b - rgb.r) / range; }
            else                  { h = 4.0f + (rgb.r - rgb.g) / range; }
            if (h < 0.0f) { h += 6.0f; }
        }
        return float3(h, s, v);
    }

    static inline float3 dcpHSVtoRGB(float3 hsv)
    {
        float v = hsv.z;
        float s = clamp(hsv.y, 0.0f, 1.0f);
        if (s <= 0.0f) { return float3(v, v, v); }
        float h = hsv.x;
        h = h - 6.0f * floor(h * (1.0f / 6.0f));   // wrap into [0, 6)
        int i = int(h);
        float f = h - float(i);
        float p = v * (1.0f - s);
        float q = v * (1.0f - s * f);
        float t = v * (1.0f - s * (1.0f - f));
        switch (i) {
            case 0:  return float3(v, t, p);
            case 1:  return float3(q, v, p);
            case 2:  return float3(p, v, t);
            case 3:  return float3(p, q, v);
            case 4:  return float3(t, p, v);
            default: return float3(v, p, q);
        }
    }

    // Trilinear fetch from a DNG hue/sat table.
    //
    // Axis order is value-outer, hue-middle, saturation-inner — the reverse of
    // the order the dimension triple lists them in. See `DCPTableIndex`.
    //
    // The hue axis is periodic and its last cell wraps to its first, so it has
    // `hueDivisions` intervals rather than `hueDivisions - 1`. Saturation and
    // value are clamped axes with one fewer interval than cells. Treating hue
    // like the other two leaves a seam at red.
    static inline float3 dcpSample(
        device const float3 *table, uint3 dims, float3 hsv)
    {
        int hDim = int(dims.x), sDim = int(dims.y), vDim = int(dims.z);

        float hScale = (hDim < 2) ? 0.0f : float(hDim) / 6.0f;
        float sScale = float(max(sDim - 1, 0));
        float vScale = float(max(vDim - 1, 0));

        // Hue: wrapping.
        float hf = hsv.x * hScale;
        int h0 = int(floor(hf));
        float hFract = hf - float(h0);
        int h1;
        if (hDim < 2) {
            h0 = 0; h1 = 0; hFract = 0.0f;
        } else {
            h0 = ((h0 % hDim) + hDim) % hDim;
            h1 = h0 + 1;
            if (h1 >= hDim) { h1 = 0; }
        }

        // Saturation: clamped. Input saturation is already 0..1.
        float sf = min(clamp(hsv.y, 0.0f, 1.0f) * sScale, sScale);
        int s0 = (sDim < 2) ? 0 : min(int(sf), sDim - 2);
        float sFract = (sDim < 2) ? 0.0f : sf - float(s0);
        int s1 = (sDim < 2) ? 0 : s0 + 1;

        // Value: clamped. Scene-linear value can exceed 1 (the decoder keeps
        // the file's highlight headroom), so the *index* saturates at the top
        // cell while the value itself is left alone.
        float vf = min(max(hsv.z, 0.0f) * vScale, vScale);
        int v0 = (vDim < 2) ? 0 : min(int(vf), vDim - 2);
        float vFract = (vDim < 2) ? 0.0f : vf - float(v0);
        int v1 = (vDim < 2) ? 0 : v0 + 1;

        int hStride = sDim;
        int vStride = hDim * sDim;

        float3 c000 = table[v0 * vStride + h0 * hStride + s0];
        float3 c001 = table[v0 * vStride + h0 * hStride + s1];
        float3 c010 = table[v0 * vStride + h1 * hStride + s0];
        float3 c011 = table[v0 * vStride + h1 * hStride + s1];
        float3 c100 = table[v1 * vStride + h0 * hStride + s0];
        float3 c101 = table[v1 * vStride + h0 * hStride + s1];
        float3 c110 = table[v1 * vStride + h1 * hStride + s0];
        float3 c111 = table[v1 * vStride + h1 * hStride + s1];

        float3 c00 = mix(c000, c001, sFract);
        float3 c01 = mix(c010, c011, sFract);
        float3 c10 = mix(c100, c101, sFract);
        float3 c11 = mix(c110, c111, sFract);
        float3 c0 = mix(c00, c01, hFract);
        float3 c1 = mix(c10, c11, hFract);
        return mix(c0, c1, vFract);
    }

    // Apply one table's deltas. Hue shift is additive and in degrees;
    // saturation and value scales are multiplicative.
    //
    // Saturation is clamped to 1 as dng_sdk does. Value deliberately is not:
    // dng_sdk clamps it because its pipeline is display-referred by this
    // point, whereas this one is scene-linear with the DNG's above-1.0
    // headroom still intact, and clamping here would flatten every highlight
    // the decoder went out of its way to preserve.
    static inline float3 dcpApply(float3 hsv, float3 delta)
    {
        return float3(
            hsv.x + delta.x * (1.0f / 60.0f),
            clamp(hsv.y * delta.y, 0.0f, 1.0f),
            hsv.z * delta.z);
    }

    kernel void applyDCPLookTable(
        texture2d<float, access::read> source [[texture(0)]],
        texture2d<float, access::write> destination [[texture(1)]],
        constant DCPParams &p [[buffer(0)]],
        device const float3 *hueSatTable [[buffer(1)]],
        device const float3 *lookTable [[buffer(2)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
            return;
        }
        float4 texel = source.read(gid);

        // Negative components are legal in extended-range P3 and meaningless
        // to a max/min hue angle, so the working copy is clamped at zero.
        float3 working = max(p.toWorking * texel.rgb, 0.0f);
        float3 hsv = dcpRGBtoHSV(working);

        if (p.hasHueSat != 0u) {
            hsv = dcpApply(hsv, dcpSample(hueSatTable, p.hueSatDims, hsv));
        }
        if (p.hasLook != 0u) {
            hsv = dcpApply(hsv, dcpSample(lookTable, p.lookDims, hsv));
        }

        float3 mapped = p.fromWorking * dcpHSVtoRGB(hsv);
        destination.write(float4(mapped, texel.a), gid);
    }
    """
}

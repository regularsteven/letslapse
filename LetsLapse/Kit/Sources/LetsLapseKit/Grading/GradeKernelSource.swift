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
        float tau;      // tanh limiter, encoded domain
        float sigma;    // Gaussian sigma at the blur's resolution
        int   radius;   // tap radius
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

    // Luminance noise reduction: a small bilateral on encoded luma. The
    // range gate opens with the slider, so grain within it averages away
    // while anything resembling an edge keeps its value; luma-ratio
    // application leaves chroma to the colour-noise control.
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
        float twoRangeSq = 2.0 * p.tau * p.tau;
        float sum = 0.0;
        float weightSum = 0.0;
        for (int dy = -p.radius; dy <= p.radius; dy++) {
            for (int dx = -p.radius; dx <= p.radius; dx++) {
                int2 coordinate = clamp(int2(gid) + int2(dx, dy), int2(0), limit);
                float yTap = max(dot(graded.read(uint2(coordinate)).rgb, kLuma), 0.0);
                float gTap = pow(yTap, 1.0 / 2.2);
                float d = gTap - g;
                float w = exp(-float(dx * dx + dy * dy) / twoSigmaSq)
                    * exp(-(d * d) / twoRangeSq);
                sum += w * gTap;
                weightSum += w;
            }
        }
        float smoothed = sum / weightSum;
        float g2 = mix(g, smoothed, p.amount);
        float ratio = pow(max(g2, 0.0), 2.2) / y;
        float3 outv = clamp(v * ratio, 0.0, 1.0);
        outv = select(outv, float3(0.0), isnan(outv));
        destination.write(float4(outv, 1.0), gid);
    }

    // Capture sharpening: small-radius unsharp on encoded luma, computed
    // inline (the radius never exceeds 3). The tanh limiter keeps strong
    // edges from ringing; luma-only application leaves chroma noise alone.
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
        float g2 = g + p.amount * limited;
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
}

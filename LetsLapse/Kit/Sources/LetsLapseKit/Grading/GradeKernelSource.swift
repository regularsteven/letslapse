import Foundation

/// The tone engine's Metal source, compiled at runtime exactly like
/// `BlendKernels.metal`. Kept as a single Swift string — one source of truth,
/// no bundled twin to drift from. The math mirrors `ToneMath` operation for
/// operation; the parity test holds the two together.
enum GradeKernelSource {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    constant float3 kLuma = float3(0.2289746, 0.6917385, 0.0792869);

    struct GradeParams {
        float3x3 wb;             // white-balance matrix, Display P3
        float exposureGain;      // 2^EV
        float kneeK;             // 0.95 - 0.6 * recovery
        float recoveryStrength;  // max(recovery, recoveryBase)
        float shadowGain;        // 0.9 * shadows (linear rolled-off lift)
        float desatCoeff;        // 0.5 * recoveryStrength
        float saturationGain;    // 1 + 0.8 * saturation
        float vibranceCoeff;     // 0.9 * vibrance
        float lutEndSlope;       // extrapolation slope above encoded 1.0
        uint  lutSize;
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

    // Scene-linear in, display-referred [0,1] linear out. Per-pixel only —
    // a pure function of the pixel's own value, so halos are impossible.
    kernel void gradeTone(
        texture2d<float, access::read> source [[texture(0)]],
        texture2d<float, access::write> destination [[texture(1)]],
        constant GradeParams &p [[buffer(0)]],
        constant float *toneLUT [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
            return;
        }
        float3 v = p.wb * source.read(gid).rgb;
        v = max(v * p.exposureGain, 0.0);

        float y = max(dot(v, kLuma), 1e-6);
        float y1 = y;
        if (y > p.kneeK) {
            float u = (y - p.kneeK) / (1.0 - p.kneeK);
            float compressed = p.kneeK + (1.0 - p.kneeK) * u / (1.0 + u);
            y1 = y + (compressed - y) * p.recoveryStrength;
        }
        y1 *= 1.0 + p.shadowGain * 0.16 / (0.16 + y1);
        float g = pow(y1, 1.0 / 2.2);
        float mapped = lutSample(toneLUT, p.lutSize, p.lutEndSlope, g);
        float y2 = pow(max(mapped, 0.0), 2.2);

        float3 outv = v * (y2 / y);
        float d = p.desatCoeff * smoothstep(0.7, 1.0, y2);
        outv = mix(outv, float3(y2), d);

        float maxc = max(outv.r, max(outv.g, outv.b));
        float minc = min(outv.r, min(outv.g, outv.b));
        float satM = clamp((maxc - minc) / max(maxc, 1e-4), 0.0, 1.0);
        float gain = p.saturationGain * (1.0 + p.vibranceCoeff * (1.0 - satM));
        float L = dot(outv, kLuma);
        outv = L + (outv - L) * gain;

        outv = clamp(outv, 0.0, 1.0);
        outv = select(outv, float3(0.0), isnan(outv));
        destination.write(float4(outv, 1.0), gid);
    }

    struct ClarityParams {
        float amount;   // 0.8 * clarity
        float tau;      // detail soft limit — the anti-halo
        float sigma;    // Gaussian sigma at blur resolution
        int   radius;   // tap radius at blur resolution
    };

    // Half-resolution encoded luma of the graded image — the clarity base.
    kernel void clarityLuma(
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

    static inline float blurTap(
        texture2d<float, access::read> source, int2 coordinate, int2 limit)
    {
        int2 clamped = clamp(coordinate, int2(0), limit);
        return source.read(uint2(clamped)).r;
    }

    kernel void blurHorizontal(
        texture2d<float, access::read> source [[texture(0)]],
        texture2d<float, access::write> destination [[texture(1)]],
        constant ClarityParams &p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
            return;
        }
        int2 limit = int2(source.get_width() - 1, source.get_height() - 1);
        float twoSigmaSq = 2.0 * p.sigma * p.sigma;
        float sum = 0.0;
        float weightSum = 0.0;
        for (int dx = -p.radius; dx <= p.radius; dx++) {
            float w = exp(-float(dx * dx) / twoSigmaSq);
            sum += w * blurTap(source, int2(gid) + int2(dx, 0), limit);
            weightSum += w;
        }
        destination.write(float4(sum / weightSum, 0.0, 0.0, 1.0), gid);
    }

    kernel void blurVertical(
        texture2d<float, access::read> source [[texture(0)]],
        texture2d<float, access::write> destination [[texture(1)]],
        constant ClarityParams &p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
            return;
        }
        int2 limit = int2(source.get_width() - 1, source.get_height() - 1);
        float twoSigmaSq = 2.0 * p.sigma * p.sigma;
        float sum = 0.0;
        float weightSum = 0.0;
        for (int dy = -p.radius; dy <= p.radius; dy++) {
            float w = exp(-float(dy * dy) / twoSigmaSq);
            sum += w * blurTap(source, int2(gid) + int2(0, dy), limit);
            weightSum += w;
        }
        destination.write(float4(sum / weightSum, 0.0, 0.0, 1.0), gid);
    }

    // Local contrast with a tanh-limited detail term: micro-contrast passes,
    // strong edges saturate the limiter, so no halos at any slider position.
    kernel void clarityApply(
        texture2d<float, access::read> graded [[texture(0)]],
        texture2d<float, access::sample> blurred [[texture(1)]],
        texture2d<float, access::write> destination [[texture(2)]],
        constant ClarityParams &p [[buffer(0)]],
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
    """
}

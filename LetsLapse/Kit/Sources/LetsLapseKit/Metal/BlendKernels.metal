#include <metal_stdlib>
using namespace metal;

// The blend engine's entire GPU surface: sum a window of frames into a
// float32 accumulator, then divide by the frame count. Written once, shared
// by iOS, iPadOS, and macOS.

kernel void clearAccumulator(
    texture2d<float, access::write> accumulator [[texture(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= accumulator.get_width() || gid.y >= accumulator.get_height()) {
        return;
    }
    accumulator.write(float4(0.0), gid);
}

kernel void accumulateFrame(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::read_write> accumulator [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= accumulator.get_width() || gid.y >= accumulator.get_height()) {
        return;
    }
    accumulator.write(accumulator.read(gid) + source.read(gid), gid);
}

kernel void finalizeAverage(
    texture2d<float, access::read> accumulator [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant float &frameCount [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
        return;
    }
    float4 mean = accumulator.read(gid) / max(frameCount, 1.0);
    destination.write(float4(mean.rgb, 1.0), gid);
}

// The high-precision finalize pair: the mean lands in a float destination
// untouched, and `encodeGamma` is the pipeline's single quantization point —
// transfer curve plus triangular-PDF dither, so smooth gradients quantize to
// noise instead of contours.

struct EncodeParams {
    float3x3 gamut;     // linear-domain primaries conversion; identity = none
    float ditherLSB;    // 1/255 for 8-bit targets, 0 for 10-bit and wider
    uint  frameIndex;   // reseeds the dither per output frame
    uint  applySRGB;    // 1 = encode linear -> sRGB here, 0 = store verbatim
};

static inline uint hashPCG(uint x)
{
    x ^= x >> 16; x *= 0x7feb352dU;
    x ^= x >> 15; x *= 0x846ca68bU;
    x ^= x >> 16;
    return x;
}

static inline float ditherNoise(uint2 gid, uint seed)
{
    uint h = hashPCG(gid.x * 1973u ^ gid.y * 9277u ^ seed * 26699u);
    return float(h) / 4294967295.0;
}

static inline float linearToSRGB(float x)
{
    return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1.0 / 2.4) - 0.055;
}

kernel void finalizeMeanLinear(
    texture2d<float, access::read> accumulator [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant float &frameCount [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
        return;
    }
    float4 mean = accumulator.read(gid) / max(frameCount, 1.0);
    destination.write(float4(mean.rgb, 1.0), gid);
}

// The destination view must be a non-sRGB format: the transfer curve is
// applied in-kernel, never by the hardware store.
kernel void encodeGamma(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant EncodeParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
        return;
    }
    float3 value = clamp(params.gamut * source.read(gid).rgb, 0.0, 1.0);
    if (params.applySRGB != 0) {
        value = float3(linearToSRGB(value.r), linearToSRGB(value.g), linearToSRGB(value.b));
    }
    if (params.ditherLSB > 0.0) {
        uint base = params.frameIndex * 3u;
        for (uint c = 0; c < 3; c++) {
            float noise = ditherNoise(gid, base + c)
                        + ditherNoise(gid, (base + c) ^ 0x9E3779B9u) - 1.0;
            value[c] += noise * params.ditherLSB;
        }
    }
    destination.write(float4(clamp(value, 0.0, 1.0), 1.0), gid);
}

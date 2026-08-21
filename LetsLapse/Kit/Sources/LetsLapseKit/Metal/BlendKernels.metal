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

// The native-YUV accumulate path. Asking the reader for 32BGRA makes
// VideoToolbox convert every frame, and that conversion — not the decode —
// is what bounds a blend render (measured 212 fps to BGRA vs 481 fps native
// on the same 12 MP HEVC clip, same single thread). Reading the decoder's own
// biplanar output and converting here costs the GPU almost nothing, and moves
// a quarter as many bytes.

struct YUVParams {
    float3x3 matrix;    // (Y,Cb,Cr) -> (R,G,B), full-range coefficients
    float lumaOffset;   // subtracted from Y before scaling
    float chromaOffset; // subtracted from Cb/Cr before scaling
    float lumaScale;    // video-range expansion for Y
    float chromaScale;  // video-range expansion for Cb/Cr
    uint  toLinear;     // 1 = decode sRGB -> linear light, matching the
                        // bgra8Unorm_srgb texture view the BGRA path relied on
};

static inline float srgbToLinear(float x)
{
    return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4);
}

kernel void accumulateFrameYUV(
    texture2d<float, access::read> luma [[texture(0)]],
    texture2d<float> chroma [[texture(1)]],
    texture2d<float, access::read_write> accumulator [[texture(2)]],
    constant YUVParams &params [[buffer(0)]],
    sampler chromaSampler [[sampler(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint width = accumulator.get_width();
    uint height = accumulator.get_height();
    if (gid.x >= width || gid.y >= height) {
        return;
    }
    // Chroma is half resolution; sampling it bilinearly at the luma pixel
    // centre reproduces the decoder's own upsampling closely enough that the
    // difference disappears into the window average.
    float2 centre = (float2(gid) + 0.5) / float2(width, height);
    float y = luma.read(gid).r;
    float2 cbcr = chroma.sample(chromaSampler, centre).rg;
    float3 ycc = float3(
        (y - params.lumaOffset) * params.lumaScale,
        (cbcr.x - params.chromaOffset) * params.chromaScale,
        (cbcr.y - params.chromaOffset) * params.chromaScale);
    // Clamped before the transfer curve because the 8-bit BGRA buffer this
    // replaces was clamped by the conversion that wrote it.
    float3 rgb = clamp(params.matrix * ycc, 0.0, 1.0);
    if (params.toLinear != 0) {
        rgb = float3(srgbToLinear(rgb.r), srgbToLinear(rgb.g), srgbToLinear(rgb.b));
    }
    accumulator.write(accumulator.read(gid) + float4(rgb, 1.0), gid);
}

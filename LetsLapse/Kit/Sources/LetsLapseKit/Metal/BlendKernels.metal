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

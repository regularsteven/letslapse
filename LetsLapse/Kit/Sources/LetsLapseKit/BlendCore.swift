import Foundation
import Metal
import CoreVideo
import simd

/// Shared Metal state for all blending work: device, command queue, compiled
/// kernels, and a CoreVideo texture cache for zero-copy CVPixelBuffer access.
/// Immutable after init, safe to share across threads.
public final class BlendCore: @unchecked Sendable {
    public let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let clearPipeline: MTLComputePipelineState
    let accumulatePipeline: MTLComputePipelineState
    let finalizePipeline: MTLComputePipelineState
    let finalizeMeanPipeline: MTLComputePipelineState
    let encodeGammaPipeline: MTLComputePipelineState
    let textureCache: CVMetalTextureCache

    public init(device: MTLDevice? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw LapseError.metalUnavailable
        }
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw LapseError.gpuSetupFailed("could not create a command queue")
        }
        self.commandQueue = queue

        let library = try BlendCore.makeLibrary(device: device)
        self.clearPipeline = try BlendCore.makePipeline(library: library, function: "clearAccumulator")
        self.accumulatePipeline = try BlendCore.makePipeline(library: library, function: "accumulateFrame")
        self.finalizePipeline = try BlendCore.makePipeline(library: library, function: "finalizeAverage")
        self.finalizeMeanPipeline = try BlendCore.makePipeline(library: library, function: "finalizeMeanLinear")
        self.encodeGammaPipeline = try BlendCore.makePipeline(library: library, function: "encodeGamma")

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard let cache else {
            throw LapseError.gpuSetupFailed("could not create a CoreVideo Metal texture cache")
        }
        self.textureCache = cache
    }

    // The kernel ships as source and compiles at runtime: SwiftPM's metallib
    // handling differs between `swift build` and Xcode, but source + runtime
    // compile behaves identically everywhere and costs milliseconds once.
    private static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        let source = bundledKernelSource() ?? embeddedKernelSource
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            throw LapseError.gpuSetupFailed("kernel compilation failed: \(error.localizedDescription)")
        }
    }

    /// The bundled copy of the kernel source. Internal so the test suite can
    /// assert it never drifts from `embeddedKernelSource` — the two are
    /// hand-maintained twins.
    static func bundledKernelSource() -> String? {
        let url = Bundle.module.url(
            forResource: "BlendKernels",
            withExtension: "metal",
            subdirectory: "Metal"
        ) ?? Bundle.module.url(forResource: "BlendKernels", withExtension: "metal")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    private static func makePipeline(library: MTLLibrary, function name: String) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw LapseError.gpuSetupFailed("missing kernel function \(name)")
        }
        do {
            return try library.device.makeComputePipelineState(function: function)
        } catch {
            throw LapseError.gpuSetupFailed("pipeline for \(name) failed: \(error.localizedDescription)")
        }
    }

    func makeAccumulatorTexture(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw LapseError.textureCreationFailed("\(width)x\(height) rgba32Float accumulator")
        }
        return texture
    }

    /// A half-float destination for `finalizeMeanLinear` — the window's mean
    /// at full precision, before `encodeGamma` quantizes it exactly once.
    func makeMeanTexture(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw LapseError.textureCreationFailed("\(width)x\(height) rgba16Float mean")
        }
        return texture
    }

    /// Mirror of the Metal `EncodeParams` struct — layouts must match.
    struct EncodeParams {
        var gamut: simd_float3x3
        var ditherLSB: Float
        var frameIndex: UInt32
        var applySRGB: UInt32
    }

    /// Transfer-encode `source` into `destination` with triangular-PDF dither
    /// (and, when `gamut` isn't identity, a linear-domain primaries
    /// conversion first). `destination` must be a non-sRGB view — the curve
    /// is applied in-kernel.
    func encodeGamma(
        from source: MTLTexture,
        to destination: MTLTexture,
        ditherLSB: Float,
        frameIndex: Int,
        applySRGB: Bool,
        gamut: simd_float3x3 = matrix_identity_float3x3,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw LapseError.gpuSetupFailed("could not encode gamma pass")
        }
        var params = EncodeParams(
            gamut: gamut,
            ditherLSB: ditherLSB,
            frameIndex: UInt32(truncatingIfNeeded: frameIndex),
            applySRGB: applySRGB ? 1 : 0)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<EncodeParams>.stride, index: 0)
        dispatch(encodeGammaPipeline, encoder: encoder, width: destination.width, height: destination.height)
        encoder.endEncoding()
    }

    /// Wraps a CVPixelBuffer as a Metal texture — BGRA at 8 bits, or RGBA
    /// half-float for the 10-bit encode path's `64RGBAHalf` pool buffers. The
    /// returned holder must stay alive until GPU work reading the texture has
    /// completed.
    func makeTexture(from pixelBuffer: CVPixelBuffer, srgb: Bool) throws -> (texture: MTLTexture, holder: CVMetalTexture) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format: MTLPixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_64RGBAHalf
            ? .rgba16Float
            : (srgb ? .bgra8Unorm_srgb : .bgra8Unorm)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil, format, width, height, 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
            throw LapseError.textureCreationFailed("CVPixelBuffer wrap failed (status \(status))")
        }
        return (texture, cvTexture)
    }

    func dispatch(_ pipeline: MTLComputePipelineState, encoder: MTLComputeCommandEncoder, width: Int, height: Int) {
        encoder.setComputePipelineState(pipeline)
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        let groups = MTLSize(width: (width + w - 1) / w, height: (height + h - 1) / h, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
    }

    func flushTextureCache() {
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    static let embeddedKernelSource = """
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
    """
}

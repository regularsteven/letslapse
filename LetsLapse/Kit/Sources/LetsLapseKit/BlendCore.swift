import Foundation
import Metal
import CoreVideo

/// Shared Metal state for all blending work: device, command queue, compiled
/// kernels, and a CoreVideo texture cache for zero-copy CVPixelBuffer access.
/// Immutable after init, safe to share across threads.
public final class BlendCore: @unchecked Sendable {
    public let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let clearPipeline: MTLComputePipelineState
    let accumulatePipeline: MTLComputePipelineState
    let finalizePipeline: MTLComputePipelineState
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
        let url = Bundle.module.url(
            forResource: "BlendKernels",
            withExtension: "metal",
            subdirectory: "Metal"
        ) ?? Bundle.module.url(forResource: "BlendKernels", withExtension: "metal")
        let source = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? embeddedKernelSource
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            throw LapseError.gpuSetupFailed("kernel compilation failed: \(error.localizedDescription)")
        }
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

    /// Wraps a BGRA CVPixelBuffer as a Metal texture. The returned holder must
    /// stay alive until GPU work reading the texture has completed.
    func makeTexture(from pixelBuffer: CVPixelBuffer, srgb: Bool) throws -> (texture: MTLTexture, holder: CVMetalTexture) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format: MTLPixelFormat = srgb ? .bgra8Unorm_srgb : .bgra8Unorm
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

    private static let embeddedKernelSource = """
    #include <metal_stdlib>
    using namespace metal;

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
    """
}

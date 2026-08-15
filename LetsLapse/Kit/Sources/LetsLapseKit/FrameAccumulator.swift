import Foundation
import Metal

/// Accumulates frames into a float32 buffer on the GPU and averages them out.
/// Reusable across output frames: reset → accumulate × N → finalize.
/// Not thread-safe; drive it from a single worker.
public final class FrameAccumulator {
    private let core: BlendCore
    private var accumulator: MTLTexture?
    public private(set) var frameCount = 0
    public private(set) var width = 0
    public private(set) var height = 0

    public init(core: BlendCore) {
        self.core = core
    }

    public func reset(width: Int, height: Int, commandBuffer: MTLCommandBuffer) throws {
        if accumulator == nil || width != self.width || height != self.height {
            accumulator = try core.makeAccumulatorTexture(width: width, height: height)
            self.width = width
            self.height = height
        }
        frameCount = 0
        guard let accumulator, let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw LapseError.gpuSetupFailed("could not encode accumulator clear")
        }
        encoder.setTexture(accumulator, index: 0)
        core.dispatch(core.clearPipeline, encoder: encoder, width: width, height: height)
        encoder.endEncoding()
    }

    public func accumulate(_ source: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        guard let accumulator else {
            throw LapseError.gpuSetupFailed("accumulate called before reset")
        }
        guard source.width == width, source.height == height else {
            throw LapseError.sizeMismatch(
                expectedWidth: width, expectedHeight: height,
                actualWidth: source.width, actualHeight: source.height)
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw LapseError.gpuSetupFailed("could not encode frame accumulation")
        }
        encoder.setTexture(source, index: 0)
        encoder.setTexture(accumulator, index: 1)
        core.dispatch(core.accumulatePipeline, encoder: encoder, width: width, height: height)
        encoder.endEncoding()
        frameCount += 1
    }

    public func finalize(into destination: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        try finalize(into: destination, pipeline: core.finalizePipeline, commandBuffer: commandBuffer)
    }

    /// Like `finalize`, but into a float destination that keeps the mean at
    /// full precision — the input to `BlendCore.encodeGamma`, which owns the
    /// one quantization step.
    public func finalizeMean(into destination: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        try finalize(into: destination, pipeline: core.finalizeMeanPipeline, commandBuffer: commandBuffer)
    }

    private func finalize(
        into destination: MTLTexture,
        pipeline: MTLComputePipelineState,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard let accumulator, frameCount > 0 else {
            throw LapseError.noInputFrames
        }
        guard destination.width == width, destination.height == height else {
            throw LapseError.sizeMismatch(
                expectedWidth: width, expectedHeight: height,
                actualWidth: destination.width, actualHeight: destination.height)
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw LapseError.gpuSetupFailed("could not encode finalize")
        }
        var count = Float(frameCount)
        encoder.setTexture(accumulator, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(&count, length: MemoryLayout<Float>.size, index: 0)
        core.dispatch(pipeline, encoder: encoder, width: width, height: height)
        encoder.endEncoding()
    }
}

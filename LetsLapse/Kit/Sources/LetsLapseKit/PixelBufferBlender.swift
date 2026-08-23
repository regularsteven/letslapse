import Foundation
import CoreGraphics
import CoreVideo
import Metal

/// Equal-weight streaming average of live CVPixelBuffers into one CGImage.
/// Feed frames one at a time with `accumulate`; `finalizeImage` averages
/// whatever arrived and leaves the instance ready for the next window, so one
/// blender serves a whole capture session. With `linearLight` (default) frames
/// are linearized before averaging, matching the offline blend pipeline.
/// Not thread-safe; drive it from a single serial queue.
public final class PixelBufferBlender {
    private let core: BlendCore
    private let linearLight: Bool
    private let accumulator: FrameAccumulator
    // Bounds how many camera buffers wait on the GPU at once, so a slow GPU
    // can never pile up retained frames.
    private let inFlight = DispatchSemaphore(value: 3)
    private var windowOpen = false

    public var frameCount: Int { accumulator.frameCount }
    public private(set) var width = 0
    public private(set) var height = 0

    public init(core: BlendCore, linearLight: Bool = true) {
        self.core = core
        self.linearLight = linearLight
        self.accumulator = FrameAccumulator(core: core)
    }

    /// Adds one BGRA frame to the current window. The first frame after init,
    /// `finalizeImage`, or `discardWindow` opens a new window and fixes its
    /// size; later frames must match or this throws `LapseError.sizeMismatch`.
    /// GPU work is committed without waiting; the buffer stays retained until
    /// the GPU has read it.
    public func accumulate(_ pixelBuffer: CVPixelBuffer) throws {
        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        if windowOpen {
            guard bufferWidth == width, bufferHeight == height else {
                throw LapseError.sizeMismatch(
                    expectedWidth: width, expectedHeight: height,
                    actualWidth: bufferWidth, actualHeight: bufferHeight)
            }
        }
        let (texture, holder) = try core.makeTexture(from: pixelBuffer, srgb: linearLight)
        guard let commandBuffer = core.commandQueue.makeCommandBuffer() else {
            throw LapseError.gpuSetupFailed("could not create a command buffer")
        }
        if !windowOpen {
            width = bufferWidth
            height = bufferHeight
            try accumulator.reset(width: width, height: height, commandBuffer: commandBuffer)
            windowOpen = true
        }
        try accumulator.accumulate(texture, commandBuffer: commandBuffer)
        inFlight.wait()
        commandBuffer.addCompletedHandler { _ in
            // Keeps the camera buffer alive until the GPU has read it.
            _ = holder
            _ = pixelBuffer
            self.inFlight.signal()
        }
        commandBuffer.commit()
    }

    /// Averages the accumulated frames into one image and closes the window.
    /// Command buffers on one queue run in commit order, so this implicitly
    /// waits for every pending `accumulate`. Throws `LapseError.noInputFrames`
    /// when nothing was accumulated.
    public func finalizeImage() throws -> CGImage {
        guard windowOpen, accumulator.frameCount > 0 else {
            throw LapseError.noInputFrames
        }
        defer {
            windowOpen = false
            core.flushTextureCache()
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: linearLight ? .bgra8Unorm_srgb : .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .private
        guard let destination = core.device.makeTexture(descriptor: descriptor) else {
            throw LapseError.textureCreationFailed("\(width)x\(height) live blend destination")
        }
        guard let commandBuffer = core.commandQueue.makeCommandBuffer() else {
            throw LapseError.gpuSetupFailed("could not create a command buffer")
        }
        try accumulator.finalize(into: destination, commandBuffer: commandBuffer)
        return try readImage(from: destination, commandBuffer: commandBuffer)
    }

    /// Like `finalizeImage`, but returns the window's mean as a HALF-FLOAT
    /// image instead of quantizing to 8 bits — `finalizeMeanLinear` into an
    /// rgba16Float destination, read back verbatim. With `linearLight` the
    /// pixel values are linear and the image says so (linear sRGB colorspace),
    /// so downstream CoreImage work happens on the window's real precision;
    /// the caller owns the single 8-bit quantization at encode. This is what
    /// lets a save-time look (Capture Flat) be applied to ~5 extra bits of
    /// temporally-dithered tone instead of to an already-encoded 8-bit result.
    public func finalizeFloatImage() throws -> CGImage {
        guard windowOpen, accumulator.frameCount > 0 else {
            throw LapseError.noInputFrames
        }
        defer {
            windowOpen = false
            core.flushTextureCache()
        }
        let destination = try core.makeMeanTexture(width: width, height: height)
        guard let commandBuffer = core.commandQueue.makeCommandBuffer() else {
            throw LapseError.gpuSetupFailed("could not create a command buffer")
        }
        try accumulator.finalizeMean(into: destination, commandBuffer: commandBuffer)
        return try readFloatImage(from: destination, commandBuffer: commandBuffer)
    }

    /// Drops the current window's accumulated sum without producing an image
    /// (cancel path). In-flight GPU work self-releases its buffers.
    public func discardWindow() {
        windowOpen = false
        core.flushTextureCache()
    }

    // Blit-to-buffer readback, same approach as ImageStacker: works on every
    // GPU family, unlike reading shared textures directly.
    private func readImage(from texture: MTLTexture, commandBuffer: MTLCommandBuffer) throws -> CGImage {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        guard let buffer = core.device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared) else {
            throw LapseError.gpuSetupFailed("could not allocate readback buffer")
        }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw LapseError.gpuSetupFailed("could not encode readback blit")
        }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer, destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw LapseError.gpuSetupFailed("GPU error: \(error.localizedDescription)")
        }

        let data = Data(bytes: buffer.contents(), count: bytesPerRow * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent) else {
            throw LapseError.imageEncodeFailed("could not wrap GPU output as an image")
        }
        return image
    }

    // `readImage`'s half-float twin: rgba16Float memory wrapped as a 64-bit
    // RGBA image. The colorspace states what the values ARE — linear when the
    // accumulator worked in linear light — which is what makes CoreImage
    // treat this identically to a decoded 8-bit image of the same scene.
    private func readFloatImage(from texture: MTLTexture, commandBuffer: MTLCommandBuffer) throws -> CGImage {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 8
        guard let buffer = core.device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared) else {
            throw LapseError.gpuSetupFailed("could not allocate readback buffer")
        }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw LapseError.gpuSetupFailed("could not encode readback blit")
        }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer, destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw LapseError.gpuSetupFailed("GPU error: \(error.localizedDescription)")
        }

        let data = Data(bytes: buffer.contents(), count: bytesPerRow * height)
        let spaceName = linearLight ? CGColorSpace.linearSRGB : CGColorSpace.sRGB
        guard let colorSpace = CGColorSpace(name: spaceName),
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width, height: height,
                bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.floatComponents.rawValue
                    | CGBitmapInfo.byteOrder16Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent) else {
            throw LapseError.imageEncodeFailed("could not wrap GPU float output as an image")
        }
        return image
    }
}

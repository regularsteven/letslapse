import Foundation
import CoreGraphics
import ImageIO
import Metal
import AVFoundation
import CoreVideo
import UniformTypeIdentifiers

/// The outcome of `ImageStacker.stackSequence` — how many frames were written
/// and at what pixel size.
public struct StackSequenceResult: Sendable {
    public let outputFrames: Int
    public let width: Int
    public let height: Int
}

/// Averages a set of same-sized still images into one — a synthetic long
/// exposure with the noise knocked down by roughly sqrt(N).
public final class ImageStacker {
    private let core: BlendCore

    public init(core: BlendCore) {
        self.core = core
    }

    /// Stacks images loaded lazily from disk, one at a time, so memory stays
    /// bounded no matter how many frames go in. With `linearLight` (default)
    /// frames are linearized before averaging, matching how a real long
    /// exposure integrates light.
    public func stack(imageURLs: [URL], linearLight: Bool = true, progress: ((Double) -> Void)? = nil) throws -> CGImage {
        try stackImages(count: imageURLs.count, linearLight: linearLight, progress: progress) { index in
            try ImageStacker.loadImage(at: imageURLs[index])
        }
    }

    public func stack(images: [CGImage], linearLight: Bool = true, progress: ((Double) -> Void)? = nil) throws -> CGImage {
        try stackImages(count: images.count, linearLight: linearLight, progress: progress) { images[$0] }
    }

    private func stackImages(count: Int, linearLight: Bool, progress: ((Double) -> Void)?, imageAt: (Int) throws -> CGImage) throws -> CGImage {
        guard count > 0 else { throw LapseError.noInputFrames }
        let accumulator = FrameAccumulator(core: core)
        var width = 0
        var height = 0

        for index in 0..<count {
            try autoreleasepool {
                let image = try imageAt(index)
                if index == 0 {
                    width = image.width
                    height = image.height
                }
                guard image.width == width, image.height == height else {
                    throw LapseError.sizeMismatch(
                        expectedWidth: width, expectedHeight: height,
                        actualWidth: image.width, actualHeight: image.height)
                }
                let texture = try uploadTexture(for: image, srgb: linearLight)
                guard let commandBuffer = core.commandQueue.makeCommandBuffer() else {
                    throw LapseError.gpuSetupFailed("could not create a command buffer")
                }
                if index == 0 {
                    try accumulator.reset(width: width, height: height, commandBuffer: commandBuffer)
                }
                try accumulator.accumulate(texture, commandBuffer: commandBuffer)
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                if let error = commandBuffer.error {
                    throw LapseError.gpuSetupFailed("GPU error: \(error.localizedDescription)")
                }
            }
            progress?(Double(index + 1) / Double(count + 1))
        }

        let destinationFormat: MTLPixelFormat = linearLight ? .bgra8Unorm_srgb : .bgra8Unorm
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: destinationFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .private
        guard let destination = core.device.makeTexture(descriptor: descriptor) else {
            throw LapseError.textureCreationFailed("\(width)x\(height) stack destination")
        }
        guard let commandBuffer = core.commandQueue.makeCommandBuffer() else {
            throw LapseError.gpuSetupFailed("could not create a command buffer")
        }
        try accumulator.finalize(into: destination, commandBuffer: commandBuffer)
        let result = try readImage(from: destination, commandBuffer: commandBuffer)
        progress?(1.0)
        return result
    }

    // MARK: - Sequence (variable-blend timelapse)

    /// Produces a blended timelapse video from a sequence of still images.
    /// Each output frame is the average of a window of consecutive input
    /// stills, laid out by `ramp`: a flat window gives an evenly motion-blurred
    /// timelapse, while a window of 1 gives a straight timelapse with no
    /// stacking. Images are streamed off disk one at a time, so memory stays
    /// bounded no matter how many go in. Returns the written file's frame count
    /// and pixel dimensions.
    public func stackSequence(
        imageURLs: [URL],
        ramp: BlendRamp,
        outputFPS: Double,
        linearLight: Bool = true,
        outputURL: URL,
        progress: ((Double) -> Void)? = nil
    ) throws -> StackSequenceResult {
        guard imageURLs.count >= 2 else {
            throw LapseError.writerFailed("a timelapse needs at least two photos")
        }
        let schedule = WindowSchedule.make(totalInputFrames: imageURLs.count, ramp: ramp)
        guard !schedule.isEmpty else { throw LapseError.noInputFrames }

        // Size the writer from the first still (orientation already baked in).
        let firstImage = try ImageStacker.loadImage(at: imageURLs[0])
        let width = firstImage.width
        let height = firstImage.height

        try? FileManager.default.removeItem(at: outputURL)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw LapseError.writerFailed(error.localizedDescription)
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
        guard writer.canAdd(writerInput) else {
            throw LapseError.writerFailed("cannot attach video input")
        }
        writer.add(writerInput)
        guard writer.startWriting() else {
            throw LapseError.writerFailed(writer.error?.localizedDescription ?? "could not start encoding")
        }
        writer.startSession(atSourceTime: .zero)

        defer {
            if writer.status == .writing { writer.cancelWriting() }
        }

        let accumulator = FrameAccumulator(core: core)
        let srgb = linearLight
        var inputIndex = 0
        var outputFrames = 0

        for window in schedule {
            // Average this window's stills into the accumulator.
            for offset in 0..<window {
                let index = inputIndex + offset
                try autoreleasepool {
                    let image = index == 0 ? firstImage : try ImageStacker.loadImage(at: imageURLs[index])
                    guard image.width == width, image.height == height else {
                        throw LapseError.sizeMismatch(
                            expectedWidth: width, expectedHeight: height,
                            actualWidth: image.width, actualHeight: image.height)
                    }
                    let texture = try uploadTexture(for: image, srgb: srgb)
                    guard let commandBuffer = core.commandQueue.makeCommandBuffer() else {
                        throw LapseError.gpuSetupFailed("could not create a command buffer")
                    }
                    if offset == 0 {
                        try accumulator.reset(width: width, height: height, commandBuffer: commandBuffer)
                    }
                    try accumulator.accumulate(texture, commandBuffer: commandBuffer)
                    commandBuffer.commit()
                    commandBuffer.waitUntilCompleted()
                    if let error = commandBuffer.error {
                        throw LapseError.gpuSetupFailed("GPU error: \(error.localizedDescription)")
                    }
                }
            }
            inputIndex += window

            // Finalize the window into a pooled pixel buffer and append it.
            guard let pool = adaptor.pixelBufferPool else {
                throw LapseError.writerFailed("no pixel buffer pool (writer status \(writer.status.rawValue))")
            }
            var outBuffer: CVPixelBuffer?
            let poolStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outBuffer)
            guard poolStatus == kCVReturnSuccess, let outBuffer else {
                throw LapseError.writerFailed("output buffer allocation failed (\(poolStatus))")
            }
            let (destination, destinationHolder) = try core.makeTexture(from: outBuffer, srgb: srgb)
            guard let commandBuffer = core.commandQueue.makeCommandBuffer() else {
                throw LapseError.gpuSetupFailed("could not create a command buffer")
            }
            try accumulator.finalize(into: destination, commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if let error = commandBuffer.error {
                throw LapseError.gpuSetupFailed("GPU error: \(error.localizedDescription)")
            }
            _ = destinationHolder

            while !writerInput.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw LapseError.writerFailed(writer.error?.localizedDescription ?? "encoder failed")
                }
                usleep(2000)
            }
            let time = CMTime(
                value: Int64((Double(outputFrames) / outputFPS * 60000).rounded()),
                timescale: 60000)
            guard adaptor.append(outBuffer, withPresentationTime: time) else {
                throw LapseError.writerFailed(writer.error?.localizedDescription ?? "frame append failed")
            }
            outputFrames += 1
            core.flushTextureCache()
            progress?(min(0.99, Double(inputIndex) / Double(imageURLs.count)))
        }

        guard outputFrames > 0 else { throw LapseError.noInputFrames }

        writerInput.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw LapseError.writerFailed(writer.error?.localizedDescription ?? "could not finalize file")
        }
        progress?(1.0)

        return StackSequenceResult(outputFrames: outputFrames, width: width, height: height)
    }

    // MARK: - CPU <-> GPU transfer

    private func uploadTexture(for image: CGImage, srgb: Bool) throws -> MTLTexture {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw LapseError.gpuSetupFailed("sRGB color space unavailable")
        }
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        try pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: colorSpace, bitmapInfo: bitmapInfo) else {
                throw LapseError.gpuSetupFailed("could not create a bitmap context")
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: srgb ? .bgra8Unorm_srgb : .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = core.device.makeTexture(descriptor: descriptor) else {
            throw LapseError.textureCreationFailed("\(width)x\(height) image upload")
        }
        pixels.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: raw.baseAddress!, bytesPerRow: bytesPerRow)
        }
        return texture
    }

    /// Encodes a blit of `texture` into a shared buffer on `commandBuffer`
    /// (which must already hold the finalize dispatch), runs it, and wraps the
    /// bytes as a CGImage. Blit-to-buffer readback works on every GPU family,
    /// unlike reading shared textures.
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

    /// Loads an image with its EXIF orientation baked in, so portrait shots
    /// stack upright.
    static func loadImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw LapseError.imageLoadFailed(url)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 20000,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw LapseError.imageLoadFailed(url)
        }
        return image
    }
}

// MARK: - Export

public enum ImageFormat: String, CaseIterable, Sendable {
    case png
    case jpeg
    case heic

    public var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        }
    }

    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        }
    }

    public static func infer(from url: URL) -> ImageFormat? {
        switch url.pathExtension.lowercased() {
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "heic", "heif": return .heic
        default: return nil
        }
    }
}

public enum ImageExporter {
    public static func write(_ image: CGImage, to url: URL, format: ImageFormat, quality: Double = 0.95) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw LapseError.imageEncodeFailed("could not create \(format.rawValue) destination")
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw LapseError.imageEncodeFailed("could not write \(url.lastPathComponent)")
        }
    }
}

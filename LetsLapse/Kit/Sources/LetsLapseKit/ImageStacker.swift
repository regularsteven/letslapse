import Foundation
import CoreGraphics
import ImageIO
import Metal
import UniformTypeIdentifiers

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

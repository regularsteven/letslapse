import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal

/// Decodes a source frame to the tone engine's working form: an rgba16Float
/// texture of scene-linear Display P3, top row first, with the DNG's
/// above-1.0 highlight headroom intact.
///
/// DNGs go through `CIRAWFilter` with `boostAmount 0` (no contrast "look")
/// and `extendedDynamicRangeAmount 2` — the Stage-0 probe showed EDR defaults
/// to 0, which silently clamps the headroom the files were authored to carry.
/// JPEGs decode through ImageIO; their 8-bit pixels gain nothing from the
/// float path, but all *math* downstream still runs in half-float linear.
public final class LinearFrameDecoder {
    public struct Frame {
        public let texture: MTLTexture
        /// The as-shot illuminant the decoder reported (D65 for JPEGs) — the
        /// anchor for `GradeReference`.
        public let asShotTemperatureK: Double
        public let asShotTint: Double
    }

    public let device: MTLDevice
    private let context: CIContext
    private let workingSpace: CGColorSpace

    public init(device: MTLDevice? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw LapseError.metalUnavailable
        }
        guard let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else {
            throw LapseError.gpuSetupFailed("extended linear Display P3 unavailable")
        }
        self.device = device
        self.workingSpace = linearP3
        self.context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: linearP3,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
        ])
    }

    /// Decodes `url` at `scale` (1 = full sensor resolution, 0.5 = half — the
    /// editor-preview size). The texture is freshly created per call; cache at
    /// the call site.
    public func decode(url: URL, scale: Float = 1) throws -> Frame {
        let isRAW = ["dng", "raw"].contains(url.pathExtension.lowercased())
        if isRAW, let raw = CIRAWFilter(imageURL: url) {
            raw.boostAmount = 0
            raw.extendedDynamicRangeAmount = 2
            raw.scaleFactor = scale
            guard let image = raw.outputImage else {
                throw LapseError.imageLoadFailed(url)
            }
            return Frame(
                texture: try render(image),
                asShotTemperatureK: Double(raw.neutralTemperature),
                asShotTint: Double(raw.neutralTint))
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: 20000,
              ] as CFDictionary) else {
            throw LapseError.imageLoadFailed(url)
        }
        var image = CIImage(cgImage: decoded)
        if scale != 1 {
            image = image.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        }
        return Frame(texture: try render(image), asShotTemperatureK: 6500, asShotTint: 0)
    }

    /// Renders a CIImage into a fresh rgba16Float texture in the working
    /// space, flipped so the texture's row 0 is the image's top (Core Image
    /// is bottom-up; every consumer of these textures is top-down).
    private func render(_ image: CIImage) throws -> MTLTexture {
        let extent = image.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else {
            throw LapseError.gpuSetupFailed("decode produced an empty image")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw LapseError.textureCreationFailed("\(width)x\(height) linear decode")
        }
        let flipped = image
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1)
                .translatedBy(x: -extent.origin.x, y: -extent.maxY))
        context.render(
            flipped, to: texture, commandBuffer: nil,
            bounds: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
            colorSpace: workingSpace)
        return texture
    }

    /// Wraps an engine-output texture (display-referred linear P3, top-down)
    /// back into a CIImage tagged for the working space, ready for JPEG/HEIF
    /// encode or display conversion.
    public func image(from texture: MTLTexture) throws -> CIImage {
        guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: workingSpace]) else {
            throw LapseError.gpuSetupFailed("could not wrap the graded texture")
        }
        // Undo the top-down flip for Core Image's bottom-up world.
        return image.transformed(by: CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -image.extent.height))
    }

    /// A display-ready CGImage of a graded texture: 8-bit Display P3, for the
    /// preview surfaces and CGImage-based exporters.
    public func cgImage(from texture: MTLTexture) throws -> CGImage {
        guard let displayP3 = CGColorSpace(name: CGColorSpace.displayP3) else {
            throw LapseError.gpuSetupFailed("Display P3 unavailable")
        }
        let image = try image(from: texture)
        guard let rendered = context.createCGImage(
            image, from: image.extent, format: .RGBA8, colorSpace: displayP3) else {
            throw LapseError.gpuSetupFailed("CGImage render failed")
        }
        return rendered
    }

    /// Encodes a graded texture as JPEG bytes in Display P3.
    public func jpegData(from texture: MTLTexture, quality: Double = 0.95) throws -> Data {
        guard let displayP3 = CGColorSpace(name: CGColorSpace.displayP3) else {
            throw LapseError.gpuSetupFailed("Display P3 unavailable")
        }
        let image = try image(from: texture)
        guard let data = context.jpegRepresentation(
            of: image, colorSpace: displayP3,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]) else {
            throw LapseError.gpuSetupFailed("JPEG encode failed")
        }
        return data
    }
}

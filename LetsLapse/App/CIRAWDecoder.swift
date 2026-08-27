#if canImport(CoreImage)
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import LetsLapseKit
import Metal

/// The `.cirawFilter` decode path, as a standalone surface.
///
/// `LinearFrameDecoder` in the Kit is what the app and the CLI actually render
/// through — it owns the texture pool, the working colour space and the
/// top-down flip, and it takes a `RawDecodePath` so the production path stays
/// one code path rather than two. This type is the same decode expressed
/// directly, for callers that want a `CIImage` rather than a graded texture:
/// comparison harnesses, one-off diagnostics, and anything that needs to hand
/// the raw converter's output to another Core Image graph.
///
/// The one thing it demonstrates that the Bradford path cannot: white balance
/// applied *inside* the converter. `CIRAWFilter.neutralTemperature` moves the
/// declared illuminant in camera space, ahead of Apple's device colour
/// profile, so the profile's tone-dependent rendering sees re-balanced camera
/// data — the ordering Lightroom uses, and the reason a downstream 3×3 in
/// Display P3 can never quite reproduce it in the shadows.
@available(iOS 15, macOS 12, *)
public enum CIRAWDecoder {

    public enum Error: Swift.Error, LocalizedError {
        case notRaw(URL)
        case noOutput(URL)
        case noAsShotNeutral(URL)
        case textureCreationFailed

        public var errorDescription: String? {
            switch self {
            case .notRaw(let url):
                return "CIRAWFilter could not open \(url.lastPathComponent) as a raw file."
            case .noOutput(let url):
                return "CIRAWFilter produced no image for \(url.lastPathComponent)."
            case .noAsShotNeutral(let url):
                return "CIRAWFilter reports no usable as-shot neutral for "
                    + "\(url.lastPathComponent), so there is nothing to declare an "
                    + "illuminant against."
            case .textureCreationFailed:
                return "Could not allocate a texture for the decoded frame."
            }
        }
    }

    /// Decode a DNG at `url` to a linear-light `CIImage` using `CIRAWFilter`.
    ///
    /// - Parameters:
    ///   - url: the raw file.
    ///   - temperatureMiredOffset: mired offset from as-shot, in the same
    ///     units and with the same sign convention as
    ///     `GradeRecipe.temperatureMired` — positive renders warmer.
    ///   - tint: −1…+1, in `GradeRecipe`'s units and with its sign convention,
    ///     mapped onto the converter's own travel by
    ///     `LinearFrameDecoder.cirawTintPerRecipeUnit` — which is negative, and
    ///     about a third of the ±150 the naive reading suggests. See that
    ///     constant for the measurement.
    ///   - boostAmount: 1.0 = as captured (Apple's default "look"); the grade
    ///     engine asks for 0, because its own base curve is fitted to supply
    ///     that look and taking both would apply it twice.
    ///   - extendedDynamicRange: 0…2. The engine uses 2 — the Stage-0 probe
    ///     showed this defaults to 0, which silently clamps the headroom the
    ///     files were authored to carry.
    ///   - scale: 1 = full sensor resolution.
    ///
    /// The output is in the converter's own linear working space; render it
    /// through a context whose working space is extended linear Display P3
    /// (which is what `toTexture` does) to land where the grade engine expects.
    public static func decode(
        url: URL,
        temperatureMiredOffset: Float,
        tint: Float,
        boostAmount: Float = 0,
        extendedDynamicRange: Float = 2,
        scale: Float = 1
    ) throws -> CIImage {
        guard let raw = CIRAWFilter(imageURL: url) else { throw Error.notRaw(url) }
        raw.boostAmount = boostAmount
        raw.extendedDynamicRangeAmount = extendedDynamicRange
        raw.scaleFactor = scale

        // Read the file's neutral point once, before either half of it is
        // written: writing one moves the other, so a second read describes the
        // declaration rather than the file. `LinearFrameDecoder` snapshots the
        // same way, and this type has to match it to be a fair comparison.
        let reportedK = Double(raw.neutralTemperature)
        let reportedTint = Double(raw.neutralTint)

        if temperatureMiredOffset != 0 || tint != 0 {
            // A reading the converter's own travel cannot contain is not a
            // reading — declaring an illuminant from it renders the frame
            // violently mis-balanced rather than slightly off. See
            // `LinearFrameDecoder.isUsableNeutral`.
            guard LinearFrameDecoder.isUsableNeutral(
                temperatureK: reportedK, tint: reportedTint) else {
                throw Error.noAsShotNeutral(url)
            }
            // The file's own as-shot neutral is the baseline; the recipe
            // carries an offset from it, not an absolute Kelvin, so a preset
            // means "warm it a little" on every frame of a shoot rather than
            // pinning them all to one temperature.
            let asShotMired = 1e6 / min(max(reportedK, 1667), 25000)
            let declaredMired = min(max(asShotMired - Double(temperatureMiredOffset), 40), 600)
            raw.neutralTemperature = Float(1e6 / declaredMired)
            raw.neutralTint = Float(reportedTint) + tint * LinearFrameDecoder.cirawTintPerRecipeUnit
        }

        guard let image = raw.outputImage else { throw Error.noOutput(url) }
        return image
    }

    /// The as-shot illuminant a file reports, for anchoring a `GradeReference`.
    public static func asShotNeutral(url: URL) -> (temperatureK: Double, tint: Double)? {
        guard let raw = CIRAWFilter(imageURL: url) else { return nil }
        return (Double(raw.neutralTemperature), Double(raw.neutralTint))
    }

    /// Renders a decoded `CIImage` into a fresh `rgba16Float` texture in the
    /// engine's working space.
    ///
    /// Top row first: Core Image is bottom-up and every consumer of these
    /// textures is top-down, so the image is flipped on the way in — the same
    /// convention `LinearFrameDecoder.render` uses. Getting this wrong does
    /// not fail, it silently renders the picture upside down.
    public static func toTexture(
        _ image: CIImage, device: MTLDevice, commandQueue: MTLCommandQueue
    ) throws -> MTLTexture {
        let extent = image.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { throw Error.textureCreationFailed }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw Error.textureCreationFailed
        }

        let context = self.context(for: device)
        let flipped = image.transformed(
            by: CGAffineTransform(scaleX: 1, y: -1)
                .translatedBy(x: -extent.origin.x, y: -extent.maxY))
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw Error.textureCreationFailed
        }
        context.render(
            flipped, to: texture, commandBuffer: commandBuffer,
            bounds: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
            colorSpace: workingSpace)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return texture
    }

    /// Extended linear Display P3 — the engine's working space, and the space
    /// the returned textures are tagged as being in.
    public static let workingSpace: CGColorSpace = {
        CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            ?? CGColorSpaceCreateDeviceRGB()
    }()

    /// One context per device, since building a `CIContext` is expensive and
    /// these are stateless renders.
    private static let contextLock = NSLock()
    nonisolated(unsafe) private static var contexts: [ObjectIdentifier: CIContext] = [:]

    private static func context(for device: MTLDevice) -> CIContext {
        contextLock.lock()
        defer { contextLock.unlock() }
        let key = ObjectIdentifier(device)
        if let hit = contexts[key] { return hit }
        let made = CIContext(mtlDevice: device, options: [
            .workingColorSpace: workingSpace,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
        ])
        contexts[key] = made
        return made
    }
}
#endif

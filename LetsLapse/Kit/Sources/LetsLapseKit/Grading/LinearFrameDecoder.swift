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
        /// The file these pixels came from, when there is one.
        public let sourceURL: URL?
        /// Which path decoded them. Carried so the grade side knows whether
        /// the white balance is already in the pixels (`.cirawFilter`) or
        /// still owed as a 3×3 (everything else).
        public let decodePath: RawDecodePath

        public init(
            texture: MTLTexture,
            asShotTemperatureK: Double,
            asShotTint: Double,
            sourceURL: URL? = nil,
            decodePath: RawDecodePath = .bradfordAdaptation
        ) {
            self.texture = texture
            self.asShotTemperatureK = asShotTemperatureK
            self.asShotTint = asShotTint
            self.sourceURL = sourceURL
            self.decodePath = decodePath
        }

        /// The `GradeReference` for this frame, wired to the path that decoded
        /// it. Callers that grade a *crop* must pass the whole picture's long
        /// edge rather than the crop's — see `GradeRenderer.encode`.
        public func reference(longEdge: Double? = nil) -> GradeReference {
            GradeReference(
                asShotTemperatureK: asShotTemperatureK,
                asShotTint: asShotTint,
                longEdge: longEdge ?? Double(max(texture.width, texture.height)),
                sourceURL: sourceURL,
                decodePath: decodePath)
        }
    }

    public let device: MTLDevice
    private let context: CIContext
    private let workingSpace: CGColorSpace
    private let commandQueue: MTLCommandQueue

    public init(device: MTLDevice? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw LapseError.metalUnavailable
        }
        guard let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else {
            throw LapseError.gpuSetupFailed("extended linear Display P3 unavailable")
        }
        guard let queue = device.makeCommandQueue() else {
            throw LapseError.gpuSetupFailed("could not create a decode command queue")
        }
        self.device = device
        self.workingSpace = linearP3
        self.commandQueue = queue
        self.context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: linearP3,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
        ])
    }

    /// How much `CIRAWFilter.neutralTint` moves per unit of recipe tint, so
    /// `.cirawFilter` renders the same green–magenta shift `.bradfordAdaptation`
    /// does. Measured, not assumed — and note the sign.
    ///
    /// **Direction.** Both paths' controls *declare* the illuminant, but they
    /// declare it with opposite polarity. Recipe tint is a Bradford source
    /// white: positive lowers chromaticity y (`ToneMath.whitePointXYZ`), which
    /// declares the light more magenta and therefore renders the picture
    /// *greener* — the same "declare it, and we adapt away from it" convention
    /// the mired offset uses. `CIRAWFilter.neutralTint` runs the other way:
    /// raising it renders magenta. So a recipe unit is a *negative* step here.
    ///
    /// **Magnitude.** Adobe's tint axis (which Apple's ±150 travel follows)
    /// is an offset along the perpendicular to the Planckian locus in CIE 1960
    /// uv, scaled by 3000 — so 150 units ≈ 0.05 in uv. Bradford's is 0.05 per
    /// unit in xy *y*, and near D65 ∂v/∂y ≈ 0.356, so matching Bradford's
    /// travel predicts ≈ 53 converter units per recipe unit rather than 150.
    /// Sweeping the constant against Bradford renders of the same frame at
    /// tint ±20/±40/±80 puts the least-squares fit at 50, which is what this
    /// is. Residual is ~6% and concentrated at the ends of the travel, where
    /// balancing in camera space genuinely does not equal balancing in P3.
    ///
    /// Before this was measured the constant was 150 with no sign flip, which
    /// put the paths ~3× apart *and* pushed them in opposite directions: a
    /// recipe carrying tint 0.40 rendered a heavy magenta cast under
    /// `.cirawFilter` where `.bradfordAdaptation` rendered a mild green one.
    public static let cirawTintPerRecipeUnit: Float = -50

    /// Decodes `url` at `scale` (1 = full sensor resolution, 0.5 = half — the
    /// editor-preview size). The texture is freshly created per call; cache at
    /// the call site.
    ///
    /// `path` selects the raw pipeline. Only `.cirawFilter` changes what
    /// happens here — it moves the white balance *into* the converter, so the
    /// temperature/tint the recipe asks for is applied in camera space ahead
    /// of Apple's device profile instead of as a 3×3 in P3 afterwards. Every
    /// other path decodes at the as-shot neutral exactly as this decoder
    /// always has, and settles white balance later in `GradeRenderer`.
    ///
    /// Because of that, `recipe` participates in the decode on the
    /// `.cirawFilter` path and nowhere else: a caller that caches decoded
    /// frames must key on the recipe's white balance under that path, or a
    /// temperature drag will hand back yesterday's pixels.
    public func decode(
        url: URL,
        scale: Float = 1,
        path: RawDecodePath = .bradfordAdaptation,
        recipe: GradeRecipe = .neutral
    ) throws -> Frame {
        // The scaffolded path renders as the default one rather than failing;
        // `DCPDecoder` is the thing that reports it is not implemented.
        let effective: RawDecodePath = RawDecodePathRegistry.isAvailable(path)
            ? path : .bradfordAdaptation
        let isRAW = ["dng", "raw"].contains(url.pathExtension.lowercased())
        if isRAW, let raw = CIRAWFilter(imageURL: url) {
            raw.boostAmount = 0
            raw.extendedDynamicRangeAmount = 2
            raw.scaleFactor = scale
            // What the file was shot at, before we move it — read once, up
            // front, because writing either half of the neutral point moves
            // the other and a second read would no longer describe the file.
            let reportedK = Double(raw.neutralTemperature)
            let reportedTint = Double(raw.neutralTint)
            let usableNeutral = Self.isUsableNeutral(temperatureK: reportedK, tint: reportedTint)
            let asShotK = usableNeutral ? reportedK : Self.fallbackNeutralK
            let asShotTint = usableNeutral ? reportedTint : 0

            let balancesInConverter = effective == .cirawFilter || effective == .dcpProfile
            let asksForBalance = recipe.temperatureMired != 0 || recipe.tint != 0
            var balanced = false
            if balancesInConverter, asksForBalance, usableNeutral {
                // Same declaration semantics as `ToneMath.whiteBalanceMatrix`:
                // a positive mired offset lowers the declared mired, raises the
                // declared Kelvin, and renders warmer.
                let asShotMired = 1e6 / min(max(asShotK, 1667), 25000)
                let declaredMired = min(max(asShotMired - Double(recipe.temperatureMired), 40), 600)
                let declaredK = Float(1e6 / declaredMired)
                let declaredTint = Float(asShotTint) + recipe.tint * Self.cirawTintPerRecipeUnit
                raw.neutralTemperature = declaredK
                raw.neutralTint = declaredTint
                // Read back: the properties are plain stores on every platform
                // this has been measured on, so a mismatch means the converter
                // refused the write and the pixels are about to come back at
                // the as-shot neutral with the recipe's balance nowhere.
                balanced = abs(raw.neutralTemperature - declaredK) <= max(declaredK * 0.01, 1)
                    && abs(raw.neutralTint - declaredTint) <= 1
                if !balanced {
                    lastConverterBalanceFallbackReason =
                        "CIRAWFilter did not take the declared neutral for "
                        + "\(url.lastPathComponent) (asked \(Int(declaredK)) K / "
                        + "\(Int(declaredTint)), read back \(Int(raw.neutralTemperature)) K / "
                        + "\(Int(raw.neutralTint)))"
                }
            } else if balancesInConverter, asksForBalance {
                lastConverterBalanceFallbackReason =
                    "\(url.lastPathComponent) reports no usable as-shot neutral "
                    + "(\(reportedK) K / \(reportedTint))"
            } else {
                lastConverterBalanceFallbackReason = nil
            }

            guard let image = raw.outputImage else {
                throw LapseError.imageLoadFailed(url)
            }
            var texture = try render(image)
            if effective == .dcpProfile {
                texture = try applyDCPProfile(to: texture, url: url, temperatureK: Float(asShotK))
            }
            return Frame(
                texture: texture,
                // The anchor stays the as-shot illuminant whatever we asked the
                // converter to render at — `GradeReference` means "what this
                // file was shot under", and the recipe's offset is measured
                // from it. Reporting the moved value would make the offset
                // compound on the next render.
                asShotTemperatureK: asShotK,
                asShotTint: asShotTint,
                sourceURL: url,
                decodePath: Self.reportedPath(
                    effective, balanceWasAsked: asksForBalance, balancedInConverter: balanced))
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
        // Not raw: there is no converter to balance inside, so the frame
        // reports `.bradfordAdaptation` however it was asked for. Reporting
        // the requested path instead would tell `ToneMath.wbMatrix` the pixels
        // were already balanced under `.cirawFilter`, and the recipe's
        // temperature and tint would then be applied nowhere at all. Cache
        // keys are unaffected: every call site keys on the path it *asked*
        // for (`PhotoGrader.decodeToken`), not on the one the frame reports.
        lastConverterBalanceFallbackReason = nil
        return Frame(
            texture: try render(image), asShotTemperatureK: Self.fallbackNeutralK, asShotTint: 0,
            sourceURL: url, decodePath: .bradfordAdaptation)
    }

    // MARK: - White balance in the converter

    /// Why the last decode balanced downstream instead of inside the raw
    /// converter, if it did.
    ///
    /// Same posture as `lastDCPFallbackReason`: the path degrades rather than
    /// throwing, and degrading *silently* would be the worst of the three.
    public private(set) var lastConverterBalanceFallbackReason: String?

    /// The illuminant a frame is anchored to when the file has none to report.
    /// D65, the same neutral the non-raw branch has always assumed.
    public static let fallbackNeutralK: Double = 6500

    /// Whether `CIRAWFilter` reported an as-shot neutral this decoder can
    /// build a *declared* illuminant from.
    ///
    /// The check exists because the failure it catches is silent and severe.
    /// `.cirawFilter` does not nudge the pixels — it tells the converter what
    /// light the picture was taken under, and the converter adapts away from
    /// whatever it is told. Feed that a bad reading and the clamp below turns
    /// it into a *plausible-looking* extreme: a zero comes out of
    /// `min(max(k, 1667), 25000)` as 1667 K, so a +60 mired nudge on a
    /// daylight frame declares the light to be candlelight and renders the
    /// whole frame violet. Bradford cannot fail this way — its matrix is
    /// anchored on the same reading but applied as a *relative* adaptation, so
    /// a bad anchor costs a little accuracy rather than the picture.
    ///
    /// The bounds are the converter's own travel: 1667…25000 K is what
    /// `neutralTemperature` accepts, ±150 what Adobe's (and Apple's) tint axis
    /// spans. Anything outside them, or not finite, is not a reading.
    public static func isUsableNeutral(temperatureK: Double, tint: Double) -> Bool {
        guard temperatureK.isFinite, tint.isFinite else { return false }
        guard temperatureK >= 1667, temperatureK <= 25000 else { return false }
        return abs(tint) <= 150
    }

    /// Which path a decoded frame should report — which is to say, *where its
    /// white balance is*, since that is the only question `ToneMath.wbMatrix`
    /// asks the answer.
    ///
    /// A `.cirawFilter` or `.dcpProfile` decode that could not declare its
    /// illuminant reports `.bradfordAdaptation`, so the balance the recipe
    /// asked for is applied downstream instead of being dropped between the
    /// two halves of the pipeline. A decode that was never asked to balance
    /// anything reports the path it ran, which is what it did.
    public static func reportedPath(
        _ effective: RawDecodePath, balanceWasAsked: Bool, balancedInConverter: Bool
    ) -> RawDecodePath {
        switch effective {
        case .bradfordAdaptation, .forwardMatrix:
            return effective
        case .cirawFilter, .dcpProfile:
            guard balanceWasAsked, !balancedInConverter else { return effective }
            return .bradfordAdaptation
        }
    }

    // MARK: - Adobe DCP

    /// Why the last `.dcpProfile` decode fell back, if it did.
    ///
    /// The path degrades rather than throwing when a camera has no Adobe
    /// profile — the same posture the rest of this file takes towards missing
    /// colour data, and the only one that survives a six-hundred-frame render
    /// where the alternative is failing at frame one. Degrading silently would
    /// be worse than either, so the reason is kept here for the settings
    /// picker and the tests to read back.
    public private(set) var lastDCPFallbackReason: String?

    private var dcpApplier: DCPProfileApplier?
    private var dcpProfileCache: [String: DCPFile] = [:]

    /// Runs the camera's Adobe profile over a decoded frame.
    ///
    /// The pixels arriving here have already been through `CIRAWFilter`, so
    /// Apple's device profile is in them — and that fact decides what of the
    /// DCP may be used:
    ///
    /// - Its **forward matrix** must not be. That matrix maps *camera* RGB to
    ///   XYZ, and these pixels left camera space in the converter; applying it
    ///   would stack a second camera profile on the first.
    /// - Its **hue/sat map** must not be either, for the same reason one step
    ///   further in: it is Adobe's calibration of this sensor's raw deviation,
    ///   which Apple's profile has already corrected. `DCPTableAblationTests`
    ///   measures the double-correction — it pushes shadow blue *up* 17%,
    ///   past where the path started.
    /// - Its **look table** is the piece that belongs here. It is authored to
    ///   sit on top of a rendered image, which is precisely what this is, and
    ///   it is the tone-dependent hue map the other three paths structurally
    ///   cannot supply. On the calibration frame it pulls the shadow cast down
    ///   8.9% from the `.cirawFilter` baseline.
    ///
    /// So this is the achievable share of Lightroom parity without demosaicing
    /// the Bayer data ourselves. Reaching the rest means decoding in genuine
    /// camera space, at which point the matrix and the hue/sat map become
    /// correct too and `DCPProfileApplier.Tables` is the switch for them.
    private func applyDCPProfile(
        to texture: MTLTexture, url: URL, temperatureK: Float
    ) throws -> MTLTexture {
        do {
            guard let model = DngMetadata.cameraModel(url: url) else {
                throw DCPProfileLocator.Error.noProfileFound(model: url.lastPathComponent)
            }
            let profileURL = try DCPProfileLocator.profile(forCameraModel: model)
            let key = profileURL.path
            let profile: DCPFile
            if let cached = dcpProfileCache[key] {
                profile = cached
            } else {
                profile = try DCPParser.parse(url: profileURL)
                dcpProfileCache[key] = profile
            }
            let applier: DCPProfileApplier
            if let existing = dcpApplier {
                applier = existing
            } else {
                applier = try DCPProfileApplier(device: device)
                dcpApplier = applier
            }
            lastDCPFallbackReason = nil
            return try applier.apply(
                profile, to: texture, temperatureK: temperatureK,
                commandQueue: commandQueue, cacheKey: key)
        } catch {
            lastDCPFallbackReason = error.localizedDescription
            return texture
        }
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

    /// Copies a pixel rect out of a decoded frame into a texture of its own.
    ///
    /// The pixel-peep path: the editor's 1:1 view and its detail loupe grade a
    /// few hundred thousand pixels of a twelve-megapixel frame rather than the
    /// whole thing, so a noise slider can move at the frame rate of the drag.
    /// `rect` is in the texture's own top-down pixel coordinates and is
    /// clamped to it; grade the result with a `GradeReference` carrying the
    /// *full* frame's long edge, or every spatial footprint will be sized for
    /// the crop (see `GradeRenderer.encode`).
    public func crop(_ texture: MTLTexture, to rect: CGRect) throws -> MTLTexture {
        let bounds = CGRect(x: 0, y: 0, width: texture.width, height: texture.height)
        let region = rect.integral.intersection(bounds)
        guard !region.isNull, region.width >= 1, region.height >= 1 else {
            throw LapseError.gpuSetupFailed("crop rect falls outside the frame")
        }
        let width = Int(region.width)
        let height = Int(region.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let destination = device.makeTexture(descriptor: descriptor) else {
            throw LapseError.textureCreationFailed("\(width)x\(height) crop")
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw LapseError.gpuSetupFailed("could not encode the crop blit")
        }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: Int(region.minX), y: Int(region.minY), z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: destination, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw LapseError.gpuSetupFailed("crop blit failed: \(error.localizedDescription)")
        }
        return destination
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

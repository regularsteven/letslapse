import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import LetsLapseKit
import Metal
import UniformTypeIdentifiers

/// Non-destructive colour grades for any capture — Photo, Interval or Video.
/// Each preset is a short chain of Core Image parametric filters — no LUT/.cube
/// files — so a grade is just math applied to the decoded pixels. The original
/// file on disk is never rewritten; the grade is re-derived on demand and baked
/// in only where a new file is written: a rendered version, or an export.
enum PhotoPreset: String, CaseIterable, Identifiable, Codable {
    /// On by default: a gentle balance — pulled highlights, lifted shadows, a
    /// touch more colour, and a warm auto white balance.
    case natural = "Natural"
    /// Filmic: deep shadow lift, tamed highlights, desaturated and cooler.
    case cinema = "Cinema"
    /// Faded matte: lifted blacks, crushed whites, low contrast.
    case matte = "Matte"
    /// Punchy: strong saturation and contrast with highlights held back.
    case vivid = "Vivid"
    /// Pass-through — the file exactly as captured.
    case original = "Original"

    var id: String { rawValue }
    var displayName: String { rawValue }

    /// The grade applied to a photo capture until the user picks otherwise.
    /// Original since the engine rebuild: a new capture shows honest pixels,
    /// and an untouched project exports its original bytes. Projects that
    /// existed before the change were stamped with an explicit "Natural" so
    /// their look didn't shift (see `AppModel.stampLegacyDefaultPresets`).
    static let `default`: PhotoPreset = .original

    /// The order the chips appear in the strip.
    static let strip: [PhotoPreset] = [.natural, .cinema, .matte, .vivid, .original]

    /// Resolve a stored raw name to a preset, falling back to the default so a
    /// missing or unknown value still renders something sensible.
    static func resolve(_ name: String?) -> PhotoPreset {
        guard let name, let preset = PhotoPreset(rawValue: name) else { return .default }
        return preset
    }

    /// The engine-side base recipe each chip stands for — the old Core Image
    /// chains re-expressed as tone-engine parameters against the same
    /// calibration frame. The manual sliders layer on top of these.
    var recipe: GradeRecipe {
        var recipe = GradeRecipe()
        switch self {
        case .original:
            break
        case .natural:
            recipe.highlights = -0.25
            recipe.shadows = 0.18
            recipe.vibrance = 0.10
            recipe.temperatureMired = 8
        case .cinema:
            recipe.highlights = -0.45
            recipe.shadows = 0.35
            recipe.contrast = -0.05
            recipe.saturation = -0.15
            recipe.temperatureMired = -15
        case .matte:
            recipe.blacks = 0.35
            recipe.whites = -0.10
            recipe.contrast = -0.15
            recipe.saturation = -0.08
        case .vivid:
            recipe.highlights = -0.15
            recipe.contrast = 0.12
            recipe.vibrance = 0.30
            recipe.saturation = 0.12
        }
        return recipe
    }

    /// Applies this preset's filter chain to a working image. `Original` passes
    /// the image straight through.
    func apply(to image: CIImage) -> CIImage {
        switch self {
        case .original:
            return image

        case .natural:
            // Reduce highlights (~-0.15), lift shadows (~+0.15), a slight
            // saturation boost, and a warm auto white balance.
            var out = Self.highlightShadow(image, highlight: 0.85, shadow: 0.15)
            out = Self.temperature(out, targetKelvin: 6100) // < 6500 ⇒ warmer
            out = Self.colorControls(out, saturation: 1.10, contrast: 1.0)
            return out

        case .cinema:
            // Strong shadow lift (+0.25), reduced highlights (-0.25),
            // desaturated (~-0.15), cooler tint.
            var out = Self.highlightShadow(image, highlight: 0.75, shadow: 0.25)
            out = Self.temperature(out, targetKelvin: 7200) // > 6500 ⇒ cooler
            out = Self.colorControls(out, saturation: 0.85, contrast: 0.97)
            return out

        case .matte:
            // Lifted blacks (+0.2), crushed whites (-0.1), low contrast, faded.
            var out = Self.highlightShadow(image, highlight: 0.90, shadow: 0.20)
            out = Self.colorControls(out, saturation: 0.92, contrast: 0.88)
            out = Self.liftBlacks(out, lift: 0.055, crushWhites: 0.04)
            return out

        case .vivid:
            // Boosted saturation (+0.3), contrast up, highlights slightly pulled.
            var out = Self.highlightShadow(image, highlight: 0.90, shadow: 0.05)
            out = Self.vibrance(out, amount: 0.3)
            out = Self.colorControls(out, saturation: 1.12, contrast: 1.08)
            return out
        }
    }

    // MARK: - Filter helpers

    /// `CIHighlightShadowAdjust`: `highlight` in 0…1 (lower darkens highlights),
    /// `shadow` in -1…1 (positive lifts shadows).
    static func highlightShadow(_ image: CIImage, highlight: Float, shadow: Float) -> CIImage {
        guard let filter = CIFilter(name: "CIHighlightShadowAdjust") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(highlight, forKey: "inputHighlightAmount")
        filter.setValue(shadow, forKey: "inputShadowAmount")
        return filter.outputImage ?? image
    }

    /// `CIColorControls`: saturation and contrast (1.0 = unchanged).
    static func colorControls(_ image: CIImage, saturation: Float, contrast: Float) -> CIImage {
        guard let filter = CIFilter(name: "CIColorControls") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(saturation, forKey: kCIInputSaturationKey)
        filter.setValue(contrast, forKey: kCIInputContrastKey)
        return filter.outputImage ?? image
    }

    /// `CIVibrance`: raises muted colours more than already-saturated ones.
    static func vibrance(_ image: CIImage, amount: Float) -> CIImage {
        guard let filter = CIFilter(name: "CIVibrance") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(amount, forKey: "inputAmount")
        return filter.outputImage ?? image
    }

    /// `CITemperatureAndTint` as a white-balance nudge. Treats the source as a
    /// 6500K neutral and remaps it: a lower target Kelvin warms the image, a
    /// higher one cools it.
    private static func temperature(_ image: CIImage, targetKelvin: CGFloat) -> CIImage {
        guard let filter = CIFilter(name: "CITemperatureAndTint") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
        filter.setValue(CIVector(x: targetKelvin, y: 0), forKey: "inputTargetNeutral")
        return filter.outputImage ?? image
    }

    /// Fades the tonal range via `CIColorMatrix`: `lift` raises the black point
    /// (a positive bias on every channel), `crushWhites` pulls the ceiling down
    /// (a sub-1 gain), giving the matte's washed look.
    private static func liftBlacks(_ image: CIImage, lift: CGFloat, crushWhites: CGFloat) -> CIImage {
        guard let filter = CIFilter(name: "CIColorMatrix") else { return image }
        let gain = 1 - crushWhites
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: gain, y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: gain, z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: gain, w: 0), forKey: "inputBVector")
        filter.setValue(CIVector(x: lift, y: lift, z: lift, w: 0), forKey: "inputBiasVector")
        return filter.outputImage ?? image
    }
}

/// Renders graded stills off a shared Core Image context and memoises the
/// result per (file, modification time, preset, size) so flicking between chips
/// is instant after the first render of each.
enum PhotoGrader {
    /// GPU-backed and thread-safe; reused for every render.
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// The white point to grade against when a file declares none: D65, which is
    /// what sRGB JPEGs and every video frame are written to. Only the
    /// white-balance control cares, and only relative to this anchor.
    static let neutralKelvin: CGFloat = 6500

    /// The whole grade as one function of an image, for callers that hold pixels
    /// rather than a file: the video composition that bakes a grade into every
    /// frame of a movie, and the still paths below.
    ///
    /// Both arguments are optional because that is how a project stores them —
    /// nil means "never chosen". Nil (or a grade that is `Original` with neutral
    /// sliders) gives the identity closure, so a caller can build the chain
    /// unconditionally and let the no-op case cost nothing.
    static func filterChain(
        preset: PhotoPreset?,
        adjustments: PhotoAdjustments?,
        asShotKelvin: CGFloat = neutralKelvin
    ) -> (CIImage) -> CIImage {
        let preset = preset ?? .original
        let adjustments = adjustments ?? .neutral
        guard preset != .original || !adjustments.isNeutral else { return { $0 } }
        return { image in
            let out = preset.apply(to: image)
            guard !adjustments.isNeutral else { return out }
            return adjust(out, adjustments, asShotKelvin: asShotKelvin)
        }
    }

    /// `filterChain` for a project's stored grade.
    static func filterChain(_ grade: PhotoGrade, asShotKelvin: CGFloat = neutralKelvin) -> (CIImage) -> CIImage {
        filterChain(preset: grade.preset, adjustments: grade.adjustments, asShotKelvin: asShotKelvin)
    }

    /// CGImage isn't an `AnyObject`, so box it to live in `NSCache`.
    private final class Box { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 24
        // Previews are ~8 MB each; keep the whole cache well under what
        // would pressure a phone that is also running a capture session.
        cache.totalCostLimit = 192 * 1024 * 1024
        return cache
    }()

    // The engine stack: one decoder and one engine per process, shared by
    // every surface. Both are cheap to hold and thread-safe to share; the
    // per-recipe renderers are made per call.
    private static let linearDecoder = try? LinearFrameDecoder()
    private static let gradeEngine: GradeEngine? = {
        guard let decoder = linearDecoder else { return nil }
        return try? GradeEngine(device: decoder.device)
    }()

    /// Decoded linear frames, keyed `path|mtime|scale`. A slider tick re-runs
    /// only the kernel graph on the cached texture, never the decoder.
    private final class FrameBox {
        let frame: LinearFrameDecoder.Frame
        init(_ frame: LinearFrameDecoder.Frame) { self.frame = frame }
    }
    private static let decodedCache: NSCache<NSString, FrameBox> = {
        let cache = NSCache<NSString, FrameBox>()
        cache.countLimit = 3
        // Three 2000 px half-float previews ≈ 150 MB; full-resolution decodes
        // are deliberately never cached (they're one-shot exports).
        cache.totalCostLimit = 220 * 1024 * 1024
        return cache
    }()

    /// Renders `url` through `preset`, then through the manual `adjustments`
    /// on top — the tone engine end to end: linear RAW decode (headroom
    /// intact), the grade kernel, Display P3 out. `maxDimension`, when set,
    /// decodes at reduced scale — cheap, low-memory previews; export passes
    /// `nil` for full resolution. Preview and export share one decoder and one
    /// engine, so what the sliders show is what the export bakes.
    static func render(
        url: URL,
        preset: PhotoPreset,
        adjustments: PhotoAdjustments = .neutral,
        maxDimension: CGFloat? = nil
    ) -> CGImage? {
        let key = cacheKey(url: url, preset: preset, adjustments: adjustments, maxDimension: maxDimension)
        if let cached = cache.object(forKey: key) { return cached.image }
        do {
            let grade = PhotoGrade(preset: preset, adjustments: adjustments)
            let cgImage = try engineRender(url: url, grade: grade, maxDimension: maxDimension)
            if maxDimension != nil {
                cache.setObject(Box(cgImage), forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
            }
            return cgImage
        } catch {
            MediaWorkQueue.note(
                "grade render failed for \(url.lastPathComponent): \(error.localizedDescription)",
                isError: true)
            return nil
        }
    }

    /// The engine path shared by previews, exports and the blend loader.
    static func engineRender(url: URL, grade: PhotoGrade, maxDimension: CGFloat?) throws -> CGImage {
        guard let decoder = linearDecoder, let engine = gradeEngine else {
            throw GradeError.renderFailed
        }
        var scale: Float = 1
        if let maxDimension {
            let longEdge = sourceLongEdge(url: url)
            if longEdge > 0 { scale = min(1, Float(maxDimension) / Float(longEdge)) }
        }
        let frame = try decodedFrame(url: url, scale: scale, decoder: decoder)
        let reference = GradeReference(
            asShotTemperatureK: frame.asShotTemperatureK,
            asShotTint: frame.asShotTint,
            longEdge: Double(max(frame.texture.width, frame.texture.height)))
        let renderer = engine.makeRenderer(grade.recipe, reference: reference)
        let output = try renderer.apply(to: frame.texture)
        return try decoder.cgImage(from: output)
    }

    private static func decodedFrame(
        url: URL, scale: Float, decoder: LinearFrameDecoder
    ) throws -> LinearFrameDecoder.Frame {
        // Full-resolution decodes are one-shot exports; caching one would
        // evict every preview for no gain.
        guard scale < 1 else { return try decoder.decode(url: url, scale: scale) }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(modified)|\(String(format: "%.3f", scale))" as NSString
        if let boxed = decodedCache.object(forKey: key) { return boxed.frame }
        let frame = try decoder.decode(url: url, scale: scale)
        decodedCache.setObject(
            FrameBox(frame), forKey: key,
            cost: frame.texture.width * frame.texture.height * 8)
        return frame
    }

    /// The source's longest pixel edge, from metadata only — sizes the decode
    /// scale without touching pixel data.
    private static func sourceLongEdge(url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return 0
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
        return max(width, height)
    }

    // MARK: - Manual adjustments

    /// The clarity filter's radius at this reference edge length. The radius is
    /// scaled by the actual image size so a 1400 px preview and a 4032 px export
    /// get the same *look* rather than the same pixel radius — without it the
    /// preview understates the effect the export applies.
    private static let clarityReferenceEdge: CGFloat = 1400
    /// A large radius is what separates "clarity" (broad local contrast) from
    /// "sharpening" (a bright outline on every edge). At 10 px the rock/sky
    /// horizon in the calibration frame gained a visible halo; 40 px reads as
    /// local contrast.
    private static let clarityRadius: CGFloat = 40
    /// Clarity 1.0 maps to this unsharp-mask intensity. Calibrated to stop
    /// short of haloing on a high-contrast edge.
    private static let clarityMaxIntensity: CGFloat = 0.5
    /// Vignette 1.0 maps to this `CIVignette` intensity.
    private static let vignetteMaxIntensity: CGFloat = 2.0
    private static let vignetteRadius: CGFloat = 1.5

    /// Applies the manual grade on top of whatever the preset produced.
    ///
    /// This is the *legacy Core Image path*, kept only for the video
    /// composition (`VideoGrader`) until it moves onto the tone engine — a
    /// coarse approximation of the engine's math with parametric CI filters.
    /// Stills never come through here any more.
    ///
    /// Order matters: white balance first (it is a property of the light, so
    /// everything after it grades an already-neutral image), then tone, then
    /// colour, then the two spatial effects. The vignette goes last so it
    /// darkens the finished picture rather than being clarity's input.
    static func adjust(
        _ image: CIImage,
        _ adjustments: PhotoAdjustments,
        asShotKelvin: CGFloat
    ) -> CIImage {
        // Filters like the unsharp mask grow the extent; everything downstream
        // (and the vignette's centre in particular) has to stay keyed to the
        // picture's own bounds.
        let baseExtent = image.extent
        var out = image

        if adjustments.temperature != 0 || adjustments.tint != 0,
           let filter = CIFilter(name: "CITemperatureAndTint") {
            // Same semantics as the engine: the sliders declare the scene's
            // illuminant relative to as-shot; a positive mired offset warms.
            let asShotMired = 1_000_000 / max(Double(asShotKelvin), 1667)
            let declaredMired = min(max(asShotMired - Double(adjustments.temperature), 40), 600)
            filter.setValue(out, forKey: kCIInputImageKey)
            filter.setValue(
                CIVector(x: 1_000_000 / declaredMired, y: CGFloat(adjustments.tint) * 50),
                forKey: "inputNeutral")
            filter.setValue(CIVector(x: asShotKelvin, y: 0), forKey: "inputTargetNeutral")
            out = filter.outputImage ?? out
        }

        if adjustments.exposure != 0, let filter = CIFilter(name: "CIExposureAdjust") {
            filter.setValue(out, forKey: kCIInputImageKey)
            filter.setValue(adjustments.exposure, forKey: kCIInputEVKey)
            out = filter.outputImage ?? out
        }

        if adjustments.highlights < 0 || adjustments.shadows != 0 {
            out = PhotoPreset.highlightShadow(
                out,
                highlight: 1.0 + min(adjustments.highlights, 0),
                shadow: adjustments.shadows)
        }

        if adjustments.whites != 0 || adjustments.blacks != 0,
           let filter = CIFilter(name: "CIColorMatrix") {
            let gain = CGFloat(1 + 0.15 * adjustments.whites)
            let lift = CGFloat(0.06 * adjustments.blacks)
            filter.setValue(out, forKey: kCIInputImageKey)
            filter.setValue(CIVector(x: gain, y: 0, z: 0, w: 0), forKey: "inputRVector")
            filter.setValue(CIVector(x: 0, y: gain, z: 0, w: 0), forKey: "inputGVector")
            filter.setValue(CIVector(x: 0, y: 0, z: gain, w: 0), forKey: "inputBVector")
            filter.setValue(CIVector(x: lift, y: lift, z: lift, w: 0), forKey: "inputBiasVector")
            out = filter.outputImage ?? out
        }

        if adjustments.contrast != 0 || adjustments.saturation != 0 {
            out = PhotoPreset.colorControls(
                out,
                saturation: 1 + 0.8 * adjustments.saturation,
                contrast: 1 + 0.2 * adjustments.contrast)
        }

        if adjustments.vibrance != 0 {
            out = PhotoPreset.vibrance(out, amount: adjustments.vibrance)
        }

        if adjustments.clarity != 0, let filter = CIFilter(name: "CIUnsharpMask") {
            let longest = max(baseExtent.width, baseExtent.height)
            filter.setValue(out, forKey: kCIInputImageKey)
            filter.setValue(clarityRadius * max(longest, 1) / clarityReferenceEdge,
                            forKey: kCIInputRadiusKey)
            filter.setValue(CGFloat(adjustments.clarity) * clarityMaxIntensity,
                            forKey: kCIInputIntensityKey)
            out = (filter.outputImage ?? out).cropped(to: baseExtent)
        }

        if adjustments.vignetteIntensity != 0, let filter = CIFilter(name: "CIVignette") {
            filter.setValue(out, forKey: kCIInputImageKey)
            filter.setValue(CGFloat(adjustments.vignetteIntensity) * vignetteMaxIntensity,
                            forKey: kCIInputIntensityKey)
            filter.setValue(vignetteRadius, forKey: kCIInputRadiusKey)
            out = filter.outputImage ?? out
        }

        return out.cropped(to: baseExtent)
    }

    // MARK: - As-shot white balance

    /// Derived as-shot temperatures, keyed by file. Reading and solving costs a
    /// metadata parse plus a short iteration, and the viewer re-renders on every
    /// slider tick.
    private static let kelvinCache = NSCache<NSString, NSNumber>()

    /// The colour temperature the camera balanced this shot at.
    ///
    /// For a DNG this is solved from the `AsShotNeutral` tag and the two
    /// calibration matrices; for anything else (a JPEG, which has no such tag)
    /// it falls back to D65, the sRGB white point those files are written
    /// against. It is the anchor every other white-balance option is expressed
    /// relative to.
    static func asShotKelvin(url: URL) -> CGFloat {
        let key = url.path as NSString
        if let cached = kelvinCache.object(forKey: key) { return CGFloat(cached.doubleValue) }
        let kelvin = solveAsShotKelvin(url: url) ?? 6500
        kelvinCache.setObject(NSNumber(value: Double(kelvin)), forKey: key)
        return kelvin
    }

    private static func solveAsShotKelvin(url: URL) -> CGFloat? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let dng = properties[kCGImagePropertyDNGDictionary] as? [CFString: Any],
              let neutral = (dng[kCGImagePropertyDNGAsShotNeutral] as? [NSNumber])?.map({ $0.doubleValue }),
              neutral.count == 3,
              let matrix1 = (dng[kCGImagePropertyDNGColorMatrix1] as? [NSNumber])?.map({ $0.doubleValue }),
              let matrix2 = (dng[kCGImagePropertyDNGColorMatrix2] as? [NSNumber])?.map({ $0.doubleValue }),
              matrix1.count == 9, matrix2.count == 9
        else { return nil }

        // The DNG spec's iteration: guess a temperature, interpolate the colour
        // matrix for it, map the camera-space neutral back to XYZ, read the
        // temperature of the chromaticity that falls out, repeat. It converges
        // in a handful of rounds.
        //
        // The illuminants are the ones Apple tags these files with: Standard
        // Illuminant A (2856 K) and D65 (6504 K).
        let t1 = 2856.0, t2 = 6504.0
        var temperature = 5000.0
        for _ in 0..<12 {
            let weight = min(max((1 / temperature - 1 / t2) / (1 / t1 - 1 / t2), 0), 1)
            let interpolated = (0..<9).map { weight * matrix1[$0] + (1 - weight) * matrix2[$0] }
            guard let inverted = invert3x3(interpolated) else { return nil }
            let xyz = multiply3x3(inverted, neutral)
            let sum = xyz[0] + xyz[1] + xyz[2]
            guard sum > 0 else { return nil }
            let next = correlatedColorTemperature(x: xyz[0] / sum, y: xyz[1] / sum)
            guard next.isFinite else { return nil }
            if abs(next - temperature) < 0.5 {
                temperature = next
                break
            }
            temperature = min(max(next, 1667), 25000)
        }
        return CGFloat(temperature)
    }

    /// McCamy's cubic approximation of correlated colour temperature from a CIE
    /// xy chromaticity — accurate well beyond what a white-balance slider needs.
    private static func correlatedColorTemperature(x: Double, y: Double) -> Double {
        let n = (x - 0.3320) / (0.1858 - y)
        return 449 * n * n * n + 3525 * n * n + 6823.3 * n + 5520.33
    }

    private static func multiply3x3(_ m: [Double], _ v: [Double]) -> [Double] {
        [m[0] * v[0] + m[1] * v[1] + m[2] * v[2],
         m[3] * v[0] + m[4] * v[1] + m[5] * v[2],
         m[6] * v[0] + m[7] * v[1] + m[8] * v[2]]
    }

    private static func invert3x3(_ m: [Double]) -> [Double]? {
        let (a, b, c) = (m[0], m[1], m[2])
        let (d, e, f) = (m[3], m[4], m[5])
        let (g, h, i) = (m[6], m[7], m[8])
        let determinant = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        guard abs(determinant) > 1e-12 else { return nil }
        return [(e * i - f * h) / determinant, (c * h - b * i) / determinant, (b * f - c * e) / determinant,
                (f * g - d * i) / determinant, (a * i - c * g) / determinant, (c * d - a * f) / determinant,
                (d * h - e * g) / determinant, (b * g - a * h) / determinant, (a * e - b * d) / determinant]
    }

    /// One frame of a blend, graded — the tone engine at full resolution.
    /// Nothing is cached: a blend reads each frame exactly once, and
    /// full-resolution frames would evict every preview for no gain.
    static func renderForBlend(url: URL, grade: PhotoGrade) throws -> CGImage {
        guard !grade.isIdentity else { return try ImageStacker.loadImage(at: url) }
        return try engineRender(url: url, grade: grade, maxDimension: nil)
    }

    /// The pieces the linear blend path needs: a decode closure handing the
    /// stacker scene-linear half-float textures, and a hook that grades each
    /// OUTPUT frame's mean. The hook runs for EVERY grade, identity included:
    /// the engine's neutral is the hidden base look, not a no-op — skipping it
    /// would render blends scene-linear-flat instead of the way the app has
    /// always rendered them. The renderer is anchored to the first decoded
    /// frame's as-shot metadata, which is uniform across a shoot.
    static func blendSupport(grade: PhotoGrade) throws
        -> (decode: (URL) throws -> MTLTexture,
            hook: (MTLTexture, MTLCommandBuffer, Double) throws -> MTLTexture) {
        guard let decoder = linearDecoder, let engine = gradeEngine else {
            throw GradeError.renderFailed
        }
        final class RendererBox {
            var renderer: GradeRenderer?
            /// The step of the position ladder the renderer is currently
            /// staged on, so a keyframed blend recomputes its tone LUT a few
            /// hundred times across a shoot rather than once per output frame.
            var step = -1
        }
        let box = RendererBox()
        let decode: (URL) throws -> MTLTexture = { url in
            let frame = try decoder.decode(url: url)
            if box.renderer == nil {
                box.renderer = engine.makeRenderer(grade.recipe, reference: GradeReference(
                    asShotTemperatureK: frame.asShotTemperatureK,
                    asShotTint: frame.asShotTint,
                    longEdge: Double(max(frame.texture.width, frame.texture.height))))
                box.step = 0
            }
            return frame.texture
        }
        let hook: (MTLTexture, MTLCommandBuffer, Double) throws
            -> MTLTexture = { texture, commandBuffer, position in
            guard let renderer = box.renderer else { return texture }
            if grade.isKeyframed {
                let step = Int((min(max(position, 0), 1) * Double(gradeLadderSteps)).rounded())
                if step != box.step {
                    box.step = step
                    renderer.restage(grade.recipe(at: Double(step) / Double(gradeLadderSteps)))
                }
            }
            return try renderer.encode(from: texture, commandBuffer: commandBuffer)
        }
        return (decode, hook)
    }

    /// How finely a keyframed grade is sampled across a clip when it is baked.
    ///
    /// A grade that moves has to be re-staged as the render walks the source,
    /// and every re-stage recomputes a tone LUT. 512 steps is finer than any
    /// ease is visible at — a two-hour shoot changes look every 15 seconds of
    /// capture — and bounds the CPU cost of a bake at 512 LUTs however many
    /// thousand frames the shoot has.
    static let gradeLadderSteps = 512

    /// Renders `url` through `preset` and `adjustments` at full resolution and
    /// writes it to a temporary JPEG, returning that file's URL for a Photos
    /// export. The caller owns the temp file and should delete it when done.
    static func renderJPEG(
        url: URL,
        preset: PhotoPreset,
        adjustments: PhotoAdjustments = .neutral,
        quality: CGFloat = 0.95
    ) throws -> URL {
        guard let cgImage = render(
            url: url, preset: preset, adjustments: adjustments, maxDimension: nil) else {
            throw GradeError.renderFailed
        }
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("graded-\(UUID().uuidString).jpg")
        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw GradeError.renderFailed
        }
        var options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            // `render` decodes through `ImageStacker.loadImage`, which bakes the
            // source orientation into the pixels; declare "up" so viewers don't
            // rotate again.
            kCGImagePropertyOrientation: 1,
        ]
        // A graded copy is still the same photograph, so it keeps the source's
        // EXIF, GPS fix and camera identity. A CGImageDestination copies nothing
        // from the source on its own: without this the JPEG handed to Photos has
        // no capture time and no location.
        if var metadata = ImageExporter.carryoverMetadata(from: url) {
            if var exif = metadata[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                // The source's recorded dimensions describe it before the
                // orientation bake, which transposes them for a 90° rotation.
                exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
                exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
                metadata[kCGImagePropertyExifDictionary] = exif
            }
            for (key, value) in metadata { options[key] = value }
        }
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw GradeError.renderFailed
        }
        return destinationURL
    }

    enum GradeError: LocalizedError {
        case renderFailed
        var errorDescription: String? { "Couldn't render the colour grade." }
    }

    private static func cacheKey(
        url: URL,
        preset: PhotoPreset,
        adjustments: PhotoAdjustments,
        maxDimension: CGFloat?
    ) -> NSString {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = maxDimension.map { String(Int($0)) } ?? "full"
        // The engine version is in the key so cached renders self-invalidate
        // whenever the engine's math changes.
        return "e\(GradeRecipe.engineVersion)|\(url.path)|\(modified)|\(preset.rawValue)|\(adjustments.cacheToken)|\(size)" as NSString
    }
}

/// "Capture Flat": a low-contrast, log-ish grade baked into JPEG stills at
/// save time, giving more grading latitude in post. Reuses `PhotoPreset`'s
/// Core Image parametric filters — lifted shadows, pulled highlights, reduced
/// saturation and contrast. (Video captures flatness a different way, via
/// Apple Log at the sensor; this covers the JPEG still path.)
enum FlatCapture {
    /// `@AppStorage`/`UserDefaults` key shared by the toggle and the capture
    /// paths that read it.
    static let storageKey = "capture.captureFlat"

    /// GPU-backed and thread-safe; the capture delegate runs off the main queue.
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// The flat grade: pull highlights (~-0.2), lift shadows (~+0.15), and
    /// desaturate/soften contrast so the file holds more room for a later grade.
    static func apply(to image: CIImage) -> CIImage {
        var out = PhotoPreset.highlightShadow(image, highlight: 0.80, shadow: 0.15)
        out = PhotoPreset.colorControls(out, saturation: 0.80, contrast: 0.90)
        return out
    }

    /// The grade applied to a full-precision image — the live-blend path's
    /// half-float window mean — quantized to 8 bits exactly once, here at the
    /// render. Same filters as `write(jpegData:)`, so the photo-output path
    /// and the blended path deliver one look; the difference is what the
    /// curve gets to work with (the window's real tonal depth versus an
    /// already-encoded 8-bit JPEG). Returns nil on any CoreImage failure so
    /// the caller can fall back to writing the ungraded mean.
    static func flatten(_ image: CGImage) -> CGImage? {
        let output = apply(to: CIImage(cgImage: image))
        guard output.extent.width > 0, output.extent.height > 0 else { return nil }
        return context.createCGImage(output, from: output.extent)
    }

    /// Renders `jpegData` through the flat grade and writes a JPEG to `url`,
    /// baking in the source orientation and carrying an optional GPS dictionary.
    /// Returns false if any step fails so the caller can fall back to writing the
    /// original bytes untouched.
    static func write(jpegData: Data, to url: URL, gps: Any?, quality: CGFloat = 0.95) -> Bool {
        guard let image = CIImage(data: jpegData, options: [.applyOrientationProperty: true]) else {
            return false
        }
        let output = apply(to: image)
        guard output.extent.width > 0, output.extent.height > 0,
              let cgImage = context.createCGImage(output, from: output.extent),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return false
        }
        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            // Orientation is baked into the pixels; declare "up" so viewers
            // don't rotate again.
            kCGImagePropertyOrientation: 1,
        ]
        if let gps { properties[kCGImagePropertyGPSDictionary] = gps }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}

/// "Capture Flat" for video on devices without Apple Log support. Apple Log is a
/// sensor-level colour space available only on iPhone 15 Pro and newer; on every
/// other device we bake the same flat grade as the JPEG still path
/// (`FlatCapture.apply`) into the recorded movie with an `AVVideoComposition`
/// that runs each frame through Core Image at export time. It re-encodes the
/// file (ProRes falls back to H.264/HEVC), which is the accepted trade for
/// giving non-Log hardware the flat profile.
enum VideoFlatten {
    /// GPU-backed and thread-safe; the export runs off the session queue.
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Re-encodes the movie at `sourceURL` through the flat grade, writing the
    /// result over the original. Blocks the calling queue until the export
    /// finishes. Returns false (leaving the original untouched) if any step
    /// fails, so recording still yields a usable, if ungraded, file.
    static func flattenInPlace(_ sourceURL: URL) -> Bool {
        let asset = AVURLAsset(url: sourceURL)

        let composition = AVMutableVideoComposition(asset: asset) { request in
            let flat = FlatCapture.apply(to: request.sourceImage)
                .cropped(to: request.sourceImage.extent)
            request.finish(with: flat, context: context)
        }

        guard let export = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            return false
        }

        let tempURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent("flat-" + sourceURL.lastPathComponent)
        try? FileManager.default.removeItem(at: tempURL)

        export.videoComposition = composition
        export.outputURL = tempURL
        export.outputFileType = .mov
        export.shouldOptimizeForNetworkUse = true

        let semaphore = DispatchSemaphore(value: 0)
        export.exportAsynchronously { semaphore.signal() }
        semaphore.wait()

        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }

        do {
            _ = try FileManager.default.replaceItemAt(sourceURL, withItemAt: tempURL)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
    }
}

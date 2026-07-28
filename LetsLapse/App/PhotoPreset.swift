import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

/// Non-destructive colour grades for Photo-mode captures. Each preset is a
/// short chain of Core Image parametric filters — no LUT/.cube files — so a
/// grade is just math applied to the decoded pixels. The original file on disk
/// is never rewritten; the grade is re-derived on demand and re-applied only
/// when the user exports.
enum PhotoPreset: String, CaseIterable, Identifiable {
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
    static let `default`: PhotoPreset = .natural

    /// The order the chips appear in the strip.
    static let strip: [PhotoPreset] = [.natural, .cinema, .matte, .vivid, .original]

    /// Resolve a stored raw name to a preset, falling back to the default so a
    /// missing or unknown value still renders something sensible.
    static func resolve(_ name: String?) -> PhotoPreset {
        guard let name, let preset = PhotoPreset(rawValue: name) else { return .default }
        return preset
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
    private static func vibrance(_ image: CIImage, amount: Float) -> CIImage {
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

    /// CGImage isn't an `AnyObject`, so box it to live in `NSCache`.
    private final class Box { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 24
        return cache
    }()

    /// Renders `url` through `preset`. `maxDimension`, when set, downscales the
    /// longest edge first — cheap, low-memory previews; export passes `nil` for
    /// full resolution. Works for both JPEG and DNG (Core Image decodes RAW).
    static func render(url: URL, preset: PhotoPreset, maxDimension: CGFloat? = nil) -> CGImage? {
        let key = cacheKey(url: url, preset: preset, maxDimension: maxDimension)
        if let cached = cache.object(forKey: key) { return cached.image }

        guard var image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        if let maxDimension {
            let longest = max(image.extent.width, image.extent.height)
            if longest > maxDimension, longest > 0 {
                let scale = maxDimension / longest
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }
        let output = preset.apply(to: image)
        guard output.extent.width > 0, output.extent.height > 0,
              let cgImage = context.createCGImage(output, from: output.extent) else {
            return nil
        }
        cache.setObject(Box(cgImage), forKey: key)
        return cgImage
    }

    /// Renders `url` through `preset` at full resolution and writes it to a
    /// temporary JPEG, returning that file's URL for a Photos export. The
    /// caller owns the temp file and should delete it when done.
    static func renderJPEG(url: URL, preset: PhotoPreset, quality: CGFloat = 0.95) throws -> URL {
        guard let cgImage = render(url: url, preset: preset, maxDimension: nil) else {
            throw GradeError.renderFailed
        }
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("graded-\(UUID().uuidString).jpg")
        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw GradeError.renderFailed
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
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

    private static func cacheKey(url: URL, preset: PhotoPreset, maxDimension: CGFloat?) -> NSString {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = maxDimension.map { String(Int($0)) } ?? "full"
        return "\(url.path)|\(modified)|\(preset.rawValue)|\(size)" as NSString
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

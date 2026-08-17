import Foundation
#if canImport(CoreImage)
import CoreImage
import CoreGraphics
import ImageIO

/// The paper the operator says they are shooting, when they know.
///
/// A rectified page is only as square as the corners it was rectified from, and
/// the corners come from a preview frame a few hundred pixels wide — so a
/// perfectly detected A4 sheet still lands a percent or two off 1:√2. Naming
/// the stock lets the correction finish the job: `auto` keeps whatever the quad
/// itself implies (right for an object of unknown proportion), and every other
/// case snaps the output to a ratio that is *known* rather than measured.
public enum PerspectiveAspect: String, CaseIterable, Codable, Sendable {
    case auto
    case a4
    case letter
    /// 4×6 — the standard photographic print.
    case fourBySix
    case square

    /// The picker's label. `.auto` is deliberately the first case and the
    /// default everywhere: guessing a stock the user didn't ask for would
    /// silently distort every frame of a set.
    public var label: String {
        switch self {
        case .auto: return "Auto"
        case .a4: return "A4"
        case .letter: return "Letter"
        case .fourBySix: return "4×6"
        case .square: return "Square"
        }
    }

    /// Width ÷ height **in portrait form** (so always ≤ 1), or nil for `.auto`.
    ///
    /// Portrait form only, because the hint is about the stock and not about
    /// how it was lying on the table: the corrector reads the detected quad's
    /// own orientation and inverts this when the page is landscape. A user who
    /// picks "A4" for a page they shot sideways means A4, not portrait.
    public var portraitRatio: Double? {
        switch self {
        case .auto: return nil
        case .a4: return 1 / 2.0.squareRoot()   // 210 × 297 mm
        case .letter: return 8.5 / 11.0
        case .fourBySix: return 4.0 / 6.0
        case .square: return 1
        }
    }
}

/// Rectifies a photographed flat object from the four corners the Scanner saw,
/// using `CIPerspectiveCorrection`.
///
/// **Why the HEIC and never the DNG.** A Scanner pose lands as a pair: a Bayer
/// RAW for the solver and a processed sibling for humans. Only the sibling can
/// be rectified — a DNG's pixels are a colour-filter mosaic, and resampling a
/// mosaic destroys the very structure that makes it raw (every output pixel
/// would mix red, green and blue sites). So the correction is a **third** file
/// beside the pair, never a replacement for either: the original DNG and HEIC
/// are untouched, and `frame-00001-corrected.heic` sits next to them.
public enum PerspectiveCorrector {

    /// The suffix that marks a rectified frame, so a corrected sequence can be
    /// picked out of a directory (and never corrected twice).
    public static let correctedSuffix = "-corrected"

    /// Whether a corrected page on disk was written by the broken geometry that
    /// preceded the orientation fix, and should therefore be treated as **not
    /// corrected** — shown as its original, offered to the Correct action
    /// again, and overwritten when it runs.
    ///
    /// The test is exact rather than heuristic. A correction written since the
    /// fix rectifies pixels that are already upright, so the file it writes
    /// carries no orientation tag at all (or the identity, 1). The broken path
    /// rectified the *unrotated* sensor read-out and inherited that image's own
    /// tag along with it, so every file it produced is stamped 6 (or 8, or 3,
    /// for the other poses) — a rotation applied on top of an already-wrong
    /// quarter-turned crop.
    ///
    /// So: a corrected page that still asks to be rotated is one of the old
    /// ones. There is no version to read and none was ever written; this is the
    /// signature the bug left behind, and it costs one property read on a file
    /// the caller was about to decode anyway.
    public static func isSupersededCorrection(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let orientation = properties[kCGImagePropertyOrientation] as? Int
        else { return false }
        return orientation != 1
    }

    /// `frame-00001.heic` → `frame-00001-corrected.heic`, alongside the source.
    public static func correctedURL(for source: URL) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        return source
            .deletingLastPathComponent()
            .appendingPathComponent("\(base)\(correctedSuffix).heic")
    }

    // MARK: - The correction itself

    /// Rectifies `image` from `quad`, whose corners are normalised 0…1 of the
    /// image with a bottom-left origin — the same convention Core Image itself
    /// uses, which is why the mapping below is a plain scale with no flip.
    ///
    /// Returns nil for a degenerate quad (a corner set with no area), which is
    /// what a spurious detection at the edge of a frame looks like.
    public static func correct(
        _ image: CIImage,
        quad: NormalizedQuad,
        aspect: PerspectiveAspect = .auto
    ) -> CIImage? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.isInfinite == false else { return nil }

        func point(_ corner: NormalizedQuad.Point) -> CIVector {
            CIVector(
                x: extent.minX + CGFloat(corner.x) * extent.width,
                y: extent.minY + CGFloat(corner.y) * extent.height)
        }

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(point(quad.topLeft), forKey: "inputTopLeft")
        filter.setValue(point(quad.topRight), forKey: "inputTopRight")
        filter.setValue(point(quad.bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(point(quad.bottomRight), forKey: "inputBottomRight")
        guard let corrected = filter.outputImage else { return nil }
        let rectified = corrected.extent
        guard rectified.width >= 1, rectified.height >= 1, rectified.isInfinite == false else {
            return nil
        }

        guard let ratio = targetRatio(for: aspect, correctedWidth: rectified.width, correctedHeight: rectified.height)
        else {
            // `.auto` — the quad's own proportions are the answer.
            return corrected
        }

        // Width is held and height derived, so the rectified detail the
        // correction just recovered is never thrown away by a downscale; the
        // adjustment is a single-axis resample of at most a few percent for a
        // real page, which is the size of the detection error it exists to
        // absorb.
        let targetHeight = rectified.width / ratio
        guard targetHeight >= 1 else { return corrected }
        let scaleY = targetHeight / rectified.height
        guard scaleY.isFinite, scaleY > 0 else { return corrected }
        return corrected.transformed(by: CGAffineTransform(scaleX: 1, y: scaleY))
    }

    /// The width ÷ height the output should end up at, or nil to leave the
    /// correction as it came out. Handles the landscape case: a hint names a
    /// stock, and a page photographed on its side is the same stock rotated.
    static func targetRatio(
        for aspect: PerspectiveAspect,
        correctedWidth: CGFloat,
        correctedHeight: CGFloat
    ) -> CGFloat? {
        guard let portrait = aspect.portraitRatio, correctedHeight > 0 else { return nil }
        let isLandscape = correctedWidth > correctedHeight
        return CGFloat(isLandscape ? 1 / portrait : portrait)
    }

    // MARK: - Files

    /// Reads `source`, rectifies it and writes `frame-…-corrected.heic` beside
    /// it. Returns the URL written.
    ///
    /// The source must be the **processed** sibling of a pose (see the type
    /// note); handing this a `.dng` is a caller error and throws rather than
    /// quietly producing a demosaic-shaped mess.
    @discardableResult
    public static func writeCorrected(
        from source: URL,
        quad: NormalizedQuad,
        aspect: PerspectiveAspect = .auto,
        context: CIContext? = nil
    ) throws -> URL {
        guard source.pathExtension.lowercased() != "dng" else {
            throw PerspectiveCorrectionError.rawIsNotRectifiable(source)
        }
        // **The orientation must be applied before the corners mean anything.**
        //
        // A still from `AVCapturePhotoOutput` is written in the sensor's own
        // landscape with an EXIF orientation tag (6 — rotate 90° CW — for a
        // portrait shoot), and `CIImage(contentsOf:)` hands back those raw
        // landscape pixels with the tag left in the metadata. The quad in the
        // sidecar is in the *upright* space Vision measured it in, so applying
        // it to the unrotated extent selects a quarter-turned region: on a real
        // A4 page (iPhone 16 Pro, 2026-08-17) that came out as a near-full-frame
        // quad — desk included, page still keystoned — which the aspect snap
        // then squashed to A4 *landscape*. Every corrected page written before
        // this line was that.
        //
        // Applying the orientation first puts the pixels in the same space the
        // corners are in, and the two agree by construction: the run freezes one
        // capture orientation, the photo connection tags every still with it and
        // `RectangleDetector` is handed the same one. The output is then upright
        // with no tag of its own (verified: a round trip through
        // `writeHEIFRepresentation` writes orientation 1), so nothing downstream
        // rotates it a second time.
        guard let image = CIImage(contentsOf: source, options: [.applyOrientationProperty: true])
        else {
            throw PerspectiveCorrectionError.unreadable(source)
        }
        guard let corrected = correct(image, quad: quad, aspect: aspect) else {
            throw PerspectiveCorrectionError.degenerateQuad
        }
        let destination = correctedURL(for: source)
        let ciContext = context ?? CIContext()
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        do {
            try ciContext.writeHEIFRepresentation(
                of: corrected,
                to: destination,
                format: .RGBA8,
                colorSpace: colorSpace)
        } catch {
            throw PerspectiveCorrectionError.writeFailed(destination, error)
        }
        return destination
    }

    /// Rectifies a whole Scanner sequence from its `frames.timestamps` sidecar:
    /// every entry that recorded a rectangle, applied to that frame's processed
    /// sibling. Frames captured with no rectangle in view are skipped — nothing
    /// is written for them and nothing is destroyed.
    ///
    /// Non-throwing per frame on purpose: one unreadable file in a 36-pose set
    /// must not cost the other 35 their correction. The returned list is what
    /// actually landed; `failures` says what didn't and why.
    /// `progress` is called after each page is attempted — succeeded or failed —
    /// with how many of the correctable pages are done and how many there are.
    /// It runs on the **calling** thread, which is a background one by
    /// construction (this is seconds of GPU work), so a caller driving a UI from
    /// it has to hop to the main actor itself.
    ///
    /// It exists so a set can be watched correcting rather than waiting: a
    /// 36-pose scan is a minute of work, and the pages land one at a time
    /// whether or not anyone is told about it.
    @discardableResult
    public static func correctSequence(
        in directory: URL,
        aspect: PerspectiveAspect = .auto,
        progress: ((_ completed: Int, _ total: Int) -> Void)? = nil
    ) -> (written: [URL], failures: [(frame: Int, error: Error)]) {
        let sidecarURL = directory.appendingPathComponent(FrameTimestamps.fileName)
        guard let sidecar = try? FrameTimestamps.load(from: sidecarURL) else {
            progress?(0, 0)
            return ([], [])
        }
        let context = CIContext()
        var written: [URL] = []
        var failures: [(frame: Int, error: Error)] = []
        // Counted before the walk so the caller can say "of N" from the first
        // moment rather than watching a total climb.
        let total = sidecar.entries.filter { $0.rectangle != nil }.count
        progress?(0, total)
        var completed = 0
        for entry in sidecar.entries {
            guard let quad = entry.rectangle else { continue }
            defer {
                completed += 1
                progress?(completed, total)
            }
            guard let source = processedFrameURL(in: directory, frame: entry.frame) else {
                failures.append((entry.frame, PerspectiveCorrectionError.missingFrame(entry.frame)))
                continue
            }
            do {
                written.append(
                    try writeCorrected(from: source, quad: quad, aspect: aspect, context: context))
            } catch {
                failures.append((entry.frame, error))
            }
        }
        return (written, failures)
    }

    /// The human-viewable file for a pose: `frame-00001.heic`, or the `.jpg`
    /// the honest no-RAW fallback wrote instead. Never the DNG.
    static func processedFrameURL(in directory: URL, frame: Int) -> URL? {
        let base = String(format: "frame-%05d", frame + 1)
        for ext in ["heic", "jpg", "jpeg"] {
            let url = directory.appendingPathComponent("\(base).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}

public enum PerspectiveCorrectionError: Error {
    case unreadable(URL)
    case rawIsNotRectifiable(URL)
    case degenerateQuad
    case missingFrame(Int)
    case writeFailed(URL, Error)
}

#endif

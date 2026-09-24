import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Metadata-only 90°-clockwise rotation for captured media — the standard
/// mechanisms only: the EXIF/TIFF orientation tag for stills, the QuickTime
/// `preferredTransform` for video. Pixels and encoded bitstreams are left
/// untouched wherever the container allows it (JPEG/HEIC/DNG/MOV/MP4); the
/// one exception is PNG, which has no honoured orientation tag in practice,
/// so its pixels are rotated losslessly instead.
///
/// Since 2026-09-24 the app's Rotate 90° does not come here: a project's
/// turn is a record (`QuarterTurns`) and its files are never rewritten. What
/// uses this now is a COPY leaving the app — `rotate(at:quarterTurns:)` on a
/// temporary file, so a Save to Photos or a Share shows the way the project
/// does.
public enum MediaRotator {

    /// EXIF orientation after a further 90° clockwise display rotation,
    /// indexed by the current value 1–8 (index 0 unused). Covers the mirrored
    /// values too: 1→6→3→8→1 and 2→7→4→5→2.
    public static let exifRotated90CW: [UInt16] = [0, 6, 7, 8, 5, 2, 3, 4, 1]

    public enum RotateError: Error, LocalizedError {
        case unsupported(URL)
        case unreadable(URL)
        case noVideoTrack(URL)
        case encodeFailed(URL, String)

        public var errorDescription: String? {
            switch self {
            case .unsupported(let url):
                return "Can't rotate \(url.lastPathComponent): unsupported format"
            case .unreadable(let url):
                return "Can't read \(url.lastPathComponent)"
            case .noVideoTrack(let url):
                return "\(url.lastPathComponent) has no video track"
            case .encodeFailed(let url, let detail):
                return "Couldn't rewrite \(url.lastPathComponent): \(detail)"
            }
        }
    }

    // MARK: - Stills

    /// Rotates a still 90° clockwise. JPEG/HEIC: metadata-only — the encoded
    /// bitstream is copied, only the orientation tag changes. PNG: pixels are
    /// rotated losslessly (blend outputs are PNG with upright pixels; PNG
    /// orientation metadata is widely ignored, so baking is the honest move).
    /// Writes a temp file, then atomically replaces the original — the mtime
    /// bump is what lets the disk thumbnail cache self-heal.
    public static func rotateStill90CW(at url: URL) throws {
        guard let format = ImageFormat.infer(from: url) else {
            throw RotateError.unsupported(url)
        }
        switch format {
        case .png:
            try rotatePNGPixels(at: url, turns: 1)
        case .jpeg, .heic:
            try rotateEncodedStill(at: url, turns: 1)
        }
    }

    /// Rotates a DNG 90° clockwise by editing IFD0's Orientation tag at the
    /// byte level (raw strips untouched). Works for Apple pass-through
    /// originals and app-authored DNGs alike.
    public static func rotateDNG90CW(at url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RotateError.unreadable(url)
        }
        let current = normalizedOrientation(DNGAuthor.dngOrientation(in: data))
        let output = try DNGAuthor.dngBySettingOrientation(data, to: exifRotated90CW[Int(current)])
        try output.write(to: url, options: .atomic)
    }

    private static func rotateEncodedStill(at url: URL, turns: Int) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sourceType = CGImageSourceGetType(source)
        else { throw RotateError.unreadable(url) }
        let next = turned(currentOrientation(of: source), by: turns)

        // Preferred: ImageIO's lossless metadata-editing copy. No decode, no
        // recompression — the API built for exactly this edit.
        let copied = tempSibling(for: url)
        if let destination = CGImageDestinationCreateWithURL(
            copied as CFURL, sourceType, 1, nil) {
            var error: Unmanaged<CFError>?
            let options = [kCGImageDestinationOrientation: Int(next)] as CFDictionary
            if CGImageDestinationCopyImageSource(destination, source, options, &error) {
                try replace(url, with: copied)
                return
            }
        }
        try? FileManager.default.removeItem(at: copied)

        // Fallback (e.g. a container the copy call refuses): re-mux the
        // encoded image with an orientation override — the same call the GPS
        // tagger relies on to preserve the compressed bitstream.
        let remuxed = tempSibling(for: url)
        guard let destination = CGImageDestinationCreateWithURL(
            remuxed as CFURL, sourceType, 1, nil) else {
            throw RotateError.encodeFailed(url, "could not create image destination")
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: Int(next),
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: Int(next)],
        ]
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: remuxed)
            throw RotateError.encodeFailed(url, "could not rewrite orientation")
        }
        try replace(url, with: remuxed)
    }

    private static func rotatePNGPixels(at url: URL, turns: Int) throws {
        // loadImage bakes any existing tag first, so the rotate composes
        // correctly even for imported PNGs that do carry one.
        let upright = try ImageStacker.loadImage(at: url)
        let rotated = ImageStacker.oriented(upright, exifOrientation: Int(turned(1, by: turns)))
        let temp = tempSibling(for: url)
        try ImageExporter.write(
            rotated, to: temp, format: .png,
            metadata: ImageExporter.carryoverMetadata(from: url))
        try replace(url, with: temp)
    }

    // MARK: - A copy leaving the app

    /// Raw formats built on TIFF, whose IFD0 carries the Orientation tag the
    /// DNG editor overwrites — Sony, Canon CR2, Nikon, Pentax, Samsung,
    /// Epson, Hasselblad, Kodak, Leaf, Phase One, Mamiya — and TIFF itself.
    /// CR3, RAF, ORF and RW2 are not TIFF files and are not listed.
    static let tiffExtensions: Set<String> = [
        "arw", "sr2", "srf", "cr2", "nef", "nrw", "pef", "srw", "erf",
        "3fr", "fff", "dcr", "kdc", "mos", "iiq", "mef", "tif", "tiff",
    ]

    /// Writes `quarterTurns` clockwise quarter turns into the file at `url`,
    /// the way its format carries a turn — for a COPY leaving the app (Save
    /// to Photos, Share, Export). A project's turn is a record
    /// (`QuarterTurns`, 2026-09-24); its originals are never rewritten, so a
    /// copy that goes somewhere the record can't follow has to carry it.
    ///
    /// JPEG, HEIC, DNG and the TIFF-built raws change their orientation tag
    /// only — a raw other than DNG only when the tag can be overwritten where
    /// it stands, since rebuilding another maker's IFD0 is not a move its own
    /// readers are known to follow. PNG turns its pixels, losslessly; a movie
    /// its track transform, samples untouched. Anything else throws
    /// `.unsupported`, and the caller sends the file as it is.
    public static func rotate(at url: URL, quarterTurns: Int) async throws {
        let turns = QuarterTurns.normalized(quarterTurns)
        guard turns != 0 else { return }
        let ext = url.pathExtension.lowercased()
        if ext == "dng" || tiffExtensions.contains(ext) {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw RotateError.unreadable(url)
            }
            let next = turned(normalizedOrientation(DNGAuthor.dngOrientation(in: data)), by: turns)
            let output = try DNGAuthor.dngBySettingOrientation(data, to: next)
            guard ext == "dng" || output.count == data.count else { throw RotateError.unsupported(url) }
            try output.write(to: url, options: .atomic)
            return
        }
        if ["mov", "qt", "mp4", "m4v"].contains(ext) {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw RotateError.noVideoTrack(url)
            }
            let naturalSize = try await track.load(.naturalSize)
            let current = try await track.load(.preferredTransform)
            let transform = QuarterTurns.transform(current, naturalSize: naturalSize, turnedBy: turns)
            if ["mov", "qt"].contains(ext) {
                try await rotateQuickTimeHeader(at: url, to: transform)
            } else {
                try await rewriteViaPassthrough(at: url, transform: transform)
            }
            return
        }
        guard let format = ImageFormat.infer(from: url) else { throw RotateError.unsupported(url) }
        switch format {
        case .png: try rotatePNGPixels(at: url, turns: turns)
        case .jpeg, .heic: try rotateEncodedStill(at: url, turns: turns)
        }
    }

    /// An EXIF orientation value turned `turns` further quarter turns.
    private static func turned(_ orientation: UInt16, by turns: Int) -> UInt16 {
        let base = CGImagePropertyOrientation(rawValue: UInt32(normalizedOrientation(orientation))) ?? .up
        return UInt16(QuarterTurns.orientation(base, turnedBy: turns).rawValue)
    }

    // MARK: - Video

    /// Rotates a video 90° clockwise by updating the track `preferredTransform`.
    /// QuickTime (.mov): in-place header rewrite — a fresh moov is appended and
    /// the stale one invalidated; media data is never touched. Anything else
    /// (.mp4/.m4v): passthrough export to a temp file (samples copied, not
    /// re-encoded), then atomic replace.
    public static func rotateVideo90CW(at url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RotateError.noVideoTrack(url)
        }
        let naturalSize = try await track.load(.naturalSize)
        let current = try await track.load(.preferredTransform)
        let transform = rotated90CW(current, naturalSize: naturalSize)

        if ["mov", "qt"].contains(url.pathExtension.lowercased()) {
            try await rotateQuickTimeHeader(at: url, to: transform)
        } else {
            try await rewriteViaPassthrough(at: url, transform: transform)
        }
    }

    /// The transform that shows the movie a further 90° clockwise: apply the
    /// rotation after the existing transform, then renormalize the translation
    /// so the mapped rect's origin lands at (0,0) — the same convention Apple
    /// stamps on portrait recordings and `refreshVideoMetadata` reads back.
    static func rotated90CW(_ current: CGAffineTransform, naturalSize: CGSize) -> CGAffineTransform {
        let rotated = current.concatenating(CGAffineTransform(rotationAngle: .pi / 2))
        let mapped = CGRect(origin: .zero, size: naturalSize).applying(rotated)
        return rotated.concatenating(CGAffineTransform(translationX: -mapped.minX, y: -mapped.minY))
    }

    private static func rotateQuickTimeHeader(at url: URL, to transform: CGAffineTransform) async throws {
        let movie = AVMutableMovie(url: url, options: nil)
        let tracks = try await movie.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw RotateError.noVideoTrack(url) }
        for track in tracks {
            track.preferredTransform = transform
        }
        do {
            // Appends the updated moov to the same file and invalidates the
            // old one — the sanctioned QuickTime in-place metadata edit.
            try movie.writeHeader(to: url, fileType: .mov, options: .addMovieHeaderToDestination)
        } catch {
            throw RotateError.encodeFailed(url, error.localizedDescription)
        }
    }

    private static func rewriteViaPassthrough(at url: URL, transform: CGAffineTransform) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        let composition = AVMutableComposition()
        for track in try await asset.loadTracks(withMediaType: .video) {
            guard let compositionTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try compositionTrack.insertTimeRange(range, of: track, at: .zero)
            compositionTrack.preferredTransform = transform
        }
        guard !composition.tracks(withMediaType: .video).isEmpty else {
            throw RotateError.noVideoTrack(url)
        }
        for track in try await asset.loadTracks(withMediaType: .audio) {
            guard let compositionTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try compositionTrack.insertTimeRange(range, of: track, at: .zero)
        }

        guard let export = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw RotateError.encodeFailed(url, "no passthrough export session")
        }
        let temp = tempSibling(for: url)
        export.outputURL = temp
        export.outputFileType = url.pathExtension.lowercased() == "m4v" ? .m4v : .mp4
        let box = SessionBox(export)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            box.session.exportAsynchronously {
                switch box.session.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: RotateError.encodeFailed(url, "export cancelled"))
                default:
                    continuation.resume(throwing: RotateError.encodeFailed(
                        url, box.session.error?.localizedDescription ?? "passthrough export failed"))
                }
            }
        }
        try replace(url, with: temp)
    }

    private final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }

    // MARK: - Shared helpers

    private static func currentOrientation(of source: CGImageSource) -> UInt16 {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let value = properties[kCGImagePropertyOrientation] as? UInt32
        else { return 1 }
        return normalizedOrientation(UInt16(clamping: value))
    }

    private static func normalizedOrientation(_ value: UInt16) -> UInt16 {
        (1...8).contains(value) ? value : 1
    }

    private static func tempSibling(for url: URL) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rotate-\(UUID().uuidString).\(url.pathExtension)")
    }

    private static func replace(_ original: URL, with temp: URL) throws {
        _ = try FileManager.default.replaceItemAt(original, withItemAt: temp)
    }
}

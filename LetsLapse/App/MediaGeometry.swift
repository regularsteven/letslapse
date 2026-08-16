import AVFoundation
import CoreGraphics
import ImageIO

/// How big a piece of media *displays*, as opposed to how it is stored.
///
/// Both answers need a correction that is easy to forget and invisible until a
/// portrait asset lays out landscape:
///
/// - a movie's `naturalSize` ignores `preferredTransform`, so a phone-shot
///   portrait clip reports 1920×1080;
/// - a still's `kCGImagePropertyPixelWidth`/`Height` are the *stored* dimensions,
///   so a camera that writes landscape pixels plus an EXIF rotation tag reports
///   landscape too.
///
/// Both incantations were already open-coded around the app —
/// `AppModel.probeBlendMediaIfNeeded`, `refreshVideoMetadata`,
/// `CollectionExporter`, `VideoCanvasCropper` for video, and
/// `PhotoGrader.sourceLongEdge` for stills (which skips orientation entirely,
/// because it only ever wanted the longer edge to size a decode). This is the
/// one place that gets it right; the others can adopt it as they are touched.
///
/// AVFoundation + ImageIO only, so it builds for macOS as well as iOS.
enum MediaGeometry {
    /// A movie's oriented display size — `naturalSize` put through
    /// `preferredTransform` — or nil if the file has no video track.
    static func videoDisplaySize(asset: AVAsset) async -> CGSize? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let oriented = CGRect(origin: .zero, size: natural).applying(transform).standardized
        let size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        return (size.width > 0 && size.height > 0) ? size : nil
    }

    /// A still's oriented display size, from metadata alone — no pixel decode,
    /// which matters because a DNG has no preview IFD and decoding one to learn
    /// its shape would cost a full RAW pass.
    static func stillDisplaySize(url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else { return nil }
        let width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
        guard width > 0, height > 0 else { return nil }
        // EXIF 5–8 are the quarter-turns: the stored pixels are laid out across
        // the other axis from how the image reads. Swapping here keeps this in
        // step with `ProjectThumbnailGenerator.displayImage`, which asks Image I/O
        // to apply the same transform via `kCGImageSourceCreateThumbnailWithTransform`.
        let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
        let quarterTurned = (5...8).contains(orientation)
        return quarterTurned
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }
}

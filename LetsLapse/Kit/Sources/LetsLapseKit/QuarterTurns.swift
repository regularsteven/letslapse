import CoreGraphics
import ImageIO

/// A project's quarter turns — **Rotate 90° as a record** (2026-09-24): whole
/// clockwise turns, 0…3, applied *after* a file's own orientation (the EXIF
/// tag a camera wrote, the track transform a movie carries, or pixels a
/// camera baked upright) and never written into the file.
///
/// Until 2026-09-24 Rotate 90° wrote the turn into every source file and
/// blend (`MediaRotator`): originals changed bytes (a sync re-uploaded the
/// whole shoot, PicPlace could not hold them write-once), a failure part way
/// left a half-rotated shoot, and every raw format but DNG was silently
/// skipped. Now the turn lives on the project (`CaptureProject.quarterTurns`)
/// and every read composes it — the same for DNG, ARW, CR2, JPEG, HEIC, PNG,
/// a MOV or an MP4, since no format has to be able to carry it.
///
/// Pure arithmetic: the orientation a decoder should apply, the size a
/// turned picture has, and the transform a video track should be drawn with.
public enum QuarterTurns {

    /// `turns` folded into 0…3 (negative turns count anticlockwise).
    public static func normalized(_ turns: Int) -> Int {
        ((turns % 4) + 4) % 4
    }

    /// The EXIF orientation that shows a file `turns` further quarter turns
    /// clockwise than `base` does — mirrored orientations stay mirrored.
    public static func orientation(_ base: CGImagePropertyOrientation, turnedBy turns: Int) -> CGImagePropertyOrientation {
        var raw = Int(base.rawValue)
        guard (1...8).contains(raw) else { return base }
        for _ in 0 ..< normalized(turns) { raw = Int(exifTurned90CW[raw]) }
        return CGImagePropertyOrientation(rawValue: UInt32(raw)) ?? base
    }

    /// EXIF orientation after one more clockwise quarter turn, indexed by the
    /// current value 1–8: 1→6→3→8→1 and, mirrored, 2→7→4→5→2.
    public static let exifTurned90CW: [UInt32] = [0, 6, 7, 8, 5, 2, 3, 4, 1]

    /// A picture's size after `turns` — width and height swap on an odd turn.
    public static func size(_ size: CGSize, turnedBy turns: Int) -> CGSize {
        normalized(turns) % 2 == 1 ? CGSize(width: size.height, height: size.width) : size
    }

    /// Integer dimensions after `turns`, for the persisted pixel size.
    public static func dimensions(width: Int, height: Int, turnedBy turns: Int) -> (width: Int, height: Int) {
        normalized(turns) % 2 == 1 ? (height, width) : (width, height)
    }

    /// A video track's display transform followed by `turns` clockwise
    /// quarter turns: what a composition layer instruction draws the track
    /// with, so the turned picture lands at the origin, upright for the
    /// person, in a render size of `size(displaySize, turnedBy:)`.
    ///
    /// AVFoundation's frame is top-left, y down: a clockwise quarter turn of a
    /// picture `h` tall maps (x, y) to (h − y, x).
    public static func transform(_ preferred: CGAffineTransform, naturalSize: CGSize, turnedBy turns: Int) -> CGAffineTransform {
        var transform = preferred
        for _ in 0 ..< normalized(turns) {
            let shown = CGRect(origin: .zero, size: naturalSize).applying(transform)
            transform = transform
                .concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY))
                .concatenating(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: shown.height, ty: 0))
        }
        // The last step already sits at the origin; an untouched transform is
        // returned as the track carries it.
        return transform
    }

    /// `image` turned `turns` quarter turns clockwise — a frame an
    /// `AVAssetImageGenerator` handed back with only the file's own transform
    /// applied, brought to how its project shows it. The pixels are moved
    /// one for one (`OrientedDecode.oriented`), no resampling.
    public static func turned(_ image: CGImage, by turns: Int) -> CGImage {
        guard normalized(turns) != 0 else { return image }
        return OrientedDecode.oriented(image, orientation(.up, turnedBy: turns))
    }

    /// The display rectangle a transform produces for `naturalSize`, moved to
    /// the origin — the render size of a turned track.
    public static func displaySize(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
        let shown = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return CGSize(width: abs(shown.width), height: abs(shown.height))
    }
}

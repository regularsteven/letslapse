import CoreGraphics
import Foundation
import ImageIO

/// Reads a project's hand-supplied black-and-white mask files into the same
/// `SceneMask` grid the segmentation model produces, so everything
/// downstream — post-processing dials, occlusion, the debug tint — treats a
/// drawn mask and an inferred one identically.
///
/// White is the region the mask names; black is its complement. Cached by
/// file path and modification date, because the export loop asks per frame
/// and a PNG decode per frame would dominate the render.
enum CustomMaskLoader {

    /// The grid's long edge. The model works at 448²; a hand-drawn mask is
    /// usually cleaner than that, and 512 keeps a soft edge soft without
    /// making the Core Image post-processing chain measurably slower.
    private static let gridLongEdge = 512

    private static let cache: NSCache<NSString, CacheBox> = {
        let cache = NSCache<NSString, CacheBox>()
        cache.countLimit = 12
        return cache
    }()

    private final class CacheBox {
        let mask: SceneMask
        init(_ mask: SceneMask) { self.mask = mask }
    }

    /// The mask at `url`, or nil when the file is missing or unreadable —
    /// a deleted mask file degrades to "no occlusion", the same thing a
    /// missing segmentation model does.
    static func mask(at url: URL) -> SceneMask? {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { ($0[.modificationDate] as? Date)?.timeIntervalSince1970 } ?? 0
        let key = "\(url.path)|\(stamp)" as NSString
        if let box = cache.object(forKey: key) { return box.mask }
        guard let mask = load(url) else { return nil }
        cache.setObject(CacheBox(mask), forKey: key)
        return mask
    }

    private static func load(_ url: URL) -> SceneMask? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        // Stretched to the grid, matching `MaskGeometry.stretch`: the grid
        // covers the frame's unit square, so the inverse map downstream is a
        // pure per-axis scale. A mask drawn at a different aspect than the
        // footage stretches to fit, which is the documented behaviour of
        // every other mask in the system.
        let long = max(image.width, image.height)
        let scale = long > gridLongEdge ? Double(gridLongEdge) / Double(long) : 1
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))

        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                    data: base, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // No flip: a CGBitmapContext's backing store is already row-major
        // from the TOP of the drawn image, which is exactly what
        // `SceneMask.pixels` documents. Flipping here inverted every custom
        // mask — caught by tinting a hand-drawn skyline and watching the
        // magenta land on the ground instead of the sky.

        // `region` is the model's vocabulary and a drawn mask has none: what
        // matters downstream is the pixels and `inverted()`, which flips them
        // whatever the label says. `.sky` here reads as "the white region",
        // and its complement as "the black region".
        return SceneMask(
            region: .sky, width: width, height: height, pixels: pixels,
            geometry: .stretch,
            provenance: "custom mask · \(url.lastPathComponent) · \(width)×\(height)")
    }
}

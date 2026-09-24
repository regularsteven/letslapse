import CoreGraphics
import Foundation
import ImageIO
import LetsLapseKit

/// Small previews of a project's custom mask files, for the Masks tab's
/// rows. Separate from `CustomMaskLoader` because the two want different
/// things from the same file: the loader wants a probability grid at mask
/// resolution, this wants a 3× thumbnail to draw in a 52×40 pt slot.
enum CustomMaskThumbnails {

    private static let maxPixel = 160

    private static let cache: NSCache<NSString, CacheBox> = {
        let cache = NSCache<NSString, CacheBox>()
        cache.countLimit = 32
        return cache
    }()

    private final class CacheBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    /// `turnedBy`: the quarter turns the project made since the mask was
    /// drawn (`AppModel.customMaskTurns`), so the row shows it as it lies.
    static func thumbnail(at url: URL, turnedBy turns: Int = 0) -> CGImage? {
        let quarter = QuarterTurns.normalized(turns)
        let key = "\(url.path)|\(quarter)" as NSString
        if let box = cache.object(forKey: key) { return box.image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary)
        else { return nil }
        let shown = QuarterTurns.turned(image, by: quarter)
        cache.setObject(CacheBox(shown), forKey: key)
        return shown
    }
}

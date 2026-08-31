import CoreGraphics
import Foundation
import ImageIO

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

    static func thumbnail(at url: URL) -> CGImage? {
        let key = url.path as NSString
        if let box = cache.object(forKey: key) { return box.image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary)
        else { return nil }
        cache.setObject(CacheBox(image), forKey: key)
        return image
    }
}

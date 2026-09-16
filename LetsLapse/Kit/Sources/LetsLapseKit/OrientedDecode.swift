import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Bounded ImageIO decodes of a still *as it reads* — EXIF orientation
/// applied by this file, never by `kCGImageSourceCreateThumbnailWithTransform`.
///
/// **Why the option is banned (measured 2026-09-16 on the iOS 18.6 and 26.1
/// Simulator runtimes; macOS 15.6 is clean).** Above 2²⁴ pixels ImageIO
/// decodes in 1024-px tiles, and on that path a quarter-turn orientation (6
/// or 8) baked in with `…WithTransform` is applied to each tile's *pixels*
/// but not to its *position*. CoreGraphics draws the resulting `CGImage`
/// correctly and ImageIO encodes it correctly — both walk the whole image —
/// but Core Image, Metal-via-Core-Image and Vision fetch it as blocks and see
/// a transposed grid of 1024-px squares with a black band where the fifth
/// row should be: sixteen scrambled tiles, the bottom strip intact. HEIC is
/// always on the tiled path; JPEG joins it when the file is an Apple
/// multi-picture (gain-map) JPEG — the `AMPF` tail on the JFIF segment or an
/// MPF APP2, which every iPhone HDR photo carries. So a portrait 24 MP iPhone
/// photo imported through Photos graded as a grid on iOS, and its poster went
/// up to PicPlace that way; the app's own portrait HEIC captures at 24 MP and
/// above take the same path. 4096×4096 is the last size that decodes whole;
/// 12 MP is safe, 24 MP and 48 MP are not.
///
/// Decoding *without* the transform hands back a plain bitmap every consumer
/// reads alike, and the orientation is then ours: a free transform in the
/// Core Image graph for the graders (`ciImage`), a CoreGraphics redraw in the
/// source's own colour space for callers that need pixels (`cgImage`). Raw
/// files never come here — `CIRAWFilter` orients its own output.
public enum OrientedDecode {

    /// The first image's EXIF orientation, `.up` when the file carries none.
    public static func orientation(of source: CGImageSource, index: Int = 0) -> CGImagePropertyOrientation {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let raw = properties[kCGImagePropertyOrientation] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: raw) else { return .up }
        return orientation
    }

    /// ImageIO's bounded decode of the first image in the file's *stored*
    /// pixel layout, and the orientation that still has to be applied to it.
    /// `maxPixelSize` bounds the longer stored edge (the same bound
    /// `kCGImageSourceThumbnailMaxPixelSize` applies); pass something past
    /// any camera's output for the whole picture.
    public static func stored(
        source: CGImageSource, maxPixelSize: Int, cacheImmediately: Bool = true
    ) -> (image: CGImage, orientation: CGImagePropertyOrientation)? {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        if cacheImmediately { options[kCGImageSourceShouldCacheImmediately] = true }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return (image, orientation(of: source))
    }

    /// The picture as it reads, for Core Image: the stored decode wrapped and
    /// oriented in the graph, its extent at the origin.
    public static func ciImage(source: CGImageSource, maxPixelSize: Int) -> CIImage? {
        guard let stored = stored(source: source, maxPixelSize: maxPixelSize) else { return nil }
        return CIImage(cgImage: stored.image).oriented(stored.orientation)
    }

    public static func ciImage(url: URL, maxPixelSize: Int) -> CIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return ciImage(source: source, maxPixelSize: maxPixelSize)
    }

    /// The picture as it reads, as a plain bitmap: the stored decode itself
    /// when the file is upright, a CoreGraphics redraw into the same colour
    /// space and depth otherwise.
    public static func cgImage(source: CGImageSource, maxPixelSize: Int, cacheImmediately: Bool = true) -> CGImage? {
        guard let stored = stored(
            source: source, maxPixelSize: maxPixelSize, cacheImmediately: cacheImmediately) else { return nil }
        return oriented(stored.image, stored.orientation)
    }

    public static func cgImage(url: URL, maxPixelSize: Int, cacheImmediately: Bool = true) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return cgImage(source: source, maxPixelSize: maxPixelSize, cacheImmediately: cacheImmediately)
    }

    /// `image` redrawn the way `orientation` says it reads. The input comes
    /// back untouched for `.up`, and — rather than a blank — when a context
    /// cannot be made for it.
    ///
    /// The redraw keeps the source's colour space and component depth: a
    /// Display P3 JPEG stays Display P3, a 16-bit PNG stays 16-bit. Only a
    /// non-RGB space (grey, CMYK) is redrawn into sRGB, which is what
    /// CoreGraphics' RGB contexts can hold.
    public static func oriented(_ image: CGImage, _ orientation: CGImagePropertyOrientation) -> CGImage {
        guard orientation != .up else { return image }
        let width = image.width
        let height = image.height
        let swapsAxes: Bool
        switch orientation {
        case .leftMirrored, .right, .rightMirrored, .left: swapsAxes = true
        default: swapsAxes = false
        }
        let outWidth = swapsAxes ? height : width
        let outHeight = swapsAxes ? width : height
        let space: CGColorSpace
        if let own = image.colorSpace, own.model == .rgb {
            space = own
        } else if let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
            space = srgb
        } else {
            return image
        }
        let hasAlpha: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }
        let alpha = (hasAlpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue
        // Deep sources keep their depth when CoreGraphics will give us a
        // 16-bit context; otherwise 8 bits, which every RGB space supports.
        var context: CGContext?
        if image.bitsPerComponent == 16 {
            context = CGContext(
                data: nil, width: outWidth, height: outHeight, bitsPerComponent: 16, bytesPerRow: 0,
                space: space, bitmapInfo: alpha | CGBitmapInfo.byteOrder16Little.rawValue)
        }
        if context == nil {
            context = CGContext(
                data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: alpha)
        }
        guard let context else { return image }
        // A pure rotation or flip lands every source pixel on exactly one
        // destination pixel; interpolation would only soften it.
        context.interpolationQuality = .none
        let w = CGFloat(width)
        let h = CGFloat(height)
        // CoreGraphics' origin is bottom-left; each case maps the stored
        // picture onto the reading one (EXIF/TIFF tag 274 semantics).
        var transform = CGAffineTransform.identity
        switch orientation {
        case .upMirrored:
            transform = transform.translatedBy(x: w, y: 0).scaledBy(x: -1, y: 1)
        case .down:
            transform = transform.translatedBy(x: w, y: h).rotated(by: .pi)
        case .downMirrored:
            transform = transform.translatedBy(x: 0, y: h).scaledBy(x: 1, y: -1)
        case .leftMirrored:
            // EXIF 5, the transpose. Mirror, then a quarter turn — and in
            // CoreGraphics' y-up frame that turn is the one that reads as
            // counter-clockwise, or the result is EXIF 7's transverse.
            transform = transform.translatedBy(x: h, y: 0).rotated(by: .pi / 2)
            transform = transform.translatedBy(x: w, y: 0).scaledBy(x: -1, y: 1)
        case .right:
            transform = transform.translatedBy(x: 0, y: w).rotated(by: -.pi / 2)
        case .rightMirrored:
            // EXIF 7, the transverse — the other diagonal.
            transform = transform.translatedBy(x: 0, y: w).rotated(by: -.pi / 2)
            transform = transform.translatedBy(x: w, y: 0).scaledBy(x: -1, y: 1)
        case .left:
            transform = transform.translatedBy(x: h, y: 0).rotated(by: .pi / 2)
        case .up:
            break
        @unknown default:
            return image
        }
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage() ?? image
    }
}

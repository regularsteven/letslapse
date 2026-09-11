import Foundation
import CoreImage
import ImageIO
import AVFoundation
import Metal
import UniformTypeIdentifiers

/// Image access for every representative-source kind. All loads are oriented
/// (EXIF orientation applied) so geometry matches what a viewer would see.
enum ImageLoader {
    static let ciContext: CIContext = {
        if let dev = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: dev, options: [.cacheIntermediates: false])
        }
        return CIContext()
    }()
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    static func probeDimensions(path: String, source: RepresentativeSource) async -> (Int, Int)? {
        let url = URL(fileURLWithPath: path)
        if source == .blendVideo {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (size, xf) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
            let r = CGRect(origin: .zero, size: size).applying(xf)
            return (Int(abs(r.width).rounded()), Int(abs(r.height).rounded()))
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else {
            // RAW files ImageIO refuses: let Core Image tell us.
            if source == .rawDecode, let f = CIRAWFilter(imageURL: url), let img = f.outputImage {
                return (Int(img.extent.width), Int(img.extent.height))
            }
            return nil
        }
        let o = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
        return o >= 5 ? (h, w) : (w, h)
    }

    /// Oriented CGImage no larger than `maxLongEdge` (nil = native).
    static func loadCGImage(asset: Asset, maxLongEdge: Int?) async throws -> CGImage {
        let url = URL(fileURLWithPath: asset.representativePath)
        switch asset.representativeSource {
        case .blendImage, .renderedFrame:
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw LoadError.unreadable(asset.representativePath) }
            var opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            opts[kCGImageSourceThumbnailMaxPixelSize] = maxLongEdge ?? max(asset.nativeWidth, asset.nativeHeight)
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { throw LoadError.decodeFailed(asset.representativePath) }
            return img
        case .rawDecode:
            let ci = try rawCIImage(url: url, native: (asset.nativeWidth, asset.nativeHeight), maxLongEdge: maxLongEdge, draft: maxLongEdge != nil)
            guard let img = ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: srgb) else { throw LoadError.decodeFailed(asset.representativePath) }
            return img
        case .blendVideo:
            let av = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: av)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            if let m = maxLongEdge { gen.maximumSize = CGSize(width: m, height: m) }
            let duration = try await av.load(.duration)
            let t = CMTimeMultiplyByFloat64(duration, multiplier: asset.frameFraction ?? 0.5)
            let (img, _) = try await gen.image(at: t)
            return img
        }
    }

    /// Native-resolution, oriented CIImage for rendering.
    static func loadCIImage(asset: Asset) async throws -> CIImage {
        let url = URL(fileURLWithPath: asset.representativePath)
        switch asset.representativeSource {
        case .blendImage, .renderedFrame:
            guard let ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { throw LoadError.unreadable(asset.representativePath) }
            return ci
        case .rawDecode:
            return try rawCIImage(url: url, native: (asset.nativeWidth, asset.nativeHeight), maxLongEdge: nil, draft: false)
        case .blendVideo:
            let cg = try await loadCGImage(asset: asset, maxLongEdge: nil)
            return CIImage(cgImage: cg)
        }
    }

    private static func rawCIImage(url: URL, native: (Int, Int), maxLongEdge: Int?, draft: Bool) throws -> CIImage {
        guard let f = CIRAWFilter(imageURL: url) else { throw LoadError.unreadable(url.path) }
        f.extendedDynamicRangeAmount = 0
        f.isDraftModeEnabled = draft
        if let m = maxLongEdge {
            let long = max(native.0, native.1)
            if long > m { f.scaleFactor = Float(m) / Float(long) }
        }
        guard let out = f.outputImage else { throw LoadError.decodeFailed(url.path) }
        // Pin the origin at zero so extents behave like a plain image.
        return out.transformed(by: CGAffineTransform(translationX: -out.extent.origin.x, y: -out.extent.origin.y))
    }

    enum LoadError: Error, CustomStringConvertible {
        case unreadable(String), decodeFailed(String)
        var description: String {
            switch self {
            case .unreadable(let p): return "unreadable: \(p)"
            case .decodeFailed(let p): return "decode failed: \(p)"
            }
        }
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw LoadError.decodeFailed(url.path) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw LoadError.decodeFailed(url.path) }
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.9) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw LoadError.decodeFailed(url.path) }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw LoadError.decodeFailed(url.path) }
    }

    static func loadPNG(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Downscale so the longest edge is `longEdge` (no-op if already smaller).
    static func downscale(_ image: CGImage, longEdge: Int) -> CGImage {
        let w = image.width, h = image.height
        let long = max(w, h)
        guard long > longEdge else { return image }
        let s = Double(longEdge) / Double(long)
        let nw = max(1, Int((Double(w) * s).rounded())), nh = max(1, Int((Double(h) * s).rounded()))
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage() ?? image
    }
}

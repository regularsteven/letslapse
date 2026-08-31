import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The disk half of `SceneMaskService`: one small grayscale PNG per raw model
/// grid, under the library root — the `DiskThumbnailStore` pattern. PNG
/// rather than JPEG because a mask's edges are the product, and ringing on
/// them would survive every downstream feather.
///
/// Stores RAW grids only. Threshold, feather and bias are live dials applied
/// at composite time; baking them in would turn every dial tweak into a
/// re-inference.
enum SceneMaskStore {
    /// Named (and listed in `StorageRoot.libraryItemNames`) so a library move
    /// carries the masks and the storage card can count them.
    static var directory: URL {
        StorageRoot.current.appendingPathComponent("SceneMasks", isDirectory: true)
    }

    /// A frame's cache identity: sandbox-relative path + mtime — the same
    /// shape (and the same container-UUID lesson) as the thumbnail store's.
    static func frameIdentity(_ url: URL) -> String {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970
        let home = NSHomeDirectory()
        let path = url.path.hasPrefix(home) ? String(url.path.dropFirst(home.count)) : url.path
        return "\(path)|\(modified.map { String($0) } ?? "missing")"
    }

    static func read(_ key: String) -> SceneMask? {
        let file = fileURL(for: key)
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.linearGray),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: space,
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = [UInt8](UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: UInt8.self), count: width * height))
        return SceneMask(
            region: .sky, width: width, height: height, pixels: pixels,
            geometry: .stretch, provenance: "disk cache")
    }

    static func write(_ mask: SceneMask, forKey key: String) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = CFDataCreate(nil, mask.pixels, mask.pixels.count),
              let provider = CGDataProvider(data: data),
              let space = CGColorSpace(name: CGColorSpace.linearGray),
              let image = CGImage(
                width: mask.width, height: mask.height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: mask.width, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(
                fileURL(for: key) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// Deletes every stored mask; returns the bytes freed. Purely
    /// reproducible, so this is a cache in the "Clear cache" sense.
    @discardableResult
    static func clear() -> Int64 {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var freed: Int64 = 0
        for file in files {
            let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            if (try? fileManager.removeItem(at: file)) != nil { freed += size }
        }
        return freed
    }

    private static func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).png")
    }
}

import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Two-tier thumbnail cache for the Gallery and Projects grids.
///
/// Memory: without it, a `LazyVGrid` re-decodes every cell's image each time
/// it scrolls back into view; with it, each source URL is decoded once per
/// session and reused. The generator (`ProjectThumbnailGenerator`) produces
/// platform-neutral `CGImage`s, so those are cached directly — one code path
/// for iOS and macOS.
///
/// Disk: a small JPEG per source asset under Application Support/LetsLapse/
/// Thumbnails, keyed by the source's path + modification date. The app's own
/// DNG captures embed no preview, so their thumbnails cost a full sensor
/// decode (hundreds of ms each on device); paying that once per asset instead
/// of once per launch is the difference between a grid that fills instantly
/// and one that sits on gray squares.
@MainActor
final class ProjectThumbnailCache: ObservableObject {
    static let shared = ProjectThumbnailCache()

    private let cache = NSCache<NSURL, CGImage>()
    /// Sources that failed to decode this session (missing or corrupt file),
    /// remembered so scrolling doesn't re-pay a doomed decode on every pass.
    /// Keys include the modification date, so a file that later appears or
    /// changes retries naturally.
    private var failedKeys: Set<String> = []

    private init() {
        cache.countLimit = 300
        // Thumbnails are small, but hundreds of ~1 MB BGRA images is real
        // memory on a phone that is also running a camera — cap bytes too.
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    /// Returns a fitted thumbnail for `url`, decoding it only on the first
    /// request ever (memory hit, else disk hit, else generate + persist).
    /// `kind` selects the video vs. image code path in the generator.
    func thumbnail(for url: URL, kind: AppModel.MediaKind) async -> Image? {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) {
            return Image(decorative: cached, scale: 1)
        }
        let diskKey = await DiskThumbnailStore.key(for: url)
        if failedKeys.contains(diskKey) { return nil }
        if let stored = await DiskThumbnailStore.read(diskKey) {
            remember(stored, forKey: key)
            return Image(decorative: stored, scale: 1)
        }
        guard let generated = await ProjectThumbnailGenerator.thumbnail(for: url, kind: kind) else {
            failedKeys.insert(diskKey)
            return nil
        }
        remember(generated, forKey: key)
        DiskThumbnailStore.write(generated, forKey: diskKey)
        return Image(decorative: generated, scale: 1)
    }

    private func remember(_ image: CGImage, forKey key: NSURL) {
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
    }
}

/// The on-disk half of `ProjectThumbnailCache`: one small JPEG per source
/// asset. All file work runs off the calling actor.
enum DiskThumbnailStore {
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LetsLapse/Thumbnails", isDirectory: true)
    }

    /// Cache identity of a source file: its path plus modification date, so
    /// a rewritten file re-generates and a missing one is distinguishable
    /// from every real version of itself.
    static func key(for url: URL) async -> String {
        await Task.detached(priority: .utility) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970
            return "\(url.path)|\(modified.map { String($0) } ?? "missing")"
        }.value
    }

    static func read(_ key: String) async -> CGImage? {
        await Task.detached(priority: .utility) {
            let file = fileURL(for: key)
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            return CGImageSourceCreateImageAtIndex(source, 0, options)
        }.value
    }

    /// Fire-and-forget: the caller already has the image; persisting it is
    /// purely for the next launch. A torn write just fails to decode later
    /// and regenerates.
    static func write(_ image: CGImage, forKey key: String) {
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = fileURL(for: key)
            guard let destination = CGImageDestinationCreateWithURL(
                file as CFURL, UTType.jpeg.identifier as CFString, 1, nil
            ) else { return }
            let options = [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary
            CGImageDestinationAddImage(destination, image, options)
            CGImageDestinationFinalize(destination)
        }
    }

    private static func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".jpg")
    }
}

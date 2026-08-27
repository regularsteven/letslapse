import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

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
///
/// Everything below the memory tier runs on `MediaWorkQueue` — bounded and
/// cancellable — so a long scroll can't bury fresh requests under decodes for
/// rows that are already gone.
@MainActor
final class ProjectThumbnailCache: ObservableObject {
    static let shared = ProjectThumbnailCache()

    private let cache = NSCache<NSURL, CGImage>()
    /// Sources that failed to decode, remembered so scrolling doesn't re-pay a
    /// doomed decode on every pass. Keys include the modification date, so a
    /// file that later appears or changes retries naturally.
    ///
    /// Deliberately *not* permanent: a decode usually fails because the file is
    /// missing or corrupt, but ImageIO also fails transiently under memory
    /// pressure — and pressure is exactly when a whole gridful is decoding at
    /// once. Poisoning those keys for the rest of the session left every tile
    /// gray until relaunch, so a memory warning or a return to the foreground
    /// wipes the slate (see `clearFailureMemory`).
    private var failedKeys: Set<String> = []
    /// Bumped whenever cached thumbnails are invalidated (e.g. a project
    /// rotate rewrote files in place). Views fold this into their `.task(id:)`
    /// so a same-URL content change still re-requests the thumbnail; the disk
    /// tier needs nothing — its keys carry the file's modification date.
    @Published private(set) var generation = 0
    /// Display aspect (w ÷ h) per source path, learned for free: every
    /// thumbnail this cache hands out is already orientation-corrected and
    /// aspect-preserving, so its own pixel dimensions answer "what shape is
    /// this asset?" without a second file read.
    ///
    /// It is kept beside the `NSCache` rather than derived from it because the
    /// images are evictable and a Double is not worth evicting — and because
    /// the answer is what stops a hero laying itself out twice (see
    /// `MediaPaneMetrics`). A grid tile therefore pays the probe that the
    /// detail screen would otherwise pay on open.
    private var aspects: [String: Double] = [:]

    private init() {
        cache.countLimit = 300
        // Thumbnails are small, but hundreds of ~1 MB BGRA images is real
        // memory on a phone that is also running a camera — cap bytes too.
        cache.totalCostLimit = 96 * 1024 * 1024
        observeMemoryPressure()
    }

    /// Returns a fitted thumbnail for `url`, decoding it only on the first
    /// request ever (memory hit, else disk hit, else generate + persist).
    /// `kind` selects the video vs. image code path in the generator.
    ///
    /// Returns nil when there is nothing to show *yet* as well as when the
    /// decode failed, so callers must not treat nil as "show the placeholder"
    /// if they already have an image on screen.
    func thumbnail(for url: URL, kind: AppModel.MediaKind) async -> Image? {
        if let cached = cache.object(forKey: url as NSURL) {
            return Image(decorative: cached, scale: 1)
        }
        // One trip off the main actor for the whole load. Splitting identity,
        // disk read and decode into three hops meant three waits behind the
        // queue per tile, and on a big library the queue is the scarce resource.
        let poisoned = failedKeys
        let outcome = await MediaWorkQueue.shared.run { () -> Load in
            let diskKey = DiskThumbnailStore.key(for: url)
            if poisoned.contains(diskKey) {
                return Load(key: diskKey, image: nil, skipped: true)
            }
            if let stored = DiskThumbnailStore.read(diskKey) {
                return Load(key: diskKey, image: stored)
            }
            guard let generated = ProjectThumbnailGenerator.thumbnail(for: url, kind: kind) else {
                // Whether the file is even there separates "deleted behind our
                // back" from "ImageIO gave up on it" in the log.
                return Load(key: diskKey, image: nil,
                            sourceExists: FileManager.default.fileExists(atPath: url.path))
            }
            DiskThumbnailStore.write(generated, forKey: diskKey)
            return Load(key: diskKey, image: generated)
        }
        // Cancelled — the caller scrolled away. Nothing to report and nothing
        // to remember; a cancelled job is not a failed one.
        guard let outcome else { return nil }
        guard let image = outcome.image else {
            if !outcome.skipped {
                failedKeys.insert(outcome.key)
                MediaWorkQueue.note(
                    "thumbnail decode failed kind=\(kind) file=\(url.lastPathComponent) exists=\(outcome.sourceExists) queueDepth=\(MediaWorkQueue.shared.depth)",
                    isError: true)
            }
            return nil
        }
        remember(image, forKey: url as NSURL)
        return Image(decorative: image, scale: 1)
    }

    /// One thumbnail load's result: the disk-cache identity it resolved to, the
    /// image if there is one, and whether it was skipped as a known failure
    /// (which must not be re-reported as a fresh failure).
    private struct Load {
        var key: String
        var image: CGImage?
        var skipped = false
        var sourceExists = true
    }

    private func remember(_ image: CGImage, forKey key: NSURL) {
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        if image.height > 0 {
            aspects[(key as URL).path] = Double(image.width) / Double(image.height)
        }
    }

    /// What shape this asset is, if anything has already looked at it — a
    /// synchronous answer, so a view can size its slot correctly on its first
    /// paint instead of resizing when a probe lands.
    func aspect(for url: URL?) -> Double? {
        guard let url else { return nil }
        return aspects[url.path]
    }

    /// Record a shape learned somewhere else (a metadata probe, or a size the
    /// project already stored), so the next screen to ask gets it for free.
    func recordAspect(_ aspect: Double, for url: URL) {
        guard aspect.isFinite, aspect > 0 else { return }
        aspects[url.path] = aspect
    }

    /// Drop in-memory thumbnails for files rewritten in place. The disk tier
    /// self-heals (mtime-keyed); `failedKeys` is cleared wholesale — cheap,
    /// and correctness beats re-paying a few doomed decodes.
    func invalidate(urls: [URL]) {
        for url in urls {
            cache.removeObject(forKey: url as NSURL)
            // A rotate swaps the asset's width and height, so the remembered
            // shape is as stale as the picture.
            aspects.removeValue(forKey: url.path)
        }
        failedKeys.removeAll()
        generation += 1
    }

    /// Drop every in-memory thumbnail. The companion to clearing the disk tier
    /// (Settings ▸ Clear cache): without it the grids keep showing images whose
    /// JPEGs have just been deleted, so a cache clear looks like it did nothing
    /// until the next launch — which is how a bad thumbnail can outlive the fix
    /// that was supposed to remove it.
    func invalidateAll() {
        cache.removeAllObjects()
        aspects.removeAll()
        failedKeys.removeAll()
        generation += 1
    }

    /// Let every remembered failure retry. Called when the conditions that make
    /// a decode fail spuriously have changed — a memory warning has been dealt
    /// with, or the app has come back to the foreground.
    private func clearFailureMemory(reason: String) {
        guard !failedKeys.isEmpty else { return }
        MediaWorkQueue.note("clearing \(failedKeys.count) remembered thumbnail failures (\(reason))")
        failedKeys.removeAll()
        // Nudge the views: tiles that gave up on a poisoned key have no other
        // reason to ask again.
        generation += 1
    }

    private func observeMemoryPressure() {
        #if canImport(UIKit) && !os(watchOS)
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                MediaWorkQueue.note("memory warning — media queue depth \(MediaWorkQueue.shared.depth)")
                self?.clearFailureMemory(reason: "memory warning")
            }
        }
        center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.clearFailureMemory(reason: "foreground")
            }
        }
        #endif
    }
}

/// The on-disk half of `ProjectThumbnailCache`: one small JPEG per source
/// asset. Every call here is synchronous and blocking — callers run it on
/// `MediaWorkQueue`, never on the main actor or the cooperative pool.
enum DiskThumbnailStore {
    /// Where the JPEGs live. Not private: the storage card counts this folder
    /// and "Clear cache" empties it, and both need to name the same place.
    static var directory: URL {
        StorageRoot.current.appendingPathComponent("Thumbnails", isDirectory: true)
    }

    /// Deletes every stored thumbnail. Returns the bytes freed.
    ///
    /// Purely reproducible — each file regenerates from its source on the next
    /// request — so this is the definition of a cache item, and it is the one
    /// the user reaches for when a thumbnail is visibly wrong. `generatorVersion`
    /// covers the case where *we* know the output changed; this covers the case
    /// where only the user does.
    @discardableResult
    static func clear() -> Int64 {
        let fileManager = FileManager.default
        let folder = directory
        guard let files = try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        else { return 0 }
        var freed: Int64 = 0
        for file in files {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            let size = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            if (try? fileManager.removeItem(at: file)) != nil { freed += size }
        }
        return freed
    }

    /// Cache identity of a source file: its path plus modification date, so
    /// a rewritten file re-generates and a missing one is distinguishable
    /// from every real version of itself.
    ///
    /// The path part is sandbox-relative: an absolute path embeds the data
    /// container's UUID, which iOS rotates on some reinstalls — that orphaned
    /// every cached thumbnail at once and cost a full-library regeneration
    /// storm on the next launch (a burst of "can't open …Thumbnails/….jpg"
    /// in the log, and a device busy decoding for minutes).
    /// Bumped when the generator's *output* changes, so the stored JPEGs
    /// self-invalidate. Version 2: raw files decode through `CIRAWFilter`
    /// instead of ImageIO, which on iOS was persisting the file's embedded
    /// preview — a 189×252 blob for a 12 MP frame — under the key of a
    /// full-size thumbnail. Without the bump those survive the fix on disk,
    /// which is precisely how the bug outlived two rebuilds.
    private static let generatorVersion = 2

    static func key(for url: URL) -> String {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970
        let home = NSHomeDirectory()
        let path = url.path.hasPrefix(home) ? String(url.path.dropFirst(home.count)) : url.path
        return "v\(generatorVersion)|\(path)|\(modified.map { String($0) } ?? "missing")"
    }

    static func read(_ key: String) -> CGImage? {
        let file = fileURL(for: key)
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    /// Best-effort: the caller already has the image; persisting it is purely
    /// for the next launch. A torn write just fails to decode later and
    /// regenerates.
    static func write(_ image: CGImage, forKey key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = fileURL(for: key)
        guard let destination = CGImageDestinationCreateWithURL(
            file as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        if !CGImageDestinationFinalize(destination) {
            MediaWorkQueue.note("thumbnail persist failed for \(file.lastPathComponent)", isError: true)
        }
    }

    private static func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".jpg")
    }
}

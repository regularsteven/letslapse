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
    }

    /// Drop in-memory thumbnails for files rewritten in place. The disk tier
    /// self-heals (mtime-keyed); `failedKeys` is cleared wholesale — cheap,
    /// and correctness beats re-paying a few doomed decodes.
    func invalidate(urls: [URL]) {
        for url in urls {
            cache.removeObject(forKey: url as NSURL)
        }
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
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LetsLapse/Thumbnails", isDirectory: true)
    }

    /// Cache identity of a source file: its path plus modification date, so
    /// a rewritten file re-generates and a missing one is distinguishable
    /// from every real version of itself.
    static func key(for url: URL) -> String {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970
        return "\(url.path)|\(modified.map { String($0) } ?? "missing")"
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

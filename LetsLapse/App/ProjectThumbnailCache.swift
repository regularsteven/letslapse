import SwiftUI

/// In-memory thumbnail cache for the Gallery grid. Without it, a `LazyVGrid`
/// re-decodes every cell's image each time it scrolls back into view; with it,
/// each source URL is decoded once and reused.
///
/// The generator (`ProjectThumbnailGenerator`) already produces platform-neutral
/// `CGImage`s, so we cache those directly rather than `UIImage`/`NSImage` — one
/// code path for iOS and macOS, and the SwiftUI `Image(decorative:scale:)`
/// initializer takes a `CGImage` on both.
@MainActor
final class ProjectThumbnailCache: ObservableObject {
    static let shared = ProjectThumbnailCache()

    private let cache = NSCache<NSURL, CGImage>()

    private init() {
        cache.countLimit = 300
    }

    /// Returns a fitted thumbnail for `url`, decoding it only on the first
    /// request. `kind` selects the video vs. image code path in the generator.
    func thumbnail(for url: URL, kind: AppModel.MediaKind) async -> Image? {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) {
            return Image(decorative: cached, scale: 1)
        }
        guard let generated = await ProjectThumbnailGenerator.thumbnail(for: url, kind: kind) else {
            return nil
        }
        cache.setObject(generated, forKey: key)
        return Image(decorative: generated, scale: 1)
    }
}

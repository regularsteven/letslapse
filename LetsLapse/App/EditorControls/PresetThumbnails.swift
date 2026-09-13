import SwiftUI

// The live preset thumbnails of boards 2a / 5a / 3b — spec §9 "Presets" and
// decision 8: rendered through the real grader at 160 px, off-main, cached by
// preset + adjustments token + frame, refreshed on panel open and on gesture
// end, never per tick.

/// One preset tile in the Presets panel, wired to the render cache.
///
/// `PresetTile` is stateless by design (it draws whatever image it is handed);
/// this is the view that decides WHEN a tile's picture is rendered. The cache
/// key is the frame, the preset and the adjustments token, so a tile's task
/// re-runs exactly when its picture would change — a scrub to another frame
/// (the built-ins render at neutral, so nothing else moves them; a saved
/// preset's values are its own). Two rules keep that from turning into a
/// render storm:
///
/// - The first render for a tile runs at once, so opening the panel shows
///   pictures as fast as the grader can make them.
/// - Every later key change waits 350 ms before rendering, and a newer key
///   cancels the wait, so a drag or a scrub collapses into one render per
///   tile at its end rather than one per tick.
///
/// An image already in the cache shows immediately either way.
struct EditorPresetThumbnail: View {
    var name: String
    /// What the tile shows: the preset alone (see
    /// `PhotoAdjustmentsPanel.presetsContent` for why not the edits too).
    var grade: PhotoGrade
    /// The frame under the playhead, or nil when the owner has none to show —
    /// the tile then draws its placeholder and renders nothing.
    var frame: PresetPreviewFrame?
    @ObservedObject var cache: PresetThumbnailCache
    var isSelected: Bool
    var accent: Color
    var style: PresetTileStyle
    /// See `PresetTile.isOnDark` — false for the Gallery panel's light card.
    var isOnDark = true
    var action: () -> Void

    /// 160 px — every tile shares one size so `PhotoGrader`'s three-deep decode
    /// cache serves all of them from one decode of the frame.
    static let maxDimension: CGFloat = 160

    /// Set once the first render has been asked for; every key change after
    /// that is debounced.
    @State private var hasRendered = false

    private var key: String? {
        frame.map { PresetThumbnailCache.key(frame: $0, grade: grade, maxDimension: Self.maxDimension) }
    }

    var body: some View {
        PresetTile(
            name: name,
            image: key.flatMap { cache.image(for: $0) },
            isSelected: isSelected,
            accent: accent,
            style: style,
            isOnDark: isOnDark,
            action: action)
        .task(id: key) {
            guard let key, let frame, cache.image(for: key) == nil else { return }
            if hasRendered {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            }
            hasRendered = true
            await cache.render(key: key, frame: frame, grade: grade, maxDimension: Self.maxDimension)
        }
    }
}

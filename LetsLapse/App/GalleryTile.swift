import SwiftUI

// MARK: - Gallery tile

/// A 4:3 thumbnail tile used in the Gallery grid.
///
/// Badges:
/// - Bottom-left: shoot type (Photos / Interval / Video) — always shown
/// - Top-right: amber "N clips" badge — only when the project has ≥ 2 blended clips
///
/// Interaction:
/// - Single tap → `onTap` (selection → preview panel; in selection mode the
///   caller toggles instead)
/// - Double tap → `onOpen` (navigate to Hero / ProjectDetailView)
/// - Right-click → context menu (wired by the caller)
///
/// Selection (2026-09-13): the accent border marks a selected tile as it
/// always has; with `showsCircle` — selection mode, or more than one tile
/// selected — every tile also wears a 22 pt circle top-leading, empty until
/// the tile is selected and then filled accent with a tick, so a person can
/// see that tapping tile after tile is what adds to the selection.
struct GalleryTile: View {
    @EnvironmentObject var model: AppModel
    var capture: AppModel.CaptureProject
    var isSelected: Bool
    var showsCircle = false
    var onTap: () -> Void
    var onOpen: () -> Void

    @State private var blendCount: Int?

    private var thumbnailURL: URL? { model.thumbnailURL(for: capture) }
    private var mediaKind: AppModel.MediaKind { model.mediaKind(for: capture) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Thumbnail
            ProjectThumbnailView(url: thumbnailURL, kind: mediaKind, cornerRadius: 8)
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay(selectionOverlay)

            // Shoot-type badge (bottom-left)
            MediaBadge(text: typeBadge)
                .padding(6)
        }
        .overlay(alignment: .topTrailing) {
            // "N clips" badge (top-right, amber, only when ≥ 2 blended clips)
            if let count = blendCount, count >= 2 {
                MediaBadge(text: "\(count) clips", tint: LL.amber)
                    .padding(6)
            }
        }
        .overlay(alignment: .topLeading) {
            if showsCircle {
                selectionCircle
                    .padding(6)
            }
        }
        // Single tap → selection (preview panel)
        .onTapGesture(count: 1) {
            onTap()
        }
        // Double tap → open Hero
        .onTapGesture(count: 2) {
            onOpen()
        }
        // Load blend count asynchronously (already computed by the model for
        // any project the list has loaded; this is just a local observation).
        .task(id: capture.id) {
            blendCount = model.blends(for: capture).count
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Open") { onOpen() }
    }

    // MARK: Overlays

    @ViewBuilder
    private var selectionOverlay: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(LL.accent, lineWidth: 2.5)
        }
    }

    /// The selection-mode circle: white ring over black 30 % until selected,
    /// then the accent with a white tick.
    private var selectionCircle: some View {
        ZStack {
            Circle()
                .fill(isSelected ? LL.accent : Color.black.opacity(0.3))
            Circle()
                .strokeBorder(Color.white, lineWidth: 1.5)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 22, height: 22)
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .accessibilityHidden(true)
    }

    // MARK: Badge labels

    private var typeBadge: String {
        if capture.isPhotoCapture { return "Photo" }
        switch capture.kind {
        case .photos: return "Interval"
        case .video:  return "Video"
        }
    }

    private var accessibilityLabel: String {
        var parts = [capture.displayTitle, typeBadge]
        if let count = blendCount, count >= 2 {
            parts.append("\(count) blended clips")
        }
        return parts.joined(separator: ", ")
    }
}

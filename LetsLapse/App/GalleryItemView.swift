import SwiftUI

// MARK: - The Gallery's item view (macOS, 2026-09-13)
//
// The editor used to be a window of its own on the Mac. It is now a mode of
// the Gallery tab: the left column swaps the Library for the project's
// inspector, the grid and its pane swap for the editor (the media beside its
// own 330pt rail), and a filmstrip of the grid's current result set runs
// under everything, so the next project is one click — or one arrow — away.
// Nothing here is a navigation push: the columns keep their places and swap
// what they hold, which is what lets the way in read as one surface changing
// mode rather than a second screen arriving.

/// Which project fills the Gallery window, and the editor page it opened on.
/// Owned by ContentView beside the tab's navigation path, so a trip to another
/// tab and back lands on the same project rather than on the grid.
struct GalleryFocus: Equatable {
    var request: EditorOpenRequest
    var page: RailTab
    var captureID: UUID { request.captureID }
}

/// The editor for the focused project, as a column of the Gallery window.
/// A still opens `PhotoViewerView`, a movie `VideoEditorView` — the same
/// choice the Mac's editor windows make — keyed on the project so a filmstrip
/// move rebuilds the editor for the next one rather than re-seeding this one.
struct GalleryItemEditor: View {
    var focus: GalleryFocus
    var exitRequest: EditorExitRequest?
    var onExit: () -> Void

    var body: some View {
        Group {
            switch focus.request.asset {
            case .still(let url):
                PhotoViewerView(
                    captureID: focus.captureID, url: url,
                    exitRequest: exitRequest, onExit: onExit)
            case .movie(let url):
                VideoEditorView(
                    captureID: focus.captureID, url: url,
                    exitRequest: exitRequest, onExit: onExit)
            }
        }
        .id(focus.captureID)
    }
}

/// The grid folded into one row: every project the sidebar, the search and
/// the sort leave in the grid, in the grid's order, at 60pt. The focused
/// project carries the grid's own selection ring and is kept centred; a click
/// on any other asks the host to move there. Full window width, under the
/// inspector and the rail alike — the Lightroom / Photos convention, and the
/// one place a strip can go without the editors having to know about it.
struct GalleryFilmstrip: View {
    @EnvironmentObject var model: AppModel
    var captures: [AppModel.CaptureProject]
    var focusedID: UUID
    var onSelect: (UUID) -> Void

    static let tileHeight: CGFloat = 60
    static let tileCornerRadius: CGFloat = 6
    /// Tiles plus 12pt above and below.
    static let height: CGFloat = 84

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(captures) { capture in
                        tile(capture)
                            .id(capture.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onAppear { scroller.scrollTo(focusedID, anchor: .center) }
            .onChange(of: focusedID) { _, id in
                withAnimation(.easeInOut(duration: 0.25)) {
                    scroller.scrollTo(id, anchor: .center)
                }
            }
        }
        .frame(height: Self.height)
        .background(LL.cardBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filmstrip")
    }

    private func tile(_ capture: AppModel.CaptureProject) -> some View {
        let isFocused = capture.id == focusedID
        let grade = model.photoGrade(for: capture)
        let shape = RoundedRectangle(cornerRadius: Self.tileCornerRadius, style: .continuous)
        return ProjectThumbnailView(
            url: model.thumbnailURL(for: capture),
            kind: model.mediaKind(for: capture),
            cornerRadius: Self.tileCornerRadius,
            grade: grade.isIdentity ? nil : grade)
            .frame(width: Self.tileHeight * 4 / 3, height: Self.tileHeight)
            .overlay {
                if isFocused {
                    shape.strokeBorder(LL.accent, lineWidth: 2.5)
                }
            }
            .contentShape(shape)
            .onTapGesture { onSelect(capture.id) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(capture.displayTitle)
            .accessibilityAddTraits(isFocused ? [.isButton, .isSelected] : .isButton)
    }
}

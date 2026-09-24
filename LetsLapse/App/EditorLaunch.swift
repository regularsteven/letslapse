import SwiftUI

// MARK: - Opening a project's editor from outside its detail screen
//
// The Gallery panel's Edit / Text / Shapes buttons and the tile menu's Edit
// go straight to the editor — the screen the project hero's Edit pill opens,
// on the frame it opens it on — rather than through the detail screen. What
// the editor opens ON and which rail page it lands on are decided here, so
// the entry points cannot drift apart. (Until 2026-09-11 those buttons called
// `openCapture`, which is the New clip flow: three buttons, one action.)

/// The asset a project's editor opens on — the project hero's preview, which
/// is also what its Edit pill leads to. A still goes to `PhotoViewerView`, a
/// movie to `VideoEditorView`.
enum EditorAsset: Equatable {
    case still(URL)
    case movie(URL)

    var url: URL {
        switch self {
        case .still(let url), .movie(let url): return url
        }
    }

    var isMovie: Bool {
        if case .movie = self { return true }
        return false
    }
}

/// One "open the editor": which project, on which asset. The rail page rides
/// the model instead (`AppModel.requestedEditorPage`) — on the Mac the
/// editor is a window that may already be open, in which case reopening it
/// fronts the existing window rather than building a new view, so nothing
/// carried at init could move it to a page.
struct EditorOpenRequest: Identifiable, Equatable {
    let captureID: UUID
    let title: String
    let asset: EditorAsset
    var id: String { asset.url.path }
}

/// Which rail page an editor should land on, addressed to the project whose
/// editor consumes it (`PhotoViewerView` / `VideoEditorView`).
struct EditorPageRequest: Equatable {
    let captureID: UUID
    let page: RailTab
}

/// A host asking an embedded editor to leave (the Gallery's item view on the
/// Mac, 2026-09-13, where the editor is a column of the Gallery window rather
/// than a window of its own). The editor answers through its own exit path —
/// the debounced grade write, the overlay write, the library flush — and then
/// calls `onExit` instead of `dismiss`. `offersPresetSave` is the Back
/// button's exit-time offer; a filmstrip move skips it, the way a photo app
/// walks a catalogue without a prompt at every step.
struct EditorExitRequest: Equatable {
    let id = UUID()
    var offersPresetSave: Bool
}

// MARK: - Paging (iOS, 2026-09-21)
//
// On the phone and the iPad the editor is one page of a swipe through the
// library (`EditorPager`): a drag across the picture at fit scale slides to
// the neighbouring project, the way a photo app walks a camera roll. The
// pager owns the drag and the neighbours' posters; each editor says what it
// allows and where its picture is through a preference, and takes the
// state that has to outlive it — clear preview — from the context below.

/// What a pager hands the editor it mounts.
struct EditorPagingContext {
    /// Clear preview carried over from the previous page, so a swipe made
    /// with the chrome hidden lands with it hidden.
    var startsClear: Bool
    var onClearPreviewChanged: (Bool) -> Void
    /// The chrome's ⓘ: the pager presents the project's panel as a sheet.
    var onInfo: () -> Void
}

/// What the editor on the page allows and where its picture is — published
/// every layout pass through `EditorPagingStateKey`.
struct EditorPagingState: Equatable {
    /// The named coordinate space the pager registers on its container, so
    /// `paneFrame` is measured against the same origin the pager offsets in.
    static let hostSpace = "EditorPagerHost"

    /// True while a horizontal drag over the editor is the pager's to take:
    /// the Editor page at fit scale with nothing open or armed.
    var canPage: Bool
    /// The picture pane's frame in the host's space — the neighbours'
    /// posters are fitted into it, so a page turn hands over in place.
    var paneFrame: CGRect
    var anchor: PhotoZoomGeometry.Anchor
    /// True once the editor has drawn its own picture, so the settled
    /// poster over it can go.
    var hasPicture: Bool
}

struct EditorPagingStateKey: PreferenceKey {
    static let defaultValue: EditorPagingState? = nil
    static func reduce(value: inout EditorPagingState?, nextValue: () -> EditorPagingState?) {
        if let next = nextValue() { value = next }
    }
}

extension AppModel {
    /// The asset the editor opens on: a video project's movie, a Photo
    /// capture's hero image, an interval shoot's poster frame. nil when the
    /// project's files have gone missing — the hero draws its placeholder
    /// and no button, and the Gallery's buttons do nothing.
    func editorAsset(for capture: CaptureProject) -> EditorAsset? {
        switch capture.kind {
        case .video:
            return mediaURL(for: capture).map(EditorAsset.movie)
        case .photos:
            if capture.isPhotoCapture {
                return heroImageURL(for: capture).map(EditorAsset.still)
            }
            return thumbnailFrameURL(for: capture).map(EditorAsset.still)
        }
    }

    /// Stages the editor for `capture` to open on `page` and returns what to
    /// present — a full-screen cover's item on iOS (`editorCover`), a window
    /// on the Mac (`EditorOpenRequest.open(with:)`). nil, with nothing
    /// staged, when the project has no asset to open.
    func stageEditor(for capture: CaptureProject, page: RailTab = .editor) -> EditorOpenRequest? {
        guard let asset = editorAsset(for: capture) else { return nil }
        requestedEditorPage = EditorPageRequest(captureID: capture.id, page: page)
        return EditorOpenRequest(captureID: capture.id, title: capture.displayTitle, asset: asset)
    }
}

#if os(iOS)
/// Presents the editor `request` names as a full-screen cover — the same
/// presentation the detail screen gives its own editors, from wherever the
/// request was made. A modifier the presenting view applies, not one the tab
/// root could: on an iPhone the Gallery panel is itself a sheet, and a cover
/// has to be presented from inside that sheet to land above it.
private struct EditorCover: ViewModifier {
    @EnvironmentObject var model: AppModel
    @Binding var request: EditorOpenRequest?

    func body(content: Content) -> some View {
        content.fullScreenCover(item: $request) { request in
            Group {
                switch request.asset {
                case .still(let url):
                    PhotoViewerView(captureID: request.captureID, url: url)
                case .movie(let url):
                    VideoEditorView(captureID: request.captureID, url: url)
                }
            }
            .environmentObject(model)
        }
    }
}

extension View {
    func editorCover(_ request: Binding<EditorOpenRequest?>) -> some View {
        modifier(EditorCover(request: request))
    }
}
#endif

#if os(macOS)
extension EditorOpenRequest {
    /// Opens the editor window — one per asset, and reopening the same asset
    /// fronts it (see `PhotoEditorWindowRequest`). The page request staged
    /// alongside is what moves an already-open window to its page.
    func open(with openWindow: OpenWindowAction) {
        switch asset {
        case .still(let url):
            openWindow(value: PhotoEditorWindowRequest(captureID: captureID, url: url, title: title))
        case .movie(let url):
            openWindow(value: VideoEditorWindowRequest(captureID: captureID, url: url, title: title))
        }
    }
}
#endif

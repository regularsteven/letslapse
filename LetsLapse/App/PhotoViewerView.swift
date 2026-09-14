import LetsLapseKit
import SwiftUI

#if os(macOS)
/// Identifies one photo-editor window on the Mac: which capture, which file,
/// and the title to show. `Codable` so macOS can restore the window across
/// relaunches; `Hashable` so reopening the same photo fronts the existing
/// window instead of spawning a second one.
struct PhotoEditorWindowRequest: Hashable, Codable {
    let captureID: UUID
    let url: URL
    let title: String
}
#endif

/// The full-screen photo editor: the graded image, six main buttons — Presets
/// · Light · Color · Effects · Detail · Crop — and the one group panel they
/// open, which re-renders the preview live.
///
/// On iOS/iPadOS it is a `fullScreenCover` on black with a floating back
/// button top-left; on macOS it is the content of its own resizable window
/// (`PhotoEditorWindowRequest` scene in `LetsLapseApp`), so the window chrome
/// owns the title and close.
///
/// The Editor page has three dressings, chosen from the container's size and
/// shape (`editorLayout(for:)`): the phone's bottom stack over a picture that
/// has the whole screen (boards 2a / 6a — iPad portrait follows it), the
/// landscape iPad's floating card beside an anchored picture (5a / 6b), and
/// the rail beside the picture (3b / 6c on the Mac, drawn dark on a landscape
/// iPhone). The Text, Frames and Masks pages keep the older split: past
/// `wideLayoutThreshold` a side rail, below it the picture pinned above a
/// scrolling control stack. A panel opens on a snapshot of the grade and its
/// ✓ / ✕ keep or restore it (`openPanel(for:)`, `commitPanel`, `cancelPanel`).
struct PhotoViewerView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var presetStore = CustomPresetStore.shared

    let captureID: UUID
    let url: URL
    /// False when something else already owns the chrome — the fullscreen media
    /// sheet embeds this view as its photo page and draws its own close button,
    /// share and page counter above it.
    var showsBackButton: Bool = true
    /// Set by a host that embeds the editor as a column of its own window
    /// (the Gallery's item view on the Mac): the host's Back and its filmstrip
    /// ask to leave through here, so the exit path runs — and `onExit` is
    /// where the editor then goes, in place of `dismiss`.
    var exitRequest: EditorExitRequest? = nil
    var onExit: (() -> Void)? = nil

    /// Live edit state. Seeded from the project on appear and written back —
    /// debounced — as the controls move, so the detail screen and the export
    /// agree with what is on screen here.
    @State private var preset: PhotoPreset = .default
    @State private var adjustments: PhotoAdjustments = .neutral
    /// Which of the three states the live values are in. Re-resolved on every
    /// change (see `refreshState`), so a slider that moves off the applied
    /// preset flips the pill to Edited on the same frame it moves — not on
    /// save, and not on the next screen.
    @State private var presetState: PresetState = .original
    @State private var loaded = false

    // MARK: Keyframes
    //
    // An interval shoot is a clip, not a still, so its grade can travel across
    // it. Everything below is inert for a Photo-mode capture: `frames` stays
    // empty, `hasTimeline` is false, and the screen is exactly the editor it
    // has always been.

    /// How the grade moves across this shoot. Empty until somebody grades a
    /// second moment of it — see `GradeTimeline`.
    @State private var timeline: GradeTimeline = .empty
    /// The playhead, 0…1 of the source capture.
    @State private var position: Double = 0
    @State private var isScrubbing = false
    @State private var isPlaying = false
    @State private var playback: Task<Void, Never>?
    /// The shoot's stills in capture order, and the elapsed capture seconds of
    /// each where the shoot recorded a clock. Empty for a Photo capture.
    ///
    /// Every source frame, including the ones the user has nominated as bad —
    /// `frames`/`frameSeconds` are the filtered view of this pair, and both are
    /// filtered by the same predicate so a frame and its moment can never come
    /// apart.
    @State private var allFrames: [URL] = []
    @State private var allFrameSeconds: [Double] = []
    /// The filtered view of the pair above — the frames this screen walks,
    /// their rebased clock, and the axis built from them. Stored, not
    /// computed: the body reads these a dozen times per evaluation, and
    /// rebuilding a 1,480-frame URL list per read (Foundation stats the disk
    /// once per appended component) held the editor to ~5 slider ticks a
    /// second (docs/editor-performance-plan.md, finding 1 — measured).
    /// `refreshFrameWindow()` is the one writer.
    @State private var frames: [URL] = []
    @State private var frameSeconds: [Double] = []
    @State private var frameAxis = FrameAxis(
        frameCount: 0, elapsedSeconds: nil, uniformDuration: nil)

    @State private var rendered: CGImage?
    @State private var isRendering = false
    /// Bumped by every control change; the render task keys off it so a burst
    /// of slider ticks collapses into one render.
    @State private var renderToken = 0
    /// The playhead the preview is rendered at. Quantised while scrubbing or
    /// playing (see `renderPosition(for:)`) so a drag across two hours of
    /// capture asks for a few dozen frames rather than one per pixel, and set
    /// exactly when the drag lets go.
    @State private var renderedPosition: Double = 0

    /// The white balance the frame under the playhead was shot at — the anchor
    /// the Temp and Tint readouts are measured from. Re-read as the playhead
    /// moves, because on an interval shoot every frame has its own, and a
    /// camera left on auto white balance can put a hundred mired between two
    /// of them.
    @State private var asShotKelvin: Double = 6500
    @State private var asShotTint: Double = 0
    /// The file `asShotKelvin`/`asShotTint` were read from, so a scrub that
    /// lands back on the same frame does not re-open the converter.
    @State private var asShotSourcePath: String?
    @State private var isNamingPreset = false
    @State private var newPresetName = ""
    @State private var presetPendingDelete: CustomPreset?
    /// A chip tap held back for confirmation: applying it from Edited would
    /// discard the manual adjustments on screen.
    @State private var pendingApply: PresetApplyRequest?
    /// The "Save as preset?" offer raised on the way out of an Edited grade.
    @State private var isOfferingPresetSave = false
    /// Set while that offer is what sent the user into the naming alert, so a
    /// completed save leaves the editor rather than dropping them back into it.
    @State private var exitsAfterPresetSave = false
    /// "Not now" on the inline offer, where there is no exit to leave through.
    /// Cleared whenever a preset is applied, so a fresh round of edits is
    /// offered again rather than silently never asking twice.
    @State private var declinedPresetSave = false

    /// The still's display aspect (w ÷ h). nil until the metadata probe lands —
    /// see `MediaPaneMetrics` for what the layout does in the meantime.
    @State private var aspect: Double?

    // MARK: Text overlays
    //
    // The Text tab: the layer list the user places by hand, the semantic
    // masks that let the scene occlude them, and the reveal animation. State
    // lives here (like the grade) and persists through the per-project
    // sidecar (`AppModel.setOverlayDocument`) on finished gestures.

    /// Which rail page is showing. `LL_RAIL=text|masks|frames` opens the
    /// editor straight onto a page, the way `LL_EDITOR` opens the editor at
    /// all: the rail's pages are otherwise only reachable by a tap, which a
    /// screenshot or a design-mirror check has no way to make.
    @State private var railTab: RailTab = {
        #if DEBUG
        if let hook = ProcessInfo.processInfo.environment["LL_RAIL"],
           let tab = RailTab(rawValue: hook.capitalized) {
            return tab
        }
        #endif
        return .editor
    }()
    /// The project's overlay document — layers front-to-back, the project's
    /// custom masks, and the mask dials. Seeded once from the sidecar.
    @State private var overlayDocument = OverlayDocument()
    /// What this window last wrote (or seeded). `persistOverlays` no-ops
    /// against it — so a second editor window on the same project, holding a
    /// stale empty list, can never bulldoze the sidecar another window just
    /// wrote. Deleting overlays.json requires an actual Remove Text here.
    /// Set by `LL_MIXER`: the values on screen are staged for a screenshot and
    /// `persist()` is a no-op for the life of the editor.
    @State private var persistSuppressedForStaging = false
    @State private var persistedDocument = OverlayDocument()
    /// The layer the preview draws its bounding box and handles around.
    @State private var selectedOverlayID: UUID?
    /// A short confirmation floated over the media ("Linked — starts after
    /// …", "Imported Amatic SC"), 1.8 s.
    @State private var overlayToast: String?
    /// The Crafted Text sheet, owned here so `LL_TEXT=story,craft` can raise it.
    @State private var railCrafting = false
    @State private var overlayToastTask: Task<Void, Never>?
    /// The faces this project brought with it (`fonts/`), for the picker.
    @State private var importedFonts: [OverlayFontStore.ImportedFont] = []
    /// The copy field being edited and the word it is styling — owned here
    /// so the iOS accessory bar can be pinned above the keyboard from the
    /// editor's own safe-area inset, outside the scrolling panel.
    @State private var overlayRunTarget: OverlayRunTarget?

    /// True while a copy field has the keyboard. The stacked layout gives
    /// the keyboard its room by collapsing the media to its floor and
    /// hiding the lanes — the cover shrinks its safe area for the keyboard,
    /// and without this the picture keeps every point and the field being
    /// typed into is the part that vanishes.
    private var isTypingCopy: Bool {
        #if os(iOS)
        return railTab == .text && overlayRunTarget != nil
        #else
        return false
        #endif
    }
    /// The region the Masks tab is inspecting — what "Show semantic mask"
    /// tints and what the mask fetch is for. Editor state: which region is
    /// being LOOKED at says nothing about the piece.
    ///
    /// `LL_MASK=sky|land[,tint]` pre-selects it. Nothing on the Masks tab is
    /// analysed until a region is chosen, so without this the whole screen —
    /// the dials, the status line, the tint, the analysis itself — is behind
    /// a click that a screenshot run has no way to make.
    @State private var inspectedRegion: OverlayPlacement? = {
        #if DEBUG
        guard let hook = ProcessInfo.processInfo.environment["LL_MASK"] else { return nil }
        switch hook.split(separator: ",").first.map(String.init) {
        case "sky": return .sky
        case "land": return .land
        default: return nil
        }
        #else
        return nil
        #endif
    }()
    /// A live drag over the preview: the SwiftUI proxy shows `current` while
    /// the baked overlay is suppressed from the render.
    @State private var overlayDrag: OverlayDragState?
    /// Healer: SwiftUI resets this when the drag gesture is cancelled rather
    /// than ended, which is the only signal a cancelled drag gives.
    @GestureState private var overlayDragActive = false
    /// The segmentation model's identity, or nil when not installed.
    /// Resolved off the file system once at load (and when the Text tab
    /// opens), never per body evaluation.
    @State private var segModelIdentity: String?
    /// The mask debug view: the semantic mask tinted over the preview.
    @State private var showMask: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["LL_MASK"]?
            .split(separator: ",").contains("tint") ?? false
        #else
        return false
        #endif
    }()
    /// The mask readout in the Text tab — provenance, progress, or an error.
    @State private var maskStatus: String?

    // MARK: Masks as adjustment layers
    //
    // A mask has two homes: the Masks tab owns its SHAPE, the Editor tab owns
    // its GRADE. The state below is what makes the two halves one thing — an
    // expanded grade puts its mask's handles on the picture, and "Grade this
    // in Editor" jumps back with it open.

    /// Which `MaskGrade` the Editor tab's Masks card has expanded, or nil for
    /// the collapsed strip.
    ///
    /// `LL_MASKGRADE=first|empty` stages it: `first` expands the first grade
    /// (seeding one on Sky if the project has none), `empty` forces the
    /// no-grades state. Neither is reachable by automation — making one for
    /// real means drawing a mask and dragging sliders inside it — and the
    /// design mirrors are measured from them.
    @State private var expandedGradeID: UUID?
    /// The Masks tab's creation tool. Armed by a toolbar button or the Add
    /// menu's "New … mask…", and disarmed by the drag that draws one.
    @State private var maskTool: MaskShapeKind? = {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["LL_MASKTOOL"] {
        case "linear": return .linear
        case "radial": return .radial
        default: return nil
        }
        #else
        return nil
        #endif
    }()
    /// Which half of the Masks tab's detail card is showing.
    @State private var maskDetailSegment: MaskDetailSegment = .shape
    /// The slider label armed for the drag-on-the-picture gesture, and which
    /// grade it belongs to. Only masked grades arm — the whole-picture panel
    /// is a shared component and keeps its own behaviour.
    @State private var armedMaskField: PhotoAdjustmentField?
    /// The live caption over the picture while a mask gesture runs.
    @State private var maskHUD: String?
    /// A shape being drawn right now: its id and whether the drag has moved
    /// far enough to keep. Committed (or discarded) on release.
    @State private var drawingShapeID: UUID?
    /// True while a handle drag owns the picture, so the pan gesture stands
    /// down for its duration.
    @State private var maskGestureActive = false
    // MARK: Shapes — the project's register, edited from the Masks tab
    /// The Masks tab's last "Find in this picture", what was added from it,
    /// and the candidate under the mouse — shared by the rail's list and the
    /// picture's `FoundShapesOverlay` (2026-09-12).
    @State private var lastFind: ShapeFinder.Pass?
    @State private var addedFindIDs: Set<UUID> = []
    @State private var rejectedFindIDs: Set<UUID> = []
    @State private var hoveredFoundID: UUID?
    /// Where the mouse touched the hovered outline (picture hovers only), keyed
    /// by the candidate so a stale point never places another shape's pill.
    @State private var foundHoverAnchor: (id: UUID, point: CGPoint)?
    /// `shapes.json` for this project, or nil until a shape is drawn.
    @State private var shapeRegister: ShapeRegister?
    @State private var persistedShapeRegister: ShapeRegister?
    /// The register shape whose handles are on the picture (exclusive with a mask).
    @State private var selectedShapeID: UUID?
    /// The + Shape tool, armed until it draws one. `LL_SHAPETOOL=ellipse|rect|square`
    /// arms it at launch, as `LL_MASKTOOL` does for the mask tools.
    @State private var shapeTool: DetectedShape.Kind? = {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["LL_SHAPETOOL"] {
        case "ellipse": return .ellipse
        case "rect", "square": return .quad
        default: return nil
        }
        #else
        return nil
        #endif
    }()
    @State private var shapeSquareLock: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["LL_SHAPETOOL"] == "square"
        #else
        return false
        #endif
    }()
    /// The register shape being drawn right now, committed or discarded on release.
    @State private var drawingRegisterShapeID: UUID?
    /// The armed field's value when its drag began. Absolute against a frozen
    /// base, never accumulated — the same discipline `OverlayDragState.base`
    /// and `BoxResizeBase` set for the text layers.
    @State private var armedDragBase: Float?

    // MARK: Lightroom settings
    //
    // A raw file that has been through Lightroom carries its edits in an
    // `.xmp` beside it. Where one exists, the editor offers to read it —
    // rather than importing silently, because an import is lossy and the
    // photographer should see what did not come across.

    /// The sidecar beside the frame on screen, if there is one.
    @State private var lightroomSidecar: URL?
    /// The report, once read.
    @State private var lightroomReport: LightroomSettingsImport.Result?
    @State private var showsLightroomReport = false
    @State private var lightroomError: String?

    private struct OverlayDragState {
        let id: UUID
        /// The committed centre when the drag began — translation is applied
        /// to this absolute base, never accumulated.
        let base: CGPoint
        var current: CGPoint
        /// The layers that travel with this one: everything following it
        /// that has not been given an independent position, each with the
        /// centre it started from. They take the SAME translation the
        /// dragged layer took — after its snap, so a story stays in
        /// formation instead of each line snapping on its own.
        var followers: [UUID: CGPoint] = [:]
    }

    /// The box's geometry when a handle drag began, for the same reason
    /// `OverlayDragState.base` exists: resizing is absolute against a frozen
    /// base, never accumulated per event.
    private struct BoxResizeBase {
        let width: Double
        let height: Double
        let centerX: Double
        let centerY: Double
    }

    @State private var boxResizeBase: BoxResizeBase?
    /// Whether the live drag is currently snapped to a centre line — the
    /// only thing that puts a guide on screen.
    @State private var overlaySnapX = false
    @State private var overlaySnapY = false

    // MARK: Pixel peeping
    //
    // Noise reduction and sharpening work on single pixels, and the preview is
    // a 2000 px render of a 12 MP frame drawn to fit a screen — so at fit scale
    // they are invisible whatever they are set to. Everything below exists so
    // they can be graded by eye: zoom and pan into the picture, a 1:1 that
    // means one source pixel per *screen* pixel, and a loupe that puts those
    // pixels on screen while a Detail slider is actually moving.

    @Environment(\.displayScale) private var displayScale
    @State private var zoom: PhotoZoom = .fitted
    /// The image pane's size, published out of its own `GeometryReader` so the
    /// render requests — which live at the top of the view — can do the same
    /// arithmetic the picture is drawn with.
    @State private var paneSize: CGSize = .zero
    /// The source's pixel dimensions, from the same metadata probe that sizes
    /// the layout. Everything 1:1 is measured against these.
    @State private var sourcePixels: CGSize?
    /// The visible region, graded at the source's own resolution — what is
    /// actually drawn once the zoom asks for more detail than the preview
    /// render holds.
    @State private var detailPatch: PhotoGrader.DetailPatch?
    /// Which Detail control is under the finger, and the patch the loupe is
    /// showing while it is.
    @State private var loupeField: PhotoAdjustmentField?
    @State private var loupePatch: PhotoGrader.DetailPatch?
    /// Where the loupe points: the busiest part of the frame, scanned once per
    /// frame from the preview (`PhotoDetailFocus`).
    @State private var detailFocus = CGPoint(x: 0.5, y: 0.5)
    @State private var focusedFrame: URL?

    /// The controls that work on pixels, and so bring the loupe up.
    private static let detailFields: Set<PhotoAdjustmentField> = [
        .sharpen, .sharpenMasking, .noiseReduction, .noiseDetail, .colorNoiseReduction,
        .colorNoise,
    ]

    /// The preview render's longest edge. Past this the picture on screen is an
    /// upscale, which is the moment the detail patch has to take over.
    private let previewLongEdge: CGFloat = 2000
    /// Where the drag handle sits, as a fraction between the floor and the
    /// ceiling. 1 = the ceiling, which is where every presentation starts.
    /// Only the Text / Frames / Masks pages still have a handle: the Editor
    /// page's layouts give the picture the whole screen.
    @State private var mediaScale: CGFloat = 1

    // MARK: Editor groups
    //
    // The redesign's Editor page: six main buttons, one group's panel open
    // at a time, and a ✓/✕ on the panel that keeps or throws away what was
    // done since it opened. The state below is the page's, not the panel's —
    // the panel is torn down and rebuilt as it opens and closes, so anything
    // that has to outlive one opening lives here.

    /// The group whose panel is open. Nil shows the main buttons alone on
    /// the phone; the iPad and the Mac keep the buttons up either way.
    @State private var openGroup: EditorGroup?
    /// Which tool chip each group has up, for the session (spec §3).
    @State private var toolSelection: [EditorGroup: EditorTool] = [:]
    /// What the grade was when the open panel opened — restored by ✕.
    @State private var editorSnapshot: EditorSnapshot?
    /// iPad: how far the floating card has been dragged from its default
    /// bottom-right seat, kept across groups for the session. Nil = never
    /// moved.
    @State private var floatingPanelOffset: CGSize?
    /// The offset a header drag started from — absolute against a frozen
    /// base, never accumulated, the `MediaResizeHandle` discipline.
    @State private var floatingDragBase: CGSize?
    /// The floating card's measured size, for keeping it on screen.
    @State private var floatingPanelSize: CGSize = .zero
    /// The editor's container, for clamping the card and for the one
    /// decision that depends on the layout in use rather than the tap.
    @State private var containerSize: CGSize = .zero
    /// True while a crop handle or the crop body owns the picture, so pan
    /// and pinch stand down for the duration — the same arbitration
    /// `maskGestureActive` gives a mask's handles.
    @State private var cropEditing = false
    /// The phone's bottom stack — timeline card plus buttons or sheet — as
    /// measured, so the picture's own corner chrome can sit above it.
    @State private var phoneFootHeight: CGFloat = 0
    /// The Presets panel's tile renders. Owned here so they survive the
    /// phone sheet being torn down between opens.
    @StateObject private var presetThumbnails = PresetThumbnailCache()

    /// Everything ✕ has to put back. With a timeline an edit lands in the
    /// keyframes, not in `adjustments`; a preset tap moves `preset` and the
    /// state; a rotation change carries the text layers with it; and the
    /// Color group's menu can switch the shoot's white-balance source, which
    /// is a project field of its own. Snapshotting fewer than all of these
    /// would restore numbers the renderer then ignores.
    private struct EditorSnapshot {
        var preset: PhotoPreset
        var adjustments: PhotoAdjustments
        var timeline: GradeTimeline
        var presetState: PresetState
        var whiteBalanceSource: WhiteBalanceSource
    }

    /// Which of the three Editor-page dressings the container gets.
    private enum EditorLayout {
        /// 2a / 6a: the phone — every iPhone portrait, Slide Over, a narrow
        /// split.
        case phone
        /// 5a / 6b: iPad landscape — the floating card.
        case floating
        /// 3b / 6c: the Mac, and the dark rail of a landscape iPhone, a wide
        /// split and iPad portrait (settled 2026-09-13: wide enough for a
        /// rail, too tall for the sheet to reach the picture).
        case rail
    }

    /// Below this width the image is pinned above the controls instead of
    /// sitting beside them.
    ///
    /// 500 rather than a rounder 600 because of where the real widths fall: the
    /// widest iPhone portrait is 440pt (Pro Max), while a cover on iPad hands
    /// over the whole scene — 834pt portrait, 1024pt landscape. Only Slide Over
    /// (320pt) or a narrow Split View reaches the stacked branch on iPad, which
    /// is the right outcome.
    private let wideLayoutThreshold: CGFloat = 500

    /// How the image is sized and how far the handle may shrink it — the same
    /// component the video editor and the project hero lay out with.
    private var metrics: MediaPaneMetrics { MediaPaneMetrics(aspect: aspect) }

    /// Side-rail width. Fixed on macOS — resizing the window grows the photo,
    /// never the controls — at the redesign's 330 (board 3b). Capped-
    /// proportional on iOS/iPadOS.
    private func railWidth(in totalWidth: CGFloat) -> CGFloat {
        #if os(macOS)
        return 330
        #else
        return min(340, totalWidth * 0.42)
        #endif
    }

    /// Which Editor-page layout a container gets. Width AND shape, because
    /// the touch layouts are about where the hand is: a landscape iPad is
    /// the floating card (5a); anything else at least `wideLayoutThreshold`
    /// wide — a landscape iPhone, a wide split, iPad portrait — is the dark
    /// rail; the rest — every iPhone portrait, Slide Over — is the phone's
    /// bottom stack (2a). No idiom check anywhere: the size decides. The Mac
    /// is always the rail.
    private func editorLayout(for size: CGSize) -> EditorLayout {
        #if os(macOS)
        return .rail
        #else
        if size.width >= 900, size.width > size.height { return .floating }
        if size.width >= wideLayoutThreshold { return .rail }
        return .phone
        #endif
    }

    /// The page on screen. Frames only exists once frames do (see
    /// `availableRailTabs`), so a request for it on a single still falls
    /// back to the Editor rather than an empty rail.
    private var effectiveRailTab: RailTab {
        railTab == .frames && allFrames.count <= 1 ? .editor : railTab
    }

    /// Amber over the dark editor, per the "highlights over dark" rule the rest
    /// of the app's dark surfaces follow; the Mac window is a light surface and
    /// keeps the standard accent.
    private var accentColor: Color {
        #if os(iOS)
        return LL.amber
        #else
        return LL.accent
        #endif
    }

    /// How long the controls have to be still before a render starts. Long
    /// enough that dragging a slider doesn't queue a render per frame, short
    /// enough to feel live.
    private let renderDebounce: Duration = .milliseconds(100)

    private var capture: AppModel.CaptureProject? {
        model.capture(id: captureID)
    }

    /// What this shoot's white balance is anchored to.
    private var whiteBalanceSource: WhiteBalanceSource {
        capture.map(model.whiteBalanceSource(for:)) ?? .asShot
    }

    /// The white the frame under the playhead renders at while nothing owns
    /// one: the smoothed track's value, else the frame's own as-shot. Where
    /// the Temp and Tint knobs rest, and what "Match This Frame" writes.
    private var frameWhite: (kelvin: Double, tint: Double) {
        let track = capture.map(model.whiteBalanceTrack(for:)) ?? .asShot
        if let declared = track.declared(atPosition: renderedPosition) {
            return (Double(declared.kelvin), Double(declared.tint))
        }
        return (asShotKelvin, asShotTint)
    }

    /// The frame's own as-shot white at one moment of the source — a cached
    /// converter read of that frame.
    private func asShotWhite(at position: Double) -> (kelvin: Float, tint: Float) {
        let frame = hasTimeline ? frames[frameIndex(at: position)] : url
        let read = PhotoGrader.asShotNeutral(url: frame)
        return (Float(read.kelvin), Float(read.tint))
    }

    /// What one moment renders at with nothing owned: the smoothed track's
    /// white, else the frame's own.
    private func unownedWhite(at position: Double) -> (kelvin: Float, tint: Float) {
        let track = capture.map(model.whiteBalanceTrack(for:)) ?? .asShot
        return track.declared(atPosition: position) ?? asShotWhite(at: position)
    }

    /// Gives every moment that does not yet own its white the white it is
    /// currently rendering at.
    ///
    /// The invariant this keeps: **once any moment owns a white, every moment
    /// does.** Keyframes are whole panels interpolated field by field, and a
    /// white is stored in mired with 0 meaning "not owned" — so a moment left
    /// at 0 beside one that owns 200 would blend toward infinite Kelvin. Seeding
    /// the others with their own current white means the user's one edit
    /// changes exactly the moment they touched, and the transition to the next
    /// keyframe runs from that white to a real one. The camera's decision at
    /// each seeded moment is thereby *owned* rather than merely inherited, which
    /// is what lets the next edit at that moment move away from it smoothly.
    private func seedUnownedWhites(in timeline: inout GradeTimeline) {
        for keyframe in timeline.keyframes where !keyframe.adjustments.ownsWhite {
            let white = unownedWhite(at: keyframe.position)
            var values = keyframe.adjustments
            values.whiteMired = 1e6 / min(max(white.kelvin, 1667), 25000)
            values.whiteTint = white.tint
            timeline.update(keyframe.id, to: values)
        }
    }

    /// Re-expresses a grade authored when Temp/Tint were offsets from each
    /// frame's own as-shot as the whites those offsets *displayed* — once,
    /// on first open, so a keyframe that read 10328 K / +60 when it was set
    /// still reads 10328 K / +60, and the transition to the next keyframe
    /// is now between those two whites rather than between two nudges riding
    /// a camera that would not sit still.
    ///
    /// Only fires on a grade that carries offsets and owns no white; an
    /// untouched project and an already-migrated one both pass straight
    /// through. Reads the converter for each keyframe's frame, off the main
    /// actor.
    private func migrateRelativeWhiteIfNeeded() async {
        guard !adjustments.ownsWhite,
              !timeline.keyframes.contains(where: { $0.adjustments.ownsWhite }) else { return }
        let carriesOffsets = { (a: PhotoAdjustments) in a.temperature != 0 || a.tint != 0 }
        guard carriesOffsets(adjustments) || timeline.keyframes.contains(where: { carriesOffsets($0.adjustments) })
        else { return }

        let moments: [(id: UUID?, position: Double)] = timeline.keyframes.isEmpty
            ? [(nil, timeline.baselineAnchor ?? 0)]
            : timeline.keyframes.map { ($0.id, $0.position) }
        let frameURLs = moments.map { hasTimeline ? frames[frameIndex(at: $0.position)] : url }
        let asShots = await Task.detached(priority: .utility) {
            frameURLs.map { PhotoGrader.asShotNeutral(url: $0) }
        }.value

        func owned(_ a: PhotoAdjustments, asShot: (kelvin: CGFloat, tint: CGFloat)) -> PhotoAdjustments {
            var out = a
            let asShotMired = 1e6 / Double(min(max(asShot.kelvin, 1667), 25000))
            out.whiteMired = Float(min(max(asShotMired - Double(a.temperature), 40), 600))
            out.whiteTint = Float(min(max(Double(asShot.tint)
                + Double(a.tint * LinearFrameDecoder.cirawTintPerRecipeUnit), -150), 150))
            out.temperature = 0
            out.tint = 0
            return out
        }

        var updated = timeline
        if updated.keyframes.isEmpty {
            adjustments = owned(adjustments, asShot: asShots[0])
        } else {
            for (moment, asShot) in zip(moments, asShots) {
                guard let id = moment.id,
                      let keyframe = updated.keyframes.first(where: { $0.id == id }) else { continue }
                updated.update(id, to: owned(keyframe.adjustments, asShot: asShot))
            }
            adjustments = updated.adjustments(at: 0, baseline: adjustments)
        }
        timeline = updated
        refreshState()
        persist()
    }

    /// Switches smoothing on or off for the shoot, and — for the smoothed
    /// source — makes sure it has been measured first.
    ///
    /// The measure is a whole pass over every raw in the shoot, so it happens
    /// once, in the background, with the source written straight away: the
    /// picture stays as-shot until the series lands, then re-renders itself.
    /// Declaring nothing beats guessing while the numbers are still coming in.
    private func setWhiteBalanceSource(_ source: WhiteBalanceSource) {
        guard let capture else { return }
        model.setWhiteBalanceSource(source, for: capture)
        renderToken += 1
        guard case .smoothed = source else { return }
        Task {
            await model.measureWhiteBalance(for: capture)
            AppModel.forgetWhiteBalanceTrack(capture.id)
            renderToken += 1
        }
    }

    // MARK: - Hidden frames

    /// The names hidden right now: the nominated frames while the toggle is on,
    /// and nothing at all otherwise. One predicate, so the frame list, the
    /// clock and the tick marks cannot disagree about what is on screen.
    private var hiddenFrameNames: Set<String> {
        guard let capture, model.effectiveHideBadFrames(for: capture) else { return [] }
        return model.nominatedBadFrameNames(for: capture)
    }

    /// True when this project has anything nominated at all — which is the only
    /// time the toggle is worth drawing.
    ///
    /// Measured against the UNFILTERED shoot on purpose. A run where every
    /// frame has been nominated hides its whole strip, and a toggle that
    /// disappeared with it would be a one-way door: nothing left on screen
    /// could bring the frames back.
    private var hasNominatedFrames: Bool {
        guard let capture, allFrames.count > 1 else { return false }
        return !model.nominatedBadFrameNames(for: capture).isEmpty
    }

    /// The nominations the strip still has somewhere to draw: none while they
    /// are being hidden.
    private var tickMarkedFrameNames: Set<String> {
        guard let capture, !model.effectiveHideBadFrames(for: capture) else { return [] }
        return model.nominatedBadFrameNames(for: capture)
    }

    /// Rebuilds `frames`, `frameSeconds` and `frameAxis` — the frames this
    /// screen walks (the shoot, less whatever is hidden), the capture clock
    /// rebased onto the first frame the strip actually holds, and the axis
    /// built from both. Every index in this view — the scrubber's, the
    /// steps', the render's — is an index into `frames`, so a hidden frame
    /// simply isn't a place the playhead can stand.
    ///
    /// The clock measures the frames that are on it, so hiding the opening
    /// two frames of a 4:09 shoot leaves a strip that runs 0:00 → 4:07 rather
    /// than 0:02 → 4:09: the head is the first visible frame, and the tail is
    /// how long the visible frames last. A frame hidden out of the MIDDLE
    /// takes no time off either end — the shoot still spans what it spanned,
    /// and the strip simply steps over that moment — which is why this
    /// rebases the origin rather than closing the gaps up. (A no-op when
    /// nothing is hidden: `elapsedSeconds` already starts at 0.)
    ///
    /// Called from the load task and from the `frameWindowKey` watcher — the
    /// only things the window depends on beyond `allFrames`.
    private func refreshFrameWindow() {
        let hidden = hiddenFrameNames
        frames = hidden.isEmpty
            ? allFrames
            : allFrames.filter { !hidden.contains($0.lastPathComponent) }
        if allFrameSeconds.count == allFrames.count {
            let kept = hidden.isEmpty
                ? allFrameSeconds
                : zip(allFrames, allFrameSeconds)
                    .filter { !hidden.contains($0.0.lastPathComponent) }
                    .map(\.1)
            if let origin = kept.first, origin != 0 {
                frameSeconds = kept.map { $0 - origin }
            } else {
                frameSeconds = kept
            }
        } else {
            frameSeconds = []
        }
        frameAxis = FrameAxis(
            frameCount: frames.count,
            elapsedSeconds: frameSeconds.isEmpty ? nil : frameSeconds,
            uniformDuration: uniformVisibleDuration)
    }

    /// What the visible-frame window depends on beyond `allFrames`, as one
    /// cheap Equatable the body can watch: the nomination list plus the hide
    /// toggle. Nil until the project resolves.
    private var frameWindowKey: [String]? {
        guard let capture else { return nil }
        var key = capture.nominatedBadFrameNames ?? []
        key.append(model.effectiveHideBadFrames(for: capture) ? "#hide" : "#show")
        return key
    }

    // MARK: - Keyframe surface

    /// True when this capture has length to grade across — an interval shoot
    /// with frames to scrub. A Photo-mode capture is one still: there is no
    /// second moment to grade, so there is no strip.
    private var hasTimeline: Bool { frames.count > 1 }

    /// The grade at the playhead. With no keyframes this is the stored grade at
    /// every position, which is what keeps an ungraded-over-time project
    /// behaving exactly as it did before.
    private var displayedAdjustments: PhotoAdjustments {
        timeline.adjustments(at: position, baseline: adjustments)
    }

    /// The still under the playhead. The editor opens on the first frame and
    /// stays there until somebody scrubs.
    private var displayedURL: URL {
        guard hasTimeline else { return url }
        return frames[frameIndex(at: position)]
    }

    /// The shoot's length as the strip should read it when there is no
    /// per-frame clock to rebase — the recorded duration times the share of
    /// frames still on the strip.
    ///
    /// A proportion rather than a measurement, but the uniform axis is already
    /// built on "the frames were evenly spaced": on that assumption 248 of 250
    /// frames really do last 248/250 of the shoot. Without this the tail label
    /// would be the one number on the screen that ignores hiding entirely.
    private var uniformVisibleDuration: Double? {
        guard let duration = capture?.sourceDurationSeconds else { return nil }
        guard allFrames.count > 1, frames.count < allFrames.count else { return duration }
        return duration * Double(frames.count) / Double(allFrames.count)
    }

    private func frameIndex(at position: Double) -> Int {
        frameAxis.index(atPosition: position)
    }

    /// The axis: elapsed capture time when the shoot wrote a clock, and frame
    /// numbers when it didn't — a count is honest where invented seconds
    /// wouldn't be. Either way it measures the frames on the strip, not the
    /// frames on disk (see `frameSeconds` and `uniformVisibleDuration`).
    private var timelineLabel: (Double) -> String {
        if let span = frameSeconds.last, span > 0 {
            return { position in
                let index = frameIndex(at: position)
                let seconds = frameSeconds.indices.contains(index)
                    ? frameSeconds[index] : span * min(max(position, 0), 1)
                return GradeTimelineClock.label(seconds: seconds, span: span)
            }
        }
        if let duration = uniformVisibleDuration, duration > 0 {
            return GradeTimelineClock.labeller(duration: duration)
        }
        return GradeTimelineClock.frameLabeller(count: frames.count)
    }

    /// The strip itself, in the one place both layouts pull it from, with the
    /// single-frame steps beside it: a 0…1 scrubber puts frame 2 of a 250-frame
    /// shoot four thousandths along the track, which no thumb can hit.
    @ViewBuilder private func timelineStrip(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 8) {
            timelineBody(compact: compact)
            if hasTimeline {
                stepControl(by: -1, compact: compact)
                stepControl(by: 1, compact: compact)
            }
        }
    }

    @ViewBuilder private func timelineBody(compact: Bool) -> some View {
        VStack(spacing: 3) {
            GradeTimelineView(
                position: $position,
                isScrubbing: $isScrubbing,
                keyframes: timeline.keyframes,
                label: timelineLabel,
                isPlaying: isPlaying,
                compact: compact,
                accent: accentColor,
                onPlayToggle: togglePlayback,
                onScrub: { next in
                    stopPlayback()
                    dismissTextEntry()
                    renderedPosition = renderPosition(for: next)
                    renderToken += 1
                },
                onScrubEnd: {
                    renderedPosition = position
                    renderToken += 1
                },
                onDelete: deleteKeyframe)

            // Bad-frame tick marks: a thin row of orange dashes showing
            // which frames in the shoot the user has nominated as bad.
            // Visible only when there are nominations AND they are still on the
            // strip — with hiding on there is no position left to mark, because
            // those frames are not places the playhead can stand.
            let ticks = tickMarkedFrameNames
            if !ticks.isEmpty, frames.count > 1 {
                let badSet = ticks
                GeometryReader { geo in
                    // Leave the same left margin as GradeTimelineView's play button
                    let lead = GradeTimelineView.leadInset(compact: compact)
                    let trackW = max(1, geo.size.width - lead)
                    ZStack(alignment: .leading) {
                        ForEach(Array(frames.enumerated()), id: \.offset) { idx, frameURL in
                            if badSet.contains(frameURL.lastPathComponent) {
                                let pos = frames.count > 1
                                    ? CGFloat(idx) / CGFloat(frames.count - 1) * trackW + lead
                                    : lead
                                Rectangle()
                                    .fill(Color.orange)
                                    .frame(width: 2, height: 6)
                                    .offset(x: pos - 1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 6)
            }
        }
    }

    /// The lanes show while the Text tab is the work and there is a layer
    /// to draw — everywhere else the strip stands alone, as it always has.
    private var showsOverlayLanes: Bool {
        railTab == .text && !overlayDocument.overlays.isEmpty
    }

    /// One band per layer under the strip, aligned to the track: the same
    /// lead the play control takes, and the same trail the frame steps do.
    @ViewBuilder private func overlayLanes(compact: Bool) -> some View {
        let stepSize: CGFloat = compact ? 26 : 30
        let stepGap: CGFloat = compact ? 6 : 8
        OverlayLanesView(
            document: $overlayDocument,
            selectedID: $selectedOverlayID,
            position: position,
            leadInset: GradeTimelineView.leadInset(compact: compact),
            trailInset: 2 * (stepSize + stepGap),
            compact: compact,
            accent: accentColor,
            onEdited: overlayEdited,
            onInteract: {
                stopPlayback()
                dismissTextEntry()
            })
    }

    /// The floating confirmation over the media.
    @ViewBuilder private var overlayToastView: some View {
        if let overlayToast {
            Text(overlayToast)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(Capsule().fill(Color(red: 43 / 255, green: 43 / 255, blue: 46 / 255).opacity(0.92)))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
                .padding(.bottom, 24)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .allowsHitTesting(false)
        }
    }

    private func showOverlayToast(_ message: String) {
        overlayToastTask?.cancel()
        withAnimation(.easeOut(duration: 0.18)) { overlayToast = message }
        overlayToastTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1800))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { overlayToast = nil }
        }
    }

    /// A span of the shoot as the readouts say it: seconds under a minute,
    /// m:ss above, frames where the shoot never wrote a clock.
    private var overlayDurationLabel: (Double) -> String {
        let span: Double? = {
            if let last = frameSeconds.last, last > 0 { return last }
            if let duration = uniformVisibleDuration, duration > 0 { return duration }
            return nil
        }()
        if let span {
            return { fraction in
                let seconds = max(0, fraction) * span
                if seconds < 59.5 { return "\(Int(seconds.rounded()))s" }
                let whole = Int(seconds.rounded())
                return String(format: "%d:%02d", whole / 60, whole % 60)
            }
        }
        let count = frames.count
        return { fraction in
            let n = Int((Double(max(count - 1, 0)) * max(0, fraction)).rounded())
            return "\(n) fr"
        }
    }

    /// One frame as a fraction of the shoot — the offset stepper's step.
    private var overlayFrameStep: Double {
        frames.count > 1 ? 1 / Double(frames.count - 1) : 0
    }

    /// One frame back / one frame on, drawn to match the strip's own play
    /// button so the three read as one row of transport controls.
    /// The Mac's light rail is the one light surface the strip sits on.
    private var stepsOnLightSurface: Bool {
        #if os(macOS)
        return stepColorScheme == .light
        #else
        return false
        #endif
    }
    @Environment(\.colorScheme) private var stepColorScheme

    @ViewBuilder private func stepControl(by delta: Int, compact: Bool) -> some View {
        let size: CGFloat = compact ? 26 : 30
        let index = frameIndex(at: position)
        let enabled = delta < 0 ? index > 0 : index < frames.count - 1
        Button { stepFrame(by: delta) } label: {
            ZStack {
                // The strip's own disc fill, so the three read as one row.
                Circle().fill(GradeTimelineView.controlFill(onLightSurface: stepsOnLightSurface))
                    .shadow(color: .black.opacity(0.14), radius: 1.5, y: 1)
                Image(systemName: delta < 0 ? "chevron.left" : "chevron.right")
                    .font(.system(size: compact ? 11 : 12.5, weight: .semibold))
                    .foregroundStyle(enabled ? accentColor : Color.secondary.opacity(0.45))
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(delta < 0 ? "Previous frame" : "Next frame")
    }

    /// Moves the playhead by exactly one frame index. The axis is index-linear
    /// at every position (`FrameAxis.index(atPosition:)`), so the inverse is a
    /// plain division — and the render is kicked the same way a finished scrub
    /// kicks it, because from the preview's side this *is* a finished scrub.
    private func stepFrame(by delta: Int) {
        guard hasTimeline else { return }
        stopPlayback()
        let current = frameIndex(at: position)
        let next = min(max(current + delta, 0), frames.count - 1)
        guard next != current else { return }
        position = Double(next) / Double(max(1, frames.count - 1))
        renderedPosition = position
        renderToken += 1
    }

    /// While a scrub or a playback sweep is running the preview renders on a
    /// coarse ladder of positions instead of at every one — a full-resolution
    /// still per pixel of travel is a render the machine can't finish before
    /// the next one cancels it, so the picture would simply stop moving.
    private func renderPosition(for position: Double) -> Double {
        guard frames.count > 1 else { return position }
        let steps = Double(min(frames.count - 1, 60))
        return (position * steps).rounded() / steps
    }

    /// True when this editor owns the way out — the iOS back button it draws
    /// itself. When it doesn't (the Mac window's own close button, the
    /// fullscreen sheet's chrome) there is no exit to intercept, so the
    /// "Save as preset?" offer sits inline in the controls instead.
    private var ownsExit: Bool {
        #if os(iOS)
        return showsBackButton
        #else
        return false
        #endif
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                // The Editor page has the redesign's three layouts; the other
                // pages keep the rail-or-stacked split they were drawn with.
                if effectiveRailTab == .editor {
                    switch editorLayout(for: proxy.size) {
                    case .phone: phoneEditorBody(in: proxy.size)
                    case .floating: floatingEditorBody(in: proxy.size)
                    case .rail: railBody(in: proxy.size)
                    }
                } else if proxy.size.width >= wideLayoutThreshold {
                    railBody(in: proxy.size)
                } else {
                    stackedBody(in: proxy.size)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onChange(of: proxy.size, initial: true) { _, size in containerSize = size }
        }
        .background(editorBackground)
        #if os(iOS)
        .preferredColorScheme(.dark)
        // The run toolbar as the keyboard's accessory, laid over the whole
        // editor and lifted by the keyboard's own frame — this cover keeps
        // its layout under the keyboard, so a safe-area inset would not.
        // The cover's safe area already rises with the keyboard, so the
        // bar lands on top of it with no measuring of its own.
        .overlay(alignment: .bottom) { overlayRunAccessory }
        #endif
        .task {
            // Seed once from the project, then let this view own the values —
            // re-seeding on every model change would fight the sliders.
            guard !loaded, let capture else { return }
            preset = model.photoPreset(for: capture)
            adjustments = model.photoAdjustments(for: capture)
            presetState = model.presetState(for: capture)
            timeline = model.gradeTimeline(for: capture)
            overlayDocument = model.overlayDocument(for: capture)
            // Sequenced layers are seated after their parents on the way
            // in, so a sidecar written mid-edit still opens consistent.
            overlayDocument.resolveFollows()
            persistedDocument = overlayDocument
            shapeRegister = ShapeRegister.load(inProjectFolder: model.projectFolderURL(for: capture))
            persistedShapeRegister = shapeRegister
            selectedOverlayID = overlayDocument.overlays.first?.id
            importedFonts = model.importedOverlayFonts(for: capture)
            segModelIdentity = CoreMLSceneSegmenter.locate()?.identity
            // An interval shoot's frames — and, where the shoot wrote one, the
            // capture clock they sit on, which is what turns the strip's axis
            // from "frame 812" into "1:09:41 into the shoot".
            if capture.kind == .photos, !capture.isPhotoCapture {
                let sources = model.sourceFrameURLs(for: capture)
                allFrames = sources
                // A sidecar that doesn't describe this shoot frame for frame is
                // ignored rather than guessed at — the axis falls back to frame
                // numbers, which are at least true.
                allFrameSeconds = await Task.detached(priority: .utility) {
                    FrameTimestamps.load(besideFrames: sources)?
                        .elapsedSeconds(coveringExactly: sources.count) ?? []
                }.value
            }
            refreshFrameWindow()
            refreshLightroomSidecar()
            loaded = true
            let viewedURL = url
            // First, because it sizes the layout: a metadata-only read, well
            // ahead of the render that would otherwise have to land before the
            // image slot knew its shape.
            if let size = await Task.detached(priority: .utility, operation: {
                MediaGeometry.stillDisplaySize(url: viewedURL)
            }).value, size.height > 0 {
                aspect = size.width / size.height
                // The same probe answers "how many pixels are there", which is
                // what 1:1 and every detail patch are measured against.
                sourcePixels = size
            }
            await refreshAsShotAnchor(for: viewedURL)
            await migrateRelativeWhiteIfNeeded()
            #if DEBUG
            if ProcessInfo.processInfo.environment["LL_VIEWER"] == "expanded" {
                // The handle dragged all the way up — the state the "expanded"
                // design spec draws. Only the Text / Frames / Masks pages
                // still have a handle: on the Editor page the picture already
                // has the whole screen, so there this is a no-op.
                mediaScale = 0
            }
            applyKeyframeHook()
            applyPerfWiggleHook()
            applyTextHook()
            applyMaskHook()
            applyLightroomHook()
            applyMixerHook()
            applySectionsHook()
            #endif
            renderToken += 1
        }
        .task(id: RenderRequest(
            token: renderToken,
            frame: frameIndex(at: renderedPosition),
            frameCount: frames.count,
            live: isScrubbing || isPlaying)) {
            guard loaded else { return }
            // Debounce: a newer change cancels this task before it gets here, so
            // a slider drag collapses into one render and one manifest write
            // instead of one of each per tick. A live scrub or a playback sweep
            // wants the frame it asked for as fast as it can have it, so it
            // waits a beat rather than a tenth of a second.
            try? await Task.sleep(for: isScrubbing || isPlaying ? .milliseconds(16) : renderDebounce)
            guard !Task.isCancelled else { return }
            await render()
        }
        // The persist safety net, for edits that arrive without a
        // grab/release pair — the WB quick-picks, a double-tapped label
        // reset, a hook-driven write. Slider gestures persist on release
        // (`fieldEditingChanged`); this only has to catch the stragglers, so
        // it can wait well past any debounce.
        .task(id: renderToken) {
            guard loaded else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            persist()
            persistOverlays()
        }
        .task(id: patchRequest) { await renderPatch() }
        .task(id: loupeRequest) { await renderLoupe() }
        .task(id: activeSkyMaskKey) { await maskFetchTask() }
        .onChange(of: railTab) { _, tab in
            // Leaving (or re-entering) any tab retires the soft keyboard —
            // switching tabs was the only way out before the explicit exits.
            dismissTextEntry()
            // A cheap staleness fix on the way in: the model may have been
            // downloaded (or deleted) in Settings while this window sat open.
            if tab == .text {
                segModelIdentity = CoreMLSceneSegmenter.locate()?.identity
            }
            // Leaving the Text tab mid-drag: the proxy is gone, so the baked
            // overlay must come back.
            if tab != .text, overlayDrag != nil {
                overlayDrag = nil
                renderToken += 1
            }
        }
        .onChange(of: overlayDragActive) { _, active in
            // The gesture was cancelled rather than ended (SwiftUI reset the
            // @GestureState): drop the uncommitted move and restore the bake.
            if !active {
                overlaySnapX = false
                overlaySnapY = false
                boxResizeBase = nil
                if overlayDrag != nil {
                    overlayDrag = nil
                    renderToken += 1
                }
            }
        }
        // Escape releases whatever the picture is currently armed for. The
        // gesture is modal for as long as it is armed, so there has to be one
        // key that always gets out of it.
        #if os(macOS)
        .onExitCommand {
            maskTool = nil
            shapeTool = nil
            armedMaskField = nil
        }
        #endif
        .onChange(of: railTab) { _, _ in
            // A tool or an armed label belongs to the tab it was armed in.
            maskTool = nil
            shapeTool = nil
            armedMaskField = nil
            maskHUD = nil
            // And so does an open panel: leaving the Editor tab keeps what
            // it holds (✓), so a Text or Masks edit made meanwhile can never
            // be thrown away by a ✕ on the way back.
            if openGroup != nil { commitPanel() }
        }
        // A page asked for from outside — the Gallery panel's Text and Shapes
        // buttons. `onReceive` rather than a value at init because on the Mac
        // this window may already exist: reopening fronts it, and this is the
        // only way a fronted window learns which page it was opened for.
        .onReceive(model.$requestedEditorPage) { consumePageRequest($0) }
        .onChange(of: exitRequest) { _, request in
            guard let request else { return }
            if request.offersPresetSave { requestExit() } else { finishExit() }
        }
        .onChange(of: frameWindowKey) { _, _ in refreshFrameWindow() }
        .onChange(of: displayedURL) { _, _ in
            // A scrub moved to a different still: what is on screen at full
            // resolution is now a patch of the wrong frame.
            detailPatch = nil
            loupePatch = nil
            refreshLightroomSidecar()
        }
        .onChange(of: isPeeping) { _, peeping in
            guard !peeping else { return }
            // Back to fit with no slider under a finger: the ~100 MB
            // full-resolution frame has nothing left to serve.
            detailPatch = nil
            loupePatch = nil
            PhotoGrader.releaseDetailFrame()
        }
        .onDisappear {
            stopPlayback()
            PhotoGrader.releaseDetailFrame()
            // The macOS editor window has no exit of ours to intercept —
            // closing it must not lose text typed in the last two seconds.
            persistOverlays()
        }
        .overlay(alignment: .bottom) {
            if isOfferingPresetSave {
                presetSaveOffer
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .alert("Save as preset", isPresented: $isNamingPreset) {
            TextField("Preset name", text: $newPresetName)
            Button("Save") { saveCurrentAsPreset() }
            Button("Cancel", role: .cancel) { exitsAfterPresetSave = false }
        } message: {
            Text("Saves the \(preset.displayName) grade and these adjustments so you can apply them to another photo.")
        }
        .alert(item: $pendingApply) { request in
            Alert(
                title: Text(request.confirmationTitle),
                message: Text(request.confirmationMessage),
                primaryButton: .destructive(Text(request.confirmationButton)) { apply(request) },
                secondaryButton: .cancel())
        }
        .sheet(isPresented: $showsLightroomReport) {
            if let lightroomReport {
                LightroomReportSheet(
                    report: lightroomReport,
                    fileName: lightroomSidecar?.lastPathComponent ?? "",
                    accent: accentColor) { showsLightroomReport = false }
            }
        }
        .alert("Could not read that sidecar", isPresented: Binding(
            get: { lightroomError != nil }, set: { if !$0 { lightroomError = nil } })) {
            Button("OK", role: .cancel) { lightroomError = nil }
        } message: {
            Text(lightroomError ?? "")
        }
        .alert(item: $presetPendingDelete) { target in
            Alert(
                title: Text("Delete “\(target.name)”?"),
                message: Text("This removes the saved preset everywhere. Photos already using it keep their current grade."),
                primaryButton: .destructive(Text("Delete")) { presetStore.delete(target) },
                secondaryButton: .cancel()
            )
        }
    }

    private var editorBackground: some View {
        #if os(iOS)
        // Painted behind the safe areas so the screen reads edge to edge. The
        // layout itself stays inside them — the media's 80% is 80% of the space
        // people can actually see.
        Color.black.ignoresSafeArea()
        #else
        LL.screenBackground
        #endif
    }

    // MARK: - Stacked layout (iPhone portrait)

    /// The image pinned at the top with the controls scrolling beneath it. The
    /// image is given an exact frame, so the scroll view can only have the room
    /// left over — the ordering that keeps a greedy `ScrollView` from claiming
    /// the screen and squeezing the picture to a sliver.
    private func stackedBody(in container: CGSize) -> some View {
        let media = metrics.frame(in: container, scale: isTypingCopy ? 0 : mediaScale)
        let span = metrics.dragSpan(in: container)
        return VStack(spacing: 0) {
            imagePane()
                .frame(width: media.width, height: media.height)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .top) { chrome }
                .overlay(alignment: .bottom) { overlayToastView }
            // Between the media and the controls, and on the media's side of
            // the handle: the strip says which frame is on screen, so it moves
            // with the picture rather than with the panel.
            if hasTimeline {
                timelineStrip(compact: false)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 2)
                // Lanes stay with the strip — they belong to the media, on
                // the picture's side of the grabber.
                if showsOverlayLanes, !isTypingCopy {
                    overlayLanes(compact: false)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 2)
                }
            }
            if span > 0, !isTypingCopy {
                MediaResizeHandle(scale: $mediaScale, span: span)
            }
            railTabBar
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 2)
            ScrollViewReader { scroller in
                ScrollView(.vertical) {
                    controlStack(isWide: false)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: overlayRunTarget?.layer) { _, layer in
                    // The card being typed into comes up to the top of
                    // what is left above the keyboard.
                    guard let layer else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        scroller.scrollTo(layer, anchor: .top)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: - Chrome

    /// Floats over the media rather than sitting above it, so the picture keeps
    /// the top of the screen.
    ///
    /// The back button and nothing else. The project's name belongs on the
    /// screen you came from — here you are looking at the picture, not
    /// identifying it. And no scrim: a gradient over the top of the frame would
    /// darken the very pixels you are grading. The button carries its own disc
    /// for contrast, the same one the fullscreen player uses.
    @ViewBuilder private var chrome: some View {
        #if os(iOS)
        if showsBackButton {
            HStack {
                backButton
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        #else
        // The window's own title bar and close button do this job.
        EmptyView()
        #endif
    }

    /// The 36 pt disc the fullscreen player uses too.
    private var backButton: some View {
        Button { requestExit() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.4), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
    }

    // MARK: - Editor page layouts
    //
    // Three dressings of one page (boards 2a / 5a / 3b, with the timeline on
    // 6a / 6b / 6c). Everything below is Editor-page only: the Text, Frames
    // and Masks pages keep `stackedBody` / `railBody` with their own rail.

    /// The touch editors' top row over the picture: the back button leading,
    /// the tab pill trailing (2a / 5a). The floating layout puts the marquee
    /// badge — and, while zoomed, the zoom pill — beside the back button.
    /// Inside the fullscreen sheet the sheet's own bar sits at this height
    /// (close, page counter, share), so the row drops below it instead of
    /// stacking on it.
    private func touchChrome(showsBadge: Bool) -> some View {
        HStack(spacing: 8) {
            if showsBackButton { backButton }
            if showsBadge {
                marqueeBadge
                if !zoom.isFitted { zoomPill }
            }
            Spacer(minLength: 8)
            EditorTabPill(selection: $railTab, tabs: availableRailTabs, accent: accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .padding(.top, showsBackButton ? 0 : 48)
    }

    /// `INTERVAL · 2 h 14 min · 58 frames` — what the strip is measuring.
    private var marqueeBadge: some View {
        EditorMarqueeBadge(
            kind: capture?.kind == .video ? .video : (hasTimeline ? .interval : .photo),
            durationSeconds: shootDurationSeconds,
            frameCount: hasTimeline ? frames.count : nil)
    }

    /// The shoot's length as the strip reads it — the frames' own clock,
    /// else the recorded duration — or nil where neither exists.
    private var shootDurationSeconds: Double? {
        if let last = frameSeconds.last, last > 0 { return last }
        if let duration = uniformVisibleDuration, duration > 0 { return duration }
        return nil
    }

    /// 5a: "2.5× · tap to fit" beside the back button while the picture is
    /// released from its anchor.
    private var zoomPill: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { zoom = .fitted }
        } label: {
            Text("\(Double(zoom.scale).formatted(.number.precision(.fractionLength(1))))× · tap to fit")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accentColor)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(EditorPalette.rgb(0x1C1C1E).opacity(0.85), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Fit to screen")
    }

    /// The six main buttons' selection: a tap opens that group's panel
    /// through `openPanel(for:)`, which is where the ✓/✕ snapshot is taken.
    /// The bar never sets nil — closing is the panel's ✓/✕.
    private var groupSelection: Binding<EditorGroup?> {
        Binding(
            get: { openGroup },
            set: { group in
                if let group { openPanel(for: group) }
            })
    }

    /// Which buttons carry the dot — the panel's own header rule, asked per
    /// group at the moment under the playhead.
    private var nonNeutralGroups: Set<EditorGroup> {
        let values = displayedAdjustments
        return Set(EditorGroup.allCases.filter {
            !PhotoAdjustmentsPanel.isNeutral(
                $0, adjustments: values, keyframedFields: timeline.keyframedFields,
                whiteBalanceSource: whiteBalanceSource, presetState: presetState)
        })
    }

    /// The levelled picture's width ÷ height — the source's, since the level
    /// keeps the frame's dimensions. What a locked crop aspect is fitted
    /// into, and what the floating layout sizes the pane from.
    private var pictureAspect: Double {
        if let aspect, aspect > 0 { return aspect }
        let source = sourcePixelSize
        return source.height > 0 ? source.width / source.height : 4 / 3
    }

    // MARK: Phone (2a / 6a)

    /// The picture fills the safe area and everything else floats over it.
    /// Its foot carries the timeline card and then EITHER the six main
    /// buttons or the open group's sheet — one or the other, because on a
    /// phone the sheet needs the buttons' room. The foot's height is measured
    /// so the picture's own corner chrome (1:1, the toast) can sit above it
    /// rather than under it.
    private func phoneEditorBody(in container: CGSize) -> some View {
        // While the Crop panel is open the picture is fitted into the room
        // BELOW the chrome row and ABOVE the foot rather than centred behind
        // both: a tall picture's bottom handles would otherwise lie under
        // the sheet's material, where the sheet takes the touch, and its top
        // handles under the back button and the tab pill, which take it
        // first. The pane is the picture's fitted room, so a corner handle's
        // 36 pt reach (18 pt past the corner) needs the margins to be wider
        // than that: `cropMargin` at the sides and under the chrome, and the
        // same again above the foot. The zoom controls then need no lift of
        // their own — the pane already ends at the foot.
        let cropping = openGroup == .crop
        let cropRoom = cropping ? phoneFootHeight + Self.phoneCropMargin : 0
        let cropTop = cropping ? Self.touchChromeHeight + Self.phoneCropMargin : 0
        let cropSide = cropping ? Self.phoneCropMargin : 0
        return ZStack(alignment: .bottom) {
            imagePane(footInset: cropping ? 0 : phoneFootHeight, topInset: Self.touchChromeHeight)
                .padding(.top, cropTop)
                .padding(.horizontal, cropSide)
                .padding(.bottom, cropRoom)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) { touchChrome(showsBadge: false) }
            overlayToastView
                .padding(.bottom, phoneFootHeight)
            phoneFoot(in: container)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: EditorFootHeightKey.self, value: proxy.size.height)
                    }
                }
        }
        .onPreferenceChange(EditorFootHeightKey.self) { phoneFootHeight = $0 }
    }

    @ViewBuilder private func phoneFoot(in container: CGSize) -> some View {
        VStack(spacing: 0) {
            if hasTimeline { phoneTimelineCard }
            if let group = openGroup {
                // The sheet's own material already runs under the home
                // indicator; it is placed at the safe area's foot and not
                // padded again.
                groupPanel(group, layout: .phone, style: .dark)
            } else if expandedGradeID != nil {
                touchMasksCard(maxHeight: container.height * 0.5)
            } else {
                EditorGroupBar(
                    selection: groupSelection, nonNeutral: nonNeutralGroups,
                    style: .phone, accent: accentColor)
            }
        }
    }

    /// 6a: the marquee badge over the strip, in a card of black 60 % over
    /// material. No `.clipped()` anywhere on it — the strip's elapsed bubble
    /// and its delete affordance float above its top edge.
    private var phoneTimelineCard: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(alignment: .leading, spacing: 20) {
            marqueeBadge
            timelineStrip(compact: false)
        }
        .padding(.top, 10)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color.black.opacity(0.6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// A masked grade opened from the Masks tab ("Grade this in Editor")
    /// needs somewhere to be graded on the touch layouts, whose boards keep
    /// the masks on their own page and draw no card on the Editor page.
    /// Until that page gets one, the card takes the open panel's slot for
    /// exactly as long as a grade is expanded — collapsing it (the card's
    /// own tap on the tile) brings the main buttons back. Not a board of
    /// the redesign; a stopgap so the flow has a landing.
    private func touchMasksCard(maxHeight: CGFloat) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous)
        return ScrollView(.vertical, showsIndicators: false) {
            masksCard
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: maxHeight)
        .background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(EditorPalette.rgb(0x1C1C1E).opacity(0.86))
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    // MARK: iPad landscape (5a / 6b)

    /// The picture anchored top-left at the size its aspect gives it, the
    /// chrome in the corners, the strip and the buttons along the foot, and
    /// the open group as a card floating above the buttons — draggable by
    /// its header, or filling the height when it is Presets.
    private func floatingEditorBody(in container: CGSize) -> some View {
        let frame = floatingPictureFrame(in: container)
        // The pane's corner chrome (1:1, the spinner, the loupe) is lifted
        // clear of the foot row and the chrome row by however far the pane
        // reaches under them — a height-limited picture ends at the foot,
        // a width-limited one may not reach it.
        let footInset = max(0, frame.maxY - (container.height - Self.floatingFootHeight))
        return ZStack(alignment: .topLeading) {
            Color.black
            imagePane(footInset: footInset, topInset: Self.touchChromeHeight)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
            // 5a draws no chip on a photo; 6b's INTERVAL chip is the strip's.
            touchChrome(showsBadge: hasTimeline)
                .frame(maxWidth: .infinity)
            floatingFootRow
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            overlayToastView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 96)
            floatingPanel(in: container)
        }
        .onPreferenceChange(EditorPanelSizeKey.self) { floatingPanelSize = $0 }
    }

    /// The foot row's reach on the floating layout: the buttons pill and
    /// the strip capsule sit 16 pt off the bottom, and the panel seats 96 pt
    /// up — everything under that line is covered.
    private static let floatingFootHeight: CGFloat = 96
    /// The touch chrome row's reach: 12 pt of padding, the 36 pt back disc
    /// and tab pill, 12 pt more.
    private static let touchChromeHeight: CGFloat = 60
    /// The phone's margin around the fitted picture while Crop is open — a
    /// corner handle reaches 18 pt past its corner, so 24 pt keeps every
    /// handle whole and a finger's width clear of the chrome and the sheet.
    private static let phoneCropMargin: CGFloat = 24

    /// 5a: full height for a tall picture, full width for a wide one, at the
    /// top-left. While the Crop panel is open the picture is fitted inside a
    /// margin and centred instead, so the handles have room to be dragged
    /// into: 48 pt at the sides, and enough at the top and the foot to clear
    /// the chrome row and the foot row — a corner handle under the buttons
    /// pill cannot be grabbed.
    private func floatingPictureFrame(in container: CGSize) -> CGRect {
        if openGroup == .crop {
            let side: CGFloat = 48
            let top = Self.touchChromeHeight + 8
            let bottom = Self.floatingFootHeight + 48
            let room = CGSize(
                width: max(1, container.width - 2 * side),
                height: max(1, container.height - top - bottom))
            let size = Self.fit(aspect: pictureAspect, in: room)
            return CGRect(
                x: (container.width - size.width) / 2,
                y: top + (room.height - size.height) / 2,
                width: size.width, height: size.height)
        }
        return CGRect(origin: .zero, size: Self.fit(aspect: pictureAspect, in: container))
    }

    /// The largest `aspect` rectangle inside `room`.
    private static func fit(aspect: Double, in room: CGSize) -> CGSize {
        let ratio = max(aspect, 0.01)
        let byHeight = CGSize(width: room.height * ratio, height: room.height)
        if byHeight.width <= room.width { return byHeight }
        return CGSize(width: room.width, height: room.width / ratio)
    }

    /// 6b: the compact strip in a 66 pt capsule from the left edge to 18 pt
    /// short of the buttons pill, both 16 pt off the foot.
    private var floatingFootRow: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        return HStack(alignment: .bottom, spacing: 18) {
            if hasTimeline {
                timelineStrip(compact: true)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    .frame(height: 66)
                    .background {
                        ZStack {
                            shape.fill(.ultraThinMaterial)
                            shape.fill(EditorPalette.rgb(0x1C1C1E).opacity(0.85))
                        }
                    }
            } else {
                Spacer(minLength: 0)
            }
            EditorGroupBar(
                selection: groupSelection, nonNeutral: nonNeutralGroups,
                style: .padPill, accent: accentColor)
        }
        .padding(16)
    }

    /// The floating card: Presets fills the height between the tab pill and
    /// the buttons (top 62 / bottom 96 / right 16); every other group sits
    /// bottom-right above the buttons and follows wherever its header has
    /// been dragged, held on screen.
    @ViewBuilder private func floatingPanel(in container: CGSize) -> some View {
        if let group = openGroup {
            if group == .presets {
                groupPanel(group, layout: .floating, style: .dark)
                    .frame(maxHeight: .infinity)
                    .padding(.top, 62)
                    .padding(.bottom, 96)
                    .padding(.trailing, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            } else {
                groupPanel(group, layout: .floating, style: .dark)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: EditorPanelSizeKey.self, value: proxy.size)
                        }
                    }
                    .offset(clampedFloatingOffset(floatingPanelOffset ?? .zero, in: container))
                    .padding(.bottom, 96)
                    .padding(.trailing, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        } else if expandedGradeID != nil {
            touchMasksCard(maxHeight: container.height - 62 - 96)
                .frame(width: 400)
                .padding(.bottom, 96)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    /// The offset that keeps the card inside the container: it may go as far
    /// left and up as the screen allows, and no further right or down than
    /// its default seat's margins.
    private func clampedFloatingOffset(_ offset: CGSize, in container: CGSize) -> CGSize {
        let card = floatingPanelSize
        guard card.width > 0, card.height > 0, container.width > 0, container.height > 0 else {
            return offset
        }
        let seatX = container.width - 16 - card.width
        let seatY = container.height - 96 - card.height
        return CGSize(
            width: min(max(offset.width, -max(seatX, 0)), 16),
            height: min(max(offset.height, -max(seatY, 0)), 96))
    }

    /// The header drag, as the panel reports it: translation since the drag
    /// began, `ended` on the last call. Applied to the offset the drag
    /// started from — frozen at its first event — and clamped once it ends,
    /// so the stored seat is always one that is on screen.
    private func floatingHeaderDragged(_ translation: CGSize, ended: Bool) {
        let base = floatingDragBase ?? (floatingPanelOffset ?? .zero)
        floatingDragBase = base
        let moved = CGSize(width: base.width + translation.width, height: base.height + translation.height)
        floatingPanelOffset = ended ? clampedFloatingOffset(moved, in: containerSize) : moved
        if ended { floatingDragBase = nil }
    }

    // MARK: Rail (3b / 6c, and the wide non-Editor pages)

    /// The wide layout: the media column beside the rail. On the Editor page
    /// the rail is the redesign's (3b / 6c) and the strip sits in the board's
    /// 54 pt row under the picture; every other page keeps the rail and the
    /// strip it was drawn with.
    private func railBody(in container: CGSize) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                imagePane()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) { chrome }
                    .overlay(alignment: .bottom) { overlayToastView }
                    .overlay(alignment: .bottomLeading) { railMarqueeBadge }
                // The scrubber belongs to the media, so it takes the media
                // pane's width rather than the rail's — which keeps the rail
                // identical to the photo editor's and the whole
                // photo/interval difference to exactly one component.
                if hasTimeline {
                    if effectiveRailTab == .editor {
                        timelineStrip(compact: true)
                            .padding(.top, 6)
                            .padding(.horizontal, 16)
                            .frame(height: 54, alignment: .top)
                    } else {
                        timelineStrip(compact: true)
                            .padding(.horizontal, 18)
                            .padding(.top, 9)
                            .padding(.bottom, 4)
                        // The layer lanes belong to the media too: one band
                        // per text layer, under the strip's own axis, while
                        // the Text tab is the work.
                        if showsOverlayLanes {
                            overlayLanes(compact: true)
                                .padding(.horizontal, 18)
                                .padding(.bottom, 4)
                        }
                    }
                }
            }
            Divider()
            controlRail
                .frame(width: railWidth(in: container.width))
        }
    }

    /// 6c: the marquee badge bottom-left of the Mac's media pane — on an
    /// interval project only; 3b draws nothing over a photo. The touch rail
    /// (a landscape iPhone) has no board with one and shows none.
    @ViewBuilder private var railMarqueeBadge: some View {
        #if os(macOS)
        if effectiveRailTab == .editor, hasTimeline {
            marqueeBadge.padding(12)
        }
        #endif
    }

    /// The panel's dressing on the rail: the Mac's light card, the iPhone's
    /// dark one.
    private var railPanelStyle: XYPadStyle {
        #if os(macOS)
        return .light
        #else
        return .dark
        #endif
    }

    /// The Editor page's rail (3b / 6c), top to bottom: the tab pill, the
    /// six main buttons, the open group's card, the masks and "Reset
    /// adjustments". All of it scrolls. The inline save offer is NOT here:
    /// it lives in one place only, inside the Presets card under the tiles
    /// (`presetsContext.saveOffer`), so an Edited grade does not grow a
    /// prompt at the foot of every other group.
    @ViewBuilder private var railEditorStack: some View {
        railTabBar
        EditorGroupBar(
            selection: groupSelection, nonNeutral: nonNeutralGroups,
            style: .macCard, accent: accentColor)
        if let group = openGroup {
            groupPanel(group, layout: .rail, style: railPanelStyle)
        }
        masksCard
        #if os(macOS)
        Button("Reset adjustments") { resetEverything() }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(accentColor)
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!canResetEverything)
            .opacity(canResetEverything ? 1 : 0.4)
        #endif
        if let error = presetStore.lastError {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    /// Whether "Reset adjustments" has anything to do — anything that would
    /// change a pixel (`hasCrop`: a set-but-full crop keeps its aspect for
    /// the chip yet takes no pixel off) or a moment.
    private var canResetEverything: Bool {
        let values = displayedAdjustments
        return !values.withoutGeometry.isNeutral || values.hasRotation || values.hasCrop
            || !timeline.isEmpty
    }

    // MARK: - Image

    /// The picture and its corner chrome. `footInset` lifts the bottom
    /// chrome (1:1, the mask hint) above whatever a layout stacks over the
    /// picture's foot; `topInset` drops the top chrome (the spinner, the
    /// loupe) below whatever it overlays on the head — the touch layouts'
    /// tab pill sits exactly where the loupe would otherwise appear.
    private func imagePane(footInset: CGFloat = 0, topInset: CGFloat = 0) -> some View {
        GeometryReader { proxy in
            let geometry = zoomGeometry(in: proxy.size)
            ZStack {
                Color.black
                picture(in: geometry)
                // The spinner steps aside for the loupe rather than sitting
                // under it — they share the corner and the loupe carries a
                // progress view of its own.
                let showsLoupe = loupeField != nil && geometry.hasPixelsToReveal
                if isRendering, !showsLoupe {
                    ProgressView()
                        .controlSize(.small)
                        .padding(10)
                        .background(.black.opacity(0.4), in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(16)
                        .padding(.top, topInset)
                        .allowsHitTesting(false)
                }
                if showsLoupe {
                    DetailLoupe(
                        image: loupePatch?.image,
                        displayScale: displayScale,
                        side: loupeSide(in: proxy.size))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(12)
                        .padding(.top, topInset)
                        .transition(.opacity)
                }
                // The foot inset lifts the corner chrome above whatever the
                // phone layout stacks over the picture's foot.
                zoomControls(in: geometry)
                    .padding(.bottom, footInset)
                if let maskHUD {
                    MaskHUDPill(text: maskHUD)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 12)
                }
                if let hint = maskModeHint {
                    MaskModeHint(text: hint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 12 + footInset)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { toggleActualPixels(in: geometry) }
            // The crop frame's own pinch scales the crop, not the picture:
            // the whole time the Crop panel is open (it fitted the picture
            // on opening, and a pinch there is for the frame), not only once
            // the overlay has reported a change — the first events of a
            // pinch would otherwise reach both and the picture would leave
            // fit scale under the frame being scaled.
            .gesture(magnifyGesture(in: geometry),
                     including: cropEditing || openGroup == .crop ? .subviews : .all)
            // Ahead of pan, and only while something is armed: with no tool
            // and no armed label the picture behaves exactly as it always
            // has. A handle inside the overlay takes the drag before either,
            // being deeper in the hierarchy — which is what lets a mask be
            // nudged in the middle of grading it.
            .highPriorityGesture(maskPictureGesture(in: geometry),
                                 including: maskGestureWantsDrag ? .all : .subviews)
            // Only claimed once there is something to pan: at fit scale a drag
            // over the picture still belongs to whatever is presenting it —
            // the fullscreen sheet pages between photos with one. A crop
            // handle owning the picture stands it down the same way a mask's
            // handle does.
            .gesture(panGesture(in: geometry),
                     including: zoom.isFitted || maskGestureActive || maskGestureWantsDrag
                         || cropEditing
                         ? .subviews : .all)
            .onAppear { paneSize = proxy.size }
            .onChange(of: proxy.size) { _, size in
                paneSize = size
                zoom.offset = zoomGeometry(in: size)
                    .clamped(offset: zoom.offset, scale: zoom.scale)
            }
            .animation(.easeInOut(duration: 0.18), value: loupeField)
        }
    }

    /// The picture itself: the preview, the full-resolution patch registered
    /// over the part of it being looked at, and the pan.
    ///
    /// Sized rather than `scaleEffect`-ed. A scale effect transforms an already
    /// drawn layer, which would hand back an upscale of the preview at exactly
    /// the moment the point of the exercise is not to see one; giving the image
    /// its drawn size makes SwiftUI resample from the source instead.
    @ViewBuilder private func picture(in geometry: PhotoZoomGeometry) -> some View {
        let drawn = geometry.drawnSize(scale: zoom.scale)
        ZStack(alignment: .topLeading) {
            if let rendered {
                Image(decorative: rendered, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: drawn.width, height: drawn.height)
            } else {
                ProjectPreviewImage(url: displayedURL, background: AnyShapeStyle(Color.black))
                    .frame(width: drawn.width, height: drawn.height)
            }
            if let patch = detailPatch, !zoom.isFitted {
                Image(decorative: patch.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: drawn.width * patch.region.width,
                           height: drawn.height * patch.region.height)
                    .offset(x: drawn.width * patch.region.minX,
                            y: drawn.height * patch.region.minY)
            }
            // The overlays' drag surfaces, only while the Text tab is the
            // work: everywhere else the baked pixels are the overlay.
            // Reversed so the frontmost layer (row 1) takes the hit first,
            // matching what the composite paints on top.
            if railTab == .text {
                ForEach(overlayDocument.overlays.reversed()) { overlay in
                    if overlay.isVisible || overlay.onionSkin {
                        overlayProxy(overlay, drawn: drawn)
                    }
                }
                // The layers that will travel with the selection if it is
                // dragged, outlined dashed so the group is visible BEFORE
                // the gesture rather than as a surprise during it.
                if let selected = selectedOverlay {
                    let travelling = overlayDocument.movers(of: selected.id)
                    ForEach(overlayDocument.overlays.filter { travelling.contains($0.id) }) { follower in
                        overlayFollowerOutline(follower, drawn: drawn)
                    }
                    overlayChrome(selected, drawn: drawn)
                }
                overlaySnapGuides(drawn: drawn)
            }
            // The mask chrome: the handles of whichever shape is active —
            // the Masks tab's selection, or the mask of the grade the Editor
            // tab has expanded, so it can be nudged mid-grade without leaving
            // the sliders.
            if let index = activeShapeIndex {
                MaskShapeOverlay(
                    shape: $overlayDocument.shapeMasks[index].shape,
                    drawn: drawn,
                    accent: LL.amber,
                    onEditing: { editing in
                        maskGestureActive = editing
                        if editing {
                            scheduleUpdate()
                        } else {
                            overlayEdited(commit: true)
                        }
                    },
                    onHUD: { maskHUD = $0 })
            }
            // The crop, over the whole levelled picture (decision 3): the
            // frame with its handles while the Crop panel is open, a dim
            // reminder of it once closed. The picture itself is never cut
            // here, so every other overlay keeps its coordinate space.
            if effectiveRailTab == .editor, openGroup == .crop || displayedAdjustments.hasCrop {
                CropFrameOverlay(
                    crop: cropBinding,
                    frameAspect: drawn.height > 0 ? drawn.width / drawn.height : pictureAspect,
                    drawn: drawn,
                    isEditing: openGroup == .crop,
                    onEditing: { editing in cropEditing = editing },
                    onChanged: { persist() })
            }
            // What "Find in this picture" found, as lines, before it is added.
            if railTab == .masks, let find = lastFind, !find.found.isEmpty {
                FoundShapesOverlay(found: find.found, added: addedFindIDs, rejected: rejectedFindIDs, hovered: hoveredFoundID,
                                   hoverAnchor: foundHoverAnchor.flatMap { $0.id == hoveredFoundID ? $0.point : nil },
                                   drawn: drawn, actions: foundActions, isListed: registerHolds, accent: LL.amber)
            }
            // A register shape's handles — the Masks tab's Shapes selection.
            if railTab == .masks, let index = selectedRegisterShapeIndex {
                RegisterShapeOverlay(
                    shape: registerShapeBinding(index),
                    drawn: drawn,
                    native: registerFrame,
                    accent: LL.amber,
                    squareLock: shapeSquareLock,
                    onEditing: { editing in
                        maskGestureActive = editing
                        if !editing { shapesEdited(commit: true) }
                    },
                    onHUD: { maskHUD = $0 })
            }
        }
        .frame(width: drawn.width, height: drawn.height)
        .coordinateSpace(name: MaskShapeOverlay.space)
        // The found-shape hover, from the mouse over the whole picture — see
        // `FoundShapesOverlay` for why the outlines cannot track it themselves.
        .onContinuousHover(coordinateSpace: .local) { phase in updateFoundHover(phase, drawn: drawn) }
        .offset(zoom.offset)
    }

    // MARK: Mask gestures

    /// The shape whose handles are on the picture right now, as an index into
    /// the document so the overlay can bind straight into it.
    ///
    /// Masks tab: the deck's selection. Editor tab: the expanded grade's
    /// mask. Nothing anywhere else — the chrome is for the tab doing the work.
    private var activeShapeID: UUID? {
        switch railTab {
        case .masks: return inspectedRegion?.shapeMaskID
        case .editor:
            guard let id = expandedGradeID,
                  let grade = overlayDocument.maskGrade(id: id) else { return nil }
            return grade.mask.shapeMaskID
        case .text, .frames: return nil
        }
    }

    private var activeShapeIndex: Int? {
        guard let id = activeShapeID else { return nil }
        return overlayDocument.shapeMasks.firstIndex { $0.id == id }
    }

    /// What a drag on the picture will do right now, or nil when it will do
    /// what it always did. On screen only while something is armed, so the
    /// mode is never a thing to remember.
    private var maskModeHint: String? {
        if railTab == .masks, let tool = maskTool {
            return "Drag to draw a \(tool.displayName.lowercased()) mask · esc to cancel"
        }
        if railTab == .masks, let tool = shapeTool {
            let what = tool == .ellipse ? "an ellipse" : (shapeSquareLock ? "a square" : "a rectangle")
            return "Drag to draw \(what) shape · esc to cancel"
        }
        if railTab == .editor, let field = armedMaskField, supportsDragToAdjust {
            let name = expandedGradeID
                .flatMap { overlayDocument.maskGrade(id: $0) }
                .flatMap { grade in
                    overlayDocument.projectMask(grade.mask)?.name(inverted: grade.inverted)
                } ?? "this mask"
            return "Drag ↕ to set \(MaskGradeSection.label(for: field)) in \(name) · esc to release"
        }
        return nil
    }

    /// The picture's drawn size at the current zoom — the space every mask
    /// coordinate is resolved against.
    private var drawnPictureSize: CGSize {
        guard paneSize != .zero else { return .zero }
        return zoomGeometry(in: paneSize).drawnSize(scale: zoom.scale)
    }

    /// A drag on the picture that is NOT on a handle: it draws a new mask
    /// while a tool is armed, or sets an armed slider. Both are the same
    /// gesture object because they are the same finger, and only one of them
    /// can be live at a time.
    ///
    /// It reads the PANE's points and converts them itself. The gesture sits
    /// on the pane so a stroke can begin in the letterbox, and the picture's
    /// named space (`MaskShapeOverlay.space`) is registered on a descendant
    /// of it — a `.named` space a gesture cannot find among its ancestors is
    /// silently resolved as `.local` (measured 2026-09-13), which put every
    /// drawn mask and shape one letterbox inset away from where it was drawn:
    /// to the right for a portrait picture in a wide pane, down for a wide
    /// one in a tall pane, and by the pan once zoomed. The handles inside
    /// the picture keep using the named space; from in there it resolves.
    private func maskPictureGesture(in geometry: PhotoZoomGeometry) -> some Gesture {
        let scale = zoom.scale, offset = zoom.offset
        let drawn = geometry.drawnSize(scale: scale)
        return DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let start = geometry.picturePoint(value.startLocation, scale: scale, offset: offset)
                let point = geometry.picturePoint(value.location, scale: scale, offset: offset)
                if railTab == .masks, let kind = shapeTool {
                    continueDrawingShape(kind, from: start, to: point, in: drawn)
                } else if railTab == .masks, let kind = maskTool {
                    continueDrawing(kind, from: start, to: point, in: drawn)
                } else if let field = armedMaskField {
                    continueArmedDrag(field, translation: value.translation)
                }
            }
            .onEnded { _ in finishMaskGesture() }
    }

    /// Whether that gesture should claim the drag at all — with nothing armed
    /// the picture belongs to pan and zoom, as it always has.
    private var maskGestureWantsDrag: Bool {
        (railTab == .masks && (maskTool != nil || shapeTool != nil))
            || (railTab == .editor && armedMaskField != nil && supportsDragToAdjust)
    }

    /// Draws — and keeps redrawing — the shape under a create drag. The mask
    /// is added on the first change so the handles and the mask itself are
    /// live from the first pixel, and discarded on release if the drag never
    /// went anywhere.
    private func continueDrawing(
        _ kind: MaskShapeKind, from start: CGPoint, to end: CGPoint, in drawn: CGSize
    ) {
        guard drawn.width > 0, drawn.height > 0 else { return }
        let origin = CGPoint(x: start.x / drawn.width, y: start.y / drawn.height)
        let shape: MaskShape
        switch kind {
        case .linear:
            shape = .linear(
                from: MaskShape.clamped(origin),
                to: CGPoint(x: end.x / drawn.width, y: end.y / drawn.height))
        case .radial:
            // A true circle from the centre out, which is what the release
            // commits; the cardinal handles are how it becomes an ellipse.
            let radius = Double(hypot(end.x - start.x, end.y - start.y))
            shape = .radial(
                center: MaskShape.clamped(origin), radiusPoints: max(radius, 1), in: drawn)
        }
        if let id = drawingShapeID,
           let index = overlayDocument.shapeMasks.firstIndex(where: { $0.id == id }) {
            overlayDocument.shapeMasks[index].shape = shape
        } else {
            let mask = ShapeMask(
                name: overlayDocument.nextShapeName(for: kind), shape: shape)
            overlayDocument.shapeMasks.append(mask)
            drawingShapeID = mask.id
            inspectedRegion = .shape(mask.id)
            maskDetailSegment = .shape
        }
        maskHUD = "\(kind.displayName) · \(shape.sizeCaption(in: drawn))"
        scheduleUpdate()
    }

    /// The armed slider, moved by a vertical drag on the picture.
    /// `Δvalue = −Δy / 220 pt × range` — a full sweep of a tall editor window
    /// covers a little more than the whole travel, which is coarse enough to
    /// aim and fine enough to land on.
    private func continueArmedDrag(_ field: PhotoAdjustmentField, translation: CGSize) {
        guard let id = expandedGradeID,
              let index = overlayDocument.maskGrades.firstIndex(where: { $0.id == id })
        else { return }
        let range = MaskGrade.range(for: field)
        let span = range.upperBound - range.lowerBound
        let base = armedDragBase ?? overlayDocument.maskGrades[index].adjustments[keyPath: field.keyPath]
        if armedDragBase == nil { armedDragBase = base }
        let next = min(max(base - Float(translation.height) / 220 * span,
                           range.lowerBound), range.upperBound)
        overlayDocument.maskGrades[index].adjustments[keyPath: field.keyPath] = next
        let name = overlayDocument.projectMask(overlayDocument.maskGrades[index].mask)
            .map { $0.name(inverted: overlayDocument.maskGrades[index].inverted) } ?? "Mask"
        maskHUD = "\(name) · \(MaskGradeSection.label(for: field))  "
            + MaskGradeSection.readout(field, next)
        scheduleUpdate()
    }

    /// Release: commit the drawn shape (or throw away a stray click), drop
    /// the drag base, clear the HUD, and disarm the tool — one drag makes one
    /// mask, so there is never a mode left running.
    private func finishMaskGesture() {
        if let id = drawingShapeID {
            let drawn = drawnPictureSize
            if let index = overlayDocument.shapeMasks.firstIndex(where: { $0.id == id }),
               overlayDocument.shapeMasks[index].shape.isDegenerate(in: drawn) {
                overlayDocument.shapeMasks.remove(at: index)
                inspectedRegion = nil
            }
            drawingShapeID = nil
            maskTool = nil
        }
        if let id = drawingRegisterShapeID {
            let drawn = drawnPictureSize
            if let index = shapeRegister?.shapes.firstIndex(where: { $0.id == id }),
               let shape = shapeRegister?.shapes[index],
               shape.majorAxis * Double(drawn.width) < 8 {
                shapeRegister?.shapes.remove(at: index)
                selectedShapeID = nil
            }
            drawingRegisterShapeID = nil
            shapeTool = nil
            shapesEdited(commit: true)
        }
        armedDragBase = nil
        maskHUD = nil
        overlayEdited(commit: true)
    }

    // MARK: Register shapes

    /// The frame the register measures in: the register's own, else the
    /// capture's oriented pixel size, else the picture as drawn.
    private var registerFrame: CGSize {
        if let f = shapeRegister?.frameSize, f.width > 0, f.height > 0 { return f }
        if let capture, let w = capture.sourceWidth, let h = capture.sourceHeight, w > 0, h > 0 {
            return CGSize(width: w, height: h)
        }
        return drawnPictureSize
    }

    private var selectedRegisterShapeIndex: Int? {
        guard let id = selectedShapeID else { return nil }
        return shapeRegister?.shapes.firstIndex { $0.id == id }
    }

    private func registerShapeBinding(_ index: Int) -> Binding<DetectedShape> {
        Binding(
            get: {
                guard let shapes = shapeRegister?.shapes, index < shapes.count else {
                    return DetectedShape(kind: .ellipse, centre: CGPoint(x: 0.5, y: 0.5), majorAxis: 0.1, minorAxis: 0.1,
                                         rotation: 0, corners: nil, confidence: 0, nativeDiameterPx: 0)
                }
                return shapes[index]
            },
            set: { new in
                guard let count = shapeRegister?.shapes.count, index < count else { return }
                shapeRegister?.shapes[index] = new
            })
    }

    /// The Masks panel edits the register through this; a project without
    /// one gets a manual register the first time a shape is written.
    private var shapesBinding: Binding<[DetectedShape]> {
        Binding(
            get: { shapeRegister?.shapes ?? [] },
            set: { new in
                ensureShapeRegister()
                shapeRegister?.shapes = new
            })
    }

    private func ensureShapeRegister() {
        guard shapeRegister == nil, let capture else { return }
        let folder = model.projectFolderURL(for: capture)
        let media = model.mediaURL(for: capture)
        let relative: String = media.map { url in
            url.path.hasPrefix(folder.path) ? String(url.path.dropFirst(folder.path.count + 1)) : url.lastPathComponent
        } ?? ""
        let source: ShapeRegister.Representative.Source = capture.kind == .video ? .blendVideo : .sourceFrame
        let frame = registerFrame
        shapeRegister = ShapeRegister.manual(representative: .init(
            relativePath: relative, source: source, frameFraction: nil,
            width: Int(frame.width), height: Int(frame.height)))
    }

    /// Draws — and keeps redrawing — a register shape under a create drag,
    /// the way `continueDrawing` does for a mask.
    private func continueDrawingShape(_ kind: DetectedShape.Kind, from start: CGPoint, to end: CGPoint, in drawn: CGSize) {
        guard drawn.width > 0, drawn.height > 0 else { return }
        let native = registerFrame
        var shape: DetectedShape
        switch kind {
        case .ellipse:
            let radius = max(Double(hypot(end.x - start.x, end.y - start.y)), 1)
            shape = DetectedShape.ellipse(centre: start, semiAxisX: radius, semiAxisY: radius, rotation: 0, frame: drawn)
        case .quad:
            var dx = end.x - start.x, dy = end.y - start.y
            if shapeSquareLock {
                let side = max(abs(dx), abs(dy))
                dx = side * (dx < 0 ? -1 : 1); dy = side * (dy < 0 ? -1 : 1)
            }
            let x0 = min(start.x, start.x + dx), x1 = max(start.x, start.x + dx)
            let y0 = min(start.y, start.y + dy), y1 = max(start.y, start.y + dy)
            shape = DetectedShape.quad(corners: [CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0),
                                                 CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y1)], frame: drawn)
        }
        shape = shape.remeasured(frame: native)
        ensureShapeRegister()
        if let id = drawingRegisterShapeID, let index = shapeRegister?.shapes.firstIndex(where: { $0.id == id }) {
            shape.id = id
            shape.name = shapeRegister?.shapes[index].name
            shapeRegister?.shapes[index] = shape
        } else {
            shapeRegister?.shapes.append(shape)
            drawingRegisterShapeID = shape.id
            selectedShapeID = shape.id
            inspectedRegion = nil
        }
        maskHUD = "\(shape.displayName) · \(Int(shape.nativeDiameterPx)) px"
    }

    private func shapesEdited(commit: Bool) {
        if commit { persistShapeRegister() }
    }

    private func persistShapeRegister() {
        guard let capture, let register = shapeRegister, register != persistedShapeRegister else { return }
        do {
            // A hand-edited quad's own proportions follow its new corners —
            // the register's lens (when it has one) re-measures every quad.
            let register = register.rectifyingQuads()
            try register.save(inProjectFolder: model.projectFolderURL(for: capture))
            persistedShapeRegister = register
            model.shapeRegisterDidChange(for: capture)
        } catch {
            showOverlayToast("Could not save shapes: \(error.localizedDescription)")
        }
    }

    /// "Use as Radial mask": a copy of an ellipse as a drawn mask, same
    /// centre, radii and turn, the default feather — selected so its handles
    /// come up at once.
    private func useShapeAsMask(_ shape: DetectedShape) {
        guard shape.kind == .ellipse else { return }
        let frame = registerFrame
        let radiusX = shape.majorAxis / 2
        let radiusY = frame.height > 0 ? shape.minorAxis / 2 * Double(frame.width) / Double(frame.height) : shape.minorAxis / 2
        let maskShape = MaskShape(kind: .radial, center: shape.centre, radiusX: radiusX, radiusY: radiusY,
                                  rotationDegrees: max(-90, min(90, shape.rotation * 180 / .pi)))
        let mask = ShapeMask(name: shape.displayName, shape: maskShape)
        overlayDocument.shapeMasks.append(mask)
        selectedShapeID = nil
        inspectedRegion = .shape(mask.id)
        maskDetailSegment = .shape
        overlayEdited(commit: true)
        showOverlayToast("Radial mask made from \(shape.displayName)")
    }

    /// The draggable stand-in over the baked overlay. At rest it is an
    /// invisible hit target registered exactly over the baked text; during a
    /// drag the bake is suppressed from the render and this proxy — drawn at
    /// final layout, full strength, because the resting state is what is
    /// being placed — is what moves.
    @ViewBuilder private func overlayProxy(_ stored: SceneOverlay, drawn: CGSize) -> some View {
        let overlay = displayOverlay(stored)
        let dragging = overlayDrag?.id == overlay.id
        let carried = overlayDrag?.followers[overlay.id] != nil
        let center = overlayDragCenter(for: overlay)
        let style = overlay.textStyle
        let fontSize = TextOverlayRasterizer.resolvedSize(
            for: overlay, aspect: drawnAspect(drawn)) * max(drawn.width, drawn.height)
        // An unrevealed (or already exited) SELECTED layer ghosts at 16%, so
        // the badge and outline have a target; every other resting proxy
        // is an invisible hit area over the bake.
        let ghosted = selectedOverlayID == overlay.id && !overlay.isOnScreen(at: renderedPosition)
        proxyText(overlay, style: style, fontSize: fontSize)
            .italic(style?.isItalic == true)
            .multilineTextAlignment(proxyAlignment(style))
            .shadow(color: .black.opacity(0.55), radius: fontSize * 0.06)
            .frame(width: overlay.mode == .box ? drawn.width * overlay.boxWidth : nil)
            // A follower is being carried by this drag, so its bake is
            // suppressed too and the proxy is all there is to see.
            .opacity(dragging || carried ? 1 : (ghosted ? 0.16 : 0.02))
            // The layer's own turn, about its anchor — the rasterizer's
            // rotation, so the proxy sits where the bake will.
            .rotationEffect(.degrees(overlay.rotationDegrees))
            .position(x: drawn.width * center.x, y: drawn.height * center.y)
            .highPriorityGesture(overlayDragGesture(overlay, drawn: drawn))
            // Right-click / ⌃-click on the Mac, touch and hold on iOS —
            // both are what `.contextMenu` already means on its platform.
            .contextMenu { associationMenu(for: stored) }
    }

    /// Where a layer is drawn right now: its committed centre, unless this
    /// drag is carrying it — as the layer being dragged, or as one of the
    /// followers travelling with it.
    private func overlayDragCenter(for overlay: SceneOverlay) -> CGPoint {
        let resting = CGPoint(x: overlay.centerX, y: overlay.centerY)
        guard let drag = overlayDrag else { return resting }
        if drag.id == overlay.id { return drag.current }
        guard let base = drag.followers[overlay.id] else { return resting }
        // Followers take the translation the dragged layer ended up with,
        // snap included, and clamp to the frame the same way it does.
        let delta = CGPoint(x: drag.current.x - drag.base.x, y: drag.current.y - drag.base.y)
        return CGPoint(x: min(max(base.x + delta.x, 0), 1),
                       y: min(max(base.y + delta.y, 0), 1))
    }

    /// The proxy's copy, run by run — each word in its own weight, colour
    /// and underline, the way the bake draws it.
    private func proxyText(_ overlay: SceneOverlay, style: TextOverlayContent?, fontSize: CGFloat) -> Text {
        guard let style else { return Text(overlay.text) }
        var out = Text("")
        for run in style.runs {
            var piece = Text(run.text)
                .font(proxyFont(style, size: fontSize, bold: style.resolvedBold(run)))
                .foregroundColor(Color(cgColor: TextOverlayRasterizer.color(
                    fromHex: style.resolvedColorHex(run))))
            if style.resolvedUnderline(run) { piece = piece.underline() }
            out = out + piece
        }
        return out
    }

    /// The proxy's face. A named family the device lacks falls back to the
    /// system face, the same rule the rasterizer applies.
    private func proxyFont(_ style: TextOverlayContent?, size: CGFloat, bold: Bool) -> Font {
        guard let family = style?.fontFamily, !family.isEmpty else {
            return .system(size: size, weight: bold ? .bold : .regular)
        }
        let base = Font.custom(family, size: size)
        return bold ? base.weight(.bold) : base
    }

    private func proxyAlignment(_ style: TextOverlayContent?) -> TextAlignment {
        switch style?.alignment ?? .center {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private func drawnAspect(_ drawn: CGSize) -> Double {
        drawn.height > 0 ? Double(drawn.width / drawn.height) : 1
    }

    /// The selected layer, which is what the preview draws chrome around.
    private var selectedOverlay: SceneOverlay? {
        guard let selectedOverlayID else { return overlayDocument.overlays.first }
        return overlayDocument.overlays.first { $0.id == selectedOverlayID }
            ?? overlayDocument.overlays.first
    }

    // MARK: Selection chrome

    /// The selected layer's bounding box, its badge, and — in box mode — the
    /// eight handles that resize it. Free text gets a solid accent outline
    /// around the space its line occupies; boxed text gets the dashed amber
    /// box it is actually constrained by, which is the thing being dragged.
    /// A layer that travels with the selection: a light dashed ring, no
    /// badge and no handles. It says "this comes too" and nothing else.
    @ViewBuilder private func overlayFollowerOutline(_ stored: SceneOverlay, drawn: CGSize) -> some View {
        let overlay = displayOverlay(stored)
        let size = chromeSize(overlay, drawn: drawn)
        let center = overlayDragCenter(for: overlay)
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .strokeBorder(accentColor.opacity(0.6),
                          style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
            .rotationEffect(.degrees(overlay.rotationDegrees))
            .position(x: drawn.width * center.x, y: drawn.height * center.y)
    }

    @ViewBuilder private func overlayChrome(_ stored: SceneOverlay, drawn: CGSize) -> some View {
        let overlay = displayOverlay(stored)
        let boxed = overlay.mode == .box
        let center = overlayDragCenter(for: overlay)
        let size = chromeSize(overlay, drawn: drawn)
        // How many layers this one takes with it when it moves.
        let followerCount = overlayDocument.movers(of: overlay.id).count
        let tint = boxed ? LL.amber : accentColor
        ZStack {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(
                    tint,
                    style: StrokeStyle(lineWidth: 1.5, dash: boxed ? [5, 4] : []))
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .topLeading) {
                    // The layer's own name, and what comes with it. `BOX`
                    // survives because the dashed outline needs saying;
                    // `FREE` did not — the name is worth more than the mode.
                    Text("\(boxed ? "BOX · " : "")\(overlay.displayName.prefix(22))"
                         + (followerCount > 0
                            ? " · +\(followerCount) follow\(followerCount > 1 ? "" : "s")" : ""))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(tint))
                        .fixedSize()
                        .offset(y: -22)
                }
                .overlay(alignment: .bottomTrailing) {
                    if boxed, overlay.autoSize {
                        autoSizeChip(overlay, drawn: drawn).offset(y: 24)
                    }
                }
            if boxed {
                overlayHandles(overlay, size: size, drawn: drawn, tint: tint)
            }
        }
        .allowsHitTesting(boxed)
        // The outline and its handles turn with the layer.
        .rotationEffect(.degrees(overlay.rotationDegrees))
        .position(x: drawn.width * center.x, y: drawn.height * center.y)
    }

    /// The chrome's footprint. A box has one; free text's is measured from
    /// the resolved type, which is an estimate — the exact ink extent lives
    /// in the rasterizer and is not worth a render round trip for an outline.
    private func chromeSize(_ overlay: SceneOverlay, drawn: CGSize) -> CGSize {
        if overlay.mode == .box {
            return CGSize(
                width: drawn.width * overlay.boxWidth,
                height: drawn.height * overlay.boxHeight)
        }
        let resolved = TextOverlayRasterizer.resolvedSize(
            for: overlay, aspect: drawnAspect(drawn))
        let pixels = resolved * Double(max(drawn.width, drawn.height))
        let lines = max(overlay.text.components(separatedBy: "\n").count, 1)
        let widest = overlay.text.components(separatedBy: "\n")
            .map(\.count).max() ?? 1
        return CGSize(
            width: min(CGFloat(Double(widest) * pixels * 0.56), drawn.width),
            height: CGFloat(Double(lines) * pixels * 1.35))
    }

    /// The AUTO readout: what auto-size resolved to, and where that sits in
    /// the Min…Max bracket it searched.
    @ViewBuilder private func autoSizeChip(_ overlay: SceneOverlay, drawn: CGSize) -> some View {
        let resolved = TextOverlayRasterizer.resolvedSize(
            for: overlay, aspect: drawnAspect(drawn))
        let span = max(overlay.maxSize - overlay.minSize, 0.0001)
        let fill = min(max((resolved - overlay.minSize) / span, 0), 1)
        HStack(spacing: 6) {
            Text("AUTO")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LL.amber)
            Text("\(Int((resolved * sourceLongEdgePixels).rounded())) px")
                .font(.system(size: 10, weight: .semibold))
                .monospaced()
                .foregroundStyle(.white)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.28)).frame(width: 44, height: 3)
                Circle().fill(LL.amber).frame(width: 8, height: 8)
                    .offset(x: 44 * CGFloat(fill) - 4)
            }
            .frame(width: 44)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .fixedSize()
    }

    /// Four corner squares and four edge circles. Dragging one moves that
    /// edge and leaves the opposite one where it is — the box grows from the
    /// side under the pointer, not from its centre.
    @ViewBuilder private func overlayHandles(
        _ overlay: SceneOverlay, size: CGSize, drawn: CGSize, tint: Color
    ) -> some View {
        ForEach(Self.handleAnchors, id: \.id) { anchor in
            let corner = anchor.x != 0 && anchor.y != 0
            Group {
                if corner {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.white)
                        .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .stroke(tint, lineWidth: 1.5))
                        .frame(width: 8, height: 8)
                } else {
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(tint, lineWidth: 1.5))
                        .frame(width: 7, height: 7)
                }
            }
            .contentShape(Rectangle().inset(by: -8))
            .offset(
                x: size.width / 2 * CGFloat(anchor.x),
                y: size.height / 2 * CGFloat(anchor.y))
            .highPriorityGesture(boxResizeGesture(overlay, anchor: anchor, drawn: drawn))
        }
    }

    private struct HandleAnchor: Identifiable {
        let id: String
        let x: Int
        let y: Int
    }

    private static let handleAnchors: [HandleAnchor] = [
        .init(id: "tl", x: -1, y: -1), .init(id: "tr", x: 1, y: -1),
        .init(id: "bl", x: -1, y: 1), .init(id: "br", x: 1, y: 1),
        .init(id: "t", x: 0, y: -1), .init(id: "b", x: 0, y: 1),
        .init(id: "l", x: -1, y: 0), .init(id: "r", x: 1, y: 0),
    ]

    /// Resizing writes straight to the document — there is no proxy for a
    /// box, because the box is chrome and the bake below it does not draw it.
    private func boxResizeGesture(
        _ overlay: SceneOverlay, anchor: HandleAnchor, drawn: CGSize
    ) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .updating($overlayDragActive) { _, state, _ in state = true }
            .onChanged { value in
                guard drawn.width > 0, drawn.height > 0,
                      let index = overlayDocument.overlays
                        .firstIndex(where: { $0.id == overlay.id })
                else { return }
                // Everything here is in THIS moment's frame (the displayed
                // layer); the result goes back to the stored frame at the end.
                let shown = displayOverlay(overlay)
                if boxResizeBase == nil {
                    dismissTextEntry()
                    selectedOverlayID = overlay.id
                    boxResizeBase = BoxResizeBase(
                        width: shown.boxWidth, height: shown.boxHeight,
                        centerX: shown.centerX, centerY: shown.centerY)
                }
                guard let base = boxResizeBase else { return }
                // The handles live on a box that may be turned: the pointer's
                // travel is read along the box's own axes, so dragging its
                // right edge grows it along that edge whatever the angle.
                let theta = -shown.rotationDegrees * .pi / 180
                let tx = Double(value.translation.width), ty = Double(value.translation.height)
                let along = CGSize(
                    width: tx * cos(theta) - ty * sin(theta),
                    height: tx * sin(theta) + ty * cos(theta))
                let dx = Double(along.width / drawn.width)
                let dy = Double(along.height / drawn.height)
                var width = base.width, height = base.height
                var centerX = base.centerX, centerY = base.centerY
                if anchor.x != 0 {
                    width = min(max(base.width + Double(anchor.x) * dx, 0.04), 1)
                    // Half the travel, so the opposite edge stays put.
                    centerX = base.centerX + Double(anchor.x) * (width - base.width) / 2
                }
                if anchor.y != 0 {
                    height = min(max(base.height + Double(anchor.y) * dy, 0.03), 1)
                    centerY = base.centerY + Double(anchor.y) * (height - base.height) / 2
                }
                let grow = displayGrow
                let stored = storedPoint(CGPoint(x: min(max(centerX, 0), 1), y: min(max(centerY, 0), 1)))
                overlayDocument.overlays[index].boxWidth = width / grow
                overlayDocument.overlays[index].boxHeight = height / grow
                overlayDocument.overlays[index].centerX = stored.x
                overlayDocument.overlays[index].centerY = stored.y
                scheduleUpdate()
            }
            .onEnded { _ in
                boxResizeBase = nil
                persistOverlays()
                scheduleUpdate()
            }
    }

    /// The centre guides, drawn while a drag is snapped to them.
    @ViewBuilder private func overlaySnapGuides(drawn: CGSize) -> some View {
        if overlaySnapX {
            Rectangle().fill(LL.amber.opacity(0.9))
                .frame(width: 1, height: drawn.height)
                .position(x: drawn.width / 2, y: drawn.height / 2)
                .allowsHitTesting(false)
        }
        if overlaySnapY {
            Rectangle().fill(LL.amber.opacity(0.9))
                .frame(width: drawn.width, height: 1)
                .position(x: drawn.width / 2, y: drawn.height / 2)
                .allowsHitTesting(false)
        }
    }

    /// The Ken Burns drag idiom: a frozen committed base, absolute
    /// translation divided into unit space, clamped, committed on release.
    private func overlayDragGesture(_ stored: SceneOverlay, drawn: CGSize) -> some Gesture {
        // The drag happens on THIS moment's frame; the committed centre goes
        // back to the stored (opening) frame on release.
        let overlay = displayOverlay(stored)
        return DragGesture(minimumDistance: 1)
            .updating($overlayDragActive) { _, state, _ in state = true }
            .onChanged { value in
                guard drawn.width > 0, drawn.height > 0 else { return }
                if overlayDrag?.id != overlay.id {
                    // Placing the text IS being done with typing it.
                    dismissTextEntry()
                    // Dragging a layer is a way of choosing it.
                    selectedOverlayID = overlay.id
                    // Layers that start after this one are part of the same
                    // thought, so they move with it — unless they hold an
                    // independent position (a pinned byline, a URL in a
                    // corner), which keeps its spot and follows in time only.
                    let travelling = overlayDocument.movers(of: overlay.id)
                    var followers: [UUID: CGPoint] = [:]
                    for other in overlayDocument.overlays where travelling.contains(other.id) {
                        let shown = displayOverlay(other)
                        followers[other.id] = CGPoint(x: shown.centerX, y: shown.centerY)
                    }
                    overlayDrag = OverlayDragState(
                        id: overlay.id,
                        base: CGPoint(x: overlay.centerX, y: overlay.centerY),
                        current: CGPoint(x: overlay.centerX, y: overlay.centerY),
                        followers: followers)
                    // One re-render without this overlay; the proxy carries
                    // it for the rest of the drag.
                    renderToken += 1
                }
                guard var drag = overlayDrag else { return }
                var x = min(max(drag.base.x + value.translation.width / drawn.width, 0), 1)
                var y = min(max(drag.base.y + value.translation.height / drawn.height, 0), 1)
                // Centre snap, with the guide as its only feedback.
                let snapX = abs(x - 0.5) < 0.018
                let snapY = abs(y - 0.5) < 0.018
                if snapX { x = 0.5 }
                if snapY { y = 0.5 }
                if overlaySnapX != snapX { overlaySnapX = snapX }
                if overlaySnapY != snapY { overlaySnapY = snapY }
                drag.current = CGPoint(x: x, y: y)
                overlayDrag = drag
            }
            .onEnded { _ in
                guard let drag = overlayDrag else { return }
                if let index = overlayDocument.overlays
                    .firstIndex(where: { $0.id == drag.id }) {
                    let stored = storedPoint(drag.current)
                    overlayDocument.overlays[index].centerX = stored.x
                    overlayDocument.overlays[index].centerY = stored.y
                }
                // The layers that came along keep where they were carried to.
                for (id, base) in drag.followers {
                    guard let index = overlayDocument.overlays
                        .firstIndex(where: { $0.id == id }) else { continue }
                    let delta = CGPoint(x: drag.current.x - drag.base.x,
                                        y: drag.current.y - drag.base.y)
                    let moved = CGPoint(x: min(max(base.x + delta.x, 0), 1),
                                        y: min(max(base.y + delta.y, 0), 1))
                    let stored = storedPoint(moved)
                    overlayDocument.overlays[index].centerX = stored.x
                    overlayDocument.overlays[index].centerY = stored.y
                }
                if !drag.followers.isEmpty {
                    let count = drag.followers.count
                    showOverlayToast("Moved with \(count) follower\(count == 1 ? "" : "s")")
                }
                overlayDrag = nil
                overlaySnapX = false
                overlaySnapY = false
                renderToken += 1
                persistOverlays()
            }
    }

    /// The scale readout and the 1:1 toggle, bottom-trailing over the picture —
    /// the one corner the back button, the render spinner and the loupe all
    /// leave alone.
    @ViewBuilder private func zoomControls(in geometry: PhotoZoomGeometry) -> some View {
        HStack(spacing: 8) {
            if !zoom.isFitted {
                PixelScaleBadge(scale: zoom.scale, oneToOne: geometry.oneToOne)
            }
            // Nothing to jump to on a source the screen already shows whole —
            // a small JPEG on a 3× phone is past actual pixels at fit scale,
            // and a button that can only do nothing is worse than no button.
            // Pinch still zooms; the badge then says how far past 100% it is.
            if geometry.hasPixelsToReveal || !zoom.isFitted {
                Button {
                    toggleActualPixels(in: geometry)
                } label: {
                    Image(systemName: zoom.isFitted
                          ? "arrow.up.left.and.arrow.down.right"
                          : "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain)
                .help(zoom.isFitted ? "View actual pixels (1:1)" : "Fit to screen")
                .accessibilityLabel(zoom.isFitted ? "View actual pixels" : "Fit to screen")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(12)
    }

    // MARK: - Zoom

    private var sourcePixelSize: CGSize {
        if let sourcePixels, sourcePixels.width > 0, sourcePixels.height > 0 {
            return sourcePixels
        }
        if let rendered {
            return CGSize(width: rendered.width, height: rendered.height)
        }
        if let aspect, aspect > 0 { return CGSize(width: aspect * 1000, height: 1000) }
        return CGSize(width: 4, height: 3)
    }

    private func zoomGeometry(in container: CGSize) -> PhotoZoomGeometry {
        PhotoZoomGeometry(
            container: container, source: sourcePixelSize, displayScale: displayScale)
    }

    /// 280pt where there is room for it, and never more than the picture it is
    /// floating over.
    private func loupeSide(in container: CGSize) -> CGFloat {
        min(280, max(120, min(container.width, container.height) - 32))
    }

    private func magnifyGesture(in geometry: PhotoZoomGeometry) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = zoom.pinchBase ?? zoom.scale
                zoom.pinchBase = base
                zoom.scale = geometry.clamped(scale: base * value.magnification)
                zoom.offset = geometry.clamped(offset: zoom.offset, scale: zoom.scale)
            }
            .onEnded { _ in zoom.pinchBase = nil }
    }

    private func panGesture(in geometry: PhotoZoomGeometry) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard !zoom.isFitted else { return }
                let base = zoom.panBase ?? zoom.offset
                zoom.panBase = base
                zoom.offset = geometry.clamped(
                    offset: CGSize(
                        width: base.width + value.translation.width,
                        height: base.height + value.translation.height),
                    scale: zoom.scale)
            }
            .onEnded { _ in zoom.panBase = nil }
    }

    /// Double-tap, and the corner button: 1:1 from fit, fit from anywhere else.
    private func toggleActualPixels(in geometry: PhotoZoomGeometry) {
        withAnimation(.easeInOut(duration: 0.22)) {
            guard zoom.isFitted else {
                zoom = .fitted
                return
            }
            let target = geometry.actualPixelScale
            zoom.scale = target
            zoom.offset = geometry.clamped(offset: .zero, scale: target)
        }
    }

    // MARK: - Controls

    /// The side rail is tall and narrow, so it scrolls on its own, with the
    /// tab switcher pinned above the scroll. (The stacked layout's scroll
    /// view lives in `stackedBody`, outside the media.)
    @ViewBuilder private var controlRail: some View {
        if effectiveRailTab == .editor {
            // 3b / 6c: the whole rail scrolls, tab pill included, padded 14
            // top / 16 sides / 20 bottom with 12 between cards.
            ScrollView {
                VStack(spacing: 12) {
                    railEditorStack
                }
                .padding(.top, 14)
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        } else {
            VStack(spacing: 0) {
                railTabBar
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                ScrollView {
                    controlStack(isWide: true)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 14)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
    }

    /// The rail's pages. Frames exists only where frames do — a single still
    /// has nothing to nominate, and a tab that can never unlock would just
    /// advertise a dead end.
    ///
    /// Measured against the UNFILTERED shoot, same as `hasNominatedFrames`
    /// and for the same reason: hiding every nominated frame must not take
    /// the tab (and with it the hide toggle — the only route back) off the
    /// screen.
    private var availableRailTabs: [RailTab] {
        allFrames.count > 1
            ? [.editor, .text, .frames, .masks]
            : [.editor, .text, .masks]
    }

    private var railTabBar: some View {
        RailTabBar(
            selection: $railTab, tabs: availableRailTabs,
            accent: accentColor, onAccent: pillTextColor)
    }

    /// A page requested for this project's editor (`AppModel.requestedEditorPage`).
    /// Frames is never taken from outside: it exists only once the shoot's
    /// frames have loaded, which they have not at the first delivery.
    private func consumePageRequest(_ request: EditorPageRequest?) {
        guard let request, request.captureID == captureID else { return }
        if request.page != .frames { railTab = request.page }
        DispatchQueue.main.async {
            if model.requestedEditorPage == request { model.requestedEditorPage = nil }
        }
    }

    /// The non-Editor pages' content. The Editor page never comes through
    /// here — `body` gives it its own layouts — and Frames on a single still
    /// is folded back to the Editor before the switch (`effectiveRailTab`).
    @ViewBuilder private func controlStack(isWide: Bool) -> some View {
        switch railTab {
        case .editor:
            EmptyView()
        case .text:
            textTab
        case .frames:
            if allFrames.count > 1 { framesTab } else { EmptyView() }
        case .masks:
            masksTab
        }
    }

    private var textTab: some View {
        OverlayEditingPanel(
            document: $overlayDocument,
            selectedID: $selectedOverlayID,
            hasTimeline: hasTimeline,
            position: position,
            label: timelineLabel,
            durationLabel: overlayDurationLabel,
            frameStep: overlayFrameStep,
            accent: accentColor,
            onAccent: pillTextColor,
            frameLongEdgePixels: sourceLongEdgePixels,
            frameAspect: sourceAspect,
            importedFonts: importedFonts,
            onEdited: overlayEdited,
            onOpenMasks: { railTab = .masks },
            onImportFont: importOverlayFont,
            onToast: showOverlayToast,
            isCrafting: $railCrafting,
            runTarget: $overlayRunTarget)
    }

    /// iOS: the run toolbar as the keyboard's accessory — B · U · swatches
    /// and Done, pinned above the keyboard while a copy field is focused.
    /// Drawn by hand rather than a `.toolbar(placement: .keyboard)`, which
    /// never appeared inside this full-screen cover's scroll view.
    @ViewBuilder private var overlayRunAccessory: some View {
        if railTab == .text, let target = overlayRunTarget,
           let index = overlayDocument.overlays.firstIndex(where: { $0.id == target.layer }) {
            HStack(spacing: 10) {
                OverlayRunToolbarControls(
                    layer: $overlayDocument.overlays[index],
                    range: target.range,
                    accent: accentColor, onAccent: pillTextColor, compact: true,
                    onEdited: { overlayEdited(commit: true) })
                Spacer(minLength: 0)
                Button("Done") {
                    dismissTextEntry()
                    overlayRunTarget = nil
                    overlayEdited(commit: true)
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accentColor)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255))
            .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Copies a picked TTF/OTF into the project's `fonts/` folder, registers
    /// it, and puts the layer being edited in the new face.
    private func importOverlayFont(_ url: URL) {
        guard let capture else { return }
        do {
            let font = try model.importOverlayFont(from: url, for: capture)
            importedFonts = model.importedOverlayFonts(for: capture)
            if let selectedOverlayID,
               let index = overlayDocument.overlays.firstIndex(where: { $0.id == selectedOverlayID }) {
                overlayDocument.overlays[index].textStyle?.fontFamily = font.family
                overlayEdited(commit: true)
            }
            showOverlayToast("Imported \(font.family)")
        } catch {
            showOverlayToast(error.localizedDescription)
        }
    }

    private var masksTab: some View {
        OverlayMasksPanel(
            document: $overlayDocument,
            inspectedRegion: $inspectedRegion,
            showMask: $showMask,
            tool: $maskTool,
            detailSegment: $maskDetailSegment,
            modelInstalled: segModelIdentity != nil,
            maskStatus: inspectedMaskStatus,
            thresholdIsLive: thresholdIsLive,
            canVoteAcrossFrames: hasTimeline,
            frameSize: drawnPictureSize,
            accent: accentColor,
            sources: maskThumbnailSources,
            thumbnail: { mask in
                guard let capture else { return nil }
                return CustomMaskThumbnails.thumbnail(
                    at: model.customMaskURL(mask, for: capture))
            },
            onEdited: overlayEdited,
            onImportMask: importCustomMask,
            onGradeInEditor: { ref, inverted in openGrade(for: ref, inverted: inverted) },
            shapes: shapesBinding,
            selectedShapeID: $selectedShapeID,
            shapeTool: $shapeTool,
            squareLock: $shapeSquareLock,
            shapeFrame: registerFrame,
            onShapesEdited: shapesEdited,
            onUseAsMask: useShapeAsMask,
            onFindShapes: findShapesOnce,
            lastFind: $lastFind,
            addedFindIDs: $addedFindIDs,
            rejectedFindIDs: $rejectedFindIDs,
            hoveredFoundID: $hoveredFoundID,
            findActions: foundActions)
    }

    // MARK: Find in this picture

    /// The Masks tab's "Find in this picture": the project's representative
    /// (the same picture Find shapes measures) through one detection mode.
    /// Pending candidates of the previous find are passed over first.
    private func findShapesOnce(_ mode: ShapeDetectionMode) async {
        settleFind()
        guard let capture, let rep = ShapeFinder.representative(for: capture, in: model) else {
            lastFind = ShapeFinder.Pass(runID: UUID(), mode: mode, found: [], engines: [], milliseconds: 0,
                                        note: "The picture could not be read.", failed: true)
            return
        }
        let size = RepresentativeLoader.orientedPixelSize(rep) ?? registerFrame
        let pass = await Task.detached(priority: .userInitiated) { ShapeFinder.pass(rep, size: size, mode: mode) }.value
        addedFindIDs = []
        rejectedFindIDs = []
        hoveredFoundID = nil
        foundHoverAnchor = nil
        lastFind = pass ?? ShapeFinder.Pass(runID: UUID(), mode: mode, found: [], engines: [], milliseconds: 0,
                                            note: "The picture could not be read.", failed: true)
        if let pass {
            ShapeDetectorFeedback.shared.recordPass(pass, project: capture.id, listed: registerHolds)
        }
    }

    /// The register already holds this shape (same kind over the same
    /// bounds, the Kit's own near-identical bar).
    private func registerHolds(_ shape: DetectedShape) -> Bool {
        (shapeRegister?.shapes ?? []).contains { $0.kind == shape.kind && ShapeDetector.overlap($0, shape) > 0.9 }
    }

    private var foundActions: ShapeFinder.FoundActions {
        ShapeFinder.FoundActions(add: addFound, reject: rejectFound, undo: undoFound, settle: settleFind, clear: clearFind)
    }

    private func addFound(_ found: ShapeFinder.Found) {
        guard let find = lastFind, !addedFindIDs.contains(found.id) else { return }
        var shape = found.shape
        shape.source = .detected
        ensureShapeRegister()
        shapeRegister?.shapes.append(shape)
        addedFindIDs.insert(found.id)
        rejectedFindIDs.remove(found.id)
        persistShapeRegister()
        if let capture { ShapeDetectorFeedback.shared.recordVerdict(.accepted, for: found, in: find, project: capture.id) }
    }

    private func rejectFound(_ found: ShapeFinder.Found) {
        guard let find = lastFind else { return }
        if addedFindIDs.contains(found.id) { removeAddedFound(found) }
        rejectedFindIDs.insert(found.id)
        if hoveredFoundID == found.id { hoveredFoundID = nil; foundHoverAnchor = nil }
        if let capture { ShapeDetectorFeedback.shared.recordVerdict(.rejected, for: found, in: find, project: capture.id) }
    }

    /// An added or rejected candidate back to pending; its verdict withdrawn.
    private func undoFound(_ found: ShapeFinder.Found) {
        guard let find = lastFind else { return }
        if addedFindIDs.contains(found.id) { removeAddedFound(found) }
        rejectedFindIDs.remove(found.id)
        if let capture { ShapeDetectorFeedback.shared.recordVerdict(.pending, for: found, in: find, project: capture.id) }
    }

    private func removeAddedFound(_ found: ShapeFinder.Found) {
        shapeRegister?.shapes.removeAll { $0.id == found.id }
        if selectedShapeID == found.id { selectedShapeID = nil }
        addedFindIDs.remove(found.id)
        persistShapeRegister()
    }

    /// Candidates left neither added, rejected nor already listed when a find
    /// is cleared, replaced or left behind were looked at and passed over: a
    /// false alarm for every engine that proposed them.
    private func settleFind() {
        guard let find = lastFind, !find.failed, let capture else { return }
        for found in find.found where !addedFindIDs.contains(found.id) && !rejectedFindIDs.contains(found.id) && !registerHolds(found.shape) {
            ShapeDetectorFeedback.shared.recordVerdict(.rejected, for: found, in: find, project: capture.id)
            rejectedFindIDs.insert(found.id)
        }
    }

    private func clearFind() {
        settleFind()
        lastFind = nil
        addedFindIDs = []
        rejectedFindIDs = []
        hoveredFoundID = nil
        foundHoverAnchor = nil
    }

    /// The hover over the picture, worked out from the mouse position: the
    /// nearest found outline within reach, the pill of the current one, or —
    /// sticky — the current one still. The pill is anchored where the mouse
    /// first touched the outline. Leaving the picture keeps the hover; the
    /// list's rows and a new find replace it.
    private func updateFoundHover(_ phase: HoverPhase, drawn: CGSize) {
        guard railTab == .masks, let find = lastFind, !find.found.isEmpty else { return }
        switch phase {
        case .active(let point):
            let anchor = foundHoverAnchor.flatMap { $0.id == hoveredFoundID ? $0.point : nil }
            let target = FoundShapesOverlay.hoverTarget(at: point, found: find.found, rejected: rejectedFindIDs,
                                                        current: hoveredFoundID, currentAnchor: anchor, drawn: drawn)
            if target != hoveredFoundID {
                hoveredFoundID = target
                foundHoverAnchor = target.map { ($0, point) }
            } else if let target, anchor == nil {
                // Hovered from the list, now touched on the picture: the pill moves to the mouse.
                foundHoverAnchor = (target, point)
            }
        case .ended:
            break
        }
    }

    #if DEBUG
    /// `LL_MASKGRADE=first|empty|shapes` stages the Masks work.
    ///
    /// Same reason as the other staging hooks: making a masked grade for real
    /// means drawing a mask on the picture and dragging sliders inside it,
    /// which no screenshot run can do — and the design mirrors are measured
    /// from these exact values. `first` seeds a radial "Sun" over the upper
    /// right and a linear "Quay lift", grades the first warm and open, and
    /// leaves the second applied inverted; `shapes` seeds the two masks with
    /// no grades at all (the Masks tab's own deck); `empty` forces the
    /// no-grades state on a project that has some.
    ///
    /// **In memory only.** Every path out of here re-baselines
    /// `persistedDocument`, so the 2 s persist safety net has nothing to
    /// write and staged masks never reach a real project's sidecar. (The
    /// text hook's convention is to write; masks are heavier and a stray
    /// screenshot run should not leave two of them in somebody's shoot.) A
    /// real edit still persists the moment it commits — that goes through
    /// `overlayEdited(commit:)`, not through here.
    private func applyMaskHook() {
        guard let hook = ProcessInfo.processInfo.environment["LL_MASKGRADE"] else { return }
        // Whatever this hook does, the sidecar must not learn about it.
        defer { persistedDocument = overlayDocument }
        if hook == "empty" {
            overlayDocument.maskGrades = []
            expandedGradeID = nil
            return
        }
        // Seeding is what must not tread on a project's real masks; EXPANDING
        // one is harmless. A run against an already-staged (or genuinely
        // masked) project therefore opens the first grade rather than
        // silently doing nothing, which is what the collapsed card on every
        // second run turned out to be (2026-09-07).
        guard overlayDocument.shapeMasks.isEmpty, overlayDocument.maskGrades.isEmpty else {
            expandedGradeID = overlayDocument.maskGrades.first?.id
            inspectedRegion = overlayDocument.shapeMasks.first.map { .shape($0.id) }
            railTab = hook == "shapes" ? .masks : .editor
            return
        }
        let sun = ShapeMask(
            name: "Sun",
            shape: MaskShape(
                kind: .radial, center: CGPoint(x: 0.8, y: 0.31),
                radiusX: 0.188, radiusY: 0.162, rotationDegrees: -12, feather: 0.6))
        let quay = ShapeMask(
            name: "Quay lift",
            shape: .linear(from: CGPoint(x: 0.5, y: 0.965),
                           to: CGPoint(x: 0.5, y: 0.606), feather: 0.5))
        overlayDocument.shapeMasks = [sun, quay]
        guard hook != "shapes" else {
            inspectedRegion = .shape(sun.id)
            railTab = .masks
            return
        }
        var warm = PhotoAdjustments.neutral
        // The design's "+450 K", which is what this field is in mired.
        warm.temperature = 10
        warm.exposure = 0.35
        var lift = PhotoAdjustments.neutral
        lift.highlights = -0.35
        lift.saturation = 0.12
        overlayDocument.maskGrades = [
            MaskGrade(mask: .shape(sun.id), adjustments: warm),
            MaskGrade(mask: .shape(quay.id), inverted: true, adjustments: lift),
        ]
        expandedGradeID = overlayDocument.maskGrades.first?.id
        railTab = .editor
    }
    #endif

    #if DEBUG
    /// `LL_LIGHTROOM=import` runs the import on load, and `=report` also
    /// leaves the report sheet open.
    ///
    /// Same reason as the staging hooks around it: the import is behind a
    /// button in a card that only exists for a project whose frames came from
    /// Lightroom, so neither the applied grade nor the report sheet can be
    /// screenshotted — or checked against a reference render — without a tap.
    private func applyLightroomHook() {
        guard let hook = ProcessInfo.processInfo.environment["LL_LIGHTROOM"],
              lightroomSidecar != nil else { return }
        readLightroomSidecar()
        if hook != "report" { showsLightroomReport = false }
    }
    #endif

    /// Offered only when Lightroom actually left a sidecar beside this frame.
    /// A row that is always there, greyed out, would advertise a feature most
    /// projects can never use.
    @ViewBuilder private var lightroomCard: some View {
        if lightroomSidecar != nil {
            Button {
                readLightroomSidecar()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 15))
                        .foregroundStyle(accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Lightroom settings found")
                            .font(.system(size: 13, weight: .semibold))
                        Text(lightroomReport.map(\.summary) ?? "Read the .xmp beside this frame")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(lightroomReport == nil ? "Import" : "Review")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accentColor)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LL.cardBackground,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Reads the sidecar and applies it, then shows the report. Applying
    /// first and reporting after is deliberate: the picture changing IS the
    /// answer to "what did that do", and the sheet explains the difference
    /// while it is on screen behind it.
    private func readLightroomSidecar() {
        guard let url = lightroomSidecar else { return }
        do {
            let result = try LightroomSettingsImport.read(url)
            adjustments = result.adjustments
            preset = .original
            // Lightroom's masks are ADDED to whatever the project already has
            // rather than replacing them — an import must not throw away work
            // done here.
            overlayDocument.shapeMasks.append(contentsOf: result.shapeMasks)
            overlayDocument.maskGrades.append(contentsOf: result.maskGrades)
            lightroomReport = result
            refreshState()
            persist()
            overlayEdited(commit: true)
            scheduleUpdate()
            showsLightroomReport = true
        } catch {
            lightroomError = error.localizedDescription
        }
    }

    private func refreshLightroomSidecar() {
        lightroomSidecar = LightroomSettingsImport.sidecarURL(besideFrame: displayedURL)
    }

    /// The Editor tab's Masks card — a mask's grade, as against the Masks
    /// tab's shape.
    private var masksCard: some View {
        MasksCard(
            document: $overlayDocument,
            expandedGradeID: $expandedGradeID,
            showMask: $showMask,
            accent: accentColor,
            sources: maskThumbnailSources,
            modelInstalled: segModelIdentity != nil,
            // The drag-to-adjust gesture needs a picture that is not already
            // carrying pan and zoom for the same finger. On the Mac and iPad
            // it is a pointer drag on a fitted picture and unambiguous; on a
            // phone the picture is the smaller half of a stacked layout and
            // the gesture would fight scrolling, so the labels do not arm.
            armedField: supportsDragToAdjust ? armedMaskField : nil,
            onArmField: supportsDragToAdjust ? { armedMaskField = $0 } : nil,
            onEdited: overlayEdited,
            onManage: { ref in
                railTab = .masks
                if let ref { inspectedRegion = ref.placement(inverted: false) }
                maskDetailSegment = .shape
                armedMaskField = nil
            },
            onNewShape: { kind in
                railTab = .masks
                maskTool = kind
                armedMaskField = nil
            })
    }

    /// Whether a drag on the picture can set an armed slider. Wide layouts
    /// only — see `masksCard`.
    private var supportsDragToAdjust: Bool {
        #if os(macOS)
        return true
        #else
        return paneSize.width >= wideLayoutThreshold * 0.5
        #endif
    }

    /// Create-or-open a grade and show it, from either side of the app.
    private func openGrade(for ref: MaskRef, inverted: Bool) {
        let id = overlayDocument.addMaskGrade(for: ref, inverted: inverted)
        expandedGradeID = id
        armedMaskField = nil
        railTab = .editor
        overlayEdited(commit: true)
    }

    /// What the mask tiles need to draw themselves: whatever the segmenter
    /// has already produced, and the project's custom-mask files.
    private var maskThumbnailSources: MaskThumbnails.Sources {
        MaskThumbnails.Sources(
            skyMask: skyMaskKey.flatMap {
                SceneMaskService.shared.cachedSkyMask(forKey: $0)
            },
            customThumbnail: { id in
                guard let capture,
                      let mask = overlayDocument.customMasks.first(where: { $0.id == id })
                else { return nil }
                return CustomMaskThumbnails.thumbnail(
                    at: model.customMaskURL(mask, for: capture))
            })
    }

    /// Copies a picked or dropped image into the project and adds it to the
    /// document. Named for the file it came from, which is nearly always the
    /// name the user already gave the region.
    private func importCustomMask(_ url: URL) {
        guard let capture else { return }
        do {
            let name = url.deletingPathExtension().lastPathComponent
            let mask = try model.importCustomMask(from: url, name: name, for: capture)
            overlayDocument.customMasks.append(mask)
            persistOverlays()
            scheduleUpdate()
        } catch {
            LLog("custom mask import failed: \(error.localizedDescription)")
        }
    }

    /// Whether the grid currently on screen has anything for the Threshold
    /// dial to cut. An argmax model on one frame gives 2 levels — a hard
    /// yes/no — and thresholding that is a no-op; the vote across frames is
    /// what produces real confidence. A custom mask is a drawn image and
    /// usually has soft edges, so it answers for itself.
    private var thresholdIsLive: Bool {
        guard let region = inspectedRegion else { return true }
        if let id = region.customMaskID {
            guard let capture,
                  let mask = overlayDocument.customMasks.first(where: { $0.id == id })
            else { return false }
            return CustomMaskLoader.mask(at: model.customMaskURL(mask, for: capture))?
                .carriesConfidence ?? false
        }
        guard let key = activeSkyMaskKey,
              let mask = SceneMaskService.shared.cachedSkyMask(forKey: key)
        else { return overlayDocument.maskSettings.maskMode == .sequence }
        return mask.carriesConfidence
    }

    /// The readout under the mask dials. A custom region is a FILE, so the
    /// model's provenance line ("sequence vote · 9 frames") would be a lie
    /// there — it gets the file's own instead, and says so when the file has
    /// gone missing.
    private var inspectedMaskStatus: String? {
        guard let id = inspectedRegion?.customMaskID else { return maskStatus }
        guard let capture,
              let mask = overlayDocument.customMasks.first(where: { $0.id == id })
        else { return nil }
        return CustomMaskLoader.mask(at: model.customMaskURL(mask, for: capture))?
            .provenance ?? "mask file missing — this region will not occlude"
    }

    /// The source frame's long edge in pixels, so the Text tab's size
    /// readouts describe the DELIVERED file. The preview render is the wrong
    /// ruler — it is capped at 2000 px (1100 mid-scrub), so a size quoted
    /// against it would change as you scrub.
    private var sourceLongEdgePixels: Double {
        if let capture, let w = capture.sourceWidth, let h = capture.sourceHeight,
           w > 0, h > 0 {
            return Double(max(w, h))
        }
        guard let rendered else { return 4032 }
        return Double(max(rendered.width, rendered.height))
    }

    private var sourceAspect: Double {
        if let capture, let w = capture.sourceWidth, let h = capture.sourceHeight,
           w > 0, h > 0 {
            return Double(w) / Double(h)
        }
        if let aspect { return aspect }
        guard let rendered, rendered.height > 0 else { return 4 / 3 }
        return Double(rendered.width) / Double(rendered.height)
    }

    /// Frame management — the bad-frame pair, promoted from the foot of the
    /// old single stack to a page of its own.
    private var framesTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            badFrameToggleButton
            if hasNominatedFrames {
                hideBadFramesToggle
            }
        }
    }

    /// The file name of the frame currently on screen, for nomination purposes.
    private var currentFrameFileName: String {
        displayedURL.lastPathComponent
    }

    /// Whether the frame currently on screen has been nominated as bad.
    private var isCurrentFrameNominated: Bool {
        guard let capture else { return false }
        return model.isFrameNominated(currentFrameFileName, in: capture)
    }

    /// A toggle that marks or un-marks the current frame as a bad frame to
    /// exclude from every blend. The frame stays on disk — nomination is
    /// purely metadata. Gated on `hasTimeline` (shown only for interval shoots).
    @ViewBuilder private var badFrameToggleButton: some View {
        Button {
            model.toggleFrameNomination(fileName: currentFrameFileName, in: captureID)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isCurrentFrameNominated
                      ? "exclamationmark.triangle.fill"
                      : "exclamationmark.triangle")
                    .foregroundStyle(isCurrentFrameNominated ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isCurrentFrameNominated ? "Frame marked bad" : "Mark frame as bad")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isCurrentFrameNominated ? Color.orange : Color.primary)
                    Text(isCurrentFrameNominated
                         ? "This frame will be excluded from all blends. Tap to undo."
                         : "Exclude this frame from all blends. The file stays on disk.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .background(
            isCurrentFrameNominated
                ? Color.orange.opacity(0.12)
                : LL.cardBackground,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    /// "Hide bad frames" — whether the frames marked above are taken out of
    /// this screen and out of the counts the project advertises.
    ///
    /// Directly under the row that makes the nominations, at the foot of the
    /// stack: it is the second half of one idea, and it has no business
    /// sitting between the picture and the sliders.
    ///
    /// On by default (`AppModel.effectiveHideBadFrames(for:)`): marking a frame
    /// bad and then still having to scrub past it is not what the nomination
    /// was for. Turning it off is how a nominated frame becomes reachable
    /// again — which is the only route back to un-marking one.
    private var hideBadFramesToggle: some View {
        Toggle(isOn: hideBadFrames) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Hide bad frames")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(hideBadFramesCaption)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        #if os(macOS)
        .toggleStyle(.checkbox)
        #endif
        .tint(LL.amber)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Says what the switch is doing to *this* project, counted — "hidden" is
    /// too vague to act on when the number is the thing you want to know.
    private var hideBadFramesCaption: String {
        let count = capture.map { model.nominatedBadFrameNames(for: $0).count } ?? 0
        let frames = count == 1 ? "1 marked frame" : "\(count) marked frames"
        guard capture.map({ model.effectiveHideBadFrames(for: $0) }) == true else {
            return "\(frames) stay on the timeline, ticked in orange."
        }
        return "\(frames) are off the timeline and out of this project's counts."
    }

    private var hideBadFrames: Binding<Bool> {
        Binding(
            get: { capture.map(model.effectiveHideBadFrames(for:)) ?? false },
            set: { model.setHideBadFrames($0, for: captureID) })
    }

    /// Black on the editors' amber, white on the Mac's accent — the pair the
    /// rail's tab bar uses.
    private var pillTextColor: Color {
        #if os(iOS)
        return .black
        #else
        return .white
        #endif
    }

    /// "Save as preset?" — the offer made when an Edited grade is about to be
    /// left behind. Inline rather than a blocking alert: the edits are already
    /// safe on the project, so this is an invitation to name a look, not a
    /// warning about losing one.
    private var presetSaveOffer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save these edits as a preset?")
                .font(.system(size: 14.5, weight: .semibold))
            Text("Your adjustments stay on this project either way. Saving them makes the look reusable.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                // Where the offer is standing in for an exit we don't own,
                // declining dismisses the offer — not the editor.
                Button("Not now") {
                    if ownsExit {
                        finishExit()
                    } else {
                        withAnimation(.easeOut(duration: 0.2)) { declinedPresetSave = true }
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                Button("Save as Preset") {
                    isOfferingPresetSave = false
                    exitsAfterPresetSave = ownsExit
                    newPresetName = ""
                    isNamingPreset = true
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accentColor)
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - The group panel

    /// The one `PhotoAdjustmentsPanel` call site, dressed for the layout in
    /// use. Every parameter the old always-open panel took is still here;
    /// the redesign adds the group, the chip selection, the Presets group's
    /// data, WB Auto, the crop's frame aspect, ✓/✕ and the floating header's
    /// drag.
    private func groupPanel(
        _ group: EditorGroup, layout: EditorPanelLayout, style: XYPadStyle
    ) -> some View {
        PhotoAdjustmentsPanel(
            adjustments: editedAdjustments,
            group: group,
            layout: layout,
            style: style,
            toolSelection: $toolSelection,
            frameWhiteKelvin: frameWhite.kelvin,
            frameWhiteTint: frameWhite.tint,
            whiteBalanceSource: whiteBalanceSource,
            onSetWhiteBalanceSource: capture == nil ? nil : setWhiteBalanceSource,
            playheadPosition: renderedPosition,
            accent: accentColor,
            keyframedFields: timeline.keyframedFields,
            hasKeyframes: !timeline.isEmpty,
            onResetField: hasTimeline ? resetField : nil,
            onResetAll: hasTimeline ? resetEverything : nil,
            onFieldEditing: fieldEditingChanged,
            presets: presetsContext,
            autoWhite: capture == nil ? nil : { await autoWhiteEstimate() },
            cropFrameAspect: pictureAspect,
            onCommit: commitPanel,
            onCancel: cancelPanel,
            // The Presets card is pinned (top 62 / bottom 96) and ignores
            // the seat, so its header must not move it for the next group.
            onHeaderDrag: layout == .floating && group != .presets ? floatingHeaderDragged : nil,
            initialBand: hookBand)
    }

    /// What the Presets group renders and does: the frame under the
    /// playhead for the tiles, the built-in and saved presets, and the same
    /// apply / delete / save paths the chip strip used to drive. The
    /// Lightroom card and the inline save offer go in here too, since the
    /// Presets panel is the page that is about the look as a whole.
    private var presetsContext: EditorPresetsContext {
        EditorPresetsContext(
            frame: capture.map { capture in
                PresetPreviewFrame(
                    captureID: capture.id, title: capture.displayTitle,
                    fileName: displayedURL.lastPathComponent,
                    source: .still(displayedURL), isChosen: true)
            },
            presetState: presetState,
            basePreset: preset,
            customPresets: presetStore.presets,
            cache: presetThumbnails,
            onSelect: { request($0) },
            onDelete: { presetPendingDelete = $0 },
            onSaveAsPreset: {
                newPresetName = ""
                isNamingPreset = true
            },
            saveOffer: presetState.isEdited && !ownsExit && !declinedPresetSave
                ? AnyView(presetSaveOffer) : nil,
            lightroomCard: lightroomSidecar != nil ? AnyView(lightroomCard) : nil)
    }

    // MARK: Opening, keeping, reverting

    /// A main button tapped. A different group already open is committed
    /// first — its snapshot dropped, its values kept — and the new group
    /// gets a fresh snapshot of them (spec §3: switching group commits and
    /// re-snapshots; the board's `openGroup`). The open group tapped again
    /// is left exactly as it is. Crop opens on a fitted picture, so the
    /// frame and its handles are all on screen.
    private func openPanel(for group: EditorGroup) {
        if let open = openGroup {
            guard open != group else { return }
            editorSnapshot = nil
            persist()
            persistOverlays()
        }
        editorSnapshot = takeSnapshot()
        openGroup = group
        if group == .crop, !zoom.isFitted {
            withAnimation(.easeInOut(duration: 0.22)) { zoom = .fitted }
        }
        // The editing crop overlay may have been torn down mid-gesture; its
        // `onEditing(false)` then never arrives, and the pane's pan and
        // pinch would stay masked. The overlay is gone, so nothing is
        // editing.
        cropEditing = false
    }

    private func takeSnapshot() -> EditorSnapshot {
        EditorSnapshot(
            preset: preset, adjustments: adjustments, timeline: timeline,
            presetState: presetState, whiteBalanceSource: whiteBalanceSource)
    }

    /// ✓ / Done: the values stay, the snapshot goes, the panel closes.
    /// Persisted here as a finished gesture rather than left to the safety
    /// net — the panel may be the last thing before the back button.
    private func commitPanel() {
        editorSnapshot = nil
        openGroup = nil
        cropEditing = false
        persist()
        persistOverlays()
    }

    /// ✕ / Revert: the grade back to what it was when the panel opened.
    /// Every release since opening has already been persisted, so the
    /// restore is persisted too.
    ///
    /// The overlay document is NOT snapshotted and restored: the panel can
    /// stay open while the Text and Masks tabs add or move layers, and a
    /// wholesale restore would throw that work away and persist the loss.
    /// The only thing the panel itself does to the document is carry the
    /// layers with the opening level (`carryOverlays`), so undoing the level
    /// carries them back — the same remap the write applied, run in reverse.
    private func cancelPanel() {
        if let snapshot = editorSnapshot {
            stopPlayback()
            let openingBefore = openingRotation
            preset = snapshot.preset
            adjustments = snapshot.adjustments
            withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) {
                timeline = snapshot.timeline
            }
            presetState = snapshot.presetState
            carryOverlays(fromRotation: openingBefore, to: openingRotation)
            if whiteBalanceSource != snapshot.whiteBalanceSource {
                setWhiteBalanceSource(snapshot.whiteBalanceSource)
            }
            refreshState()
            scheduleUpdate()
            persist()
            persistOverlays()
        }
        editorSnapshot = nil
        openGroup = nil
        cropEditing = false
    }

    /// The crop as the picture's overlay edits it: `.full` while there is
    /// none, and nothing again once a drag has put the whole frame back with
    /// no ratio to keep — an all-of-it crop with no aspect is no crop. A full
    /// frame under a chosen aspect is kept, so the chip stays on the choice.
    private var cropBinding: Binding<FrameCrop> {
        Binding(
            get: { displayedAdjustments.crop ?? .full },
            set: { crop in
                var values = displayedAdjustments
                values.crop = crop.isFull && crop.aspect == .original ? nil : crop
                editedAdjustments.wrappedValue = values
            })
    }

    /// WB Auto (spec §8): the frame under the playhead through the grade in
    /// hand at 256 px, read for its grey-world white. Off the main actor on
    /// the shared media lane, since a raw decode is behind it. The panel
    /// writes the estimate through the binding like a menu pick, which is
    /// what seeds every other moment's white (`seedUnownedWhites`).
    private func autoWhiteEstimate() async -> AutoWhiteBalance.Estimate? {
        let preset = preset
        let graded: PhotoAdjustments = {
            var moment = displayedAdjustments
            moment.crop = nil
            return moment
        }()
        let url = displayedURL
        let whiteBalance = frozenWhiteBalance(at: position)
        // The white the estimate corrects FROM: the owned one when there is
        // one, else the white the frame is rendering at.
        let current: (kelvin: Double, tint: Double) = graded.ownsWhite
            ? (1e6 / Double(graded.whiteMired), Double(graded.whiteTint))
            : frameWhite
        let image = await MediaWorkQueue.shared.run { () -> CGImage? in
            PhotoGrader.render(
                url: url, preset: preset, adjustments: graded,
                whiteBalance: whiteBalance, maxDimension: 256, cropped: false)
        }
        guard let image, let image else { return nil }
        return AutoWhiteBalance.estimate(
            image: image, currentKelvin: current.kelvin, currentTint: current.tint)
    }

    // MARK: Rotation and the text layers

    /// The level at the opening moment — the space the text layers are
    /// stored in (`SceneOverlay.remapped`).
    private var openingRotation: Double {
        Double(timeline.adjustments(at: 0, baseline: adjustments).rotationDegrees)
    }

    /// The level under the playhead — what the picture on screen is turned by.
    private var displayedRotation: Double { Double(displayedAdjustments.rotationDegrees) }

    /// Carries every text layer with a change of the OPENING level: layers
    /// live in that levelled frame's space, so each one is re-expressed from
    /// the old level to the new — pinned to the same point of the scene,
    /// turned by the same amount, grown by the same crop-in. A layer added
    /// afterwards starts at 0 and reads level, which is the other half of
    /// the rule. A level that only changes at a LATER moment moves nothing
    /// here: the layers stay stored at the opening and the render carries
    /// them into each moment (`displayOverlay`).
    private func carryOverlays(fromRotation old: Double, to new: Double) {
        guard old != new else { return }
        let frame = sourcePixelSize
        overlayDocument.overlays = overlayDocument.overlays.map {
            $0.remapped(fromRotation: old, to: new, width: frame.width, height: frame.height)
        }
    }

    /// A stored layer as this moment's frame shows it — the same remap the
    /// export applies per frame, so the proxy and chrome sit where the bake
    /// will put the text.
    private func displayOverlay(_ overlay: SceneOverlay) -> SceneOverlay {
        let frame = sourcePixelSize
        return overlay.remapped(
            fromRotation: openingRotation, to: displayedRotation,
            width: frame.width, height: frame.height)
    }

    /// The inverse: a point placed on this moment's frame, back into the
    /// stored (opening) frame.
    private func storedPoint(_ point: CGPoint) -> CGPoint {
        let frame = sourcePixelSize
        return FrameRotation.remap(
            point, width: frame.width, height: frame.height,
            from: displayedRotation, to: openingRotation)
    }

    /// How much longer a stored length is on this moment's frame.
    private var displayGrow: Double {
        let frame = sourcePixelSize
        return FrameRotation.lengthScale(
            width: frame.width, height: frame.height, from: openingRotation, to: displayedRotation)
    }

    /// This shoot's white balance resolved for one moment and pinned there, so
    /// it can cross onto the render queue as a constant.
    private func frozenWhiteBalance(at position: Double) -> WhiteBalanceTrack {
        let track = capture.map(model.whiteBalanceTrack(for:)) ?? .asShot
        guard let declared = track.declared(atPosition: position) else { return .asShot }
        return WhiteBalanceTrack(source: .fixed(kelvin: declared.kelvin, tint: declared.tint))
    }

    /// Re-reads the anchor for one frame — a cached converter open, off the
    /// render path.
    ///
    /// This runs per *frame*, not once per editor: the anchor used to be taken
    /// from whichever frame the editor opened on and never updated, so
    /// scrubbing a shoot showed one file's Kelvin over every other file's
    /// pixels. On a run whose camera re-decided mid-shoot that is the
    /// difference between a readout that explains what is on screen and one
    /// that contradicts it.
    private func refreshAsShotAnchor(for url: URL) async {
        guard asShotSourcePath != url.path else { return }
        let neutral = await Task.detached(priority: .utility) {
            let read = PhotoGrader.asShotNeutral(url: url)
            return (Double(read.kelvin), Double(read.tint))
        }.value
        asShotKelvin = neutral.0
        asShotTint = neutral.1
        asShotSourcePath = url.path
    }

    /// A control grabbed or let go. The five that work on pixels bring the
    /// loupe up for as long as they are being dragged — the rest are visible
    /// at any scale and need nothing.
    private func fieldEditingChanged(_ field: PhotoAdjustmentField, _ editing: Bool) {
        if Self.detailFields.contains(field) {
            if editing {
                loupeField = field
            } else if loupeField == field {
                loupeField = nil
            }
        }
        // A released slider is a finished gesture: the grade goes through to
        // the project once, here — not once per debounce settle mid-drag,
        // which was a whole-library encode plus an app-wide invalidation
        // every 100 ms (editor-performance-plan.md, stage 2). Edits that
        // arrive without a grab/release pair are caught by the safety-net
        // task below.
        if !editing {
            persist()
            // A released level may have carried the text layers with it.
            if field == .rotation { persistOverlays() }
        }
    }

    /// What the panel reads and writes: the grade *at the playhead*.
    ///
    /// The get is the whole reason the sliders travel while you scrub. The set
    /// is where the concept lives — `GradeTimeline.write` decides, from where
    /// the playhead is standing, whether an edit grades the shoot or grades a
    /// moment of it, and materialises the first two moments when it has to.
    ///
    /// The crop is the exception: static by decision, one value for the whole
    /// shoot, so a changed crop is lifted out of the write and stamped onto
    /// every moment (`GradeTimeline.carryCrop`) — the way the owned white is
    /// seeded — and a crop-only change makes no keyframe at all. Written at
    /// the playhead it would cut only that moment, and the blend, the hero
    /// and every still export read the opening one.
    private var editedAdjustments: Binding<PhotoAdjustments> {
        Binding(
            get: { displayedAdjustments },
            set: { incoming in
                let openingBefore = openingRotation
                defer { carryOverlays(fromRotation: openingBefore, to: openingRotation) }
                guard hasTimeline else {
                    adjustments = incoming
                    refreshState()
                    scheduleUpdate()
                    return
                }
                stopPlayback()
                let shown = displayedAdjustments
                let cropChanged = incoming.crop != shown.crop
                var values = incoming
                values.crop = shown.crop
                var baseline = adjustments
                var updated = timeline
                let outcome: GradeTimeline.EditOutcome = values == shown
                    ? .none
                    : updated.write(values, at: position, baseline: &baseline)
                if cropChanged {
                    updated.carryCrop(incoming.crop, baseline: &baseline)
                }
                if values.ownsWhite {
                    // After the write, so the moment it may have just
                    // materialised from the old baseline is seeded too; then
                    // the baseline re-mirrors the opening moment.
                    seedUnownedWhites(in: &updated)
                    baseline = updated.adjustments(at: 0, baseline: baseline)
                }
                adjustments = baseline
                if case .created = outcome {
                    // The dots arriving IS the announcement that this shoot now
                    // has a grade over time, so they are worth animating.
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) {
                        timeline = updated
                    }
                } else {
                    timeline = updated
                }
                refreshState()
                scheduleUpdate()
            })
    }

    /// A double-tapped label, with a timeline in play: take this property back
    /// out of the moment under the playhead rather than writing a zero into it.
    /// A moment left saying nothing at all removes itself.
    private func resetField(_ field: PhotoAdjustmentField) {
        let openingBefore = openingRotation
        var baseline = adjustments
        var updated = timeline
        updated.resetField(field, at: position, baseline: &baseline)
        adjustments = baseline
        withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) { timeline = updated }
        carryOverlays(fromRotation: openingBefore, to: openingRotation)
        refreshState()
        scheduleUpdate()
        persist()
        persistOverlays()
    }

    private func resetEverything() {
        stopPlayback()
        let openingBefore = openingRotation
        adjustments = .neutral
        withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) { timeline.clear() }
        carryOverlays(fromRotation: openingBefore, to: 0)
        refreshState()
        scheduleUpdate()
        persist()
        persistOverlays()
    }

    private func deleteKeyframe(_ keyframe: GradeKeyframe) {
        let openingBefore = openingRotation
        var baseline = adjustments
        var updated = timeline
        updated.remove(keyframe.id, baseline: &baseline)
        adjustments = baseline
        withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) { timeline = updated }
        carryOverlays(fromRotation: openingBefore, to: openingRotation)
        refreshState()
        scheduleUpdate()
        persist()
        persistOverlays()
    }

    // MARK: - Playback

    /// How long one sweep of the strip takes: the project's own output
    /// length where a blended clip has been rendered — the pace the text
    /// reveals will actually play at — and a 14 s tour of the shoot before
    /// one exists. Floored so a very short clip still sweeps rather than
    /// flickers.
    private var playbackSweepSeconds: Double {
        if let capture,
           let clip = model.blends(for: capture)
               .sorted(by: { $0.createdAt > $1.createdAt })
               .first(where: { ($0.outputFrames ?? 0) > 0 && ($0.outputFPS ?? 0) > 0 }),
           let frames = clip.outputFrames, let fps = clip.outputFPS {
            return max(Double(frames) / Double(fps), 1)
        }
        return 14
    }

    /// Live playback: the playhead advances in real time at the output's
    /// pace and loops, so a reveal can be watched landing — and landing
    /// again — without leaving the screen. Any scrub stops it.
    private func togglePlayback() {
        guard !isPlaying else { stopPlayback(); return }
        let from = position >= 0.999 ? 0 : position
        position = from
        isPlaying = true
        let sweep = playbackSweepSeconds
        playback = Task { @MainActor in
            var started = Date()
            var origin = from
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(started)
                var next = origin + elapsed / sweep
                if next >= 1 {
                    // Loop: back to the head, on the same clock.
                    origin = 0
                    started = Date()
                    next = 0
                }
                position = next
                let quantised = renderPosition(for: next)
                if quantised != renderedPosition {
                    renderedPosition = quantised
                    renderToken += 1
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func stopPlayback() {
        playback?.cancel()
        playback = nil
        isPlaying = false
    }

    // MARK: - Actions

    /// A chip tap. From Edited it discards work the user did by hand, so it
    /// asks first; from Original or another preset it applies immediately.
    private func request(_ target: PresetApplyRequest.Target) {
        // Original clears the whole grade, keyframes included; every other chip
        // writes where the playhead is standing and leaves the rest alone.
        let request = PresetApplyRequest(
            target: target,
            discardsMoments: timeline.keyframes.count,
            writesAtPlayhead: !timeline.isEmpty && !PresetApplyRequest(target: target).isOriginal)
        guard presetState.isEdited else {
            apply(request)
            return
        }
        pendingApply = request
    }

    private func apply(_ request: PresetApplyRequest) {
        switch request.target {
        case .builtIn(let candidate):
            preset = candidate
            // Original is "no filter" — the whole grade goes, keyframes with
            // it, because there is no moment of an unfiltered clip to keep.
            guard candidate != .original else {
                adjustments = .neutral
                withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) { timeline.clear() }
                presetState = .original
                declinedPresetSave = false
                scheduleUpdate()
                persist()
                return
            }
            applyPresetValues(.neutral)
            presetState = timeline.isEmpty
                ? .named(id: candidate.presetID, snapshot: candidate.snapshot)
                : .edited
        case .custom(let custom):
            preset = custom.basePreset
            applyPresetValues(custom.adjustments)
            presetState = timeline.isEmpty
                ? .named(id: custom.id, snapshot: custom.snapshot)
                : .edited
        }
        declinedPresetSave = false
        scheduleUpdate()
        // A chip tap is a finished gesture, not a drag: persist it now.
        persist()
    }

    /// A chip's values, written where the playhead is standing.
    ///
    /// With no keyframes that is the whole clip, which is what it has always
    /// been. With keyframes it is one moment: the alternative — silently
    /// flattening a graded shoot back to one look because a chip was tapped —
    /// throws away work that took scrubbing to make. Clearing the timeline is
    /// still one tap away, on Original.
    ///
    /// The geometry stays: a preset carries no level and no crop (they are
    /// stripped at save), so the ones in hand are re-attached rather than
    /// let fall to nil — tapping Cinema must not uncrop the picture.
    private func applyPresetValues(_ preset: PhotoAdjustments) {
        var values = preset
        let now = displayedAdjustments
        values.crop = now.crop
        values.rotationDegrees = now.rotationDegrees
        guard hasTimeline, !timeline.isEmpty else {
            adjustments = values
            return
        }
        var baseline = adjustments
        var updated = timeline
        updated.write(values, at: position, baseline: &baseline)
        adjustments = baseline
        withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) { timeline = updated }
    }

    /// Re-derives the state from the live values, anchored on the state they
    /// came from — the whole divergence rule, in one call.
    private func refreshState() {
        presetState = PresetStateResolver.resolve(
            preset: preset,
            adjustments: adjustments,
            timeline: timeline,
            anchor: presetState,
            customPresets: presetStore.presets)
    }

    /// Restarts the debounce window. Both the manifest write and the re-render
    /// happen at the end of it.
    private func scheduleUpdate() {
        renderToken += 1
    }

    // MARK: - Overlays

    /// True while anything on screen needs the segmentation model's mask.
    /// Custom masks are files and drawn shapes are arithmetic, so neither
    /// ever comes through here.
    private var skyMaskWanted: Bool {
        if let tintedRegion, tintedRegion.maskRef?.ref.needsSegmentationModel == true {
            return true
        }
        return overlayDocument.needsSegmentationModel
    }

    /// The region the picture is tinting magenta right now: the Masks tab's
    /// selection, or — while a grade is expanded in the Editor — the region
    /// that grade applies to, so "Show mask" answers the question the user is
    /// actually asking.
    private var tintedRegion: OverlayPlacement? {
        guard showMask else { return nil }
        if railTab == .editor, let id = expandedGradeID,
           let grade = overlayDocument.maskGrade(id: id) {
            return grade.placement
        }
        return inspectedRegion
    }

    /// The cache key of the mask the composite should use right now, or nil
    /// when none is wanted (or no model is installed). The render path only
    /// ever LOOKS UP this key — `maskFetchTask` is what fills it.
    private var activeSkyMaskKey: String? {
        skyMaskWanted ? skyMaskKey : nil
    }

    /// The same key, whether or not anything wants the analysis run.
    ///
    /// The mask TILES read it: a Sky row in the deck draws the real skyline
    /// when one is already cached and the stand-in horizon when it is not.
    /// Cache-only, always — running inference to fill a 48 pt thumbnail would
    /// be absurd, and `skyMaskWanted` stays the one thing that can ask for it.
    private var skyMaskKey: String? {
        guard let segModelIdentity else { return nil }
        if overlayDocument.maskSettings.maskMode == .sequence, hasTimeline {
            return SceneMaskService.shared.sequenceKey(
                modelIdentity: segModelIdentity, frames: frames,
                presetID: preset.presetID.uuidString, sampleCount: SceneMaskService.sequenceSampleCount)
        }
        return SceneMaskService.shared.frameKey(
            modelIdentity: segModelIdentity, url: displayedURL, presetID: preset.presetID.uuidString)
    }

    /// Every mask the preview might need, resolved on the main actor before
    /// the render hops off it. The model's mask is looked up by cache key
    /// ONLY — the composite path can read a cached mask but must never
    /// generate one, or a drag would stall on inference.
    private func previewMaskSet() -> SceneAwareCompositor.MaskSet {
        var masks = SceneAwareCompositor.MaskSet()
        if let key = activeSkyMaskKey {
            masks.sky = SceneMaskService.shared.cachedSkyMask(forKey: key)
        }
        // Drawn shapes are parameters, so every one of them travels: there
        // is nothing to decode and nothing to infer, and the compositor only
        // resolves the ones something names.
        for mask in overlayDocument.shapeMasks {
            masks.shapes[mask.id] = mask.shape
        }
        guard let capture else { return masks }
        // Only the mask FILES something on screen actually names — a grade
        // applied through one counts as much as a layer placed in it.
        var wanted = Set(overlayDocument.overlays.compactMap { $0.placement.customMaskID })
        wanted.formUnion(
            overlayDocument.maskGrades.filter(\.isActive).compactMap { $0.placement.customMaskID })
        if let id = inspectedRegion?.customMaskID, showMask { wanted.insert(id) }
        for mask in overlayDocument.customMasks where wanted.contains(mask.id) {
            masks.custom[mask.id] = CustomMaskLoader.mask(
                at: model.customMaskURL(mask, for: capture))
        }
        return masks
    }

    /// A Text-tab edit. Motion re-renders; a finished gesture also persists —
    /// the `fieldEditingChanged` discipline, applied to overlays.
    /// The association menu, on the text itself: see
    /// `OverlayAssociationMenu`. Acting on it also selects the layer, so the
    /// rail is left describing the line the menu just changed.
    @ViewBuilder private func associationMenu(for stored: SceneOverlay) -> some View {
        OverlayAssociationMenu(
            document: $overlayDocument,
            layerID: stored.id,
            onEdited: {
                selectedOverlayID = stored.id
                overlayEdited(commit: true)
            },
            onToast: showOverlayToast)
    }

    private func overlayEdited(commit: Bool) {
        // Every edit re-seats the sequenced layers after their parents, so
        // a moved band carries its children with it.
        overlayDocument.resolveFollows()
        scheduleUpdate()
        if commit { persistOverlays() }
    }

    /// Resigns the overlay text field's soft keyboard. Called wherever the
    /// user has visibly moved on — an overlay drag, a scrub, a tab switch —
    /// because on iOS the keyboard otherwise sits over half the editor with
    /// no way out (found on device 2026-08-31). A no-op with nothing focused,
    /// and a no-op on macOS.
    private func dismissTextEntry() {
        #if os(iOS)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private func persistOverlays() {
        guard let capture, overlayDocument != persistedDocument else { return }
        model.setOverlayDocument(overlayDocument, for: capture)
        persistedDocument = overlayDocument
    }

    /// Generates whatever mask `activeSkyMaskKey` names and re-renders when
    /// it lands. Keyed on the key itself: scrubbing in per-frame mode walks
    /// it frame by frame, and the sequence mask is one fetch per project per
    /// grade. The composite path never waits on this — it composites with
    /// whatever is cached and picks the fresh mask up on the next render.
    private func maskFetchTask() async {
        guard loaded, let key = activeSkyMaskKey, let segModelIdentity else { return }
        if let cached = SceneMaskService.shared.cachedSkyMask(forKey: key) {
            maskStatus = cached.provenance
            return
        }
        // Snapshot every input WITH the key: the cache write at the end is
        // keyed on `key`, and state that moved during the debounce (a mode
        // flip, a scrub step) must not smuggle a different frame's mask —
        // or a single frame posing as the sequence vote — under it.
        let sequenceMode = overlayDocument.maskSettings.maskMode == .sequence && hasTimeline
        let sequenceFrames = frames
        let frameURL = displayedURL
        let preset = preset
        // The mask is fetched over the whole frame, as the composite applies
        // it: the crop is drawn over the picture here, never cut from it.
        let adjustments: PhotoAdjustments = {
            var whole = self.adjustments
            whole.crop = nil
            return whole
        }()
        // A beat of stillness first, so a scrub in per-frame mode asks for
        // the frame it settles on rather than one inference per step.
        try? await Task.sleep(for: .milliseconds(200))
        // Belt to the snapshot's braces: `.task(id:)` cancellation only
        // lands on the next body evaluation, so re-derive the key and bail
        // if the world moved while we slept.
        guard !Task.isCancelled, activeSkyMaskKey == key else { return }
        maskStatus = "Analysing the scene…"
        do {
            let mask: SceneMask
            if sequenceMode {
                mask = try await SceneMaskService.shared.sequenceSkyMask(
                    forKey: key, modelIdentity: segModelIdentity, frames: sequenceFrames,
                    sampleCount: SceneMaskService.sequenceSampleCount, presetID: preset.presetID.uuidString,
                    render: { url in
                        PhotoGrader.render(
                            url: url, preset: preset, adjustments: adjustments, maxDimension: 512,
                            cropped: false)
                    },
                    progress: { done, total in
                        Task { @MainActor in
                            maskStatus = "Analysing the scene — frame \(done + 1) of \(total)…"
                        }
                    })
            } else {
                mask = try await SceneMaskService.shared.skyMask(forKey: key) {
                    PhotoGrader.render(
                        url: frameURL, preset: preset, adjustments: adjustments, maxDimension: 512,
                        cropped: false)
                }
            }
            guard !Task.isCancelled else { return }
            maskStatus = mask.provenance
            renderToken += 1
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            maskStatus = error.localizedDescription
        }
    }

    /// Writes the current grade onto the project. Cheap enough after debouncing
    /// — `setPhotoGrade` no-ops when nothing changed.
    private func persist() {
        // A staged screenshot (`LL_MIXER`) must never reach a real project.
        guard !persistSuppressedForStaging, let capture else { return }
        model.setPhotoGrade(
            preset: preset, adjustments: adjustments, state: presetState,
            timeline: timeline, for: capture)
    }

    private func saveCurrentAsPreset() {
        // A preset is a look, and the look on screen is the one at the
        // playhead — which is the whole grade when nothing is keyframed. The
        // level and the crop are not part of a look.
        if let saved = presetStore.save(
            name: newPresetName, basePreset: preset,
            adjustments: displayedAdjustments.withoutGeometry) {
            // Naming a look is what takes a project out of Edited: the values
            // haven't moved, but they now have a preset behind them. A grade
            // that travels stays Edited whatever gets named — one preset can't
            // stand for a look that changes.
            if timeline.isEmpty {
                presetState = .named(id: saved.id, snapshot: saved.snapshot)
            }
        }
        newPresetName = ""
        guard exitsAfterPresetSave else {
            scheduleUpdate()
            return
        }
        exitsAfterPresetSave = false
        finishExit()
    }

    /// Back, with the exit-time offer in the way when there is one to make.
    private func requestExit() {
        guard presetState.isEdited else {
            finishExit()
            return
        }
        withAnimation(.easeOut(duration: 0.2)) { isOfferingPresetSave = true }
    }

    /// Leaves the editor. The debounced write may not have run yet, so the
    /// grade is persisted here rather than trusted to a task that is about to
    /// be torn down with the view.
    private func finishExit() {
        isOfferingPresetSave = false
        persist()
        // Typed overlay text has no release gesture — its only mid-session
        // commit is the 2 s safety net, which dies with the view.
        persistOverlays()
        // The library write is asynchronous now; drain it before the editor
        // goes away so closing the app right after closing the editor can't
        // lose the last gesture.
        model.flushLibraryPersists()
        if let onExit { onExit() } else { dismiss() }
    }

    private func render() async {
        let preset = preset
        // The moment on screen, not the project's stored grade: with keyframes
        // those are only the same thing at the head of the clip. Less its
        // crop: the editor never cuts the picture (decision 3) — the crop is
        // drawn over the whole levelled frame — and stripping it here rather
        // than only asking for the frame uncut keeps the grader's cache key,
        // and so the picture, exactly where they were through a crop drag.
        let adjustments: PhotoAdjustments = {
            var moment = timeline.adjustments(at: renderedPosition, baseline: self.adjustments)
            moment.crop = nil
            return moment
        }()
        let url = hasTimeline ? frames[frameIndex(at: renderedPosition)] : url
        // This frame's own declared white. Frozen to a fixed one before the
        // hop: the render is off the main actor, and a smoothed track's answer
        // depends on where the playhead is now, not where it is when the
        // render lands.
        let whiteBalance = frozenWhiteBalance(at: renderedPosition)
        await refreshAsShotAnchor(for: url)
        // A sweep renders smaller: a 2000px still per step is a render the
        // machine can't finish before the next one cancels it.
        let longEdge: CGFloat = isScrubbing || isPlaying ? 1100 : previewLongEdge
        isRendering = true
        // Everything the composite needs, copied before the hop: the overlay
        // list at its animation phase, the dragged overlay left out (the
        // SwiftUI proxy is showing it), and the mask by cache key only — the
        // composite path can read a cached mask but never generate one.
        // Layers as THIS moment's frame shows them (stored at the opening
        // level, carried into a travelling level per frame — the export does
        // the same in `OverlayExportBake.overlays(at:)`).
        let overlays = overlayDocument.overlays.map(displayOverlay)
        // The grades applied inside a mask, as the composite wants them: only
        // the ones that would move a pixel, in list order.
        let maskGrades = overlayDocument.maskGrades.filter(\.isActive)
        // The dragged layer AND its travelling followers: all of them are
        // being carried by proxies until the gesture ends.
        let suppressed = overlayDrag.map { Set([$0.id] + $0.followers.keys) } ?? []
        let compositePosition = renderedPosition
        let maskSettings = overlayDocument.maskSettings
        let masks = previewMaskSet()
        let debugRegion = tintedRegion
        let rotation = Double(adjustments.rotationDegrees)
        let image = await MediaWorkQueue.grading.run { () -> CGImage? in
            // Levelled inside the grader (cached with the grade, at this
            // moment's angle); the compositor is told so its source-space
            // masks turn to match.
            guard let graded = PhotoGrader.render(
                url: url, preset: preset, adjustments: adjustments,
                whiteBalance: whiteBalance, maxDimension: longEdge, cropped: false)
            else { return nil }
            return SceneAwareCompositor.compositedPreview(
                base: graded, overlays: overlays, maskGrades: maskGrades,
                suppressing: suppressed,
                position: compositePosition, masks: masks,
                settings: maskSettings, debugRegion: debugRegion,
                rotationDegrees: rotation)
        }
        isRendering = false
        // A nil render (cancelled, or a missing file) leaves whatever is on
        // screen rather than blanking the viewer. The double optional is the
        // work queue's own "didn't run" wrapped around the grader's "couldn't".
        if let image, let cgImage = image {
            rendered = cgImage
            reconcileAspect(with: cgImage)
            await locateDetail(in: cgImage, of: url)
        }
    }

    /// Points the loupe at the busiest part of this frame — once per frame, off
    /// the preview that just landed, so nothing extra is decoded for it.
    private func locateDetail(in image: CGImage, of frame: URL) async {
        // Not during a sweep: a scrub renders a frame every few milliseconds,
        // and the loupe isn't on screen for any of them.
        guard !isScrubbing, !isPlaying, focusedFrame != frame else { return }
        focusedFrame = frame
        guard let point = await MediaWorkQueue.shared.run({
            PhotoDetailFocus.busiestPoint(in: image)
        }) else { return }
        detailFocus = point ?? CGPoint(x: 0.5, y: 0.5)
    }

    /// The rendered image is the last word on shape. If it disagrees with the
    /// metadata probe by more than a rounding error the probe read the
    /// orientation wrong, and the layout would otherwise hold a portrait photo
    /// in a landscape slot for the life of the screen.
    private func reconcileAspect(with image: CGImage) {
        guard image.height > 0 else { return }
        let measured = Double(image.width) / Double(image.height)
        guard measured > 0 else { return }
        if let aspect, abs(measured - aspect) / aspect <= 0.01 { return }
        aspect = measured
    }

    // MARK: - Detail renders
    //
    // Two surfaces want the same thing — a piece of the frame graded at the
    // source's own resolution — and both key their render on a value rather
    // than firing off a task per tick, so a slider drag collapses into one
    // render and a pan doesn't queue one per pixel of travel.

    /// True while anything on screen needs full-resolution pixels.
    private var isPeeping: Bool { !zoom.isFitted || loupeField != nil }

    /// The grade being asked for, as one comparable string.
    private var gradeToken: String {
        PhotoGrade(preset: preset, adjustments: displayedAdjustments).cacheToken
    }

    /// What the visible-region patch is keyed on. Nil whenever the preview
    /// render is already showing as much as the screen can — which is every
    /// state but a real zoom-in.
    private var patchRequest: DetailPatchRequest? {
        guard loaded, !isScrubbing, !isPlaying, !zoom.isFitted else { return nil }
        let geometry = zoomGeometry(in: paneSize)
        guard geometry.container.width > 0, geometry.container.height > 0 else { return nil }
        let source = sourcePixelSize
        let drawn = geometry.drawnSize(scale: zoom.scale)
        let previewWidth = source.width * min(1, previewLongEdge / max(source.width, source.height))
        // Nothing to add when the preview already holds every pixel the file
        // has — a small JPEG is decoded whole, so a "full-resolution" patch of
        // it would be the same picture at the cost of a decode.
        guard previewWidth < source.width - 0.5 else { return nil }
        // Below this the preview has pixels to spare and a patch would be a
        // full-resolution decode for no visible gain.
        guard drawn.width * displayScale > previewWidth * 1.05 else { return nil }

        let visible = geometry.visibleRegion(scale: zoom.scale, offset: zoom.offset)
        let region = Self.quantised(visible.insetBy(
            dx: -visible.width * 0.12, dy: -visible.height * 0.12))
        let pixels = CGSize(
            width: (region.width * source.width).rounded(),
            height: (region.height * source.height).rounded())
        // A region this big is a low zoom over a large frame; the preview is
        // adequate there, and grading twelve megapixels per pan would not be.
        guard max(pixels.width, pixels.height) <= 3200 else { return nil }
        return DetailPatchRequest(
            url: displayedURL, grade: gradeToken,
            centre: CGPoint(x: region.midX, y: region.midY), pixels: pixels)
    }

    /// What the loupe is keyed on. Nil unless a Detail slider is under a
    /// finger, which is the only time it is on screen.
    ///
    /// Also nil on a source the screen already shows at actual pixels or
    /// better — the picture itself is then the loupe, and a chip showing the
    /// same pixels smaller would only cover it up.
    private var loupeRequest: DetailPatchRequest? {
        guard loaded, loupeField != nil else { return nil }
        guard zoomGeometry(in: paneSize).hasPixelsToReveal else { return nil }
        let side = (loupeSide(in: paneSize) * displayScale).rounded()
        guard side > 0 else { return nil }
        return DetailPatchRequest(
            url: displayedURL, grade: gradeToken, centre: detailFocus,
            pixels: CGSize(width: side, height: side))
    }

    /// Snapped to a 32nd of the frame, so panning inside the margin the region
    /// already carries doesn't ask for a new render.
    private static func quantised(_ region: CGRect, step: CGFloat = 1.0 / 32) -> CGRect {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let x0 = max((region.minX / step).rounded(.down) * step, 0)
        let y0 = max((region.minY / step).rounded(.down) * step, 0)
        let x1 = min((region.maxX / step).rounded(.up) * step, 1)
        let y1 = min((region.maxY / step).rounded(.up) * step, 1)
        return CGRect(x: x0, y: y0, width: max(x1 - x0, step), height: max(y1 - y0, step))
            .intersection(unit)
    }

    private func renderPatch() async {
        guard let request = patchRequest else { return }
        // Long enough that a drag collapses into one render, short enough that
        // letting go of the picture snaps it sharp.
        try? await Task.sleep(for: .milliseconds(140))
        guard !Task.isCancelled else { return }
        if let patch = await renderedPatch(for: request) { detailPatch = patch }
    }

    private func renderLoupe() async {
        guard let request = loupeRequest else { return }
        // Shorter than the preview's: the loupe is what the eye is on while
        // the slider moves, so it has to keep up with it.
        try? await Task.sleep(for: .milliseconds(60))
        guard !Task.isCancelled else { return }
        if let patch = await renderedPatch(for: request) { loupePatch = patch }
    }

    private func renderedPatch(for request: DetailPatchRequest) async -> PhotoGrader.DetailPatch? {
        let preset = preset
        let adjustments = displayedAdjustments
        let result = await MediaWorkQueue.grading.run {
            PhotoGrader.renderDetail(
                url: request.url, preset: preset, adjustments: adjustments,
                center: request.centre, pixelSize: request.pixels)
        }
        // The work queue's own "didn't run" wrapped around the grader's
        // "couldn't" — either way, leave what is on screen alone.
        return result ?? nil
    }

    /// One request for a piece of the frame at source resolution.
    private struct DetailPatchRequest: Equatable {
        var url: URL
        var grade: String
        var centre: CGPoint
        var pixels: CGSize
    }

    /// What the preview render is keyed on: the grade, the frame it is being
    /// asked for, and whether the request is part of a live sweep. Frame rather
    /// than position, so the ladder of positions a scrub walks collapses into
    /// one render per frame instead of one per pixel of travel.
    ///
    /// The count is in there because the same index means a different still
    /// once frames are hidden or shown — without it, flipping the toggle would
    /// leave the previous frame's render on screen.
    private struct RenderRequest: Equatable {
        var token: Int
        var frame: Int
        var frameCount: Int
        var live: Bool
    }

    /// `LL_SECTIONS=color:mixer:<band>` (DEBUG), handed to the panel as its
    /// opening band; nil in every other build.
    @State private var hookBand: HSLAdjustments.Band?

    #if DEBUG
    /// `LL_PERFWIGGLE=<seconds>` drives the exposure control through the same
    /// binding a finger on the slider drives, in bursts — ~0.7 s of 60 Hz
    /// ticks, ~0.35 s pause — for that many seconds, then prints the achieved
    /// in-burst tick rate. The bench instrument for
    /// docs/editor-performance-plan.md: every tick pays exactly what a slider
    /// tick pays (state writes, `refreshState`, render scheduling, body
    /// invalidation), and the pauses let the debounced settle work (persist +
    /// render) fire the way real drags let it. A saturated main thread can't
    /// hit 60 — the achieved rate IS the responsiveness measurement.
    /// One wiggle per process: window restoration (or a second editor
    /// instance) must not run a second loop and halve the measured rate.
    private static var perfWiggleRan = false

    private func applyPerfWiggleHook() {
        guard let raw = ProcessInfo.processInfo.environment["LL_PERFWIGGLE"],
              let seconds = Double(raw), seconds > 0 else { return }
        guard !Self.perfWiggleRan else { return }
        Self.perfWiggleRan = true
        Task { @MainActor in
            // Let the first render land so the run measures a settled editor.
            try? await Task.sleep(for: .seconds(3))
            let started = Date()
            var ticks = 0
            var burstTicks = 0
            var burstStarted = Date()
            var rates: [Double] = []
            print("🧪LL perfwiggle: starting \(Int(seconds))s, 60 Hz bursts")
            while Date().timeIntervalSince(started) < seconds {
                let elapsed = Date().timeIntervalSince(burstStarted)
                if elapsed >= 0.7 {
                    let rate = Double(burstTicks) / elapsed
                    rates.append(rate)
                    print(String(format: "🧪LL perfwiggle: burst %.1f ticks/s", rate))
                    burstTicks = 0
                    try? await Task.sleep(for: .milliseconds(350))
                    burstStarted = Date()
                    continue
                }
                let t = Date().timeIntervalSince(started)
                var values = editedAdjustments.wrappedValue
                values.exposure = Float(sin(t * 4) * 2)
                editedAdjustments.wrappedValue = values
                ticks += 1
                burstTicks += 1
                try? await Task.sleep(for: .milliseconds(16))
            }
            let total = Date().timeIntervalSince(started)
            let median = rates.sorted()[max(0, rates.count / 2 - (rates.count.isMultiple(of: 2) ? 1 : 0))]
            print(String(
                format: "🧪LL perfwiggle: DONE %d ticks in %.1fs, median burst %.1f ticks/s (60 = ideal)",
                ticks, total, median))
        }
    }

    /// `LL_KEYFRAMES=sunset` stages the design's own scenario on an interval
    /// project — three moments across the shoot, playhead between the first
    /// two — and `LL_KEYFRAMES=empty` the first-run state the empty spec draws.
    /// Neither is reachable by automation: making them for real means scrubbing
    /// a two-hour shoot and dragging sliders at three separate moments.
    /// `LL_TEXT=story[,toast][,craft]` — stages the design pass's four-layer Prague
    /// story on a project that has NO text yet (a project with layers is
    /// left alone: the 2 s safety net would otherwise write the staging
    /// over real work), opens the Text tab, and parks the playhead at 13%
    /// so the first line is mid-bounce. `toast` also floats the link
    /// confirmation. Reveal timings and links are the mock's own, so the
    /// lanes drawn in `photo-viewer.text.svg` are measured from this.
    private func applyTextHook() {
        guard let hook = ProcessInfo.processInfo.environment["LL_TEXT"], frames.count > 1 else { return }
        let parts = hook.split(separator: ",").map(String.init)
        // `crafted` stages what Add Crafted Text produces — the design's own
        // beach line, through the real splitter, layout and insert — so the
        // crafted result can be measured for its mirror without a model
        // installed and without typing into the sheet.
        if parts.contains("crafted"), overlayDocument.overlays.isEmpty {
            stageCraftedText()
            return
        }
        guard parts.contains("story"), overlayDocument.overlays.isEmpty else { return }
        func layer(
            _ runs: [TextRun], label: String = "", size: Double, x: Double, y: Double, bold: Bool,
            color: String = "#FFFFFF", reveal: OverlayReveal, exit: OverlayReveal?
        ) -> SceneOverlay {
            var content = TextOverlayContent(runs: runs)
            content.isBold = bold
            content.colorHex = color
            var out = SceneOverlay(content: .text(content))
            out.label = label
            out.size = size
            out.centerX = x
            out.centerY = y
            out.animation = OverlayAnimation(reveal: reveal, exit: exit)
            return out
        }
        let fadeOut = OverlayReveal(unit: .element, style: .fade, start: 0.80, end: 0.86)
        var l1 = layer(
            [TextRun(text: "Don't "), TextRun(text: "you", isBold: true), TextRun(text: " think")],
            label: "Intro top", size: 0.056, x: 0.277, y: 0.155, bold: false,
            reveal: OverlayReveal(unit: .character, style: .bounce, start: 0.08, end: 0.20), exit: fadeOut)
        var l2 = layer(
            [TextRun(text: "Prague")], size: 0.16, x: 0.55, y: 0.245, bold: true,
            reveal: OverlayReveal(unit: .element, style: .fade, start: 0.20, end: 0.28), exit: fadeOut)
        var l3 = layer(
            [TextRun(text: "is worth a "), TextRun(text: "LITTLE", colorHex: "#3A3A3C"), TextRun(text: " visit?")],
            size: 0.056, x: 0.70, y: 0.385, bold: true,
            reveal: OverlayReveal(unit: .character, style: .bounce, start: 0.28, end: 0.40), exit: fadeOut)
        var l4 = layer(
            [TextRun(text: "visitprague.com")], size: 0.072, x: 0.70, y: 0.925, bold: true, color: "#F3E37C",
            reveal: OverlayReveal(unit: .element, style: .fade, start: 0.42, end: 0.48), exit: nil)
        l1.textStyle?.isBold = true
        l2.animation?.follows = OverlayFollow(layerID: l1.id, gap: 0)
        l3.animation?.follows = OverlayFollow(layerID: l2.id, gap: 0)
        // The URL in the corner is the design's own example of a layer that
        // waits its turn but does NOT travel: dragging the line above it
        // leaves it pinned bottom-right, where a byline belongs.
        l4.animation?.follows = OverlayFollow(layerID: l3.id, gap: 0.02, independentPosition: true)
        overlayDocument.overlays = [l1, l2, l3, l4]
        overlayDocument.resolveFollows()
        selectedOverlayID = l1.id
        railTab = .text
        position = 0.13
        renderedPosition = 0.13
        if parts.contains("toast") { showOverlayToast("Linked — starts after “\(l1.displayName)”") }
        // `craft` opens the Crafted Text sheet over the staged story, which
        // is the state its own design mirror is measured from.
        if parts.contains("craft") { railCrafting = true }
    }

    /// `LL_TEXT=crafted` — runs a brief through the same path the sheet's
    /// Send does (splitter → `CraftedTextLayout` → `OverlayDocument.addCrafted`)
    /// and parks the playhead where the copy has arrived.
    private func stageCraftedText() {
        let brief = "A little sand between your toes helps wash away the woes"
        let parts = CraftedTextLayout.split(brief)
        let lines = CraftedTextLayout.lines(
            for: parts, aspect: sourceAspect,
            measure: { copy, style in
                TextOverlayRasterizer.emWidth(of: copy, family: nil, isBold: style.isBold)
            })
        overlayDocument.addCrafted(
            lines, at: 0.35, hasTimeline: frames.count > 1, fontFor: { _ in nil })
        selectedOverlayID = overlayDocument.overlays.first?.id
        railTab = .text
        position = 0.35
        renderedPosition = 0.35
    }

    /// `LL_MIXER=demo[:hue|saturation|luminance]` stages the Color Mixer and
    /// Dehaze with values worth looking at — a warm sky pulled down, the
    /// greens turned and dimmed, Dehaze up — WITHOUT persisting: the values
    /// go straight onto the grade in memory and `persist()` is switched off
    /// for the editor's life, so a screenshot run cannot leave a design's
    /// numbers in somebody's shoot. The mirrors in `docs/design` are measured
    /// from this. Pair with `LL_SECTIONS=mixer[:axis]` on the stacked layout.
    private func applyMixerHook() {
        guard let hook = ProcessInfo.processInfo.environment["LL_MIXER"],
              hook.hasPrefix("demo") else { return }
        persistSuppressedForStaging = true
        var panel = HSLAdjustments()
        panel[saturation: .blue] = -0.62
        panel[saturation: .aqua] = -0.40
        panel[luminance: .blue] = -0.25
        panel[hue: .green] = 0.18
        panel[saturation: .green] = -0.15
        panel[luminance: .green] = -0.20
        panel[saturation: .orange] = 0.30
        panel[luminance: .orange] = 0.12
        var values = displayedAdjustments
        values.hsl = panel
        values.dehaze = 0.35
        values.clarity = 0.20
        editedAdjustments.wrappedValue = values
        refreshState()
        scheduleUpdate()
    }

    private func applyKeyframeHook() {
        guard let hook = ProcessInfo.processInfo.environment["LL_KEYFRAMES"],
              frames.count > 1 else { return }
        guard hook != "empty" else {
            adjustments = .neutral
            timeline = .empty
            position = 0
            renderedPosition = 0
            refreshState()
            return
        }
        func moment(
            kelvin: Double, exposure: Float, highlights: Float,
            shadows: Float, vibrance: Float
        ) -> PhotoAdjustments {
            var values = PhotoAdjustments.neutral
            // An OWNED white: the Temp and Tint controls bind `whiteMired` /
            // `whiteTint`, and the legacy `temperature` offset — which this
            // hook used to stage — has no control left to show it, so the
            // boards' keyframed Temp could never be reproduced. Every moment
            // owns one, which is the invariant `seedUnownedWhites` keeps for
            // real edits (a 0 beside an owned white would ease toward
            // infinite Kelvin).
            values.whiteMired = Float(1e6 / kelvin)
            values.whiteTint = 0
            values.exposure = exposure
            values.highlights = highlights
            values.shadows = shadows
            values.vibrance = vibrance
            return values
        }
        preset = .natural
        var baseline = PhotoAdjustments.neutral
        var staged = GradeTimeline.empty
        staged.write(
            moment(kelvin: 6100, exposure: 0, highlights: -0.20,
                   shadows: 0.10, vibrance: 0.12),
            at: 0.10, baseline: &baseline)
        staged.write(
            moment(kelvin: 7600, exposure: -0.20, highlights: -0.35,
                   shadows: 0.18, vibrance: 0.38),
            at: 0.52, baseline: &baseline)
        staged.write(
            moment(kelvin: 5400, exposure: -0.50, highlights: -0.10,
                   shadows: 0.30, vibrance: 0.10),
            at: 0.86, baseline: &baseline)
        timeline = staged
        adjustments = baseline
        position = 0.30
        renderedPosition = 0.30
        refreshState()
    }

    /// `LL_SECTIONS=<group>[:<tool>[:<band>]]` opens a group's panel with a
    /// tool chip up, the way the screenshot recipes ask for it (spec §7):
    /// `presets|light|color|effects|detail|crop`, with `expcon|highwhites|
    /// shadblacks|wb|vibsat|mixer|texclar|vignette|dehaze|sharpen|noise` as
    /// the chip. The old names still answer — `wb` → color:wb,
    /// `mixer[:axis]` → color:mixer, `rotation` → crop, `all` → light — so
    /// the existing design recipes keep working. The band suffix — a band's
    /// Lightroom name, `orange` or `aqua` — lands in `hookBand`, which the
    /// panel takes as its `initialBand` so the mixer opens on that band. On
    /// every layout this is "open the panel"; there is nothing to scroll to
    /// any more.
    private func applySectionsHook() {
        guard let hook = ProcessInfo.processInfo.environment["LL_SECTIONS"] else { return }
        let parts = hook.split(separator: ":").map { String($0).lowercased() }
        guard let name = parts.first else { return }
        var tool = parts.count > 1 ? EditorTool.allCases.first { $0.hookName == parts[1] } : nil
        // `mixer:<band>` — the band by its Lightroom name, in either form.
        let bandNames = parts.dropFirst(name == "mixer" ? 1 : 2)
        hookBand = bandNames.first.flatMap { token in
            HSLAdjustments.Band.allCases.first { $0.lightroomName.lowercased() == token }
        }
        let group: EditorGroup?
        switch name {
        case "wb":
            group = .color
            tool = .whiteBalance
        case "mixer":
            group = .color
            tool = .mixer
        case "rotation":
            group = .crop
        case "all":
            group = .light
        default:
            group = EditorGroup.allCases.first { $0.hookName == name }
        }
        guard let group else { return }
        if let tool, tool.group == group { toolSelection[group] = tool }
        openPanel(for: group)
    }
    #endif
}

/// The phone layout's bottom stack, measured so the picture's corner chrome
/// can clear it.
private struct EditorFootHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The floating card's size, measured so a drag can keep it on screen.
private struct EditorPanelSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

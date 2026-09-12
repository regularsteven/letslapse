import AVFoundation
import AVKit
import LetsLapseKit
import SwiftUI

#if os(macOS)
/// Identifies one video-editor window on the Mac — the video-project sibling
/// of `PhotoEditorWindowRequest`, with the same restore/front semantics.
struct VideoEditorWindowRequest: Hashable, Codable {
    let captureID: UUID
    let url: URL
    let title: String
}
#endif

/// The video project's editor: the movie playing at its true aspect ratio,
/// the same six main buttons the photo editor has — Presets · Light · Color ·
/// Effects · Detail · Crop — and the one group panel they open. The grade
/// rides the player as a live video composition — scrub or play to any moment
/// and that frame renders through the current controls, which is the whole
/// point: seeing what an edit does to the footage, not to one thumbnail.
///
/// The Editor page has the photo editor's three dressings, chosen from the
/// container's size and shape (`editorLayout(for:)`): the phone's bottom
/// stack over a player that has the whole screen (boards 2a / 6a — iPad
/// portrait follows it), the landscape iPad's floating card beside an
/// anchored player (5a / 6b), and the rail beside the player (3b / 6c on the
/// Mac, drawn dark on a landscape iPhone). The Text page keeps the older
/// split: past `wideLayoutThreshold` a side rail, below it the player pinned
/// above a scrolling control stack. A panel opens on a snapshot of the grade
/// and its ✓ / ✕ keep or restore it (`openPanel(for:)`, `commitPanel`,
/// `cancelPanel`).
///
/// The movie's differences from the photo editor, all deliberate: the player
/// IS the preview, so nothing draws a crop frame over it this stage (the crop
/// bakes at export) and there is no zoom, no loupe and no WB Auto — a movie
/// has no raw white to declare; the Presets tiles render through
/// `VideoGrader.gradedFrame`; the snapshot is the grade alone, since a movie
/// carries no text layers and no white-balance source of its own.
struct VideoEditorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var presetStore = CustomPresetStore.shared

    let captureID: UUID
    let url: URL

    /// Live edit state. Seeded from the project on appear and written back —
    /// debounced — as the controls move, exactly like the photo editor.
    @State private var preset: PhotoPreset = .default
    @State private var adjustments: PhotoAdjustments = .neutral
    /// Which of the three states the live values are in — re-resolved on every
    /// change, so the pill flips to Edited the instant a slider leaves the
    /// applied preset. See `PhotoViewerView` for the same pattern on stills.
    @State private var presetState: PresetState = .original
    @State private var loaded = false

    @State private var player = AVPlayer()
    @State private var asset: AVURLAsset?

    // MARK: Keyframes
    //
    // A movie has length, so its grade can travel across it. See
    // `GradeTimeline`; the strip is the same component the interval editor
    // shows, over the movie's own clock instead of the capture clock an
    // interval shoot was shot on.

    @State private var timeline: GradeTimeline = .empty
    /// The playhead, 0…1 of the movie. Followed from the player while it plays
    /// and pushed back into it when the strip is scrubbed.
    @State private var position: Double = 0
    @State private var isScrubbing = false
    @State private var isPlaying = false
    @State private var duration: Double = 0
    @State private var timeObserver: Any?
    /// Bumped by every control change; the debounce task keys off it so a
    /// slider drag collapses into one manifest write and one composition swap.
    @State private var renderToken = 0

    @State private var isNamingPreset = false
    @State private var newPresetName = ""
    @State private var presetPendingDelete: CustomPreset?
    /// A tile tap held back for confirmation: applying it from Edited would
    /// discard the manual adjustments on screen.
    @State private var pendingApply: PresetApplyRequest?
    /// The "Save as preset?" offer raised on the way out of an Edited grade.
    @State private var isOfferingPresetSave = false
    /// Set while that offer is what sent the user into the naming alert.
    @State private var exitsAfterPresetSave = false
    /// "Not now" on the inline offer, where there is no exit to leave through.
    @State private var declinedPresetSave = false

    /// The movie's display aspect (w ÷ h). Unlike the photo editor this is
    /// normally known before the first frame: a video capture already carries
    /// its oriented size on the project.
    @State private var aspect: Double?
    /// Where the drag handle sits, as a fraction between the floor and the
    /// ceiling. 1 = the ceiling, which is where every presentation starts.
    /// Only the Text page still has a handle: the Editor page's layouts give
    /// the player the whole screen.
    @State private var mediaScale: CGFloat = 1

    /// Which rail page is showing — see `RailTabBar`.
    @State private var railTab: RailTab = .editor

    // MARK: Editor groups
    //
    // The redesign's Editor page: six main buttons, one group's panel open
    // at a time, and a ✓/✕ on the panel that keeps or throws away what was
    // done since it opened. The state below is the page's, not the panel's —
    // the panel is torn down and rebuilt as it opens and closes, so anything
    // that has to outlive one opening lives here. Mirrors `PhotoViewerView`.

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
    /// The editor's container, for clamping the card once a drag ends.
    @State private var containerSize: CGSize = .zero
    /// The Presets panel's tile renders. Owned here so they survive the
    /// phone sheet being torn down between opens.
    @StateObject private var presetThumbnails = PresetThumbnailCache()

    /// Everything ✕ has to put back. With a timeline an edit lands in the
    /// keyframes, not in `adjustments`, and a preset tap moves `preset` and
    /// the state — so all four go back together. A movie has no text layers
    /// and no white-balance source of its own, which is why this is shorter
    /// than the photo editor's snapshot.
    private struct EditorSnapshot {
        var preset: PhotoPreset
        var adjustments: PhotoAdjustments
        var timeline: GradeTimeline
        var presetState: PresetState
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

    /// Below this width the player is pinned above the controls instead of
    /// sitting beside them — the Text page's split, and the shape gate the
    /// Editor page's rail shares.
    private let wideLayoutThreshold: CGFloat = 500
    /// How the player is sized and how far the handle may shrink it — the same
    /// component the photo editor and the project hero lay out with.
    private var metrics: MediaPaneMetrics { MediaPaneMetrics(aspect: aspect) }
    /// A touch longer than the photo editor's 100ms: swapping the video
    /// composition restarts the item's render pipeline, so a drag shouldn't
    /// thrash it.
    private let renderDebounce: Duration = .milliseconds(150)

    /// The white a movie renders at while nothing owns one: D65, the sRGB
    /// white its frames are encoded against (`VideoGrader.filterChain`). A
    /// movie carries no as-shot reading and no smoothed track, so this is
    /// the one rest point — and what the panel's Temp / Tint controls sit on
    /// through their defaults.
    private static let restWhiteMired: Float = 1e6 / 6500

    private var capture: AppModel.CaptureProject? {
        model.captures.first { $0.id == captureID }
    }

    /// True when this editor owns the way out — the back button it draws on
    /// iOS. The Mac window's close button isn't ours to intercept, so there the
    /// "Save as preset?" offer sits inline in the rail instead.
    private var ownsExit: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    /// Amber over the dark editor; the light Mac window keeps the app accent.
    private var accentColor: Color {
        #if os(iOS)
        return LL.amber
        #else
        return LL.accent
        #endif
    }

    /// Side-rail width. Fixed on macOS — resizing the window grows the movie,
    /// never the controls — at the redesign's 330 (board 3b). Capped-
    /// proportional on iOS/iPadOS.
    private func railWidth(in totalWidth: CGFloat) -> CGFloat {
        #if os(macOS)
        return 330
        #else
        return min(340, totalWidth * 0.42)
        #endif
    }

    /// Which Editor-page layout a container gets — the photo editor's rule,
    /// verbatim. Width AND shape, because the touch layouts are about where
    /// the hand is: a landscape iPad is the floating card (5a); anything
    /// else at least `wideLayoutThreshold` wide — a landscape iPhone, a wide
    /// split, iPad portrait — is the dark rail; the rest — every iPhone
    /// portrait, Slide Over — is the phone's bottom stack (2a). No idiom
    /// check anywhere: the size decides. The Mac is always the rail.
    private func editorLayout(for size: CGSize) -> EditorLayout {
        #if os(macOS)
        return .rail
        #else
        if size.width >= 900, size.width > size.height { return .floating }
        if size.width >= wideLayoutThreshold { return .rail }
        return .phone
        #endif
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                // The Editor page has the redesign's three layouts; the Text
                // page keeps the rail-or-stacked split it was drawn with.
                if railTab == .editor {
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
        #endif
        .task {
            // Seed once from the project, then let this view own the values.
            guard !loaded, let capture else { return }
            preset = model.photoPreset(for: capture)
            adjustments = model.photoAdjustments(for: capture)
            presetState = model.presetState(for: capture)
            loaded = true
            // The project already knows the oriented size for a video capture,
            // so the player is laid out correctly on the very first frame.
            if let width = capture.sourceWidth, let height = capture.sourceHeight,
               width > 0, height > 0 {
                aspect = Double(width) / Double(height)
            }
            timeline = model.gradeTimeline(for: capture)
            let asset = AVURLAsset(url: url)
            self.asset = asset
            // The clip's length, before the first composition: a keyframed
            // grade has no position to render at without it.
            duration = (try? await asset.load(.duration))?.seconds ?? 0
            let item = AVPlayerItem(asset: asset)
            item.videoComposition = VideoGrader.composition(
                for: asset, grade: liveGrade, durationSeconds: duration)
            player.replaceCurrentItem(with: item)
            observePlayerTime()
            player.play()
            // Then correct from the file itself: the project's stored size
            // latches on the first segment, and a metadata-only rotate swaps it.
            if let size = await MediaGeometry.videoDisplaySize(asset: asset), size.height > 0 {
                aspect = size.width / size.height
            }
            #if DEBUG
            if ProcessInfo.processInfo.environment["LL_VIEWER"] == "expanded" {
                // The handle dragged all the way up — the state the "expanded"
                // design spec draws. Only the Text page still has a handle:
                // on the Editor page the player already has the whole screen,
                // so there this is a no-op.
                mediaScale = 0
            }
            applyKeyframeHook()
            applySectionsHook()
            #endif
        }
        .task(id: renderToken) {
            guard loaded else { return }
            try? await Task.sleep(for: renderDebounce)
            guard !Task.isCancelled else { return }
            applyGradeToPlayer()
        }
        // Persist safety net — slider gestures persist on release; this
        // catches edits that arrive without a grab/release pair (WB
        // quick-picks, double-tapped pad resets). See the photo editor.
        .task(id: renderToken) {
            guard loaded else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            persist()
        }
        // The Gallery panel's Text button asking for a page — `onReceive` so a
        // Mac window that was merely fronted hears it too (see the photo editor).
        .onReceive(model.$requestedEditorPage) { consumePageRequest($0) }
        .onDisappear {
            player.pause()
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            timeObserver = nil
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
            Text("Saves the \(preset.displayName) grade and these adjustments so you can apply them to another project.")
        }
        .alert(item: $pendingApply) { request in
            Alert(
                title: Text(request.confirmationTitle),
                message: Text(request.confirmationMessage),
                primaryButton: .destructive(Text(request.confirmationButton)) { apply(request) },
                secondaryButton: .cancel())
        }
        .alert(item: $presetPendingDelete) { target in
            Alert(
                title: Text("Delete “\(target.name)”?"),
                message: Text("This removes the saved preset everywhere. Projects already using it keep their current grade."),
                primaryButton: .destructive(Text("Delete")) { presetStore.delete(target) },
                secondaryButton: .cancel()
            )
        }
    }

    private var editorBackground: some View {
        #if os(iOS)
        Color.black.ignoresSafeArea()
        #else
        LL.screenBackground
        #endif
    }

    // MARK: - Stacked layout (the Text page on a narrow container)

    /// The player pinned at the top with the controls scrolling beneath it. The
    /// player gets an exact frame so the scroll view can only take the room left
    /// over — the ordering that stops a greedy `ScrollView` claiming the screen.
    /// The Editor page never comes through here — `body` gives it its own
    /// layouts.
    private func stackedBody(in container: CGSize) -> some View {
        let media = metrics.frame(in: container, scale: mediaScale)
        let span = metrics.dragSpan(in: container)
        return VStack(spacing: 0) {
            playerPane
                .frame(width: media.width, height: media.height)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .top) { chrome }
            // Between the player and the controls, and on the player's side of
            // the handle: the strip says which moment is on screen, so it moves
            // with the picture rather than with the panel.
            if hasTimeline {
                timelineStrip(compact: false)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 2)
            }
            if span > 0 {
                MediaResizeHandle(scale: $mediaScale, span: span)
            }
            railTabBar
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 2)
            ScrollView(.vertical) {
                controlStack(isWide: false)
                    .padding(16)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    // MARK: - Chrome

    /// Floats over the player so the movie keeps the top of the screen. AVKit's
    /// own transport is bottom-anchored, so the two never meet.
    ///
    /// The back button and nothing else — see `PhotoViewerView.chrome` for why
    /// there is no title and no scrim. The rail and stacked layouts draw this;
    /// the touch Editor layouts draw `touchChrome`, which adds the tab pill.
    @ViewBuilder private var chrome: some View {
        #if os(iOS)
        HStack {
            backButton
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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

    /// The touch editors' top row over the player: the back button leading,
    /// the tab pill trailing (2a / 5a). The floating layout puts the marquee
    /// badge beside the back button.
    private func touchChrome(showsBadge: Bool) -> some View {
        HStack(spacing: 8) {
            backButton
            if showsBadge { marqueeBadge }
            Spacer(minLength: 8)
            EditorTabPill(selection: $railTab, tabs: availableRailTabs, accent: accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// `VIDEO · 1 min 7 s` — what the strip is measuring. A movie has a
    /// length and no frame count worth stating; until the asset has said how
    /// long it is, the badge reads `VIDEO` alone.
    private var marqueeBadge: some View {
        EditorMarqueeBadge(kind: .video, durationSeconds: duration, frameCount: nil)
    }

    /// The Crop group's one honesty line for a movie: the player is the
    /// preview and nothing draws the crop frame over it this stage — the
    /// aspect chips and the Angle slider still work, and the crop is baked
    /// when the clip is exported. The panel has no slot for a note under its
    /// aspect chips, so the owner says it over the player, in the badge's
    /// own dress, for exactly as long as the Crop panel is open.
    // MARK: - Player

    /// Given an exactly-aspect-correct frame, `VideoPlayer`'s `.resizeAspect`
    /// fills it — the footage is neither cropped nor letterboxed. The black
    /// behind it only ever shows through rounding residue. Given the whole
    /// screen (the phone layout) it letterboxes on black, which is the same
    /// black the editor paints behind the safe areas.
    private var playerPane: some View {
        VideoPlayer(player: player)
            .background(Color.black)
    }

    // MARK: - Editor page layouts
    //
    // Three dressings of one page (boards 2a / 5a / 3b, with the timeline on
    // 6a / 6b / 6c). Everything below is Editor-page only: the Text page
    // keeps `stackedBody` / `railBody` with its own rail.

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
    /// group at the moment under the playhead. A movie has no white-balance
    /// source to switch, so that leg of the rule always reads as-shot.
    private var nonNeutralGroups: Set<EditorGroup> {
        let values = displayedAdjustments
        return Set(EditorGroup.allCases.filter {
            !PhotoAdjustmentsPanel.isNeutral(
                $0, adjustments: values, keyframedFields: timeline.keyframedFields,
                whiteBalanceSource: .asShot, presetState: presetState)
        })
    }

    /// The movie's width ÷ height — what a locked crop aspect is fitted into,
    /// and what the floating layout sizes the player from. 16:9 until the
    /// project or the file has said otherwise, since that is what most
    /// movies are.
    private var pictureAspect: Double {
        if let aspect, aspect > 0 { return aspect }
        return 16 / 9
    }

    // MARK: Phone (2a / 6a)

    /// The player fills the safe area and everything else floats over it.
    /// Its foot carries the timeline card and then EITHER the six main
    /// buttons or the open group's sheet — one or the other, because on a
    /// phone the sheet needs the buttons' room. A landscape movie letterboxes
    /// in the middle of the screen, clear of the foot; a portrait one runs
    /// under it, as a tall photo does in the photo editor.
    private func phoneEditorBody(in container: CGSize) -> some View {
        ZStack(alignment: .bottom) {
            playerPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) { touchChrome(showsBadge: false) }
            phoneFoot
        }
    }

    @ViewBuilder private var phoneFoot: some View {
        VStack(spacing: 0) {
            if hasTimeline { phoneTimelineCard }
            if let group = openGroup {
                // The sheet's own material already runs under the home
                // indicator; it is placed at the safe area's foot and not
                // padded again.
                groupPanel(group, layout: .phone, style: .dark)
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

    // MARK: iPad landscape (5a / 6b)

    /// The player anchored top-left at the size its aspect gives it, the
    /// chrome in the corners, the strip and the buttons along the foot, and
    /// the open group as a card floating above the buttons — draggable by
    /// its header, or filling the height when it is Presets. No zoom: the
    /// player is the preview, and AVKit owns what happens inside it.
    private func floatingEditorBody(in container: CGSize) -> some View {
        let frame = floatingPictureFrame(in: container)
        return ZStack(alignment: .topLeading) {
            Color.black
            playerPane
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
            touchChrome(showsBadge: true)
                .frame(maxWidth: .infinity)
            floatingFootRow
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            floatingPanel(in: container)
        }
        .onPreferenceChange(VideoEditorPanelSizeKey.self) { floatingPanelSize = $0 }
    }

    /// 5a: full height for a tall movie, full width for a wide one, at the
    /// top-left. The photo editor centres the picture inside a 48 pt margin
    /// while Crop is open so the frame's handles have room; with no frame
    /// drawn over a movie there is nothing to make room for, so the player
    /// stays put.
    private func floatingPictureFrame(in container: CGSize) -> CGRect {
        CGRect(origin: .zero, size: Self.fit(aspect: pictureAspect, in: container))
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
                            Color.clear.preference(key: VideoEditorPanelSizeKey.self, value: proxy.size)
                        }
                    }
                    .offset(clampedFloatingOffset(floatingPanelOffset ?? .zero, in: container))
                    .padding(.bottom, 96)
                    .padding(.trailing, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
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

    // MARK: Rail (3b / 6c, and the wide Text page)

    /// The wide layout: the media column beside the rail. On the Editor page
    /// the rail is the redesign's (3b / 6c) and the strip sits in the board's
    /// 54 pt row under the player; the Text page keeps the rail and the strip
    /// it was drawn with.
    private func railBody(in container: CGSize) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                playerPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) { chrome }
                    .overlay(alignment: .topLeading) { railMediaBadge }
                // The scrubber belongs to the media, so it takes the player
                // pane's width rather than the rail's.
                if hasTimeline {
                    if railTab == .editor {
                        timelineStrip(compact: true)
                            .padding(.top, 6)
                            .padding(.horizontal, 16)
                            .frame(height: 54, alignment: .top)
                    } else {
                        timelineStrip(compact: true)
                            .padding(.horizontal, 18)
                            .padding(.top, 9)
                            .padding(.bottom, 4)
                    }
                }
            }
            Divider()
            controlRail
                .frame(width: railWidth(in: container.width))
        }
    }

    /// The marquee badge on the Mac's media pane — TOP-leading (12, 12)
    /// here, where 6c's photo editor keeps it bottom-leading: AVKit's
    /// transport bar rises over the player's foot on hover, and a chip
    /// there met it (settled 2026-09-13). The touch rail (a landscape
    /// iPhone) has no board with a badge. The Crop group's "shown on
    /// export" note lives under the panel's aspect chips (`cropNote`), not
    /// over the player.
    @ViewBuilder private var railMediaBadge: some View {
        #if os(macOS)
        if railTab == .editor {
            marqueeBadge
                .padding(12)
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

    /// The side rail is tall and narrow, so it scrolls on its own. On the
    /// Editor page the whole rail scrolls, tab pill included (3b / 6c: padded
    /// 14 top / 16 sides / 20 bottom with 12 between cards); on the Text page
    /// the tab switcher stays pinned above the scroll, as it always has.
    @ViewBuilder private var controlRail: some View {
        Group {
            if railTab == .editor {
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
                            .padding(.bottom, 16)
                    }
                }
            }
        }
        // A plain fill, not `editorBackground` — that one ignores the safe area,
        // which a rail inside the layout has no business doing. Forced dark
        // resolves this to black on iOS anyway.
        .background(LL.screenBackground)
    }

    /// The Editor page's rail (3b / 6c), top to bottom: the tab pill, the
    /// six main buttons, the open group's card, "Reset adjustments", and the
    /// save offer where there is no exit to make it on. No masks card: shapes
    /// are drawn on stills, and a movie has no Masks page to manage them
    /// from. All of it scrolls.
    @ViewBuilder private var railEditorStack: some View {
        railTabBar
        EditorGroupBar(
            selection: groupSelection, nonNeutral: nonNeutralGroups,
            style: .macCard, accent: accentColor)
        if let group = openGroup {
            groupPanel(group, layout: .rail, style: railPanelStyle)
        }
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
        // The Presets panel hosts the offer itself while it is open.
        if presetState.isEdited, !ownsExit, !declinedPresetSave, openGroup != .presets {
            presetSaveOffer
        }
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

    // MARK: - Controls

    /// The same tab structure as the photo/interval editor, so the two rails
    /// keep reading as one design. No Frames page: a movie has no source
    /// frame files to nominate. No Masks page either — shapes are drawn on
    /// stills, and Find shapes skips movies.
    private var availableRailTabs: [RailTab] { [.editor, .text] }

    private var railTabBar: some View {
        RailTabBar(
            selection: $railTab, tabs: availableRailTabs,
            accent: accentColor, onAccent: pillTextColor)
    }

    private var pillTextColor: Color {
        #if os(iOS)
        return .black
        #else
        return .white
        #endif
    }

    /// A page requested for this project's editor (`AppModel.requestedEditorPage`)
    /// — see the photo editor's twin. A page this rail doesn't have is consumed
    /// and ignored rather than left pending for a window that will never come.
    private func consumePageRequest(_ request: EditorPageRequest?) {
        guard let request, request.captureID == captureID else { return }
        if availableRailTabs.contains(request.page) { railTab = request.page }
        DispatchQueue.main.async {
            if model.requestedEditorPage == request { model.requestedEditorPage = nil }
        }
    }

    /// The non-Editor pages' content. The Editor page never comes through
    /// here — `body` gives it its own layouts — and the pages this rail does
    /// not offer are folded into the Text placeholder rather than left as
    /// an empty scroll, since `consumePageRequest` never selects them.
    @ViewBuilder private func controlStack(isWide: Bool) -> some View {
        switch railTab {
        case .editor:
            EmptyView()
        case .text, .frames, .masks:
            // Overlay rendering rides the photo/interval engine path in the
            // spike; the movie editor states that honestly instead of half
            // of it working.
            Text("Text overlays aren't wired into movie clips yet. Open an interval project's editor to place and animate text.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// "Save as preset?" — the offer made when an Edited grade is about to be
    /// left behind. The photo editor draws the same card; see it for why this
    /// is an inline invitation rather than a blocking alert.
    private var presetSaveOffer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save these edits as a preset?")
                .font(.system(size: 14.5, weight: .semibold))
            Text("Your adjustments stay on this project either way. Saving them makes the look reusable.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
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
    /// use. The white-balance parameters are left at their defaults on
    /// purpose: a movie renders anchored at D65 with no as-shot reading and
    /// no smoothed track, so the panel's rest point IS the movie's, the
    /// source menu entry stays hidden, and `autoWhite` is nil so the Auto
    /// button never appears — there is no raw white to estimate against.
    private func groupPanel(
        _ group: EditorGroup, layout: EditorPanelLayout, style: XYPadStyle
    ) -> some View {
        PhotoAdjustmentsPanel(
            adjustments: editedAdjustments,
            group: group,
            layout: layout,
            style: style,
            toolSelection: $toolSelection,
            playheadPosition: position,
            accent: accentColor,
            keyframedFields: timeline.keyframedFields,
            hasKeyframes: !timeline.isEmpty,
            onResetField: hasTimeline ? resetField : nil,
            onResetAll: hasTimeline ? resetEverything : nil,
            // A released control is a finished gesture — write the grade
            // through once, here, not per debounce settle mid-drag.
            onFieldEditing: { _, editing in
                if !editing { persist() }
            },
            presets: presetsContext,
            autoWhite: nil,
            cropFrameAspect: pictureAspect,
            // Nothing draws a crop frame over the player: the chips choose a
            // fitted crop the export cuts, and the hint says so.
            cropNote: "shown on export",
            onCommit: commitPanel,
            onCancel: cancelPanel,
            onHeaderDrag: layout == .floating ? floatingHeaderDragged : nil,
            initialBand: hookBand)
    }

    /// What the Presets group renders and does: the movie for the tiles
    /// (`.movie`, so the cache renders one graded frame through
    /// `VideoGrader.gradedFrame`), the built-in and saved presets, and the
    /// same apply / delete / save paths the chip strip used to drive. The
    /// inline save offer goes in here too, since the Presets panel is the
    /// page that is about the look as a whole. No Lightroom card: a sidecar
    /// describes a still.
    private var presetsContext: EditorPresetsContext {
        EditorPresetsContext(
            frame: capture.map { capture in
                PresetPreviewFrame(
                    captureID: capture.id, title: capture.displayTitle,
                    fileName: url.lastPathComponent,
                    source: .movie(url), isChosen: true)
            },
            presetState: presetState,
            customPresets: presetStore.presets,
            cache: presetThumbnails,
            onSelect: { request($0) },
            onDelete: { presetPendingDelete = $0 },
            onSaveAsPreset: {
                // A saved preset's name is the natural default; a built-in's
                // is not a name to reuse.
                newPresetName = presetState.snapshot.map { $0.isBuiltIn ? "" : $0.name } ?? ""
                isNamingPreset = true
            },
            saveOffer: presetState.isEdited && !ownsExit && !declinedPresetSave
                ? AnyView(presetSaveOffer) : nil,
            lightroomCard: nil)
    }

    // MARK: Opening, keeping, reverting

    /// A main button tapped. A different group already open is committed
    /// first — its snapshot dropped, its values kept — and the new group
    /// gets a fresh snapshot of them (spec §3: switching group commits and
    /// re-snapshots; the board's `openGroup`). The open group tapped again
    /// is left exactly as it is.
    private func openPanel(for group: EditorGroup) {
        if let open = openGroup {
            guard open != group else { return }
            editorSnapshot = nil
            persist()
        }
        editorSnapshot = takeSnapshot()
        openGroup = group
    }

    private func takeSnapshot() -> EditorSnapshot {
        EditorSnapshot(
            preset: preset, adjustments: adjustments, timeline: timeline,
            presetState: presetState)
    }

    /// ✓ / Done: the values stay, the snapshot goes, the panel closes.
    /// Persisted here as a finished gesture rather than left to the safety
    /// net — the panel may be the last thing before the back button.
    private func commitPanel() {
        editorSnapshot = nil
        openGroup = nil
        persist()
    }

    /// ✕ / Revert: everything back to what it was when the panel opened.
    /// Every release since opening has already been persisted, so the
    /// restore is persisted too — and the composition is swapped back, since
    /// the player is showing the edits being thrown away.
    private func cancelPanel() {
        if let snapshot = editorSnapshot {
            stopPlayback()
            preset = snapshot.preset
            adjustments = snapshot.adjustments
            withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) {
                timeline = snapshot.timeline
            }
            presetState = snapshot.presetState
            refreshState()
            renderToken += 1
            persist()
        }
        editorSnapshot = nil
        openGroup = nil
    }

    // MARK: - Keyframe surface

    /// Every movie has length, so every movie can carry a grade that travels —
    /// unlike the photo editor, where a Photo-mode capture is one still and the
    /// strip has nothing to scrub.
    private var hasTimeline: Bool { duration > 0 }

    private var liveGrade: PhotoGrade {
        PhotoGrade(preset: preset, adjustments: adjustments, timeline: timeline)
    }

    private var displayedAdjustments: PhotoAdjustments {
        timeline.adjustments(at: position, baseline: adjustments)
    }

    /// The strip, in the one place every layout pulls it from.
    @ViewBuilder private func timelineStrip(compact: Bool) -> some View {
        GradeTimelineView(
            position: $position,
            isScrubbing: $isScrubbing,
            keyframes: timeline.keyframes,
            label: GradeTimelineClock.labeller(duration: duration),
            isPlaying: isPlaying,
            compact: compact,
            accent: accentColor,
            onPlayToggle: {
                if isPlaying { player.pause() } else { player.play() }
                isPlaying = player.rate > 0
            },
            onScrub: seek,
            onScrubEnd: {},
            onDelete: deleteKeyframe)
    }

    /// The player is the preview, so a scrub of the strip is a seek. Zero
    /// tolerance: the whole point is standing on an exact moment, and a
    /// keyframe-accurate seek is what makes the grade under the playhead the
    /// grade on screen.
    private func seek(to next: Double) {
        guard duration > 0 else { return }
        player.pause()
        isPlaying = false
        player.seek(
            to: CMTime(seconds: duration * min(max(next, 0), 1), preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// A moment can't be graded while it is moving: dragging a control
    /// through a playing clip would spray keyframes along it, and a revert
    /// has to land on the moment that was on screen.
    private func stopPlayback() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
    }

    /// Follows the player while it plays, so the playhead and the controls both
    /// travel with the picture. Skipped while a scrub is live — the strip is
    /// driving then, and letting the player answer back would fight the finger.
    private func observePlayerTime() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main
        ) { time in
            isPlaying = player.rate > 0
            guard !isScrubbing, duration > 0 else { return }
            position = min(max(time.seconds / duration, 0), 1)
        }
    }

    /// What the panel reads and writes: the grade at the playhead. See
    /// `PhotoViewerView.editedAdjustments` — the rule is the same one, and it
    /// lives in `GradeTimeline.write`. A pad writes both of its fields in one
    /// assignment, so a drag is one keyframe write per tick here, not two.
    /// The crop is lifted out of the write and carried onto every moment
    /// (`GradeTimeline.carryCrop`): one crop for the whole movie, no keyframe
    /// for a crop-only change.
    private var editedAdjustments: Binding<PhotoAdjustments> {
        Binding(
            get: { displayedAdjustments },
            set: { incoming in
                guard hasTimeline else {
                    adjustments = incoming
                    refreshState()
                    renderToken += 1
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
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) {
                        timeline = updated
                    }
                } else {
                    timeline = updated
                }
                refreshState()
                renderToken += 1
            })
    }

    /// Gives every moment that does not yet own its white the white it is
    /// rendering at — for a movie, always D65 (`restWhiteMired`).
    ///
    /// The invariant this keeps is the photo editor's: **once any moment owns
    /// a white, every moment does.** Keyframes are whole panels interpolated
    /// field by field, and a white is stored in mired with 0 meaning "not
    /// owned" — so a moment left at 0 beside one that owns 200 would blend
    /// toward infinite Kelvin. Seeding the others with D65 is a no-op for
    /// their rendering (the chain is anchored there) and makes the
    /// transition to the edited moment run from a real white to a real one.
    private func seedUnownedWhites(in timeline: inout GradeTimeline) {
        for keyframe in timeline.keyframes where !keyframe.adjustments.ownsWhite {
            var values = keyframe.adjustments
            values.whiteMired = Self.restWhiteMired
            values.whiteTint = 0
            timeline.update(keyframe.id, to: values)
        }
    }

    private func resetField(_ field: PhotoAdjustmentField) {
        var baseline = adjustments
        var updated = timeline
        updated.resetField(field, at: position, baseline: &baseline)
        adjustments = baseline
        withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) { timeline = updated }
        refreshState()
        renderToken += 1
        persist()
    }

    private func resetEverything() {
        stopPlayback()
        adjustments = .neutral
        withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) { timeline.clear() }
        refreshState()
        renderToken += 1
        persist()
    }

    private func deleteKeyframe(_ keyframe: GradeKeyframe) {
        var baseline = adjustments
        var updated = timeline
        updated.remove(keyframe.id, baseline: &baseline)
        adjustments = baseline
        withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) { timeline = updated }
        refreshState()
        renderToken += 1
        persist()
    }

    // MARK: - Actions

    /// A tile tap. From Edited it discards work the user did by hand, so it
    /// asks first; from Original or another preset it applies immediately.
    private func request(_ target: PresetApplyRequest.Target) {
        // Original clears the whole grade, keyframes included; every other tile
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
                renderToken += 1
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
        renderToken += 1
        // A tile tap is a finished gesture, not a drag: persist it now.
        persist()
    }

    /// A tile's values, written where the playhead is standing — see
    /// `PhotoViewerView.applyPresetValues` for why a preset doesn't flatten a
    /// graded clip back to one look, and why the level and crop in hand are
    /// kept (a preset carries neither).
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

    private func saveCurrentAsPreset() {
        // A preset is a look, and the look on screen is the one at the
        // playhead — which is the whole grade when nothing is keyframed. The
        // level and the crop are corrections of this movie, not part of the
        // look, so they stay behind.
        if let saved = presetStore.save(
            name: newPresetName, basePreset: preset,
            adjustments: displayedAdjustments.withoutGeometry) {
            if timeline.isEmpty {
                presetState = .named(id: saved.id, snapshot: saved.snapshot)
            }
        }
        newPresetName = ""
        guard exitsAfterPresetSave else {
            renderToken += 1
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

    /// Leaves the editor, persisting first — the debounced write may not have
    /// run yet, and its task dies with the view.
    private func finishExit() {
        isOfferingPresetSave = false
        persist()
        // The library write is asynchronous now; drain it before the editor
        // goes away.
        model.flushLibraryPersists()
        dismiss()
    }

    private func persist() {
        guard let capture else { return }
        model.setPhotoGrade(
            preset: preset, adjustments: adjustments, state: presetState,
            timeline: timeline, for: capture)
    }

    /// `LL_SECTIONS=color:mixer:<band>` (DEBUG), handed to the panel as its
    /// opening band; nil in every other build.
    @State private var hookBand: HSLAdjustments.Band?

    #if DEBUG
    /// `LL_KEYFRAMES=sunset` stages three graded moments across the movie, and
    /// `=empty` the first-run state — the video twin of the photo editor's hook,
    /// and unreachable by automation for the same reason: making them for real
    /// means scrubbing and grading at three separate moments. The same
    /// moments as the photo editor stages, so both editors' boards read the
    /// same: OWNED whites at 6100 / 7600 / 5400 K, since the Temp control
    /// binds `whiteMired` and the legacy `temperature` offset has no control
    /// left to show it.
    private func applyKeyframeHook() {
        guard let hook = ProcessInfo.processInfo.environment["LL_KEYFRAMES"],
              duration > 0 else { return }
        guard hook != "empty" else {
            adjustments = .neutral
            timeline = .empty
            position = 0
            refreshState()
            return
        }
        func moment(
            kelvin: Double, exposure: Float, highlights: Float,
            shadows: Float, vibrance: Float
        ) -> PhotoAdjustments {
            var values = PhotoAdjustments.neutral
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
        refreshState()
        applyGradeToPlayer()
    }

    /// `LL_SECTIONS=<group>[:<tool>[:<band>]]` opens a group's panel with a
    /// tool chip up, the way the screenshot recipes ask for it (spec §7) —
    /// the photo editor's hook, verbatim, reached here by `LL_EDITOR=video`:
    /// `presets|light|color|effects|detail|crop`, with `expcon|highwhites|
    /// shadblacks|wb|vibsat|mixer|texclar|vignette|dehaze|sharpen|noise` as
    /// the chip. The old names still answer — `wb` → color:wb,
    /// `mixer[:axis]` → color:mixer, `rotation` → crop, `all` → light — so
    /// the existing design recipes keep working. The band suffix is parsed
    /// and dropped: the panel holds its mixer band privately and offers no
    /// way in. On every layout this is "open the panel"; there is nothing to
    /// scroll to any more.
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

    /// Swaps the player item's composition for the current grade. Playback
    /// position and rate carry across the swap, so the frame on screen simply
    /// re-renders through the new look.
    private func applyGradeToPlayer() {
        guard let asset, let item = player.currentItem else { return }
        item.videoComposition = VideoGrader.composition(
            for: asset, grade: liveGrade, durationSeconds: duration)
    }
}

/// The floating card's size, measured so a drag can keep it on screen.
private struct VideoEditorPanelSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

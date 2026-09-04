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

/// The full-screen photo editor: the graded image, the preset chip strip, and
/// the adjustment sliders, which re-render the preview live.
///
/// On iOS/iPadOS it is a `fullScreenCover` on black — the asset pinned at the
/// top at its true aspect ratio, the controls scrolling beneath it, and a
/// floating back button top-left. The asset never scrolls: you can always see
/// what you are grading. On macOS it is the content of its own resizable window
/// (`PhotoEditorWindowRequest` scene in `LetsLapseApp`), so the window chrome
/// owns the title and close.
///
/// Layout follows the available width rather than the device: past
/// `wideLayoutThreshold` the controls move into a side rail beside the image
/// (iPhone landscape, iPad, always on the Mac); below it the image is pinned
/// above a scrolling control stack.
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

    @State private var asShotKelvin: Double = 6500
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
    @State private var persistedDocument = OverlayDocument()
    /// The layer the preview draws its bounding box and handles around.
    @State private var selectedOverlayID: UUID?
    /// A short confirmation floated over the media ("Linked — starts after
    /// …", "Imported Amatic SC"), 1.8 s.
    @State private var overlayToast: String?
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

    private struct OverlayDragState {
        let id: UUID
        /// The committed centre when the drag began — translation is applied
        /// to this absolute base, never accumulated.
        let base: CGPoint
        var current: CGPoint
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
    @State private var mediaScale: CGFloat = 1

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
    /// never the controls. Capped-proportional on iOS/iPadOS.
    private func railWidth(in totalWidth: CGFloat) -> CGFloat {
        #if os(macOS)
        return 340
        #else
        return min(340, totalWidth * 0.42)
        #endif
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
        model.captures.first { $0.id == captureID }
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
    @ViewBuilder private func stepControl(by delta: Int, compact: Bool) -> some View {
        let size: CGFloat = compact ? 26 : 30
        let index = frameIndex(at: position)
        let enabled = delta < 0 ? index > 0 : index < frames.count - 1
        Button { stepFrame(by: delta) } label: {
            ZStack {
                Circle().fill(LL.cardBackground)
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
            let isWide = proxy.size.width >= wideLayoutThreshold
            Group {
                if isWide {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            imagePane
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .overlay(alignment: .top) { chrome }
                                .overlay(alignment: .bottom) { overlayToastView }
                            // The scrubber belongs to the media, so it takes the
                            // media pane's width rather than the rail's — which
                            // keeps the rail identical to the photo editor's and
                            // the whole photo/interval difference to exactly one
                            // component.
                            if hasTimeline {
                                timelineStrip(compact: true)
                                    .padding(.horizontal, 18)
                                    .padding(.top, 9)
                                    .padding(.bottom, 4)
                                // The layer lanes belong to the media too: one
                                // band per text layer, under the strip's own
                                // axis, while the Text tab is the work.
                                if showsOverlayLanes {
                                    overlayLanes(compact: true)
                                        .padding(.horizontal, 18)
                                        .padding(.bottom, 4)
                                }
                            }
                        }
                        Divider()
                        controlRail
                            .frame(width: railWidth(in: proxy.size.width))
                    }
                } else {
                    stackedBody(in: proxy.size)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            // The as-shot anchor for the temperature readout — a cached
            // metadata parse, off the render path.
            asShotKelvin = await Task.detached(priority: .utility) {
                Double(PhotoGrader.asShotKelvin(url: viewedURL))
            }.value
            #if DEBUG
            if ProcessInfo.processInfo.environment["LL_VIEWER"] == "expanded" {
                // The handle dragged all the way up — the state the "expanded"
                // design spec draws.
                mediaScale = 0
            }
            applyKeyframeHook()
            applyPerfWiggleHook()
            applyTextHook()
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
        .onChange(of: frameWindowKey) { _, _ in refreshFrameWindow() }
        .onChange(of: displayedURL) { _, _ in
            // A scrub moved to a different still: what is on screen at full
            // resolution is now a patch of the wrong frame.
            detailPatch = nil
            loupePatch = nil
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
            imagePane
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
                Button { requestExit() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.4), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
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

    // MARK: - Image

    private var imagePane: some View {
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
                        .allowsHitTesting(false)
                }
                if showsLoupe {
                    DetailLoupe(
                        image: loupePatch?.image,
                        displayScale: displayScale,
                        side: loupeSide(in: proxy.size))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(12)
                        .transition(.opacity)
                }
                zoomControls(in: geometry)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { toggleActualPixels(in: geometry) }
            .gesture(magnifyGesture(in: geometry))
            // Only claimed once there is something to pan: at fit scale a drag
            // over the picture still belongs to whatever is presenting it —
            // the fullscreen sheet pages between photos with one.
            .gesture(panGesture(in: geometry), including: zoom.isFitted ? .subviews : .all)
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
                if let selected = selectedOverlay {
                    overlayChrome(selected, drawn: drawn)
                }
                overlaySnapGuides(drawn: drawn)
            }
        }
        .frame(width: drawn.width, height: drawn.height)
        .offset(zoom.offset)
    }

    /// The draggable stand-in over the baked overlay. At rest it is an
    /// invisible hit target registered exactly over the baked text; during a
    /// drag the bake is suppressed from the render and this proxy — drawn at
    /// final layout, full strength, because the resting state is what is
    /// being placed — is what moves.
    @ViewBuilder private func overlayProxy(_ stored: SceneOverlay, drawn: CGSize) -> some View {
        let overlay = displayOverlay(stored)
        let dragging = overlayDrag?.id == overlay.id
        let center = dragging
            ? overlayDrag?.current ?? CGPoint(x: overlay.centerX, y: overlay.centerY)
            : CGPoint(x: overlay.centerX, y: overlay.centerY)
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
            .opacity(dragging ? 1 : (ghosted ? 0.16 : 0.02))
            // The layer's own turn, about its anchor — the rasterizer's
            // rotation, so the proxy sits where the bake will.
            .rotationEffect(.degrees(overlay.rotationDegrees))
            .position(x: drawn.width * center.x, y: drawn.height * center.y)
            .highPriorityGesture(overlayDragGesture(overlay, drawn: drawn))
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
    @ViewBuilder private func overlayChrome(_ stored: SceneOverlay, drawn: CGSize) -> some View {
        let overlay = displayOverlay(stored)
        let boxed = overlay.mode == .box
        let center = overlayDrag?.id == overlay.id
            ? (overlayDrag?.current ?? CGPoint(x: overlay.centerX, y: overlay.centerY))
            : CGPoint(x: overlay.centerX, y: overlay.centerY)
        let size = chromeSize(overlay, drawn: drawn)
        let tint = boxed ? LL.amber : accentColor
        ZStack {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(
                    tint,
                    style: StrokeStyle(lineWidth: 1.5, dash: boxed ? [5, 4] : []))
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .topLeading) {
                    Text("\(boxed ? "BOX" : "FREE") · \(overlay.text.prefix(18).isEmpty ? "empty" : String(overlay.text.prefix(18)))")
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
                    overlayDrag = OverlayDragState(
                        id: overlay.id,
                        base: CGPoint(x: overlay.centerX, y: overlay.centerY),
                        current: CGPoint(x: overlay.centerX, y: overlay.centerY))
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
    private var controlRail: some View {
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

    @ViewBuilder private func controlStack(isWide: Bool) -> some View {
        switch railTab {
        case .editor:
            editorTab(isWide: isWide)
        case .text:
            textTab
        case .frames:
            if allFrames.count > 1 { framesTab } else { editorTab(isWide: isWide) }
        case .masks:
            masksTab
        }
    }

    /// The grading page — everything the rail held before it grew tabs.
    private func editorTab(isWide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            stateRow
            presetStrip

            // No disclosure to open: with the picture pinned and the controls
            // scrolling, hiding the sliders behind an accordion only adds a tap.
            sliderPanel(expanded: isWide)

            // Where there is no exit of ours to intercept, the offer lives
            // here instead — see `ownsExit`.
            if presetState.isEdited, !ownsExit, !declinedPresetSave {
                presetSaveOffer
            }

            Button {
                newPresetName = ""
                isNamingPreset = true
            } label: {
                Label("Save as Preset", systemImage: "square.and.arrow.down")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(accentColor)
            .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let error = presetStore.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
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
            modelInstalled: segModelIdentity != nil,
            maskStatus: inspectedMaskStatus,
            thresholdIsLive: thresholdIsLive,
            canVoteAcrossFrames: hasTimeline,
            accent: accentColor,
            thumbnail: { mask in
                guard let capture else { return nil }
                return CustomMaskThumbnails.thumbnail(
                    at: model.customMaskURL(mask, for: capture))
            },
            onEdited: overlayEdited,
            onImportMask: importCustomMask)
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

    /// The live state readout. It is the only thing on screen that can say
    /// "Edited", which is a state no chip stands for.
    private var stateRow: some View {
        HStack(spacing: 8) {
            Text("Preset")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            PresetStatePill(state: presetState, accent: accentColor, onAccent: pillTextColor)
            Spacer(minLength: 0)
        }
    }

    /// Black on the editors' amber, white on the Mac's accent — the same pair
    /// the chips use.
    private var pillTextColor: Color {
        #if os(iOS)
        return .black
        #else
        return .white
        #endif
    }

    private var presetStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PhotoPreset.strip) { candidate in
                    // The chips follow the state: a preset lights up only when
                    // the values on screen are still exactly what it gave us.
                    chip(
                        label: candidate.displayName,
                        isActive: candidate == .original
                            ? presetState.isOriginal
                            : presetState.isNamed(candidate.presetID)
                    ) {
                        request(.builtIn(candidate))
                    }
                    .accessibilityLabel("\(candidate.displayName) grade")
                }
                ForEach(presetStore.presets) { custom in
                    chip(label: custom.name, isActive: presetState.isNamed(custom.id)) {
                        request(.custom(custom))
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            presetPendingDelete = custom
                        } label: {
                            Label("Delete preset", systemImage: "trash")
                        }
                    }
                    .accessibilityLabel("\(custom.name) saved grade")
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
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

    private func chip(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(isActive ? Color.black : Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(isActive ? accentColor : LL.cardBackground))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private func sliderPanel(expanded: Bool) -> some View {
        PhotoAdjustmentsPanel(
            adjustments: editedAdjustments,
            alwaysExpanded: expanded,
            asShotKelvin: asShotKelvin,
            accent: accentColor,
            keyframedFields: timeline.keyframedFields,
            hasKeyframes: !timeline.isEmpty,
            onResetField: hasTimeline ? resetField : nil,
            onResetAll: hasTimeline ? resetEverything : nil,
            onFieldEditing: fieldEditingChanged)
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
    private var editedAdjustments: Binding<PhotoAdjustments> {
        Binding(
            get: { displayedAdjustments },
            set: { values in
                let openingBefore = openingRotation
                defer { carryOverlays(fromRotation: openingBefore, to: openingRotation) }
                guard hasTimeline else {
                    adjustments = values
                    refreshState()
                    scheduleUpdate()
                    return
                }
                stopPlayback()
                var baseline = adjustments
                var updated = timeline
                let outcome = updated.write(values, at: position, baseline: &baseline)
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
    private func applyPresetValues(_ values: PhotoAdjustments) {
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
    /// Custom masks are files and never come through here.
    private var skyMaskWanted: Bool {
        if showMask, let inspectedRegion, inspectedRegion.customMaskID == nil,
           inspectedRegion != .none {
            return true
        }
        return overlayDocument.needsSegmentationModel
    }

    /// The cache key of the mask the composite should use right now, or nil
    /// when none is wanted (or no model is installed). The render path only
    /// ever LOOKS UP this key — `maskFetchTask` is what fills it.
    private var activeSkyMaskKey: String? {
        guard skyMaskWanted, let segModelIdentity else { return nil }
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
        guard let capture else { return masks }
        // Only the masks something on screen actually names.
        var wanted = Set(overlayDocument.overlays.compactMap { $0.placement.customMaskID })
        if let id = inspectedRegion?.customMaskID, showMask { wanted.insert(id) }
        for mask in overlayDocument.customMasks where wanted.contains(mask.id) {
            masks.custom[mask.id] = CustomMaskLoader.mask(
                at: model.customMaskURL(mask, for: capture))
        }
        return masks
    }

    /// A Text-tab edit. Motion re-renders; a finished gesture also persists —
    /// the `fieldEditingChanged` discipline, applied to overlays.
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
        let adjustments = adjustments
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
                            url: url, preset: preset, adjustments: adjustments, maxDimension: 512)
                    },
                    progress: { done, total in
                        Task { @MainActor in
                            maskStatus = "Analysing the scene — frame \(done + 1) of \(total)…"
                        }
                    })
            } else {
                mask = try await SceneMaskService.shared.skyMask(forKey: key) {
                    PhotoGrader.render(
                        url: frameURL, preset: preset, adjustments: adjustments, maxDimension: 512)
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
        guard let capture else { return }
        model.setPhotoGrade(
            preset: preset, adjustments: adjustments, state: presetState,
            timeline: timeline, for: capture)
    }

    private func saveCurrentAsPreset() {
        // A preset is a look, and the look on screen is the one at the
        // playhead — which is the whole grade when nothing is keyframed. The
        // level is not part of a look.
        if let saved = presetStore.save(
            name: newPresetName, basePreset: preset,
            adjustments: displayedAdjustments.withoutRotation) {
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
        dismiss()
    }

    private func render() async {
        let preset = preset
        // The moment on screen, not the project's stored grade: with keyframes
        // those are only the same thing at the head of the clip.
        let adjustments = timeline.adjustments(at: renderedPosition, baseline: adjustments)
        let url = hasTimeline ? frames[frameIndex(at: renderedPosition)] : url
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
        let suppressed = overlayDrag?.id
        let compositePosition = renderedPosition
        let maskSettings = overlayDocument.maskSettings
        let masks = previewMaskSet()
        let debugRegion = showMask ? inspectedRegion : nil
        let rotation = Double(adjustments.rotationDegrees)
        let image = await MediaWorkQueue.grading.run { () -> CGImage? in
            // Levelled inside the grader (cached with the grade, at this
            // moment's angle); the compositor is told so its source-space
            // masks turn to match.
            guard let graded = PhotoGrader.render(
                url: url, preset: preset, adjustments: adjustments, maxDimension: longEdge)
            else { return nil }
            return SceneAwareCompositor.compositedPreview(
                base: graded, overlays: overlays, suppressing: suppressed,
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
    /// `LL_TEXT=story[,toast]` — stages the design pass's four-layer Prague
    /// story on a project that has NO text yet (a project with layers is
    /// left alone: the 2 s safety net would otherwise write the staging
    /// over real work), opens the Text tab, and parks the playhead at 13%
    /// so the first line is mid-bounce. `toast` also floats the link
    /// confirmation. Reveal timings and links are the mock's own, so the
    /// lanes drawn in `photo-viewer.text.svg` are measured from this.
    private func applyTextHook() {
        guard let hook = ProcessInfo.processInfo.environment["LL_TEXT"], frames.count > 1 else { return }
        let parts = hook.split(separator: ",").map(String.init)
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
        l4.animation?.follows = OverlayFollow(layerID: l3.id, gap: 0.02)
        overlayDocument.overlays = [l1, l2, l3, l4]
        overlayDocument.resolveFollows()
        selectedOverlayID = l1.id
        railTab = .text
        position = 0.13
        renderedPosition = 0.13
        if parts.contains("toast") { showOverlayToast("Linked — starts after “\(l1.displayName)”") }
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
            temperature: Float, exposure: Float, highlights: Float,
            shadows: Float, vibrance: Float
        ) -> PhotoAdjustments {
            var values = PhotoAdjustments.neutral
            values.temperature = temperature
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
            moment(temperature: -42, exposure: 0, highlights: -0.20,
                   shadows: 0.10, vibrance: 0.12),
            at: 0.10, baseline: &baseline)
        staged.write(
            moment(temperature: 63, exposure: -0.20, highlights: -0.35,
                   shadows: 0.18, vibrance: 0.38),
            at: 0.52, baseline: &baseline)
        staged.write(
            moment(temperature: 9, exposure: -0.50, highlights: -0.10,
                   shadows: 0.30, vibrance: 0.10),
            at: 0.86, baseline: &baseline)
        timeline = staged
        adjustments = baseline
        position = 0.30
        renderedPosition = 0.30
        refreshState()
    }
    #endif
}

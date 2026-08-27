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

    /// The frames this screen walks: the shoot, less whatever is hidden. Every
    /// index in this view — the scrubber's, the steps', the render's — is an
    /// index into THIS array, so a hidden frame simply isn't a place the
    /// playhead can stand.
    private var frames: [URL] {
        guard let capture, !allFrames.isEmpty else { return allFrames }
        return model.visibleFrameURLs(for: capture)
    }

    /// The capture clock for exactly those frames, rebased onto the first one
    /// the strip actually holds.
    ///
    /// The axis measures the frames that are on it, so hiding the opening two
    /// frames of a 4:09 shoot leaves a strip that runs 0:00 → 4:07 rather than
    /// 0:02 → 4:09: the head is the first visible frame, and the tail is how
    /// long the visible frames last. A frame hidden out of the MIDDLE takes no
    /// time off either end — the shoot still spans what it spanned, and the
    /// strip simply steps over that moment — which is why this rebases the
    /// origin rather than closing the gaps up.
    ///
    /// A no-op when nothing is hidden: `elapsedSeconds` already starts at 0.
    private var frameSeconds: [Double] {
        guard allFrameSeconds.count == allFrames.count else { return [] }
        let hidden = hiddenFrameNames
        let kept = hidden.isEmpty
            ? allFrameSeconds
            : zip(allFrames, allFrameSeconds)
                .filter { !hidden.contains($0.0.lastPathComponent) }
                .map(\.1)
        guard let origin = kept.first, origin != 0 else { return kept }
        return kept.map { $0 - origin }
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

    /// The shoot's time axis — the Kit component the warp timeline's stills
    /// lane shares, so "which frame is at this position" has exactly one
    /// definition (docs/interval-adjust-unification.md).
    private var frameAxis: FrameAxis {
        FrameAxis(
            frameCount: frames.count,
            elapsedSeconds: frameSeconds.isEmpty ? nil : frameSeconds,
            uniformDuration: uniformVisibleDuration)
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
                    let lead: CGFloat = compact ? 26 + 12 : 30 + 12
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
        #endif
        .task {
            // Seed once from the project, then let this view own the values —
            // re-seeding on every model change would fight the sliders.
            guard !loaded, let capture else { return }
            preset = model.photoPreset(for: capture)
            adjustments = model.photoAdjustments(for: capture)
            presetState = model.presetState(for: capture)
            timeline = model.gradeTimeline(for: capture)
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
            persist()
            await render()
        }
        .task(id: patchRequest) { await renderPatch() }
        .task(id: loupeRequest) { await renderLoupe() }
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
        let media = metrics.frame(in: container, scale: mediaScale)
        let span = metrics.dragSpan(in: container)
        return VStack(spacing: 0) {
            imagePane
                .frame(width: media.width, height: media.height)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .top) { chrome }
            // Between the media and the controls, and on the media's side of
            // the handle: the strip says which frame is on screen, so it moves
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
            ScrollView(.vertical) {
                controlStack(isWide: false)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            }
            .scrollBounceBehavior(.basedOnSize)
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
        }
        .frame(width: drawn.width, height: drawn.height)
        .offset(zoom.offset)
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

    /// The side rail is tall and narrow, so it scrolls on its own. (The stacked
    /// layout's scroll view lives in `stackedBody`, outside the media.)
    private var controlRail: some View {
        ScrollView {
            controlStack(isWide: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
    }

    private func controlStack(isWide: Bool) -> some View {
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

            // The bad-frame group, last in the stack and deliberately out of
            // the way: presets, sliders and keyframes are the work, and
            // somebody who never nominates a frame should never meet any of
            // this without scrolling to the very bottom looking for it.
            if hasTimeline {
                badFrameToggleButton
            }
            if hasNominatedFrames {
                hideBadFramesToggle
            }

            if let error = presetStore.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
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

    /// A control grabbed or let go. The five that work on pixels bring the
    /// loupe up for as long as they are being dragged — the rest are visible
    /// at any scale and need nothing.
    private func fieldEditingChanged(_ field: PhotoAdjustmentField, _ editing: Bool) {
        guard Self.detailFields.contains(field) else { return }
        if editing {
            loupeField = field
        } else if loupeField == field {
            loupeField = nil
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
        var baseline = adjustments
        var updated = timeline
        updated.resetField(field, at: position, baseline: &baseline)
        adjustments = baseline
        withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) { timeline = updated }
        refreshState()
        scheduleUpdate()
    }

    private func resetEverything() {
        stopPlayback()
        adjustments = .neutral
        withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) { timeline.clear() }
        refreshState()
        scheduleUpdate()
    }

    private func deleteKeyframe(_ keyframe: GradeKeyframe) {
        var baseline = adjustments
        var updated = timeline
        updated.remove(keyframe.id, baseline: &baseline)
        adjustments = baseline
        withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) { timeline = updated }
        refreshState()
        scheduleUpdate()
    }

    // MARK: - Playback

    /// Source-rate preview: a constant sweep across the whole shoot, so the
    /// ease between two moments can be watched landing without leaving the
    /// screen. Deliberately not the output's speed — that belongs to the speed
    /// and blend layer, and claiming it here would be a lie about the render.
    private func togglePlayback() {
        guard !isPlaying else { stopPlayback(); return }
        let from = position >= 0.999 ? 0 : position
        position = from
        isPlaying = true
        playback = Task { @MainActor in
            let started = Date()
            let sweep = 14.0
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(started)
                let next = from + elapsed / sweep
                guard next < 1 else { break }
                position = next
                let quantised = renderPosition(for: next)
                if quantised != renderedPosition {
                    renderedPosition = quantised
                    renderToken += 1
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
            guard !Task.isCancelled else { return }
            position = 1
            isPlaying = false
            renderedPosition = 1
            renderToken += 1
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
        // playhead — which is the whole grade when nothing is keyframed.
        if let saved = presetStore.save(
            name: newPresetName, basePreset: preset, adjustments: displayedAdjustments) {
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
        let image = await MediaWorkQueue.shared.run {
            PhotoGrader.render(
                url: url, preset: preset, adjustments: adjustments, maxDimension: longEdge)
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
        let result = await MediaWorkQueue.shared.run {
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
    /// `LL_KEYFRAMES=sunset` stages the design's own scenario on an interval
    /// project — three moments across the shoot, playhead between the first
    /// two — and `LL_KEYFRAMES=empty` the first-run state the empty spec draws.
    /// Neither is reachable by automation: making them for real means scrubbing
    /// a two-hour shoot and dragging sliders at three separate moments.
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

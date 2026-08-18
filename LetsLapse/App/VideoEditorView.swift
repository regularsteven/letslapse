import AVFoundation
import AVKit
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

/// The video project's editor: the movie playing at its true aspect ratio
/// beside the same preset chips and adjustment sections the photo editor has.
/// The grade rides the player as a live video composition — scrub or play to
/// any moment and that frame renders through the current sliders, which is
/// the whole point: seeing what an edit does to the footage, not to one
/// thumbnail.
///
/// Layout mirrors `PhotoViewerView`: past `wideLayoutThreshold` the controls
/// sit in a side rail beside the player; below it the player is pinned at the
/// top of a black screen with the controls scrolling underneath, resizable by
/// the handle between them.
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
    // `GradeTimeline`; the strip below the player is the same component the
    // interval editor shows, over the movie's own clock instead of the capture
    // clock an interval shoot was shot on.

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
    /// A chip tap held back for confirmation: applying it from Edited would
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
    @State private var mediaScale: CGFloat = 1
    @State private var dragBase: CGFloat?
    @GestureState private var handleLive = false

    private let wideLayoutThreshold: CGFloat = 500
    private let mediaCeilingFraction: CGFloat = 0.8
    private let mediaFloorFraction: CGFloat = 0.25
    /// A touch longer than the photo editor's 100ms: swapping the video
    /// composition restarts the item's render pipeline, so a drag shouldn't
    /// thrash it.
    private let renderDebounce: Duration = .milliseconds(150)

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

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= wideLayoutThreshold
            Group {
                if isWide {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            playerPane
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .overlay(alignment: .top) { chrome }
                            // The scrubber belongs to the media, so it takes
                            // the player pane's width rather than the rail's.
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
        .onChange(of: handleLive) { live in
            if !live { dragBase = nil }
        }
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
                mediaScale = 0
            }
            applyKeyframeHook()
            #endif
        }
        .task(id: renderToken) {
            guard loaded else { return }
            try? await Task.sleep(for: renderDebounce)
            guard !Task.isCancelled else { return }
            persist()
            applyGradeToPlayer()
        }
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

    private func railWidth(in totalWidth: CGFloat) -> CGFloat {
        #if os(macOS)
        return 340
        #else
        return min(340, totalWidth * 0.42)
        #endif
    }

    private var editorBackground: some View {
        #if os(iOS)
        Color.black.ignoresSafeArea()
        #else
        LL.screenBackground
        #endif
    }

    // MARK: - Stacked layout (iPhone portrait)

    /// The player pinned at the top with the controls scrolling beneath it. The
    /// player gets an exact frame so the scroll view can only take the room left
    /// over — the ordering that stops a greedy `ScrollView` claiming the screen.
    private func stackedBody(in container: CGSize) -> some View {
        let media = mediaFrame(in: container)
        let span = dragSpan(in: container)
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
                dragHandle(span: span)
            }
            ScrollView(.vertical) {
                controlStack(isWide: false)
                    .padding(16)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// The player's exact frame: full width at the movie's true aspect, capped
    /// at `mediaCeilingFraction` of the height and then wherever the handle sits.
    private func mediaFrame(in container: CGSize) -> CGSize {
        guard container.width > 0, container.height > 0 else { return .zero }
        let ceiling = CollectionMath.fit(
            aspect: aspect ?? 0,
            maxWidth: container.width,
            maxHeight: (container.height * mediaCeilingFraction).rounded())
        guard let aspect, ceiling.height > mediaFloor(in: container) else { return ceiling }
        let floor = mediaFloor(in: container)
        let height = (floor + (ceiling.height - floor) * mediaScale).rounded()
        return CGSize(
            width: min(container.width, (height * aspect).rounded()),
            height: height)
    }

    private func mediaFloor(in container: CGSize) -> CGFloat {
        (container.height * mediaFloorFraction).rounded()
    }

    /// How much height the handle has to give away — zero, and no handle, when
    /// a very wide clip is already shorter than the floor.
    private func dragSpan(in container: CGSize) -> CGFloat {
        guard let aspect, container.width > 0, container.height > 0 else { return 0 }
        let ceiling = CollectionMath.fit(
            aspect: aspect,
            maxWidth: container.width,
            maxHeight: (container.height * mediaCeilingFraction).rounded())
        return max(0, ceiling.height - mediaFloor(in: container))
    }

    private func dragHandle(span: CGFloat) -> some View {
        Capsule()
            .fill(.white.opacity(0.35))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($handleLive) { _, live, _ in live = true }
                    .onChanged { value in
                        let base = dragBase ?? mediaScale
                        if dragBase == nil { dragBase = base }
                        mediaScale = min(1, max(0, base + value.translation.height / span))
                    }
                    .onEnded { _ in dragBase = nil }
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) { mediaScale = 1 }
            }
            .accessibilityElement()
            .accessibilityLabel("Preview size")
            .accessibilityValue("\(Int((mediaScale * 100).rounded()))%")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: mediaScale = min(1, mediaScale + 0.1)
                case .decrement: mediaScale = max(0, mediaScale - 0.1)
                @unknown default: break
                }
            }
    }

    // MARK: - Chrome

    /// Floats over the player so the movie keeps the top of the screen. AVKit's
    /// own transport is bottom-anchored, so the two never meet.
    ///
    /// The back button and nothing else — see `PhotoViewerView.chrome` for why
    /// there is no title and no scrim.
    @ViewBuilder private var chrome: some View {
        #if os(iOS)
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
        #else
        // The window's own title bar and close button do this job.
        EmptyView()
        #endif
    }

    // MARK: - Player

    /// Given an exactly-aspect-correct frame, `VideoPlayer`'s `.resizeAspect`
    /// fills it — the footage is neither cropped nor letterboxed. The black
    /// behind it only ever shows through rounding residue.
    private var playerPane: some View {
        VideoPlayer(player: player)
            .background(Color.black)
    }

    // MARK: - Controls

    /// The side rail is tall and narrow, so it scrolls on its own. (The stacked
    /// layout's scroll view lives in `stackedBody`, outside the player.)
    private var controlRail: some View {
        ScrollView {
            controlStack(isWide: true)
                .padding(16)
        }
        // A plain fill, not `editorBackground` — that one ignores the safe area,
        // which a rail inside the layout has no business doing. Forced dark
        // resolves this to black on iOS anyway.
        .background(LL.screenBackground)
    }

    private func controlStack(isWide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            stateRow
            presetStrip
            // No disclosure to open: with the player pinned and the controls
            // scrolling, hiding the sliders behind an accordion only adds a tap.
            sliderPanel(expanded: isWide)
            if presetState.isEdited, !ownsExit, !declinedPresetSave {
                presetSaveOffer
            }
            saveAsPresetButton
        }
    }

    /// The live state readout — the only thing on screen that can say "Edited".
    private var stateRow: some View {
        HStack(spacing: 8) {
            Text("Preset")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            PresetStatePill(state: presetState, accent: accentColor, onAccent: pillTextColor)
            Spacer(minLength: 0)
        }
    }

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
                    chip(
                        label: candidate.displayName,
                        isActive: candidate == .original
                            ? presetState.isOriginal
                            : presetState.isNamed(candidate.presetID)
                    ) {
                        request(.builtIn(candidate))
                    }
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
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
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
            accent: accentColor,
            keyframedFields: timeline.keyframedFields,
            hasKeyframes: !timeline.isEmpty,
            onResetField: hasTimeline ? resetField : nil,
            onResetAll: hasTimeline ? resetEverything : nil)
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

    /// The strip, in the one place both layouts pull it from.
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

    /// Follows the player while it plays, so the playhead and the sliders both
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
    /// lives in `GradeTimeline.write`.
    private var editedAdjustments: Binding<PhotoAdjustments> {
        Binding(
            get: { displayedAdjustments },
            set: { values in
                guard hasTimeline else {
                    adjustments = values
                    refreshState()
                    renderToken += 1
                    return
                }
                // A moment can't be graded while it is moving: dragging a
                // slider through a playing clip would spray keyframes along it.
                if isPlaying {
                    player.pause()
                    isPlaying = false
                }
                var baseline = adjustments
                var updated = timeline
                let outcome = updated.write(values, at: position, baseline: &baseline)
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

    private func resetField(_ field: PhotoAdjustmentField) {
        var baseline = adjustments
        var updated = timeline
        updated.resetField(field, at: position, baseline: &baseline)
        adjustments = baseline
        withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) { timeline = updated }
        refreshState()
        renderToken += 1
    }

    private func resetEverything() {
        adjustments = .neutral
        withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) { timeline.clear() }
        refreshState()
        renderToken += 1
    }

    private func deleteKeyframe(_ keyframe: GradeKeyframe) {
        var baseline = adjustments
        var updated = timeline
        updated.remove(keyframe.id, baseline: &baseline)
        adjustments = baseline
        withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) { timeline = updated }
        refreshState()
        renderToken += 1
    }

    private var saveAsPresetButton: some View {
        Button {
            newPresetName = presetState.snapshot.map { $0.isBuiltIn ? "" : $0.name } ?? ""
            isNamingPreset = true
        } label: {
            Label("Save as Preset", systemImage: "square.and.arrow.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accentColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
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
                renderToken += 1
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
    }

    /// A chip's values, written where the playhead is standing — see
    /// `PhotoViewerView.applyPresetValues` for why a chip doesn't flatten a
    /// graded clip back to one look.
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

    private func saveCurrentAsPreset() {
        // A preset is a look, and the look on screen is the one at the
        // playhead — which is the whole grade when nothing is keyframed.
        if let saved = presetStore.save(
            name: newPresetName, basePreset: preset, adjustments: displayedAdjustments) {
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
        dismiss()
    }

    private func persist() {
        guard let capture else { return }
        model.setPhotoGrade(
            preset: preset, adjustments: adjustments, state: presetState,
            timeline: timeline, for: capture)
    }

    /// Swaps the player item's composition for the current grade. Playback
    /// position and rate carry across the swap, so the frame on screen simply
    /// re-renders through the new look.
    #if DEBUG
    /// `LL_KEYFRAMES=sunset` stages three graded moments across the movie, and
    /// `=empty` the first-run state — the video twin of the photo editor's hook,
    /// and unreachable by automation for the same reason: making them for real
    /// means scrubbing and grading at three separate moments.
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
        func moment(_ temperature: Float, _ exposure: Float, _ vibrance: Float)
            -> PhotoAdjustments {
            var values = PhotoAdjustments.neutral
            values.temperature = temperature
            values.exposure = exposure
            values.vibrance = vibrance
            return values
        }
        preset = .natural
        var baseline = PhotoAdjustments.neutral
        var staged = GradeTimeline.empty
        staged.write(moment(-42, 0, 0.12), at: 0.10, baseline: &baseline)
        staged.write(moment(63, -0.20, 0.38), at: 0.52, baseline: &baseline)
        staged.write(moment(9, -0.50, 0.10), at: 0.86, baseline: &baseline)
        timeline = staged
        adjustments = baseline
        position = 0.30
        refreshState()
        applyGradeToPlayer()
    }
    #endif

    private func applyGradeToPlayer() {
        guard let asset, let item = player.currentItem else { return }
        item.videoComposition = VideoGrader.composition(
            for: asset, grade: liveGrade, durationSeconds: duration)
    }
}

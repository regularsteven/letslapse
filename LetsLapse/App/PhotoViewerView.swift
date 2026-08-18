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

    @State private var rendered: CGImage?
    @State private var isRendering = false
    /// Bumped by every control change; the render task keys off it so a burst
    /// of slider ticks collapses into one render.
    @State private var renderToken = 0

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
    /// see `mediaFrame(in:)` for what the layout does in the meantime.
    @State private var aspect: Double?
    /// Where the drag handle sits, as a fraction between the floor and the
    /// ceiling. 1 = the ceiling, which is where every presentation starts.
    @State private var mediaScale: CGFloat = 1
    /// The scale at the start of the current drag, so cumulative translations
    /// apply once instead of compounding.
    @State private var dragBase: CGFloat?
    /// Recognition liveness: @GestureState flips false on cancel as well as end,
    /// so the healer below can clear `dragBase` when a gesture dies without
    /// `onEnded` ever running.
    @GestureState private var handleLive = false

    /// Below this width the image is pinned above the controls instead of
    /// sitting beside them.
    ///
    /// 500 rather than a rounder 600 because of where the real widths fall: the
    /// widest iPhone portrait is 440pt (Pro Max), while a cover on iPad hands
    /// over the whole scene — 834pt portrait, 1024pt landscape. Only Slide Over
    /// (320pt) or a narrow Split View reaches the stacked branch on iPad, which
    /// is the right outcome.
    private let wideLayoutThreshold: CGFloat = 500

    /// The most of the available height the media may take. It is a ceiling and
    /// the starting position, not a fixed size — the drag handle trades media
    /// height for control room below it.
    private let mediaCeilingFraction: CGFloat = 0.8
    /// The least the handle can shrink the media to.
    private let mediaFloorFraction: CGFloat = 0.25

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
                        imagePane
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(alignment: .top) { chrome }
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
        // @GestureState flips false on end AND cancel, so the anchor can't stay
        // stuck when a drag dies without onEnded.
        .onChange(of: handleLive) { live in
            if !live { dragBase = nil }
        }
        .task {
            // Seed once from the project, then let this view own the values —
            // re-seeding on every model change would fight the sliders.
            guard !loaded, let capture else { return }
            preset = model.photoPreset(for: capture)
            adjustments = model.photoAdjustments(for: capture)
            presetState = model.presetState(for: capture)
            loaded = true
            let viewedURL = url
            // First, because it sizes the layout: a metadata-only read, well
            // ahead of the render that would otherwise have to land before the
            // image slot knew its shape.
            if let size = await Task.detached(priority: .utility, operation: {
                MediaGeometry.stillDisplaySize(url: viewedURL)
            }).value, size.height > 0 {
                aspect = size.width / size.height
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
            #endif
            renderToken += 1
        }
        .task(id: renderToken) {
            guard loaded else { return }
            // Debounce: a newer change cancels this task before it gets here, so
            // a slider drag collapses into one render and one manifest write
            // instead of one of each per tick.
            try? await Task.sleep(for: renderDebounce)
            guard !Task.isCancelled else { return }
            persist()
            await render()
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
        let media = mediaFrame(in: container)
        let span = dragSpan(in: container)
        return VStack(spacing: 0) {
            imagePane
                .frame(width: media.width, height: media.height)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .top) { chrome }
            if span > 0 {
                dragHandle(span: span)
            }
            ScrollView(.vertical) {
                controlStack(isWide: false)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// The media's exact frame: full width at its true aspect, capped at
    /// `mediaCeilingFraction` of the height and then wherever the handle has
    /// been dragged to. Always centred, always anchored to the top.
    private func mediaFrame(in container: CGSize) -> CGSize {
        guard container.width > 0, container.height > 0 else { return .zero }
        // A nil aspect — the probe hasn't landed — makes `fit` hand back the
        // whole box, which is the largest the media could ever be. The first
        // paint therefore reserves the slot and the resolve shrinks it once,
        // rather than the picture growing into place.
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

    /// How much height the handle has to give away. Zero — no handle — when the
    /// media is already shorter than the floor, which is where a very wide clip
    /// lands: there is no width left for it to grow into.
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
            // Double-tap to reset, the same idiom the sliders teach.
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
        ZStack {
            Color.black
            if let rendered {
                Image(decorative: rendered, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                ProjectPreviewImage(url: url, background: AnyShapeStyle(Color.black))
            }
            if isRendering {
                ProgressView()
                    .controlSize(.small)
                    .padding(10)
                    .background(.black.opacity(0.4), in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(16)
                    .allowsHitTesting(false)
            }
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

            if let error = presetStore.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
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
            adjustments: $adjustments,
            alwaysExpanded: expanded,
            asShotKelvin: asShotKelvin,
            accent: accentColor)
            // Every tick: the state has to be true of the values *now*, not of
            // the values the debounced write eventually persists.
            .onChange(of: adjustments) { _ in
                refreshState()
                scheduleUpdate()
            }
    }

    // MARK: - Actions

    /// A chip tap. From Edited it discards work the user did by hand, so it
    /// asks first; from Original or another preset it applies immediately.
    private func request(_ target: PresetApplyRequest.Target) {
        let request = PresetApplyRequest(target: target)
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
            // Original is "no filter": the sliders go with the preset.
            adjustments = .neutral
            presetState = candidate == .original
                ? .original
                : .named(id: candidate.presetID, snapshot: candidate.snapshot)
        case .custom(let custom):
            preset = custom.basePreset
            adjustments = custom.adjustments
            presetState = .named(id: custom.id, snapshot: custom.snapshot)
        }
        declinedPresetSave = false
        scheduleUpdate()
    }

    /// Re-derives the state from the live values, anchored on the state they
    /// came from — the whole divergence rule, in one call.
    private func refreshState() {
        presetState = PresetStateResolver.resolve(
            preset: preset,
            adjustments: adjustments,
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
            preset: preset, adjustments: adjustments, state: presetState, for: capture)
    }

    private func saveCurrentAsPreset() {
        if let saved = presetStore.save(
            name: newPresetName, basePreset: preset, adjustments: adjustments) {
            // Naming a look is what takes a project out of Edited: the values
            // haven't moved, but they now have a preset behind them.
            presetState = .named(id: saved.id, snapshot: saved.snapshot)
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
        let adjustments = adjustments
        isRendering = true
        let image = await MediaWorkQueue.shared.run {
            PhotoGrader.render(
                url: url, preset: preset, adjustments: adjustments, maxDimension: 2000)
        }
        isRendering = false
        // A nil render (cancelled, or a missing file) leaves whatever is on
        // screen rather than blanking the viewer. The double optional is the
        // work queue's own "didn't run" wrapped around the grader's "couldn't".
        if let image, let cgImage = image {
            rendered = cgImage
            reconcileAspect(with: cgImage)
        }
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
}

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

/// The full-screen photo viewer with grading controls: the graded image, the
/// preset chip strip, and a Customise panel of sliders that re-render the
/// preview live.
///
/// On iOS/iPadOS it presents as a sheet with its own Done bar. On macOS it is
/// the content of its own resizable window (`PhotoEditorWindowRequest` scene in
/// `LetsLapseApp`), so the window chrome owns the title and close and no Done
/// bar is drawn.
///
/// Layout follows the available width rather than the device: past
/// `wideLayoutThreshold` the controls move into a side rail beside the image
/// (iPhone landscape, iPad, always on the Mac); below it they stack under
/// the image and the slider panel collapses so the photo is never pushed off
/// screen.
struct PhotoViewerView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var presetStore = CustomPresetStore.shared

    let captureID: UUID
    let url: URL
    var title: String

    /// Live edit state. Seeded from the project on appear and written back —
    /// debounced — as the controls move, so the detail screen and the export
    /// agree with what is on screen here.
    @State private var preset: PhotoPreset = .default
    @State private var adjustments: PhotoAdjustments = .neutral
    @State private var loaded = false

    @State private var rendered: CGImage?
    @State private var isRendering = false
    /// Bumped by every control change; the render task keys off it so a burst
    /// of slider ticks collapses into one render.
    @State private var renderToken = 0

    @State private var isCustomiseExpanded = false
    @State private var isNamingPreset = false
    @State private var newPresetName = ""
    @State private var presetPendingDelete: CustomPreset?

    /// Below this width the controls stack under the image instead of sitting
    /// beside it.
    ///
    /// 500 rather than a rounder 600 because of where the real widths fall: the
    /// widest iPhone portrait is 440pt (Pro Max), while this sheet presents at
    /// ~578pt on iPad — which a 600pt cutover left stacked on a screen with
    /// obvious room for the rail. 500 puts both firmly on the right side, with
    /// ~60pt of clearance below and ~78pt above.
    private let wideLayoutThreshold: CGFloat = 500

    /// Side-rail width. Fixed on macOS — resizing the window grows the photo,
    /// never the controls. Capped-proportional on iOS/iPadOS, where the
    /// presented widths vary more (a 578pt iPad sheet gets a 243pt rail).
    private func railWidth(in totalWidth: CGFloat) -> CGFloat {
        #if os(macOS)
        return 340
        #else
        return min(340, totalWidth * 0.42)
        #endif
    }
    /// How long the controls have to be still before a render starts. Long
    /// enough that dragging a slider doesn't queue a render per frame, short
    /// enough to feel live.
    private let renderDebounce: Duration = .milliseconds(100)

    private var capture: AppModel.CaptureProject? {
        model.captures.first { $0.id == captureID }
    }

    /// The saved grade the current selection exactly matches, if any.
    private var activeCustomPreset: CustomPreset? {
        presetStore.matching(basePreset: preset, adjustments: adjustments)
    }

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= wideLayoutThreshold
            Group {
                if isWide {
                    HStack(spacing: 0) {
                        imagePane
                        Divider()
                        controlRail(isWide: true)
                            .frame(width: railWidth(in: proxy.size.width))
                    }
                } else {
                    VStack(spacing: 0) {
                        imagePane
                        Divider()
                        // Hugs its content so the photo keeps every point the
                        // controls don't need — a greedy rail left the image
                        // squeezed against a slab of empty background.
                        controlRail(isWide: false)
                            .layoutPriority(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(LL.screenBackground)
        #if os(iOS)
        // The sheet draws its own Done bar; on macOS the window's own title
        // bar and close button do this job.
        .safeAreaInset(edge: .top, spacing: 0) { titleBar }
        #endif
        .task {
            // Seed once from the project, then let this view own the values —
            // re-seeding on every model change would fight the sliders.
            guard !loaded, let capture else { return }
            preset = model.photoPreset(for: capture)
            adjustments = model.photoAdjustments(for: capture)
            loaded = true
            #if DEBUG
            if ProcessInfo.processInfo.environment["LL_VIEWER"] == "expanded" {
                isCustomiseExpanded = true
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
        .alert("Save as preset", isPresented: $isNamingPreset) {
            TextField("Preset name", text: $newPresetName)
            Button("Save") { saveCurrentAsPreset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the \(preset.displayName) grade and these adjustments so you can apply them to another photo.")
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

    // MARK: - Title bar (iOS sheet only)

    #if os(iOS)
    private var titleBar: some View {
        HStack {
            Button("Done") { dismiss() }
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(LL.accent)
                .buttonStyle(.plain)
            Spacer()
            Text(title)
                .font(.system(size: 15.5, weight: .semibold))
                .lineLimit(1)
            Spacer()
            // Balances the leading button so the title stays centred.
            Text("Done")
                .font(.system(size: 15.5, weight: .semibold))
                .opacity(0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
    #endif

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Controls

    @ViewBuilder private func controlRail(isWide: Bool) -> some View {
        let content = VStack(alignment: .leading, spacing: 14) {
            presetStrip

            if isWide {
                // A side rail has the room to show the sliders outright.
                sliderPanel
            } else {
                customiseDisclosure
                if isCustomiseExpanded {
                    sliderPanel
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
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
            .foregroundStyle(LL.accent)
            .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let error = presetStore.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)

        if isWide {
            // The side rail is tall and narrow, so it scrolls on its own.
            ScrollView { content }
        } else {
            content
        }
    }

    private var presetStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PhotoPreset.strip) { candidate in
                    // A built-in chip is active only when it is the selected
                    // base *and* no saved preset claims the current values.
                    chip(
                        label: candidate.displayName,
                        isActive: candidate == preset && activeCustomPreset == nil
                    ) {
                        select(preset: candidate)
                    }
                    .accessibilityLabel("\(candidate.displayName) grade")
                }
                ForEach(presetStore.presets) { custom in
                    chip(label: custom.name, isActive: activeCustomPreset?.id == custom.id) {
                        apply(custom)
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

    private func chip(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(isActive ? Color.white : Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(isActive ? LL.accent : LL.cardBackground))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private var customiseDisclosure: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isCustomiseExpanded.toggle() }
        } label: {
            HStack {
                Text("Customise")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                if !adjustments.isNeutral {
                    Circle()
                        .fill(LL.accent)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("edited")
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCustomiseExpanded ? 0 : -90))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sliderPanel: some View {
        PhotoAdjustmentsPanel(adjustments: $adjustments)
            .onChange(of: adjustments) { _ in scheduleUpdate() }
    }

    // MARK: - Actions

    private func select(preset newPreset: PhotoPreset) {
        preset = newPreset
        scheduleUpdate()
    }

    private func apply(_ custom: CustomPreset) {
        preset = custom.basePreset
        adjustments = custom.adjustments
        scheduleUpdate()
    }

    /// Restarts the debounce window. Both the manifest write and the re-render
    /// happen at the end of it.
    private func scheduleUpdate() {
        renderToken += 1
    }

    /// Writes the current grade onto the project. Cheap enough after debouncing
    /// — `setPhotoPreset`/`setPhotoAdjustments` both no-op when nothing changed.
    private func persist() {
        guard let capture else { return }
        model.setPhotoPreset(preset, for: capture)
        model.setPhotoAdjustments(adjustments, for: capture)
    }

    private func saveCurrentAsPreset() {
        presetStore.save(name: newPresetName, basePreset: preset, adjustments: adjustments)
        newPresetName = ""
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
        if let image, let cgImage = image { rendered = cgImage }
    }
}

// MARK: - Adjustments panel

/// The manual grade's controls on a card: five sliders, the white-balance
/// picker, and Reset.
///
/// Shared by every surface that customises a grade — this viewer (photo and
/// interval captures) and the video project's inline Customise panel in
/// `ProjectDetailView` — so the two can't drift apart. It owns no state and does
/// no rendering: the binding's owner decides how often to re-render and when to
/// write the values back to the project.
struct PhotoAdjustmentsPanel: View {
    @Binding var adjustments: PhotoAdjustments

    var body: some View {
        VStack(spacing: 10) {
            slider("Highlights", value: $adjustments.highlights,
                   range: PhotoAdjustments.highlightsRange)
            slider("Shadows", value: $adjustments.shadows,
                   range: PhotoAdjustments.shadowsRange)
            slider("Vibrance", value: $adjustments.vibrance,
                   range: PhotoAdjustments.vibranceRange)
            slider("Clarity", value: $adjustments.clarity,
                   range: PhotoAdjustments.clarityRange)
            slider("Vignette", value: $adjustments.vignetteIntensity,
                   range: PhotoAdjustments.vignetteRange)

            HStack {
                Text("White Bal.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("White balance", selection: $adjustments.whiteBalance) {
                    ForEach(PhotoAdjustments.WhiteBalance.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(LL.accent)
            }

            Button("Reset adjustments") {
                adjustments = .neutral
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(adjustments.isNeutral ? .secondary : LL.accent)
            .buttonStyle(.plain)
            .disabled(adjustments.isNeutral)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        }
        .padding(14)
        .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func slider(
        _ label: String,
        value: Binding<Float>,
        range: ClosedRange<Float>
    ) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(readout(value.wrappedValue))
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(value.wrappedValue == 0 ? .secondary : .primary)
            }
            Slider(value: value, in: range)
                .tint(LL.accent)
                .accessibilityLabel(label)
        }
    }

    /// Slider values read as -100…100, which is the vocabulary people know from
    /// every other editor, rather than the -1…1 the filters take.
    private func readout(_ value: Float) -> String {
        value == 0 ? "0" : String(format: "%+.0f", value * 100)
    }
}

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
    @State private var loaded = false

    @State private var player = AVPlayer()
    @State private var asset: AVURLAsset?
    /// Bumped by every control change; the debounce task keys off it so a
    /// slider drag collapses into one manifest write and one composition swap.
    @State private var renderToken = 0

    @State private var isNamingPreset = false
    @State private var newPresetName = ""
    @State private var presetPendingDelete: CustomPreset?

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

    /// The saved grade the current selection exactly matches, if any.
    private var activeCustomPreset: CustomPreset? {
        presetStore.matching(basePreset: preset, adjustments: adjustments)
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
                        playerPane
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
        .onChange(of: handleLive) { live in
            if !live { dragBase = nil }
        }
        .task {
            // Seed once from the project, then let this view own the values.
            guard !loaded, let capture else { return }
            preset = model.photoPreset(for: capture)
            adjustments = model.photoAdjustments(for: capture)
            loaded = true
            // The project already knows the oriented size for a video capture,
            // so the player is laid out correctly on the very first frame.
            if let width = capture.sourceWidth, let height = capture.sourceHeight,
               width > 0, height > 0 {
                aspect = Double(width) / Double(height)
            }
            let asset = AVURLAsset(url: url)
            self.asset = asset
            let item = AVPlayerItem(asset: asset)
            item.videoComposition = VideoGrader.composition(
                for: asset, grade: PhotoGrade(preset: preset, adjustments: adjustments))
            player.replaceCurrentItem(with: item)
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
            #endif
        }
        .task(id: renderToken) {
            guard loaded else { return }
            try? await Task.sleep(for: renderDebounce)
            guard !Task.isCancelled else { return }
            persist()
            applyGradeToPlayer()
        }
        .onDisappear { player.pause() }
        .alert("Save as preset", isPresented: $isNamingPreset) {
            TextField("Preset name", text: $newPresetName)
            Button("Save") {
                presetStore.save(name: newPresetName, basePreset: preset, adjustments: adjustments)
                newPresetName = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the \(preset.displayName) grade and these adjustments so you can apply them to another project.")
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
            Button { dismiss() } label: {
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
            presetStrip
            // No disclosure to open: with the player pinned and the controls
            // scrolling, hiding the sliders behind an accordion only adds a tap.
            sliderPanel(expanded: isWide)
            saveAsPresetButton
        }
    }

    private var presetStrip: some View {
        let activeCustom = activeCustomPreset
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PhotoPreset.strip) { candidate in
                    chip(
                        label: candidate.displayName,
                        isActive: candidate == preset && activeCustom == nil
                    ) {
                        preset = candidate
                        renderToken += 1
                    }
                }
                ForEach(presetStore.presets) { custom in
                    chip(label: custom.name, isActive: activeCustom?.id == custom.id) {
                        preset = custom.basePreset
                        adjustments = custom.adjustments
                        renderToken += 1
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
            adjustments: $adjustments, alwaysExpanded: expanded, accent: accentColor)
            .onChange(of: adjustments) { _ in renderToken += 1 }
    }

    private var saveAsPresetButton: some View {
        Button {
            newPresetName = activeCustomPreset?.name ?? ""
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

    private func persist() {
        guard let capture else { return }
        model.setPhotoPreset(preset, for: capture)
        model.setPhotoAdjustments(adjustments, for: capture)
    }

    /// Swaps the player item's composition for the current grade. Playback
    /// position and rate carry across the swap, so the frame on screen simply
    /// re-renders through the new look.
    private func applyGradeToPlayer() {
        guard let asset, let item = player.currentItem else { return }
        item.videoComposition = VideoGrader.composition(
            for: asset, grade: PhotoGrade(preset: preset, adjustments: adjustments))
    }
}

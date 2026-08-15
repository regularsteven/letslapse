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
/// sit in a side rail beside the player; below it they stack underneath with
/// a collapsible Customise section.
struct VideoEditorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var presetStore = CustomPresetStore.shared

    let captureID: UUID
    let url: URL
    var title: String

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

    @State private var isCustomiseExpanded = true
    @State private var isNamingPreset = false
    @State private var newPresetName = ""
    @State private var presetPendingDelete: CustomPreset?

    private let wideLayoutThreshold: CGFloat = 500
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

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= wideLayoutThreshold
            Group {
                if isWide {
                    HStack(spacing: 0) {
                        playerPane
                        Divider()
                        controlRail(isWide: true)
                            .frame(width: railWidth(in: proxy.size.width))
                    }
                } else {
                    VStack(spacing: 0) {
                        playerPane
                        Divider()
                        controlRail(isWide: false)
                            .layoutPriority(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(LL.screenBackground)
        #if os(iOS)
        .safeAreaInset(edge: .top, spacing: 0) { titleBar }
        #endif
        .task {
            // Seed once from the project, then let this view own the values.
            guard !loaded, let capture else { return }
            preset = model.photoPreset(for: capture)
            adjustments = model.photoAdjustments(for: capture)
            loaded = true
            let asset = AVURLAsset(url: url)
            self.asset = asset
            let item = AVPlayerItem(asset: asset)
            item.videoComposition = VideoGrader.composition(
                for: asset, grade: PhotoGrade(preset: preset, adjustments: adjustments))
            player.replaceCurrentItem(with: item)
            player.play()
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
            // Mirrors Done's width so the title stays centred.
            Text("Done").font(.system(size: 15.5, weight: .semibold)).hidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(LL.screenBackground)
    }
    #endif

    // MARK: - Player

    /// `VideoPlayer` letterboxes to the movie's real aspect ratio on its own —
    /// the footage is never cropped to fit the pane.
    private var playerPane: some View {
        VideoPlayer(player: player)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
    }

    // MARK: - Controls

    @ViewBuilder private func controlRail(isWide: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                presetStrip
                if isWide {
                    sliderPanel(expanded: true)
                } else {
                    customiseDisclosure
                    if isCustomiseExpanded {
                        sliderPanel(expanded: false)
                    }
                }
                saveAsPresetButton
            }
            .padding(16)
        }
        .background(LL.screenBackground)
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

    private func sliderPanel(expanded: Bool) -> some View {
        PhotoAdjustmentsPanel(adjustments: $adjustments, alwaysExpanded: expanded)
            .onChange(of: adjustments) { _ in renderToken += 1 }
    }

    private var saveAsPresetButton: some View {
        Button {
            newPresetName = activeCustomPreset?.name ?? ""
            isNamingPreset = true
        } label: {
            Label("Save as Preset", systemImage: "square.and.arrow.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LL.accent)
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

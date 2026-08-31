import SwiftUI

/// The Text tab's controls: add text, edit it, choose how the scene
/// integrates it, inspect the mask, and shape its reveal. Deliberately lean —
/// this is the spike's experiment surface, not a typography inspector.
///
/// Owns no state: the editor holds the overlay list and everything here goes
/// back through `onEdited` — `commit: true` for finished gestures (persist +
/// render), `false` for live motion (render only).
struct OverlayEditingPanel: View {
    @Binding var overlays: [SceneOverlay]
    /// True when this capture has length — the only case reveal animation
    /// can mean anything.
    let hasTimeline: Bool
    /// The playhead, for Set Start / Set End.
    let position: Double
    /// Formats a position the way the strip does, so "Start" and the
    /// timeline bubble speak the same clock.
    let label: (Double) -> String
    let accent: Color
    /// Whether the segmentation model is installed — the gate on everything
    /// intelligent. Text works fully without it.
    let modelInstalled: Bool
    @Binding var showMask: Bool
    @Binding var settings: SegmentationSettings
    /// The mask readout — model, timing, cache state, or an error.
    let maskStatus: String?
    let onEdited: (_ commit: Bool) -> Void

    /// The text field's focus — held here so the keyboard has real ways OUT
    /// on iOS: Return (submitLabel .done), the keyboard toolbar's Done, and
    /// the editor resigning focus when the user moves on to dragging or
    /// scrubbing (PhotoViewerView.dismissTextEntry).
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if overlays.isEmpty {
                addTextCard
            } else {
                contentCard
                placementCard
                if hasTimeline {
                    animationCard
                } else {
                    footnote(
                        "Reveal animations play across a timeline; this photo shows its text throughout.")
                }
                removeButton
            }
        }
    }

    private var overlay: Binding<SceneOverlay> {
        Binding(
            get: { overlays.first ?? SceneOverlay(content: .text(.init(string: ""))) },
            set: { value in
                guard !overlays.isEmpty else { return }
                overlays[0] = value
            })
    }

    // MARK: - Add / remove

    private var addTextCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                overlays.append(SceneOverlay(content: .text(.init(string: "Your text"))))
                onEdited(true)
            } label: {
                Label("Add Text", systemImage: "textformat")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            footnote("Drag the text on the preview to place it. Where it rests is where every animation ends.")
        }
    }

    private var removeButton: some View {
        Button {
            overlays.removeAll()
            onEdited(true)
        } label: {
            Label("Remove Text", systemImage: "trash")
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Content

    private var contentCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Text")
            TextField("Text", text: Binding(
                get: { overlay.wrappedValue.text },
                set: { value in
                    overlay.wrappedValue.text = value
                    onEdited(false)
                }))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
                .focused($textFieldFocused)
                .submitLabel(.done)
                .onSubmit {
                    onEdited(true)
                    textFieldFocused = false
                }
                #if os(iOS)
                // The soft keyboard needs an explicit exit: without this the
                // only way out was leaving the tab (found on device
                // 2026-08-31). Return says Done too, and the editor resigns
                // focus when a drag or scrub starts.
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") {
                            textFieldFocused = false
                            onEdited(true)
                        }
                        .font(.system(size: 15, weight: .semibold))
                    }
                }
                #endif
            HStack(spacing: 10) {
                Text("Size")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { overlay.wrappedValue.size },
                        set: { value in
                            overlay.wrappedValue.size = value
                            onEdited(false)
                        }),
                    in: 0.03...0.2
                ) { editing in
                    if !editing { onEdited(true) }
                }
                .tint(accent)
            }
        }
        .padding(14)
        .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Intelligent placement

    private var placementCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Intelligent Placement")
            segmentRow(
                OverlayPlacement.allCases.map(\.displayName),
                selectedIndex: OverlayPlacement.allCases.firstIndex(
                    of: overlay.wrappedValue.placement) ?? 0,
                enabled: modelInstalled
            ) { index in
                overlay.wrappedValue.placement = OverlayPlacement.allCases[index]
                onEdited(true)
            }
            if modelInstalled {
                footnote("The scene occludes the text — its position never moves.")
                maskControls
            } else {
                footnote(
                    "Intelligent placement needs the segmentation model — download it in Settings ▸ AI Models. Text placement works without it.")
            }
        }
        .padding(14)
        .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private var maskControls: some View {
        Toggle(isOn: Binding(
            get: { showMask },
            set: { value in
                showMask = value
                onEdited(false)
            })) {
            Text("Show semantic mask")
                .font(.system(size: 13.5, weight: .semibold))
        }
        #if os(macOS)
        .toggleStyle(.checkbox)
        #endif
        .tint(accent)

        HStack(spacing: 8) {
            Text("Analysis")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
            segmentRow(
                ["Sequence", "This frame"],
                selectedIndex: settings.maskMode == .sequence ? 0 : 1,
                enabled: true
            ) { index in
                settings.maskMode = index == 0 ? .sequence : .perFrame
                // A finished gesture: the mode is part of the persisted
                // document (the export reads it), not just a view state.
                onEdited(true)
            }
        }

        maskDial("Threshold", value: $settings.threshold, range: 0.05...0.95)
        maskDial("Feather", value: $settings.featherRadius, range: 0...8)
        maskDial("Edge bias", value: $settings.edgeBias, range: 0...4)

        if let maskStatus {
            Text(maskStatus)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func maskDial(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double>
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Slider(
                value: Binding(
                    get: { value.wrappedValue },
                    set: { next in
                        value.wrappedValue = next
                        onEdited(false)
                    }),
                in: range
            ) { editing in
                if !editing { onEdited(true) }
            }
            .tint(accent)
        }
    }

    // MARK: - Animation

    private var animationCard: some View {
        let animation = overlay.wrappedValue.animation
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Animation")
            segmentRow(
                ["None", "Fade", "Slide"],
                selectedIndex: animation == nil ? 0
                    : (animation?.style == .characterFade ? 1 : 2),
                enabled: true
            ) { index in
                switch index {
                case 0:
                    overlay.wrappedValue.animation = nil
                case 1:
                    var next = overlay.wrappedValue.animation ?? defaultAnimation()
                    next.style = .characterFade
                    overlay.wrappedValue.animation = next
                default:
                    var next = overlay.wrappedValue.animation ?? defaultAnimation()
                    next.style = .characterSlide
                    overlay.wrappedValue.animation = next
                }
                onEdited(true)
            }

            if let animation {
                if animation.style == .characterSlide {
                    HStack(spacing: 8) {
                        Text("From")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        segmentRow(
                            OverlayAnimation.Direction.allCases.map(\.displayName),
                            selectedIndex: OverlayAnimation.Direction.allCases
                                .firstIndex(of: animation.direction) ?? 1,
                            enabled: true
                        ) { index in
                            overlay.wrappedValue.animation?.direction =
                                OverlayAnimation.Direction.allCases[index]
                            onEdited(true)
                        }
                    }
                }

                // The playhead is the precision instrument — scrub, then pin.
                HStack(spacing: 10) {
                    rangeButton("Set Start", value: label(animation.start)) {
                        var next = animation
                        next.start = min(position, next.end - 0.02)
                        overlay.wrappedValue.animation = next
                        onEdited(true)
                    }
                    rangeButton("Set End", value: label(animation.end)) {
                        var next = animation
                        next.end = max(position, next.start + 0.02)
                        overlay.wrappedValue.animation = next
                        onEdited(true)
                    }
                }
                footnote("The reveal runs across this span of the shoot and always finishes exactly where the text rests.")
            }
        }
        .padding(14)
        .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func defaultAnimation() -> OverlayAnimation {
        // Open the band at the playhead's neighborhood rather than 0…25% of
        // a two-hour shoot: the user is looking at the moment they care
        // about.
        var animation = OverlayAnimation()
        animation.start = min(max(position, 0), 0.9)
        animation.end = min(animation.start + 0.1, 1)
        return animation
    }

    private func rangeButton(
        _ title: String, value: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(value)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent)
        .background(LL.screenBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Bits

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The Ken Burns capsule-segment idiom, generalized.
    private func segmentRow(
        _ titles: [String], selectedIndex: Int, enabled: Bool,
        onSelect: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: 1) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                Button {
                    guard enabled, index != selectedIndex else { return }
                    onSelect(index)
                } label: {
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(
                            index == selectedIndex
                                ? Color.white
                                : (enabled ? accent : Color.secondary.opacity(0.5)))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(
                            index == selectedIndex
                                ? (enabled ? accent : Color.secondary.opacity(0.4))
                                : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(index == selectedIndex ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(LL.screenBackground))
    }
}

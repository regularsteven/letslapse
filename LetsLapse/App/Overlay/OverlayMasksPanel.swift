import SwiftUI
import UniformTypeIdentifiers

/// The Masks tab: the project's regions and the dials that shape them.
///
/// Separate from Text because what it authors belongs to the PROJECT, not to
/// a layer — every text layer can pick any of these regions, so they cannot
/// live inside one layer's disclosure. Picking a region here selects it for
/// inspection and tuning; it is not a placement, and nothing is analysed
/// until one is chosen.
struct OverlayMasksPanel: View {
    @Binding var document: OverlayDocument
    /// The region being inspected — drives the debug tint and tells the
    /// viewer which mask to fetch. Editor state, not part of the piece.
    @Binding var inspectedRegion: OverlayPlacement?
    @Binding var showMask: Bool
    /// Whether the segmentation model is installed — the gate on Sky and
    /// Land only. Custom masks are files and need nothing.
    let modelInstalled: Bool
    /// The mask readout — model, timing, cache state, or an error.
    let maskStatus: String?
    let accent: Color
    /// Resolves a mask's thumbnail; the panel does not know where the
    /// project's files live.
    let thumbnail: (CustomMask) -> CGImage?
    let onEdited: (_ commit: Bool) -> Void
    /// Copies a dropped or picked file into the project and returns the mask.
    let onImportMask: (URL) -> Void

    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            placementCard
            customMasksCard
        }
    }

    // MARK: - Intelligent placement

    private var placementCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Intelligent Placement")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            let regions = document.placementRegions
            if regions.isEmpty {
                Text("This project has no regions yet. Add a custom mask below, or install the segmentation model for Sky and Land.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlowRow(spacing: 1) {
                    ForEach(Array(regions.enumerated()), id: \.offset) { _, region in
                        let selected = inspectedRegion == region.placement
                        Button {
                            // Clicking the selected pill deselects: nothing
                            // is analysed until a region is chosen, and
                            // stepping back out has to be possible.
                            inspectedRegion = selected ? nil : region.placement
                        } label: {
                            Text(region.label)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(selected ? Color.white : accent)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(selected ? accent : Color.clear))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(needsModel(region.placement) && !modelInstalled)
                        .opacity(needsModel(region.placement) && !modelInstalled ? 0.4 : 1)
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LL.screenBackground))
            }

            Text(footnoteText)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if inspectedRegion != nil {
                maskDetail
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func needsModel(_ placement: OverlayPlacement) -> Bool {
        switch placement {
        case .sky, .land: return true
        case .none, .custom, .customInverted: return false
        }
    }

    private var footnoteText: String {
        if !modelInstalled && document.customMasks.isEmpty {
            return "Sky and Land need the segmentation model — download it in Settings ▸ AI Models. Text placement works without it, and a custom mask needs nothing."
        }
        return inspectedRegion == nil
            ? "Pick a region to inspect and tune it. Clicking it again deselects — nothing is analysed until one is chosen."
            : "Post-processing only. Masks are cached raw, so these dials cost no re-inference."
    }

    @ViewBuilder private var maskDetail: some View {
        VStack(alignment: .leading, spacing: 11) {
            Toggle(isOn: Binding(
                get: { showMask },
                set: { next in
                    showMask = next
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
                Spacer()
                HStack(spacing: 1) {
                    analysisPill("Sequence", mode: .sequence)
                    analysisPill("This frame", mode: .perFrame)
                }
                .padding(2)
                .background(Capsule().fill(LL.screenBackground))
            }

            dial("Threshold", value: $document.maskSettings.threshold,
                 range: 0.05...0.95, format: "%.2f")
            dial("Feather", value: $document.maskSettings.featherRadius,
                 range: 0...8, format: "%.1f")
            dial("Edge bias", value: $document.maskSettings.edgeBias,
                 range: 0...4, format: "%.1f")

            if let maskStatus {
                Text(maskStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }

    private func analysisPill(
        _ title: String, mode: SegmentationSettings.MaskMode
    ) -> some View {
        let selected = document.maskSettings.maskMode == mode
        return Button {
            guard !selected else { return }
            document.maskSettings.maskMode = mode
            // A finished gesture: the mode is part of the persisted document
            // (the export reads it), not just a view state.
            onEdited(true)
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(selected ? Color.white : accent)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(selected ? accent : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func dial(
        _ title: String, value: Binding<Double>,
        range: ClosedRange<Double>, format: String
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
            Text(String(format: format, value.wrappedValue))
                .font(.system(size: 11.5, weight: .semibold))
                .monospaced()
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    // MARK: - Custom masks

    private var customMasksCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Custom Masks")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(document.customMasks.count) \(document.customMasks.count == 1 ? "mask" : "masks")")
                    .font(.system(size: 11))
                    .monospaced()
                    .foregroundStyle(.secondary)
            }

            ForEach($document.customMasks) { $mask in
                maskRow($mask)
            }

            addMaskButton

            Text("Masks belong to the project, not the layer — every text layer can pick any of them.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let importError {
                Text(importError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private func maskRow(_ mask: Binding<CustomMask>) -> some View {
        let value = mask.wrappedValue
        let replacedElsewhere = document.customMasks
            .contains { $0.replacesSkyAndLand && $0.id != value.id }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                maskThumbnail(value)
                VStack(spacing: 5) {
                    TextField("Mask name", text: Binding(
                        get: { mask.wrappedValue.name },
                        set: { mask.wrappedValue.name = $0; onEdited(false) }))
                        .font(.system(size: 12.5, weight: .semibold))
                    TextField("Inverted name (optional)", text: Binding(
                        get: { mask.wrappedValue.invertedName },
                        set: { mask.wrappedValue.invertedName = $0; onEdited(false) }))
                        .font(.system(size: 12))
                }
                .textFieldStyle(.roundedBorder)
                .onSubmit { onEdited(true) }

                Button {
                    removeMask(value)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove mask")
            }
            .padding(10)

            Button {
                guard !replacedElsewhere else { return }
                mask.wrappedValue.replacesSkyAndLand.toggle()
                // Layers pointing at a region that just vanished would render
                // unoccluded with no way to see why; dropping them to None is
                // the honest state.
                pruneDanglingPlacements()
                onEdited(true)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: value.replacesSkyAndLand
                        ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundStyle(value.replacesSkyAndLand ? accent : .secondary)
                    Text(replaceLabel(value, replacedElsewhere: replacedElsewhere))
                        .font(.system(size: 11.5))
                        .foregroundStyle(
                            replacedElsewhere && !value.replacesSkyAndLand
                                ? Color.secondary.opacity(0.6) : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(value.replacesSkyAndLand ? accent.opacity(0.06) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(replacedElsewhere && !value.replacesSkyAndLand)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.09), lineWidth: 1))
    }

    private func replaceLabel(_ mask: CustomMask, replacedElsewhere: Bool) -> String {
        if mask.replacesSkyAndLand {
            return "Replacing Sky & Land — this project's pills are this mask's names"
        }
        return replacedElsewhere
            ? "Another mask already replaces Sky & Land"
            : "Replace Sky & Land (once per project)"
    }

    @ViewBuilder private func maskThumbnail(_ mask: CustomMask) -> some View {
        Group {
            if let image = thumbnail(mask) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.black.overlay(
                    Image(systemName: "questionmark")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary))
            }
        }
        .frame(width: 52, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var addMaskButton: some View {
        Button { importing = true } label: {
            VStack(spacing: 3) {
                Text("＋ Add Custom Mask")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                Text("Drop a black & white PNG or JPEG")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accent.opacity(0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(accent.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            importError = nil
            onImportMask(url)
            return true
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.png, .jpeg],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                importError = nil
                if let url = urls.first { onImportMask(url) }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
    }

    private func removeMask(_ mask: CustomMask) {
        document.customMasks.removeAll { $0.id == mask.id }
        if inspectedRegion?.customMaskID == mask.id { inspectedRegion = nil }
        pruneDanglingPlacements()
        onEdited(true)
    }

    /// Any layer pointing at a region that no longer exists falls back to
    /// None. Silently rendering unoccluded would look like a bug in the
    /// segmentation rather than a missing mask.
    private func pruneDanglingPlacements() {
        let live = Set(document.placementRegions.map(\.placement))
        for index in document.overlays.indices
        where document.overlays[index].placement != .none
            && !live.contains(document.overlays[index].placement) {
            document.overlays[index].placement = .none
        }
    }
}

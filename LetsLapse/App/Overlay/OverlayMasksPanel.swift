import SwiftUI
import LetsLapseKit
import UniformTypeIdentifiers

/// The Masks tab: the project's regions, and the shape of each one.
///
/// Separate from Text because what it authors belongs to the PROJECT, not to
/// a layer — every text layer can pick any of these regions, and so can any
/// grade. Rebuilt 2026-09-07 from the "Masks as Adjustment Layers" handoff:
/// a mask now has two homes, and the split is strict.
///
/// **This tab owns a mask's SHAPE** — create it, drag its handles, feather
/// it, tune the semantic dials, see what text is placed in it. The Editor
/// tab owns its **grade**. Same mask, two sides of it, and the tab is the
/// mode: a drag on the picture here draws masks, and a drag on the picture
/// there sets an armed slider.
struct OverlayMasksPanel: View {
    @Binding var document: OverlayDocument
    /// The region being inspected — drives the debug tint, the handles on the
    /// picture, and which mask to fetch. Editor state, not part of the piece.
    @Binding var inspectedRegion: OverlayPlacement?
    @Binding var showMask: Bool
    /// The creation tool, armed until it draws one mask. Owned by the viewer
    /// because the picture is where it is used.
    @Binding var tool: MaskShapeKind?
    /// Which segment of the detail card is showing.
    @Binding var detailSegment: MaskDetailSegment
    /// Whether the segmentation model is installed — the gate on Sky and
    /// Land only. Custom masks are files and shapes are arithmetic.
    let modelInstalled: Bool
    /// The mask readout — model, timing, cache state, or an error.
    let maskStatus: String?
    /// Whether the grid on screen carries confidence values at all. An
    /// argmax model on ONE frame returns a hard yes/no per cell, and a
    /// threshold applied to that cannot change the result — so the dial says
    /// so instead of pretending.
    let thresholdIsLive: Bool
    /// False for a single still, where there is no sequence to vote across.
    let canVoteAcrossFrames: Bool
    /// The picture's drawn size, for the shape captions. `.zero` before the
    /// pane has been laid out.
    let frameSize: CGSize
    let accent: Color
    let sources: MaskThumbnails.Sources
    /// Resolves a mask's thumbnail; the panel does not know where the
    /// project's files live.
    let thumbnail: (CustomMask) -> CGImage?
    let onEdited: (_ commit: Bool) -> Void
    /// Copies a dropped or picked file into the project and returns the mask.
    let onImportMask: (URL) -> Void
    /// "Grade <name>" — create-or-open the grade and jump to the Editor tab
    /// with it expanded.
    let onGradeInEditor: (MaskRef, Bool) -> Void

    @State private var importing = false
    @State private var importError: String?

    /// The mask the deck has selected, derived from the inspected region so
    /// the tint, the handles and the detail card can never disagree.
    private var selectedRef: MaskRef? { inspectedRegion?.maskRef?.ref }
    private var selectedMask: ProjectMask? { selectedRef.flatMap { document.projectMask($0) } }
    private var selectedInverted: Bool { inspectedRegion?.maskRef?.inverted ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            deckCard
            if let mask = selectedMask {
                detailCard(for: mask)
            }
            customMasksCard
        }
    }

    // MARK: - Toolbar

    /// The three ways to make a mask. Linear and Radial arm a tool — the next
    /// drag on the picture draws one and the tool disarms itself, so there is
    /// no mode to get stuck in.
    private var toolbar: some View {
        HStack(spacing: 8) {
            toolButton(.linear)
            toolButton(.radial)
            Button { importing = true } label: {
                Text("＋ Custom…")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(accent.opacity(0.04)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(accent.opacity(0.45),
                                          style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            }
            .buttonStyle(.plain)
        }
    }

    private func toolButton(_ kind: MaskShapeKind) -> some View {
        let armed = tool == kind
        return Button {
            tool = armed ? nil : kind
        } label: {
            Text(kind.displayName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(armed ? Color.white : accent)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(armed ? accent : LL.cardBackground))
                .shadow(color: .black.opacity(armed ? 0 : 0.06), radius: 1.5, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(armed ? [.isSelected] : [])
        .help(armed ? "Drag on the picture to draw it" : "Arm the \(kind.displayName) tool")
    }

    // MARK: - The deck

    private var deckCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Masks")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(document.projectMasks.count) \(document.projectMasks.count == 1 ? "mask" : "masks")")
                    .font(.system(size: 11))
                    .monospaced()
                    .foregroundStyle(.secondary)
            }
            if document.projectMasks.isEmpty {
                Text("This project has no regions yet. Draw a Linear or Radial mask on the picture, add a custom one below, or install the segmentation model for Sky and Land.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                    spacing: 10
                ) {
                    ForEach(document.projectMasks) { mask in
                        deckTile(mask)
                    }
                }
                Text("AUTO re-segments per seam · amber dot = graded inside · ⊘ = graded inverted")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func deckTile(_ mask: ProjectMask) -> some View {
        let selected = selectedRef == mask.ref
        let grades = document.maskGrades.filter { $0.mask == mask.ref && $0.isActive }
        return Button {
            // Clicking the selected tile deselects: nothing is analysed until
            // a region is chosen, and stepping back out has to be possible.
            inspectedRegion = selected ? nil : mask.ref.placement(inverted: false)
            detailSegment = .shape
        } label: {
            VStack(spacing: 4) {
                GeometryReader { proxy in
                    MaskTile(
                        mask: mask, size: CGSize(width: proxy.size.width,
                                                 height: proxy.size.width * 3 / 4),
                        sources: sources,
                        isSelected: selected,
                        isGraded: grades.contains { !$0.inverted },
                        cornerRadius: 7, accent: accent)
                        .overlay(alignment: .bottomLeading) {
                            if grades.contains(where: \.inverted) {
                                Image(systemName: "circle.slash")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(LL.amber)
                                    .padding(3)
                            }
                        }
                }
                .aspectRatio(4 / 3, contentMode: .fit)
                Text(mask.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .buttonStyle(.plain)
        .disabled(mask.kind.isAuto && !modelInstalled)
        .opacity(mask.kind.isAuto && !modelInstalled ? 0.4 : 1)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - Detail

    private func detailCard(for mask: ProjectMask) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            detailHeader(mask)
            LLInkSegment(
                options: MaskDetailSegment.allCases,
                label: \.rawValue,
                selection: $detailSegment)
                .frame(maxWidth: .infinity)
            switch detailSegment {
            case .shape: shapeSegment(mask)
            case .text: textSegment(mask)
            }
            Toggle(isOn: Binding(
                get: { showMask },
                set: { showMask = $0; onEdited(false) })) {
                Text("Show mask").font(.system(size: 13.5, weight: .semibold))
            }
            #if os(macOS)
            .toggleStyle(.checkbox)
            #endif
            .tint(accent)
            gradeInEditorRows(mask)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func detailHeader(_ mask: ProjectMask) -> some View {
        HStack(spacing: 10) {
            MaskTile(
                mask: mask, size: CGSize(width: 30, height: 24),
                sources: sources, showsAuto: false, cornerRadius: 5, accent: accent)
            if let index = shapeIndex(of: mask) {
                TextField("Mask name", text: Binding(
                    get: { document.shapeMasks[index].name },
                    set: { document.shapeMasks[index].name = $0; onEdited(false) }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .bold))
                    .onSubmit { onEdited(true) }
            } else {
                Text(mask.name)
                    .font(.system(size: 14, weight: .bold))
            }
            Spacer(minLength: 0)
            if mask.kind.isRemovableInDeck, let id = mask.ref.shapeMaskID {
                Button("Remove") {
                    inspectedRegion = nil
                    document.removeShapeMask(id: id)
                    onEdited(true)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
        }
    }

    private func shapeIndex(of mask: ProjectMask) -> Int? {
        guard let id = mask.ref.shapeMaskID else { return nil }
        return document.shapeMasks.firstIndex { $0.id == id }
    }

    // MARK: Shape segment

    @ViewBuilder private func shapeSegment(_ mask: ProjectMask) -> some View {
        switch mask.kind {
        case .shape:
            if let index = shapeIndex(of: mask) {
                parametricDials(index: index)
            }
        case .sky, .land:
            semanticDials
        case .custom:
            customDetail(mask)
        }
    }

    @ViewBuilder private func parametricDials(index: Int) -> some View {
        let shape = document.shapeMasks[index].shape
        VStack(alignment: .leading, spacing: 11) {
            dial("Feather", value: Binding(
                get: { document.shapeMasks[index].shape.feather },
                set: { document.shapeMasks[index].shape.feather = $0 }),
                 range: 0...1, format: { String(format: "%.0f%%", $0 * 100) })
            if shape.kind == .radial {
                dial("Rotation", value: Binding(
                    get: { document.shapeMasks[index].shape.rotationDegrees },
                    set: { document.shapeMasks[index].shape.rotationDegrees = $0 }),
                     range: MaskShape.rotationRange, format: { String(format: "%+.0f°", $0) })
            }
            Text(frameSize == .zero
                 ? "Drag the handles on the picture to move and resize it."
                 : "\(shape.sizeCaption(in: frameSize)) · drag the handles on the picture to move and resize it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Sky and Land's dials — unchanged from the shipped panel, moved into
    /// the detail card so every mask kind is edited in the same place.
    @ViewBuilder private var semanticDials: some View {
        VStack(alignment: .leading, spacing: 11) {
            // The assumption, stated — not a coin flip. A timelapse is shot
            // on a tripod, so the skyline is the same in every frame, and one
            // mask voted across the shoot beats any single frame's (measured
            // 2026-08-31: mean single 0.959, voted 0.975 against a
            // hand-drawn skyline). Re-detecting per frame is the exception,
            // for a camera that actually moved.
            if canVoteAcrossFrames {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(
                        get: { document.maskSettings.maskMode == .sequence },
                        set: { locked in
                            document.maskSettings.maskMode = locked ? .sequence : .perFrame
                            onEdited(true)
                        })) {
                        Text("Camera locked off")
                            .font(.system(size: 13.5, weight: .semibold))
                    }
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #endif
                    .tint(accent)

                    Text(document.maskSettings.maskMode == .sequence
                        ? "One mask for the whole shoot, voted across \(SceneMaskService.sequenceSampleCount) frames. Turn this off only if the camera moved."
                        : "Re-detecting on every frame. Slower, and it flickers where the model changes its mind — only worth it if the camera moved.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            dial("Threshold", value: $document.maskSettings.threshold,
                 range: 0.05...0.95, format: { String(format: "%.2f", $0) })
                .disabled(!thresholdIsLive)
                .opacity(thresholdIsLive ? 1 : 0.42)
            if !thresholdIsLive {
                Text("This model answers sky-or-not per cell with no confidence attached, so there is nothing for a threshold to cut. Voting across frames is what turns those answers into confidence.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            dial("Feather", value: $document.maskSettings.featherRadius,
                 range: 0...8, format: { String(format: "%.1f", $0) })
            // Bipolar: negative grows the occluder, so type tucks further
            // behind a spiky skyline instead of creeping over it.
            dial("Edge bias", value: $document.maskSettings.edgeBias,
                 range: -2...4, format: { String(format: "%+.1f", $0) })

            Text("Post-processing only. Masks are cached raw, so these dials cost no re-inference.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let maskStatus {
                Text(maskStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func customDetail(_ mask: ProjectMask) -> some View {
        if let id = mask.ref.customMaskID,
           let index = document.customMasks.firstIndex(where: { $0.id == id }) {
            let replacedElsewhere = document.customMasks
                .contains { $0.replacesSkyAndLand && $0.id != id }
            VStack(alignment: .leading, spacing: 9) {
                TextField("Inverted name (optional)", text: Binding(
                    get: { document.customMasks[index].invertedName },
                    set: { document.customMasks[index].invertedName = $0; onEdited(false) }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { onEdited(true) }
                Button {
                    guard !replacedElsewhere else { return }
                    document.customMasks[index].replacesSkyAndLand.toggle()
                    // Layers pointing at a region that just vanished would
                    // render unoccluded with no way to see why; dropping them
                    // to None is the honest state.
                    document.pruneDanglingPlacements()
                    onEdited(true)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: document.customMasks[index].replacesSkyAndLand
                            ? "checkmark.square.fill" : "square")
                            .font(.system(size: 12))
                            .foregroundStyle(document.customMasks[index].replacesSkyAndLand
                                             ? accent : .secondary)
                        Text(replaceLabel(document.customMasks[index],
                                          replacedElsewhere: replacedElsewhere))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(replacedElsewhere && !document.customMasks[index].replacesSkyAndLand)
            }
        }
    }

    /// One labelled slider with a monospaced readout — the shape every dial
    /// in this tab takes, semantic and parametric alike.
    private func dial(
        _ title: String, value: Binding<Double>,
        range: ClosedRange<Double>, format: @escaping (Double) -> String
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
            Text(format(value.wrappedValue))
                .font(.system(size: 11.5, weight: .semibold))
                .monospaced()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    // MARK: Text segment

    @ViewBuilder private func textSegment(_ mask: ProjectMask) -> some View {
        let inside = document.textLayers(placedIn: mask.ref, inverted: false)
        let outside = document.textLayers(placedIn: mask.ref, inverted: true)
        VStack(alignment: .leading, spacing: 8) {
            if inside.isEmpty && outside.isEmpty {
                Text("No text layers are placed in this region. Place one from the Text tab and the scene will occlude it here.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                layerRows(inside, heading: mask.name)
                layerRows(outside, heading: mask.invertedName)
            }
        }
    }

    @ViewBuilder private func layerRows(_ layers: [SceneOverlay], heading: String) -> some View {
        if !layers.isEmpty {
            Text(heading)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(layers) { layer in
                HStack(spacing: 8) {
                    Text(layer.label.isEmpty ? "—" : layer.label)
                        .font(.system(size: 11))
                        .monospaced()
                        .foregroundStyle(.secondary)
                    Text(layer.text)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text(layer.mode == .box ? "BOX" : "FREE")
                        .font(.system(size: 9.5, weight: .semibold))
                        .monospaced()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Grade in Editor

    /// The bridge back to the other half of a mask. Two rows, one per
    /// version — create-or-open, then over to the Editor tab with it open.
    private func gradeInEditorRows(_ mask: ProjectMask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Grade in Editor")
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            gradeRow(mask, inverted: false)
            gradeRow(mask, inverted: true)
        }
    }

    private func gradeRow(_ mask: ProjectMask, inverted: Bool) -> some View {
        let existing = document.maskGrade(for: mask.ref, inverted: inverted)
        return Button {
            onGradeInEditor(mask.ref, inverted)
        } label: {
            HStack(spacing: 9) {
                MaskTile(
                    mask: mask, inverted: inverted, size: CGSize(width: 30, height: 24),
                    sources: sources, showsAuto: false, cornerRadius: 5, accent: accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(existing == nil
                         ? "Grade \(mask.name(inverted: inverted))"
                         : mask.name(inverted: inverted))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(accent)
                    if let existing {
                        Text(existing.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(accent.opacity(existing == nil ? 0.04 : 0.09)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

            Text("Masks belong to the project, not the layer — every text layer can pick any of them, and any of them can carry a grade.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !modelInstalled {
                Text("Sky and Land need the segmentation model — download it in Settings ▸ AI Models. Drawn shapes and custom masks need nothing.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
        HStack(spacing: 10) {
            maskThumbnail(value)
            TextField("Mask name", text: Binding(
                get: { mask.wrappedValue.name },
                set: { mask.wrappedValue.name = $0; onEdited(false) }))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, weight: .semibold))
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
        .padding(9)
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
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accent.opacity(0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(accent.opacity(0.45),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
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
        document.maskGrades.removeAll { $0.mask == .custom(mask.id) }
        if inspectedRegion?.customMaskID == mask.id { inspectedRegion = nil }
        document.pruneDanglingPlacements()
        onEdited(true)
    }
}

/// Which half of the detail card is showing — a mask's shape, or the text
/// placed in it.
enum MaskDetailSegment: String, CaseIterable, Identifiable {
    case shape = "Shape"
    case text = "Text"
    var id: String { rawValue }
}

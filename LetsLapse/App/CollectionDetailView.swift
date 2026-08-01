import SwiftUI

/// The timeline builder: preview on top, canvas ratio chips, the clip rows
/// (select · trim · reorder), and the export path.
///
/// The preview IS the crop surface — it shows the selected clip itself filling
/// the space (never letterboxed by default; the canvas only shapes the white
/// crop frame). A clip that mismatches the canvas gets the draggable frame
/// right there; a tall clip fills the width and scrolls, with an "Apply
/// letterbox" pill to see it shrunk to fit instead. Past 560pt of width the
/// screen splits: preview left, controls right — iPhone landscape, iPad, Mac.
struct CollectionDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let collectionID: UUID

    @State private var selectedBlendID: UUID?
    @State private var letterboxPreview = false
    @State private var toast: String?

    @State private var cropDrag: CropDrag?
    @State private var cropPrompt: CropPrompt?

    @State private var reorder: ReorderState?

    @State private var showPicker = false
    @State private var trimEntry: LapseCollection.Entry?
    @State private var showRename = false
    @State private var renameDraft = ""
    @State private var confirmingDelete = false
    @State private var exportController: CollectionExportController?
    @State private var fullscreenRequest: FullscreenMediaRequest?

    private struct CropDrag: Equatable {
        var blendID: UUID
        var offset: Double
        var moved = false
    }

    private struct CropPrompt: Identifiable {
        let id = UUID()
        var blendID: UUID
        var ratio: CanvasRatio
        var offset: Double
        var clipLabel: String
    }

    private struct ReorderState {
        var blendID: UUID
        var fromIndex: Int
        var toIndex: Int
        var residualY: CGFloat
    }

    private let rowHeight: CGFloat = 66

    var body: some View {
        GeometryReader { geo in
            if let collection = model.collection(withID: collectionID) {
                Group {
                    if geo.size.width > 560 {
                        wideLayout(collection, size: geo.size)
                    } else {
                        portraitLayout(collection, width: geo.size.width - 32)
                    }
                }
                .navigationTitle(collection.name)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                renameDraft = collection.name
                                showRename = true
                            } label: {
                                Label("Rename collection", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                confirmingDelete = true
                            } label: {
                                Label("Delete collection…", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            } else {
                Color.clear.onAppear { dismiss() }
            }
        }
        .background(LL.screenBackground)
        .llToast($toast)
        .task {
            for entry in model.collection(withID: collectionID)?.entries ?? [] {
                if let blend = model.blends.first(where: { $0.id == entry.blendID }) {
                    await model.probeBlendMediaIfNeeded(blend)
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            CollectionClipPicker(collectionID: collectionID) { message in
                toast = message
            }
        }
        .alert("Rename collection", isPresented: $showRename) {
            TextField("Name", text: $renameDraft)
            Button("Save") { model.renameCollection(collectionID, to: renameDraft) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete collection?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                model.deleteCollection(collectionID)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The clips themselves stay in their projects — only the collection and its kept export are deleted.")
        }
        .alert(
            "Save this crop?",
            isPresented: Binding(
                get: { cropPrompt != nil },
                set: { if !$0 { cropPrompt = nil } }
            ),
            presenting: cropPrompt
        ) { prompt in
            Button("Replace the default") {
                model.setDefaultCrop(
                    blendID: prompt.blendID, ratio: prompt.ratio,
                    offset: prompt.offset, clearLocalIn: collectionID)
                cropDrag = nil
                toast = "Default \(prompt.ratio.rawValue) crop updated for every collection"
            }
            Button("Just for \(model.collection(withID: collectionID)?.name ?? "this collection")") {
                model.setLocalCrop(
                    blendID: prompt.blendID, in: collectionID,
                    ratio: prompt.ratio, offset: prompt.offset)
                cropDrag = nil
                toast = "Crop saved just for \(model.collection(withID: collectionID)?.name ?? "this collection")"
            }
            Button("Cancel", role: .cancel) {
                cropDrag = nil
            }
        } message: { prompt in
            Text("“\(prompt.clipLabel)” already has a default \(prompt.ratio.rawValue) crop that other collections use.")
        }
        .fullscreenMedia($fullscreenRequest, model: model)
        .collectionCover(item: $trimEntry) { entry in
            CollectionTrimView(collectionID: collectionID, blendID: entry.blendID) { message in
                toast = message
            }
            .environmentObject(model)
        }
        .collectionCover(isPresented: exportPresented) {
            if let exportController {
                CollectionExportFlowView(controller: exportController) { message in
                    toast = message
                }
                .environmentObject(model)
            }
        }
    }

    private var exportPresented: Binding<Bool> {
        Binding(
            get: { exportController != nil },
            set: { if !$0 { exportController = nil } }
        )
    }

    // MARK: - Portrait

    private func portraitLayout(_ collection: LapseCollection, width: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                previewSurface(collection, maxWidth: width, maxHeight: 300, landscape: false)
                    .frame(maxWidth: .infinity)

                Text(previewCaption(collection))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.horizontal, 14)

                sectionLabel("Canvas")
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                ratioChips(collection)
                Text(ratioCaption(collection))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .padding(.horizontal, 4)

                sectionLabel(timelineHeader(collection))
                    .padding(.top, 20)
                    .padding(.bottom, 8)

                if collection.entries.isEmpty {
                    emptyTimeline
                } else {
                    timelineCard(collection)

                    addClipsButton(height: 52)
                        .padding(.top, 12)

                    summaryCard(collection)
                        .padding(.top, 12)

                    Button("Export collection") { startExport() }
                        .buttonStyle(LLPrimaryButtonStyle())
                        .padding(.top, 12)

                    if let last = collection.lastExport {
                        lastExportRow(collection, last: last)
                            .padding(.top, 12)
                    }
                }

                // Clearance for the floating tab bar, so the export button
                // isn't stranded behind it at the end of the scroll.
                Spacer(minLength: 140)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }

    // MARK: - Wide (iPhone landscape, iPad, Mac)

    private func wideLayout(_ collection: LapseCollection, size: CGSize) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 8) {
                Spacer(minLength: 0)
                previewSurface(
                    collection,
                    maxWidth: min(size.width * 0.46, 420) - 20,
                    maxHeight: size.height - 120,
                    landscape: true)
                Text(previewCaption(collection))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                Spacer(minLength: 0)
            }
            .frame(width: min(size.width * 0.46, 420))

            VStack(alignment: .leading, spacing: 0) {
                ratioChips(collection)
                    .padding(.top, 10)
                Text("\(CollectionMath.timecode(model.collectionSeconds(collection))) · exports \(collection.ratio?.exportLabel ?? "—")")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .padding(.horizontal, 2)

                sectionLabel(timelineHeader(collection))
                    .padding(.top, 14)
                    .padding(.bottom, 6)

                ScrollView {
                    if collection.entries.isEmpty {
                        Button {
                            showPicker = true
                        } label: {
                            VStack(spacing: 4) {
                                Text("+ Add your first clip")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(LL.accent)
                                Text("Blended clips from any project can join")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 90)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                                    .foregroundStyle(Color.primary.opacity(0.18))
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        timelineCard(collection)
                    }
                    Spacer(minLength: 8)
                }

                HStack(spacing: 8) {
                    addClipsButton(height: 44)
                    Button("Export collection") { startExport() }
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(LL.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .buttonStyle(.plain)
                        .disabled(collection.entries.isEmpty)
                        .opacity(collection.entries.isEmpty ? 0.4 : 1)
                }
                .padding(.bottom, 10)
            }
            .padding(.trailing, 16)
        }
        .padding(.leading, 16)
    }

    // MARK: - Preview surface

    /// The selected clip filling its own shape, the crop frame over it when
    /// the canvas disagrees. All geometry in points, derived from the clip's
    /// display aspect.
    @ViewBuilder
    private func previewSurface(
        _ collection: LapseCollection, maxWidth: CGFloat, maxHeight: CGFloat, landscape: Bool
    ) -> some View {
        let entry = selectedEntry(collection)
        let blend = entry.flatMap { e in model.blends.first { $0.id == e.blendID } }

        if let entry, let blend {
            let aspect = model.blendAspect(blend)
            let tall = aspect < 1
            let letterboxed = !landscape && tall && letterboxPreview
            let clipSize: CGSize = {
                if landscape { return CollectionMath.fit(aspect: aspect, maxWidth: maxWidth, maxHeight: maxHeight) }
                if letterboxed { return CollectionMath.fit(aspect: aspect, maxWidth: maxWidth, maxHeight: 240) }
                if tall { return CollectionMath.fit(aspect: aspect, maxWidth: maxWidth, maxHeight: .greatestFiniteMagnitude) }
                return CollectionMath.fit(aspect: aspect, maxWidth: maxWidth, maxHeight: maxHeight)
            }()
            let wrapSize = letterboxed ? CGSize(width: maxWidth, height: 240) : clipSize
            let offset = displayedCropOffset(entry: entry, in: collection)
            let box = offset.flatMap { off in
                collection.ratio.flatMap { CollectionMath.cropBox(clipSize: clipSize, canvas: $0, offset: off) }
            }

            ZStack {
                Color.black

                ZStack(alignment: .topLeading) {
                    ProjectThumbnailView(url: model.mediaURL(for: blend), kind: .video)
                        .frame(width: clipSize.width, height: clipSize.height)
                        .clipped()

                    if let box {
                        cropFrame(box: box.rect, clipSize: clipSize, axis: box.axis, entry: entry, collection: collection)
                    } else {
                        Button {
                            playSelected(blend, title: collection.name)
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 17))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.black.opacity(0.45), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .position(x: clipSize.width / 2, y: clipSize.height / 2)
                    }
                }
                .frame(width: clipSize.width, height: clipSize.height)
            }
            .frame(width: wrapSize.width, height: wrapSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topLeading) {
                MediaBadge(text: "\(clipTitle(blend)) · \(blend.speedLabel)")
                    .padding(10)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                if !landscape && tall {
                    Button {
                        letterboxPreview.toggle()
                    } label: {
                        Text(letterboxPreview ? "Remove letterbox" : "Apply letterbox")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(LL.amber)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.55), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                }
            }
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black)
                .frame(width: maxWidth, height: (maxWidth * 9 / 16).rounded())
                .overlay(alignment: .topLeading) {
                    MediaBadge(text: "No clips yet")
                        .padding(10)
                }
        }
    }

    /// The draggable white frame with rule-of-thirds lines, surround dimmed.
    private func cropFrame(
        box: CGRect, clipSize: CGSize, axis: CollectionMath.Axis,
        entry: LapseCollection.Entry, collection: LapseCollection
    ) -> some View {
        ZStack(alignment: .topLeading) {
            // Dim everything the crop discards.
            DimOutside(cutout: box)
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

            ZStack {
                Rectangle().strokeBorder(.white, lineWidth: 2)
                Path { p in
                    for f in [1.0 / 3.0, 2.0 / 3.0] {
                        p.move(to: CGPoint(x: box.width * f, y: 0))
                        p.addLine(to: CGPoint(x: box.width * f, y: box.height))
                        p.move(to: CGPoint(x: 0, y: box.height * f))
                        p.addLine(to: CGPoint(x: box.width, y: box.height * f))
                    }
                }
                .stroke(.white.opacity(0.35), lineWidth: 1)
            }
            .frame(width: box.width, height: box.height)
            .contentShape(Rectangle())
            .offset(x: box.minX, y: box.minY)
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { gesture in
                        // The model's offset is frozen while the finger is
                        // down (commits happen on release), so it is the drag
                        // origin; the gesture's translation is total.
                        let slack = axis == .horizontal
                            ? clipSize.width - box.width
                            : clipSize.height - box.height
                        guard slack > 0.5 else { return }
                        let origin = model.resolvedCropOffset(entry: entry, in: collection) ?? 0.5
                        let delta = axis == .horizontal
                            ? gesture.translation.width : gesture.translation.height
                        let next = min(1, max(0, origin + Double(delta / slack)))
                        cropDrag = CropDrag(blendID: entry.blendID, offset: next, moved: true)
                    }
                    .onEnded { _ in
                        commitCrop(entry: entry, collection: collection)
                    }
            )
        }
        .frame(width: clipSize.width, height: clipSize.height, alignment: .topLeading)
    }

    /// Dims the clip outside the crop frame (even-odd fill).
    private struct DimOutside: Shape {
        var cutout: CGRect
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.addRect(rect)
            p.addRect(cutout)
            return p
        }
    }

    // MARK: - Crop logic

    private func displayedCropOffset(entry: LapseCollection.Entry, in collection: LapseCollection) -> Double? {
        if let cropDrag, cropDrag.blendID == entry.blendID {
            return cropDrag.offset
        }
        return model.resolvedCropOffset(entry: entry, in: collection)
    }

    /// The release rules: a collection-local crop updates in place; else a
    /// clip whose default is shared with other collections asks which one
    /// this drag was for; else the drag saves silently as the clip's default.
    private func commitCrop(entry: LapseCollection.Entry, collection: LapseCollection) {
        guard let drag = cropDrag, drag.moved, drag.blendID == entry.blendID,
              let ratio = collection.ratio,
              let blend = model.blends.first(where: { $0.id == entry.blendID }) else {
            cropDrag = nil
            return
        }
        if model.entryHasLocalCrop(entry, in: collection) {
            model.setLocalCrop(blendID: entry.blendID, in: collectionID, ratio: ratio, offset: drag.offset)
            cropDrag = nil
            toast = "Crop updated for this collection"
            return
        }
        let hasDefault = blend.defaultCrops?[ratio.rawValue] != nil
        let usedElsewhere = model.collectionsUsing(blendID: entry.blendID)
            .contains { $0.id != collectionID }
        if hasDefault && usedElsewhere {
            cropPrompt = CropPrompt(
                blendID: entry.blendID, ratio: ratio, offset: drag.offset,
                clipLabel: "\(clipTitle(blend)) · \(blend.speedLabel)")
        } else {
            model.setDefaultCrop(blendID: entry.blendID, ratio: ratio, offset: drag.offset, clearLocalIn: nil)
            cropDrag = nil
            toast = "Saved as this clip’s default \(ratio.rawValue) crop"
        }
    }

    // MARK: - Canvas chips

    private func ratioChips(_ collection: LapseCollection) -> some View {
        HStack(spacing: 8) {
            ForEach(CanvasRatio.allCases) { ratio in
                let selected = collection.ratio == ratio
                Button {
                    guard !collection.entries.isEmpty else { return }
                    model.setCanvasRatio(ratio, for: collectionID)
                } label: {
                    Text(ratio.rawValue)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(
                            selected ? .white
                                : (collection.entries.isEmpty ? Color.secondary.opacity(0.5) : .primary))
                        .padding(.horizontal, 13)
                        .frame(height: 33)
                        .background(
                            selected ? LL.accent : LL.cardBackground,
                            in: Capsule())
                        .shadow(color: .black.opacity(selected ? 0 : 0.06), radius: 1.5, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func ratioCaption(_ collection: LapseCollection) -> String {
        guard let ratio = collection.ratio, !collection.entries.isEmpty else {
            return "The first clip you add sets the canvas."
        }
        let firstRatio = collection.entries.first
            .flatMap { e in model.blends.first { $0.id == e.blendID } }
            .map(model.canvasRatio(for:))
        if let firstRatio, firstRatio != ratio {
            return "\(ratio.rawValue) — overriding the first clip’s \(firstRatio.rawValue). Export: \(ratio.exportLabel)."
        }
        return "\(ratio.rawValue) — set by the first clip added. Export: \(ratio.exportLabel)."
    }

    // MARK: - Timeline rows

    private func timelineHeader(_ collection: LapseCollection) -> String {
        collection.entries.isEmpty
            ? "Timeline"
            : "Timeline · \(collection.entries.count) \(collection.entries.count == 1 ? "clip" : "clips")"
    }

    private var emptyTimeline: some View {
        Button {
            showPicker = true
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(LL.accent)
                Text("Add your first clip")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LL.accent)
                Text("Blended clips from any project can join")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(Color.primary.opacity(0.18))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func addClipsButton(height: CGFloat) -> some View {
        Button {
            showPicker = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                Text("Add clips")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(LL.accent)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(Color.primary.opacity(0.18))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func timelineCard(_ collection: LapseCollection) -> some View {
        let entries = displayedEntries(collection)
        return VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                clipRow(entry, at: index, in: collection, count: entries.count)
            }
        }
        .llCard()
    }

    @ViewBuilder
    private func clipRow(
        _ entry: LapseCollection.Entry, at index: Int,
        in collection: LapseCollection, count: Int
    ) -> some View {
        let blend = model.blends.first { $0.id == entry.blendID }
        let selected = entry.blendID == selectedEntry(collection)?.blendID
        let isDraggedRow = reorder?.blendID == entry.blendID

        HStack(spacing: 10) {
            ZStack {
                ProjectThumbnailView(url: blend.map(model.mediaURL(for:)), kind: .video)
                    .frame(width: 58, height: 42)
                Image(systemName: "play.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(blend.map(clipTitle) ?? "Blended clip")
                    .font(.system(size: 14.5, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(rowSubtitle(entry, blend: blend))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    // Badges never compress — the sub text truncates instead.
                    if entry.isTrimmed {
                        Text("TRIMMED")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(LL.accentDeep)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(LL.amber.opacity(0.28), in: Capsule())
                            .fixedSize()
                    }
                    if let ratio = collection.ratio, let blend, model.blendNeedsCrop(blend, on: ratio) {
                        Text("CROP \(ratio.rawValue)\(model.entryHasLocalCrop(entry, in: collection) ? " · CUSTOM" : "")")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(LL.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1.5)
                            .background(LL.accent.opacity(0.06), in: Capsule())
                            .overlay(Capsule().strokeBorder(LL.accent.opacity(0.55), lineWidth: 1.2))
                            .fixedSize()
                    }
                }
            }
            Spacer(minLength: 0)

            Button {
                trimEntry = entry
            } label: {
                Image(systemName: "timeline.selection")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LL.accent)
                    .frame(width: 34, height: 34)
                    .background(LL.accent.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Trim in and out points")

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 15))
                .foregroundStyle(Color.secondary.opacity(0.6))
                .padding(.vertical, 12)
                .padding(.leading, 6)
                .contentShape(Rectangle())
                .highPriorityGesture(reorderGesture(entry: entry, in: collection))
                .accessibilityLabel("Reorder")
        }
        .padding(.horizontal, 12)
        .frame(height: rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isDraggedRow ? LL.cardBackground : (selected ? LL.accent.opacity(0.07) : Color.clear))
                .shadow(color: .black.opacity(isDraggedRow ? 0.18 : 0), radius: 10, y: 5)
        )
        .overlay(alignment: .bottom) {
            if index < count - 1 && !isDraggedRow {
                Divider().padding(.leading, 80)
            }
        }
        .offset(y: isDraggedRow ? (reorder?.residualY ?? 0) : 0)
        .zIndex(isDraggedRow ? 5 : 0)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedBlendID = entry.blendID
            cropDrag = nil
        }
        .animation(isDraggedRow ? nil : .spring(response: 0.3, dampingFraction: 0.86), value: reorder?.toIndex)
    }

    /// Reordering happens visually while the finger moves and lands in the
    /// model once, on release.
    private func reorderGesture(entry: LapseCollection.Entry, in collection: LapseCollection) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { gesture in
                // The model's order is untouched during the drag, so the
                // entry's model index is the stable "from".
                guard let fromIndex = collection.entries.firstIndex(where: { $0.blendID == entry.blendID })
                else { return }
                let count = collection.entries.count
                let to = min(count - 1, max(0, fromIndex + Int((gesture.translation.height / rowHeight).rounded())))
                reorder = ReorderState(
                    blendID: entry.blendID,
                    fromIndex: fromIndex,
                    toIndex: to,
                    residualY: gesture.translation.height - CGFloat(to - fromIndex) * rowHeight)
            }
            .onEnded { _ in
                if let reorder, reorder.fromIndex != reorder.toIndex {
                    model.moveEntry(in: collectionID, from: reorder.fromIndex, to: reorder.toIndex)
                }
                reorder = nil
            }
    }

    private func displayedEntries(_ collection: LapseCollection) -> [LapseCollection.Entry] {
        guard let reorder, collection.entries.indices.contains(reorder.fromIndex) else {
            return collection.entries
        }
        var entries = collection.entries
        let moved = entries.remove(at: reorder.fromIndex)
        entries.insert(moved, at: min(reorder.toIndex, entries.count))
        return entries
    }

    // MARK: - Summary + export

    private func summaryCard(_ collection: LapseCollection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(CollectionMath.timecode(model.collectionSeconds(collection)))
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("exports \(collection.ratio?.exportLabel ?? "—")")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
            }
            Text("\(collection.clipCountLabel)\(collection.ratio.map { " · \($0.rawValue) canvas" } ?? "")")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.65))
                .padding(.top, 2)
            Text("Trims retime the cut automatically — clips always butt together.")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LL.ink, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func lastExportRow(_ collection: LapseCollection, last: LapseCollection.ExportRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.green)
            Text("Last export kept · \(last.exportedAt.formatted(.relative(presentation: .named)))")
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let url = keptRenderURL(collection, last: last) {
                ShareLink(item: url) {
                    Text("Share")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(LL.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .llCard(cornerRadius: 14)
    }

    private func keptRenderURL(_ collection: LapseCollection, last: LapseCollection.ExportRecord) -> URL? {
        let url = model.collectionRenderFolderURL(for: collection.id)
            .appendingPathComponent(last.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func startExport() {
        guard let collection = model.collection(withID: collectionID),
              !collection.entries.isEmpty else { return }
        let controller = CollectionExportController(model: model, collectionID: collectionID)
        exportController = controller
        controller.start()
    }

    // MARK: - Small helpers

    private func selectedEntry(_ collection: LapseCollection) -> LapseCollection.Entry? {
        collection.entries.first { $0.blendID == selectedBlendID } ?? collection.entries.first
    }

    private func clipTitle(_ blend: AppModel.BlendProject) -> String {
        model.capture(for: blend)?.displayTitle ?? "Blended clip"
    }

    private func rowSubtitle(_ entry: LapseCollection.Entry, blend: AppModel.BlendProject?) -> String {
        guard let blend else { return "" }
        let kept = model.entrySeconds(entry)
        var text = "\(blend.speedLabel) · \(SpeedMath.clipLengthCompact(kept))"
        if entry.isTrimmed, let full = model.blendDuration(for: blend) {
            text += " of \(SpeedMath.clipLengthCompact(full))"
        }
        return text
    }

    private func previewCaption(_ collection: LapseCollection) -> String {
        guard let entry = selectedEntry(collection),
              let blend = model.blends.first(where: { $0.id == entry.blendID }) else {
            return "Add a clip — the first one sets the canvas."
        }
        guard let ratio = collection.ratio else {
            return "Add a clip — the first one sets the canvas."
        }
        guard model.blendNeedsCrop(blend, on: ratio) else {
            return "This clip matches the \(ratio.rawValue) canvas — nothing to crop."
        }
        guard let pixels = model.blendDisplaySize(for: blend),
              let offset = displayedCropOffset(entry: entry, in: collection),
              let box = CollectionMath.cropBox(clipSize: pixels, canvas: ratio, offset: offset) else {
            return "Drag the white frame to choose the \(ratio.rawValue) crop."
        }
        let kw = Int(box.rect.width.rounded())
        let kh = Int(box.rect.height.rounded())
        return "Drag the white frame — it keeps \(kw)×\(kh) of \(Int(pixels.width))×\(Int(pixels.height)) for the \(ratio.rawValue) export."
    }

    private func playSelected(_ blend: AppModel.BlendProject, title: String) {
        fullscreenRequest = FullscreenMediaRequest(
            .video(url: model.mediaURL(for: blend), grade: nil),
            title: title)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 13, weight: .semibold))
            .kerning(0.5)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }
}

// MARK: - Cover helper

extension View {
    /// Collections' modal editors: full-screen covers on iOS, sheets on macOS
    /// (which has no `fullScreenCover`).
    @ViewBuilder
    func collectionCover<Item: Identifiable, C: View>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> C
    ) -> some View {
        #if os(iOS)
        fullScreenCover(item: item, content: content)
        #else
        sheet(item: item) { value in
            content(value).frame(minWidth: 560, minHeight: 480)
        }
        #endif
    }

    @ViewBuilder
    func collectionCover<C: View>(
        isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> C
    ) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented) {
            content().frame(minWidth: 560, minHeight: 480)
        }
        #endif
    }
}

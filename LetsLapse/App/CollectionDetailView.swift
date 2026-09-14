import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The timeline builder: preview on top wearing its own controls (clip badge
/// top-left, canvas menu chip bottom-right), the timeline header carrying the
/// Ken Burns tri-state (Off · Auto · Custom), the clip rows (select · trim ·
/// reorder) right under it, then the export path. Custom's pacing/join
/// options live in a drawer off the control — Apply keeps, Cancel restores —
/// so the working loop never scrolls past a card of settings.
///
/// The preview IS the crop surface — it shows the selected clip itself filling
/// the space (never letterboxed by default; the canvas only shapes the white
/// crop frame). A clip that mismatches the canvas gets the draggable frame
/// right there, with the honest-pixels readout appearing only while a finger
/// holds it; a tall clip fills the width and scrolls, with an "Apply
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
    /// The honest-pixels readout held on screen for a beat after the crop
    /// drag lets go — the caption that used to live under the preview, now
    /// only at the moment it matters.
    @State private var cropHUDLinger: CropHUDLinger?

    /// The Custom drawer's session: what Cancel restores, and whether Apply
    /// was pressed. Any dismissal without Apply restores the snapshot.
    @State private var kenBurnsDrawerPresented = false
    @State private var kenBurnsDrawerSnapshot: LapseCollection.KenBurnsSettings?
    @State private var kenBurnsDrawerApplied = false

    /// Which framing of the selected clip's Ken Burns move the preview edits.
    @State private var kenBurnsEnd: KenBurnsMoveEnd = .start
    /// The framing in flight under a finger — the model commits on release.
    @State private var moveEdit: MoveEdit?
    /// A pinch owns the framing while it lasts; the frame drag stands down.
    @State private var pinchActive = false

    @State private var reorder: ReorderState?

    #if os(macOS)
    /// The preview's frame in window space — scopes the scroll-wheel
    /// monitor to the framing surface.
    @State private var macPreviewFrame: CGRect = .zero
    @State private var macScrollMonitor: Any?
    /// Wheel ticks stream with no clean end; edits ride `moveEdit` and this
    /// debounce commits once the wheel goes quiet.
    @State private var macScrollCommit: Task<Void, Never>?
    #endif

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

    private struct MoveEdit: Equatable {
        var blendID: UUID
        var end: KenBurnsMoveEnd
        var framing: LapseCollection.Entry.KenBurnsFraming
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

    private struct CropHUDLinger: Equatable {
        var text: String
        var id = UUID()
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
            } else {
                Color.clear.onAppear { dismiss() }
            }
        }
        .background(LL.screenBackground)
        // Navigation config lives out here on the stable view, not on the
        // conditional inside the GeometryReader — same shape as
        // ProjectDetailView, so the bar never depends on the lookup branch.
        .navigationTitle(model.collection(withID: collectionID)?.name ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        renameDraft = model.collection(withID: collectionID)?.name ?? ""
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
        .llToast($toast)
        .onChange(of: selectedBlendID) { _, _ in
            kenBurnsEnd = .start
            moveEdit = nil
            cropHUDLinger = nil
        }
        #if os(macOS)
        .onAppear(perform: installMacScrollZoom)
        .onDisappear(perform: removeMacScrollZoom)
        #endif
        .task {
            for entry in model.collection(withID: collectionID)?.entries ?? [] {
                if let blend = model.blend(id: entry.blendID) {
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
            CollectionTrimView(
                collectionID: collectionID, blendID: entry.blendID,
                windowSeconds: kenBurnsWindowSeconds
            ) { message in
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

                // The captions and the chips row are gone — the preview wears
                // the canvas menu itself, so the timeline starts right here,
                // its header carrying the Ken Burns tri-state.
                timelineHeaderRow(collection)
                    .padding(.top, 14)
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
                Spacer(minLength: 0)
            }
            .frame(width: min(size.width * 0.46, 420))

            VStack(alignment: .leading, spacing: 0) {
                // The compact meta line is the wide layout's summary card —
                // the canvas menu lives on the preview now.
                Text("\(CollectionMath.timecode(model.collectionSeconds(collection))) · exports \(collection.ratio?.exportLabel ?? "—")")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                    .padding(.horizontal, 2)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        timelineHeaderRow(collection)
                            .padding(.top, 12)
                            .padding(.bottom, 6)

                        if collection.entries.isEmpty {
                            Button {
                                showPicker = true
                            } label: {
                                VStack(spacing: 4) {
                                    Text("+ Add your first clip")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(LL.accent)
                                    Text("Blended clips from any project can join — the first sets the canvas")
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
        let blend = entry.flatMap { e in model.blend(id: e.blendID) }

        if let entry, let blend {
            let aspect = model.blendAspect(blend)
            let tall = aspect < 1
            let letterboxed = !landscape && tall && letterboxPreview
            let kenBurnsOn = collection.kenBurnsEnabled
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

            VStack(spacing: 8) {
                ZStack {
                    Color.black

                    ZStack(alignment: .topLeading) {
                        ProjectThumbnailView(url: model.mediaURL(for: blend), kind: .video)
                            .frame(width: clipSize.width, height: clipSize.height)
                            .clipped()

                        if kenBurnsOn {
                            kenBurnsFrameOverlay(entry: entry, collection: collection, clipSize: clipSize)
                        } else if let box {
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
                    // The canvas choice rides the canvas — opposite corner to
                    // the clip badge. A drag that starts on it goes to the
                    // menu, so the crop/framing frames are dragged from
                    // anywhere else on the surface.
                    canvasRatioMenu(collection)
                        .padding(10)
                }
                .overlay(alignment: .bottomLeading) {
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
                .overlay(alignment: .top) {
                    // Honest pixels, only while a hand is in the crop (and a
                    // beat after): what the white frame keeps of the source.
                    if cropPrompt == nil, let text = cropHUDText(entry: entry, in: collection) {
                        Text(text)
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.5), in: Capsule())
                            // Below the clip badge's line — the two share the
                            // top of a narrow preview (tall clip, wide layout).
                            .padding(.top, 40)
                            .allowsHitTesting(false)
                    }
                }
                .simultaneousGesture(kenBurnsPinch(entry: entry, collection: collection, enabled: kenBurnsOn))
                #if os(macOS)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { macPreviewFrame = geo.frame(in: .global) }
                            .onChange(of: geo.frame(in: .global)) { _, frame in
                                macPreviewFrame = frame
                            }
                    }
                )
                #endif

                if kenBurnsOn {
                    kenBurnsFramingBar(entry: entry, collection: collection)
                        .frame(width: wrapSize.width)
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
                        lingerCropHUD(entry: entry, collection: collection)
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

    // MARK: - Ken Burns framing editor

    /// The move as the preview should draw it right now: the committed value,
    /// with the framing under a finger substituted in.
    private func displayedKenBurnsMove(
        entry: LapseCollection.Entry, in collection: LapseCollection
    ) -> LapseCollection.Entry.KenBurnsMove {
        var move = model.kenBurnsResolvedMove(entry: entry, in: collection)
        if let moveEdit, moveEdit.blendID == entry.blendID {
            switch moveEdit.end {
            case .start: move.start = moveEdit.framing
            case .end: move.end = moveEdit.framing
            }
        }
        return move
    }

    /// Both framings, identity-styled: the start frame is always white, the
    /// end frame always amber — colour is identity, never selection. The one
    /// under edit is solid with thirds (drag to place it, pinch anywhere on
    /// the clip to zoom it); the other is dashed in its own colour. Corner
    /// ties and an amber arrow draw the travel between them, and tapping the
    /// dashed frame selects it.
    private func kenBurnsFrameOverlay(
        entry: LapseCollection.Entry, collection: LapseCollection, clipSize: CGSize
    ) -> some View {
        let base = model.kenBurnsUnitBase(entry: entry, in: collection)
        let move = displayedKenBurnsMove(entry: entry, in: collection)
        let startRect = pointsRect(CollectionMath.kenBurnsUnitRect(base: base, framing: move.start), in: clipSize)
        let endRect = pointsRect(CollectionMath.kenBurnsUnitRect(base: base, framing: move.end), in: clipSize)
        let active = kenBurnsEnd == .start ? startRect : endRect
        let inactive = kenBurnsEnd == .start ? endRect : startRect
        let distinct = abs(endRect.midX - startRect.midX) + abs(endRect.midY - startRect.midY)
            + abs(endRect.width - startRect.width) > 6

        return ZStack(alignment: .topLeading) {
            DimOutside(cutout: active)
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

            if distinct {
                KenBurnsTravel(start: startRect, end: endRect)
                    .allowsHitTesting(false)

                kenBurnsIdentityFrame(
                    rect: inactive,
                    end: kenBurnsEnd == .start ? .end : .start,
                    isActive: false)
                    .allowsHitTesting(false)
            }

            kenBurnsIdentityFrame(rect: active, end: kenBurnsEnd, isActive: true)
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { gesture in
                        guard !pinchActive else { return }
                        // The committed framing is frozen while the finger is
                        // down, so it is the drag origin; translation is total.
                        var framing = committedKenBurnsFraming(entry: entry, in: collection)
                        framing.centerX += Double(gesture.translation.width / clipSize.width)
                        framing.centerY += Double(gesture.translation.height / clipSize.height)
                        moveEdit = MoveEdit(
                            blendID: entry.blendID, end: kenBurnsEnd,
                            framing: CollectionMath.clampedKenBurnsFraming(base: base, framing: framing),
                            moved: true)
                    }
                    .onEnded { _ in
                        guard !pinchActive else { return }
                        commitMoveEdit(entry: entry)
                    }
            )

            #if os(macOS)
            kenBurnsResizeHandles(
                rect: active, entry: entry, collection: collection,
                base: base, clipSize: clipSize)
            #endif
        }
        .frame(width: clipSize.width, height: clipSize.height, alignment: .topLeading)
        .contentShape(Rectangle())
        // Tap the dashed frame to select that end. The solid frame's drag
        // fails on a stationary touch, so the tap comes through even where
        // the two overlap — a tap there reaches for the other one.
        .gesture(
            SpatialTapGesture()
                .onEnded { value in
                    guard distinct,
                          inactive.insetBy(dx: -10, dy: -10).contains(value.location)
                    else { return }
                    kenBurnsEnd = kenBurnsEnd == .start ? .end : .start
                    moveEdit = nil
                }
        )
    }

    /// One framing drawn in its identity — white for the start, amber for
    /// the end. Active gets the solid 2pt stroke and thirds; inactive is
    /// dashed. The tag rides a fixed corner (START bottom-left, END
    /// top-right) so the ends read apart even while they overlap; the clip
    /// badge owns the preview's top-left, the canvas chip its bottom-right.
    private func kenBurnsIdentityFrame(
        rect: CGRect, end: KenBurnsMoveEnd, isActive: Bool
    ) -> some View {
        let color: Color = end == .start ? .white : LL.amber
        return Group {
            if isActive {
                ZStack {
                    Rectangle().strokeBorder(color, lineWidth: 2)
                    Path { p in
                        for f in [1.0 / 3.0, 2.0 / 3.0] {
                            p.move(to: CGPoint(x: rect.width * f, y: 0))
                            p.addLine(to: CGPoint(x: rect.width * f, y: rect.height))
                            p.move(to: CGPoint(x: 0, y: rect.height * f))
                            p.addLine(to: CGPoint(x: rect.width, y: rect.height * f))
                        }
                    }
                    .stroke(color.opacity(0.35), lineWidth: 1)
                }
            } else {
                Rectangle()
                    .strokeBorder(color.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
        }
        .frame(width: rect.width, height: rect.height)
        .overlay(alignment: end == .start ? .bottomLeading : .topTrailing) {
            kenBurnsEndTag(end)
                .padding(3)
        }
        .contentShape(Rectangle())
        .offset(x: rect.minX, y: rect.minY)
    }

    /// The identity tag: a dot in the end's colour plus its name, on the
    /// same dark capsule every on-media label uses.
    private func kenBurnsEndTag(_ end: KenBurnsMoveEnd) -> some View {
        let color: Color = end == .start ? .white : LL.amber
        return HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(end == .start ? "START" : "END")
                .font(.system(size: 8.5, weight: .bold))
                .kerning(0.5)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.black.opacity(0.55), in: Capsule())
    }

    #if os(macOS)
    /// Corner grips on the active framing — a Magnify gesture needs a
    /// trackpad, so mouse users resize by the corners instead. Dragging a
    /// grip scales the frame about its centre, exactly like the pinch, and
    /// commits on release like every other framing edit.
    private func kenBurnsResizeHandles(
        rect: CGRect, entry: LapseCollection.Entry, collection: LapseCollection,
        base: CGRect, clipSize: CGSize
    ) -> some View {
        let color: Color = kenBurnsEnd == .start ? .white : LL.amber
        let signs: [(x: CGFloat, y: CGFloat)] = [(-1, -1), (1, -1), (-1, 1), (1, 1)]
        return ForEach(0..<4, id: \.self) { index in
            let sign = signs[index]
            Rectangle()
                .fill(color)
                .frame(width: 7, height: 7)
                .overlay(Rectangle().strokeBorder(.black.opacity(0.55), lineWidth: 1))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .position(
                    x: rect.midX + sign.x * rect.width / 2,
                    y: rect.midY + sign.y * rect.height / 2)
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { gesture in
                            // The committed framing is frozen while the mouse
                            // is down, so it anchors the scale; translation
                            // is total.
                            var framing = committedKenBurnsFraming(entry: entry, in: collection)
                            let startRect = pointsRect(
                                CollectionMath.kenBurnsUnitRect(base: base, framing: framing),
                                in: clipSize)
                            let corner = CGPoint(
                                x: startRect.midX + sign.x * startRect.width / 2,
                                y: startRect.midY + sign.y * startRect.height / 2)
                            let dragged = CGPoint(
                                x: corner.x + gesture.translation.width,
                                y: corner.y + gesture.translation.height)
                            let before = max(4, hypot(corner.x - startRect.midX, corner.y - startRect.midY))
                            let after = max(4, hypot(dragged.x - startRect.midX, dragged.y - startRect.midY))
                            framing.zoom *= Double(before / after)
                            moveEdit = MoveEdit(
                                blendID: entry.blendID, end: kenBurnsEnd,
                                framing: CollectionMath.clampedKenBurnsFraming(base: base, framing: framing),
                                moved: true)
                        }
                        .onEnded { _ in
                            commitMoveEdit(entry: entry)
                        }
                )
        }
    }
    #endif

    /// The travel between the two framings: thin ties joining corresponding
    /// corners, and an amber arrow from the start's centre toward the end's.
    /// A pure zoom skips the arrow — the converging ties already read as the
    /// push.
    private struct KenBurnsTravel: View {
        var start: CGRect
        var end: CGRect

        var body: some View {
            let a = CGPoint(x: start.midX, y: start.midY)
            let b = CGPoint(x: end.midX, y: end.midY)
            let travel = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()

            ZStack(alignment: .topLeading) {
                Path { p in
                    p.move(to: CGPoint(x: start.minX, y: start.minY))
                    p.addLine(to: CGPoint(x: end.minX, y: end.minY))
                    p.move(to: CGPoint(x: start.maxX, y: start.minY))
                    p.addLine(to: CGPoint(x: end.maxX, y: end.minY))
                    p.move(to: CGPoint(x: start.minX, y: start.maxY))
                    p.addLine(to: CGPoint(x: end.minX, y: end.maxY))
                    p.move(to: CGPoint(x: start.maxX, y: start.maxY))
                    p.addLine(to: CGPoint(x: end.maxX, y: end.maxY))
                }
                .stroke(.white.opacity(0.22), lineWidth: 1)

                if travel > 12 {
                    let arrow = Path { p in
                        let ux = (b.x - a.x) / travel
                        let uy = (b.y - a.y) / travel
                        let head = CGPoint(x: b.x - ux * 7, y: b.y - uy * 7)
                        p.move(to: a)
                        p.addLine(to: head)
                        p.move(to: b)
                        p.addLine(to: CGPoint(x: head.x - uy * 3.5, y: head.y + ux * 3.5))
                        p.move(to: b)
                        p.addLine(to: CGPoint(x: head.x + uy * 3.5, y: head.y - ux * 3.5))
                    }
                    // Dark halo first — amber alone sinks into bright footage.
                    arrow.stroke(.black.opacity(0.4), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    arrow.stroke(LL.amber.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
            }
        }
    }

    /// Pinch anywhere on the clip to resize the active framing — spreading
    /// fingers GROWS the frame (you are pinching the frame, not the photo;
    /// the photo-style inverse felt backwards on device). The centre holds.
    private func kenBurnsPinch(
        entry: LapseCollection.Entry, collection: LapseCollection, enabled: Bool
    ) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.02)
            .onChanged { value in
                guard enabled else { return }
                pinchActive = true
                let base = model.kenBurnsUnitBase(entry: entry, in: collection)
                var framing = committedKenBurnsFraming(entry: entry, in: collection)
                framing.zoom /= Double(value.magnification)
                moveEdit = MoveEdit(
                    blendID: entry.blendID, end: kenBurnsEnd,
                    framing: CollectionMath.clampedKenBurnsFraming(base: base, framing: framing),
                    moved: true)
            }
            .onEnded { _ in
                guard enabled else { return }
                commitMoveEdit(entry: entry)
                pinchActive = false
            }
    }

    private func committedKenBurnsFraming(
        entry: LapseCollection.Entry, in collection: LapseCollection
    ) -> LapseCollection.Entry.KenBurnsFraming {
        let move = model.kenBurnsResolvedMove(entry: entry, in: collection)
        return kenBurnsEnd == .start ? move.start : move.end
    }

    #if os(macOS)
    /// Mouse-wheel resize for the active framing — the Magnify gesture needs
    /// a trackpad, so a wheel must not leave mouse users stranded. A local
    /// monitor scoped to the preview's frame turns wheel ticks into the same
    /// clamped zoom the pinch writes: wheel up grows the frame, matching the
    /// spread-to-grow pinch. Events over the preview are swallowed so no
    /// enclosing scroll view fights the resize; everything else passes
    /// through untouched.
    private func installMacScrollZoom() {
        guard macScrollMonitor == nil else { return }
        macScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated {
                handleMacScrollEvent(event)
            }
        }
    }

    private func removeMacScrollZoom() {
        if let macScrollMonitor {
            NSEvent.removeMonitor(macScrollMonitor)
        }
        macScrollMonitor = nil
        macScrollCommit?.cancel()
        macScrollCommit = nil
    }

    private func handleMacScrollEvent(_ event: NSEvent) -> NSEvent? {
        guard let contentView = event.window?.contentView else { return event }
        var point = contentView.convert(event.locationInWindow, from: nil)
        if !contentView.isFlipped {
            point.y = contentView.bounds.height - point.y
        }
        guard macPreviewFrame.contains(point),
              let collection = model.collection(withID: collectionID),
              collection.kenBurnsEnabled,
              let entry = selectedEntry(collection)
        else { return event }

        let base = model.kenBurnsUnitBase(entry: entry, in: collection)
        var framing: LapseCollection.Entry.KenBurnsFraming
        if let moveEdit, moveEdit.blendID == entry.blendID, moveEdit.end == kenBurnsEnd {
            framing = moveEdit.framing
        } else {
            framing = committedKenBurnsFraming(entry: entry, in: collection)
        }
        let perTick = event.hasPreciseScrollingDeltas ? 0.004 : 0.05
        framing.zoom /= exp(Double(event.scrollingDeltaY) * perTick)
        moveEdit = MoveEdit(
            blendID: entry.blendID, end: kenBurnsEnd,
            framing: CollectionMath.clampedKenBurnsFraming(base: base, framing: framing),
            moved: true)

        macScrollCommit?.cancel()
        macScrollCommit = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.35))
            guard !Task.isCancelled else { return }
            commitMoveEdit(entry: entry)
        }
        return nil
    }
    #endif

    private func commitMoveEdit(entry: LapseCollection.Entry) {
        guard let edit = moveEdit, edit.moved, edit.blendID == entry.blendID else {
            moveEdit = nil
            return
        }
        model.setKenBurnsFraming(
            blendID: entry.blendID, in: collectionID, end: edit.end, framing: edit.framing)
        moveEdit = nil
    }

    /// Start/End pills wearing their frames' identity dots (white = start,
    /// amber = end — same colours as the canvas), the active framing's zoom,
    /// and the way back to the dealt move once a hand has been in it.
    private func kenBurnsFramingBar(
        entry: LapseCollection.Entry, collection: LapseCollection
    ) -> some View {
        let move = displayedKenBurnsMove(entry: entry, in: collection)
        let zoom = (kenBurnsEnd == .start ? move.start : move.end).zoom

        return HStack(spacing: 8) {
            ForEach(KenBurnsMoveEnd.allCases, id: \.rawValue) { end in
                Button {
                    kenBurnsEnd = end
                    moveEdit = nil
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(end == .start ? Color.white : LL.amber)
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                            .frame(width: 7, height: 7)
                        Text(end == .start ? "START" : "END")
                            .font(.system(size: 10.5, weight: .bold))
                            .kerning(0.5)
                            .foregroundStyle(kenBurnsEnd == end ? .white : LL.accent)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(kenBurnsEnd == end ? LL.accent : LL.accent.opacity(0.09)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Text(String(format: "%.2f×", zoom))
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if entry.kenBurns?.isCustom == true {
                // Accent, not amber — amber now means "the end framing", and
                // this resets the whole move.
                Button("Reset move") {
                    model.resetKenBurnsMove(blendID: entry.blendID, in: collectionID)
                    moveEdit = nil
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(LL.accent)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
    }

    private func pointsRect(_ unit: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: unit.minX * size.width, y: unit.minY * size.height,
            width: unit.width * size.width, height: unit.height * size.height)
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
              let blend = model.blend(id: entry.blendID) else {
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

    // MARK: - Canvas menu

    /// Widest to square to tallest — the order a shape scan reads.
    private static let canvasMenuOrder: [CanvasRatio] = [.wide, .classic, .square, .portrait, .tall]

    /// The canvas choice as an on-media chip inside the preview's
    /// bottom-right corner — the ratio is a property of the canvas, so it
    /// rides the canvas. Rows are just the ratios (the summary card already
    /// says what they export at), with the first clip's own shape marked.
    /// Only drawn with the preview, so an empty collection never shows it.
    private func canvasRatioMenu(_ collection: LapseCollection) -> some View {
        Menu {
            ForEach(Self.canvasMenuOrder) { ratio in
                Button {
                    model.setCanvasRatio(ratio, for: collectionID)
                } label: {
                    if ratio == collection.ratio {
                        Label(ratioChoiceLabel(ratio, in: collection), systemImage: "checkmark")
                    } else {
                        Text(ratioChoiceLabel(ratio, in: collection))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(collection.ratio?.rawValue ?? "Canvas")
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Canvas \(collection.ratio?.rawValue ?? "unset")")
    }

    /// "16:9", "4:3 · the first clip’s shape"
    private func ratioChoiceLabel(_ ratio: CanvasRatio, in collection: LapseCollection) -> String {
        let firstRatio = collection.entries.first
            .flatMap { e in model.blend(id: e.blendID) }
            .map(model.canvasRatio(for:))
        var label = ratio.rawValue
        if ratio == firstRatio {
            label += " · the first clip’s shape"
        }
        return label
    }

    // MARK: - Ken Burns

    /// TIMELINE · N CLIPS on the left, the Ken Burns tri-state on the right —
    /// one row, so the mode lives where the eye moves between the preview and
    /// the rows. The label drops its TIMELINE word before anything truncates.
    private func timelineHeaderRow(_ collection: LapseCollection) -> some View {
        HStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                sectionLabel(timelineHeader(collection)).fixedSize()
                sectionLabel(shortTimelineHeader(collection)).fixedSize()
            }
            Spacer(minLength: 8)
            if !collection.entries.isEmpty {
                kenBurnsModeControl(collection)
            }
        }
    }

    /// Off · Auto · Custom. On (either flavour) deals the best-effort
    /// defaults silently, so Export straight away already cuts well; Custom
    /// opens the drawer. Auto ↔ Custom parks and restores the custom
    /// answers, so no switch needs a confirmation.
    private func kenBurnsModeControl(_ collection: LapseCollection) -> some View {
        let mode = collection.kenBurnsMode
        return HStack(spacing: 5) {
            Text("Ken Burns")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 1) {
                kenBurnsModeSegment("Off", selected: mode == .off) {
                    guard mode != .off else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        model.setKenBurnsOff(for: collectionID)
                    }
                }
                kenBurnsModeSegment("Auto", selected: mode == .auto) {
                    guard mode != .auto else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        model.setKenBurnsAuto(for: collectionID)
                    }
                }
                kenBurnsModeSegment("Custom", selected: mode == .custom) {
                    openKenBurnsDrawer(collection)
                }
            }
            .padding(2)
            .background(Capsule().fill(LL.cardBackground))
            .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
            .popover(isPresented: $kenBurnsDrawerPresented) {
                kenBurnsCustomDrawer
            }
        }
        .fixedSize()
    }

    private func kenBurnsModeSegment(
        _ title: String, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? .white : LL.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(selected ? LL.accent : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Custom entered: snapshot what Cancel restores, switch the live values
    /// to the remembered custom ones, then open the drawer over them —
    /// edits inside apply live, so the preview and rows follow along.
    private func openKenBurnsDrawer(_ collection: LapseCollection) {
        kenBurnsDrawerSnapshot = collection.kenBurns
        kenBurnsDrawerApplied = false
        withAnimation(.easeInOut(duration: 0.2)) {
            model.beginKenBurnsCustom(for: collectionID)
        }
        kenBurnsDrawerPresented = true
    }

    private func closeKenBurnsDrawer(applied: Bool) {
        kenBurnsDrawerApplied = applied
        kenBurnsDrawerPresented = false
    }

    /// The pacing/join options behind Custom — a sheet on iPhone, a popover
    /// on iPad and the Mac. Apply keeps what's live; any other exit restores
    /// the snapshot, so fiddling is free.
    private var kenBurnsCustomDrawer: some View {
        Group {
            if let collection = model.collection(withID: collectionID),
               let kenBurns = collection.kenBurns {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ken Burns · Custom")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Tune the pacing and the joins — the preview and timeline follow along.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 12)

                    Divider()
                        .padding(.leading, 18)

                    ScrollView {
                        kenBurnsOptionRows(collection, kenBurns: kenBurns)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                    }

                    Divider()

                    HStack(spacing: 10) {
                        Button {
                            closeKenBurnsDrawer(applied: false)
                        } label: {
                            Text("Cancel")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(LL.accent)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(
                                    LL.accent.opacity(0.09),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            closeKenBurnsDrawer(applied: true)
                        } label: {
                            Text("Apply")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(
                                    LL.accent,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(14)
                }
            }
        }
        #if os(macOS)
        .frame(width: 380, height: 480)
        #else
        .frame(idealWidth: 380, idealHeight: 500)
        #endif
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .presentationCompactAdaptation(.sheet)
        .interactiveDismissDisabled()
        .onDisappear {
            if !kenBurnsDrawerApplied {
                model.restoreKenBurnsSettings(kenBurnsDrawerSnapshot, for: collectionID)
            }
            kenBurnsDrawerSnapshot = nil
        }
    }

    /// The four answers: pacing (consistent durations → the seconds, then
    /// how clips reach them) and the join (fade or cut). Same rows the old
    /// below-the-timeline card grew — now only on request.
    private func kenBurnsOptionRows(
        _ collection: LapseCollection, kenBurns: LapseCollection.KenBurnsSettings
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: kenBurnsBinding(\.consistentDurations)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Consistent durations")
                        .font(.system(size: 14))
                    Text(kenBurns.consistentDurations
                        ? "Every clip plays the same length"
                        : "Clips keep their own lengths, as shot")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            .tint(LL.accent)

            if kenBurns.consistentDurations {
                Stepper(
                    value: kenBurnsClipSecondsBinding,
                    in: 1...model.kenBurnsMaxClipSeconds(collection)
                ) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Clip duration")
                                .font(.system(size: 14))
                            Text("The shortest clip caps it at \(model.kenBurnsMaxClipSeconds(collection))s")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(model.kenBurnsEffectiveClipSeconds(collection))s")
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                            .foregroundStyle(LL.accentDeep)
                    }
                }

                Toggle(isOn: kenBurnsBinding(\.autoAdjustSpeed)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto adjust clip speed")
                            .font(.system(size: 14))
                        Text(kenBurns.autoAdjustSpeed
                            ? "Longer clips speed up to fit — only when required"
                            : "Each clip plays a \(model.kenBurnsEffectiveClipSeconds(collection))s window — set its start point from the timeline")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(LL.accent)
            }

            Toggle(isOn: kenBurnsBinding(\.fadeTransition)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fade transition")
                        .font(.system(size: 14))
                    Text(kenBurns.fadeTransition
                        ? "Clips crossfade for \(String(format: "%g", LapseCollection.fadeSeconds))s"
                        : "Straight cuts between clips")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            .tint(LL.accent)
        }
    }

    private func kenBurnsBinding(
        _ keyPath: WritableKeyPath<LapseCollection.KenBurnsSettings, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { model.collection(withID: collectionID)?.kenBurns?[keyPath: keyPath] == true },
            set: { value in
                model.updateKenBurnsSettings(collectionID) { $0[keyPath: keyPath] = value }
            })
    }

    /// Shows the effective (clamped) value; writes the preference.
    private var kenBurnsClipSecondsBinding: Binding<Int> {
        Binding(
            get: {
                guard let collection = model.collection(withID: collectionID) else { return 1 }
                return model.kenBurnsEffectiveClipSeconds(collection)
            },
            set: { value in
                model.updateKenBurnsSettings(collectionID) { $0.clipSeconds = value }
            })
    }

    /// The trim editor's fixed-window length when Ken Burns is choosing
    /// start points; nil keeps it the ordinary free trim.
    private var kenBurnsWindowSeconds: Double? {
        guard let collection = model.collection(withID: collectionID),
              collection.kenBurnsUsesWindows else { return nil }
        return Double(model.kenBurnsEffectiveClipSeconds(collection))
    }

    // MARK: - Timeline rows

    private func timelineHeader(_ collection: LapseCollection) -> String {
        collection.entries.isEmpty
            ? "Timeline"
            : "Timeline · \(collection.entries.count) \(collection.entries.count == 1 ? "clip" : "clips")"
    }

    /// The header once the Ken Burns control needs the room.
    private func shortTimelineHeader(_ collection: LapseCollection) -> String {
        collection.entries.isEmpty
            ? "Timeline"
            : "\(collection.entries.count) \(collection.entries.count == 1 ? "clip" : "clips")"
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
                Text("Blended clips from any project can join — the first sets the canvas")
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
        let blend = model.blend(id: entry.blendID)
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
                    Text(rowSubtitle(entry, blend: blend, in: collection))
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
            .accessibilityLabel(collection.kenBurnsUsesWindows
                ? "Set the clip's start point" : "Trim in and out points")

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
        // `claimsDrag: false` keeps the reorder handle's own drag winning on
        // its patch; a leading swipe anywhere else reveals the remove action.
        .swipeToDelete(claimsDrag: false) {
            removeFromTimeline(entry)
        }
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

    /// Dropping a clip from the timeline is recipe-only — the blended clip
    /// itself stays in its project, so no confirmation stands in the way.
    private func removeFromTimeline(_ entry: LapseCollection.Entry) {
        model.removeEntry(blendID: entry.blendID, from: collectionID)
        if selectedBlendID == entry.blendID {
            selectedBlendID = nil
        }
        if cropDrag?.blendID == entry.blendID {
            cropDrag = nil
        }
        if moveEdit?.blendID == entry.blendID {
            moveEdit = nil
        }
        toast = "Removed from the timeline — the clip stays in its project"
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
            Text(summaryFooter(collection))
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LL.ink, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func summaryFooter(_ collection: LapseCollection) -> String {
        guard let kenBurns = collection.kenBurns, kenBurns.enabled else {
            return "Trims retime the cut automatically — clips always butt together."
        }
        return kenBurns.fadeTransition
            ? "Ken Burns moves on every clip, crossfades between them."
            : "Ken Burns moves on every clip, straight cuts between them."
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

    private func rowSubtitle(
        _ entry: LapseCollection.Entry, blend: AppModel.BlendProject?, in collection: LapseCollection
    ) -> String {
        guard let blend else { return "" }
        if let kenBurns = collection.kenBurns, kenBurns.enabled, kenBurns.consistentDurations {
            let plays = model.entryOutputSeconds(entry, in: collection)
            var text = "\(blend.speedLabel) · plays \(SpeedMath.clipLengthCompact(plays))"
            if collection.kenBurnsUsesWindows, let full = model.blendDuration(for: blend), full > 0 {
                let start = min(entry.inPoint, max(0, 1 - plays / full)) * full
                text += start > 0.05 ? String(format: " from %.1fs", start) : " from the start"
            } else if kenBurns.autoAdjustSpeed {
                let kept = model.entrySeconds(entry)
                if kept > plays + 0.05 {
                    text += String(format: " · sped ×%.2f", kept / plays)
                }
            }
            return text
        }
        let kept = model.entrySeconds(entry)
        var text = "\(blend.speedLabel) · \(SpeedMath.clipLengthCompact(kept))"
        if entry.isTrimmed, let full = model.blendDuration(for: blend) {
            text += " of \(SpeedMath.clipLengthCompact(full))"
        }
        return text
    }

    /// What the crop HUD shows for this entry right now: live numbers while
    /// the finger is down, the lingering release value for a beat after.
    private func cropHUDText(entry: LapseCollection.Entry, in collection: LapseCollection) -> String? {
        if let cropDrag, cropDrag.blendID == entry.blendID, cropDrag.moved {
            return cropKeepLabel(entry: entry, in: collection)
        }
        return cropHUDLinger?.text
    }

    /// "keeps 1215×2160 of 3840×2160" — the honest pixels the retired
    /// caption used to spell out, computed from wherever the frame sits.
    private func cropKeepLabel(entry: LapseCollection.Entry, in collection: LapseCollection) -> String? {
        guard let ratio = collection.ratio,
              let blend = model.blend(id: entry.blendID),
              model.blendNeedsCrop(blend, on: ratio),
              let pixels = model.blendDisplaySize(for: blend),
              let offset = displayedCropOffset(entry: entry, in: collection),
              let box = CollectionMath.cropBox(clipSize: pixels, canvas: ratio, offset: offset)
        else { return nil }
        let kw = Int(box.rect.width.rounded())
        let kh = Int(box.rect.height.rounded())
        return "keeps \(kw)×\(kh) of \(Int(pixels.width))×\(Int(pixels.height))"
    }

    /// Hold the release value on screen briefly, then fade it out — unless a
    /// newer drag has taken over in the meantime.
    private func lingerCropHUD(entry: LapseCollection.Entry, collection: LapseCollection) {
        guard let text = cropKeepLabel(entry: entry, in: collection) else { return }
        let hud = CropHUDLinger(text: text)
        cropHUDLinger = hud
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            if cropHUDLinger == hud {
                withAnimation(.easeOut(duration: 0.25)) { cropHUDLinger = nil }
            }
        }
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

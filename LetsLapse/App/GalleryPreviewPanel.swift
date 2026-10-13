import LetsLapseKit
import SwiftUI

// MARK: - Gallery preview panel

/// The 330pt right-hand panel that slides in when a tile is selected — and,
/// in its `.inspector` dress, the left column of the Gallery's item view on
/// the Mac (2026-09-13), where the editor beside it does the tuning and this
/// column keeps to management and what comes after. On the phone the
/// inspector dress is the editor's ⓘ sheet (2026-09-21, `EditorPager`): a
/// tap on a tile opens the editor, so the panel comes to the picture rather
/// than standing between the grid and it.
///
/// One order for both dresses (Steven, 2026-09-27) — what a person manages
/// first, what the files said last:
/// - Thumbnail — `.pane` only; the inspector's picture is on screen beside
///   it. The column's full width at the picture's own shape, whole — a
///   portrait stands tall, a panorama sits low (2026-10-11; it was a 150 pt
///   strip that cut every picture to fill it)
/// - Title, date, size
/// - Open — `.pane` only, and alone: it already lands in the editor (the
///   item view on the Mac, the pager on iOS), so the Edit / Text / Shapes /
///   New clip row that sat under it is gone; New clip lives with the
///   blended clips
/// - Auto rename & tag
/// - Tags: the project's keywords in the shared tag editor (`TagField`)
/// - Presets — `.pane` only: a collapsed row that opens into the editor's
///   own Presets grid; the inspector sits beside the editor, which has them
/// - PicPlace: the project's copy there (`PicPlaceStatusCard`, `.narrow`) —
///   in the pane only once the library is bound to PicPlace
/// - Management: In frame, Storage, Here, Field notes, then the button row —
///   Rename, Share (`.pane`), Finder (Mac), Delete…
/// - Info and Metadata: what the files said (camera, lens, exposure, GPS…)
///   and the editable IPTC Core record, with an interval project's
///   shoot/frame scope (`MetadataPanelSections.swift`)
/// - Blended clips (`.pane`), or the inspector's OUTPUT group: New clip,
///   Share project and the blended-clips list
///
/// Steven's three phases (2026-09-13) still hold: tags / titles / metadata
/// are management, the editor is craft, blends / export / share are what
/// comes next.
struct GalleryPreviewPanel: View {
    enum Style {
        /// The Gallery's right-hand pane over a selected tile.
        case pane
        /// The item view's left column, beside the editor.
        case inspector
    }

    @EnvironmentObject var model: AppModel
    @ObservedObject private var presetStore = CustomPresetStore.shared
    #if os(iOS)
    /// Compact is the iPhone's sheet, where the Presets group is the
    /// editor's horizontal strip; regular is the iPad's pane, which takes
    /// the Mac's grid (its column is the Mac's 272 pt).
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    var capture: AppModel.CaptureProject
    /// Open: the project screen. Owned by the host because it is the host's
    /// navigation stack — and, on an iPhone, its sheet to dismiss.
    var onOpen: () -> Void
    /// New clip: the blend flow. The host's for the same reason as Open — on
    /// an iPhone the flow rises over the tabs, under a sheet that doesn't go.
    var onNewClip: () -> Void
    var onDelete: () -> Void
    var style: Style = .pane

    // Async loads
    @State private var storageBytes: Int64?
    @State private var isRenaming = false
    @State private var renameText = ""
    /// Auto rename & tag on this one project (2026-09-16): the same sheet the
    /// project screen presents, from the row above TAGS — in both dresses
    /// since 2026-09-27.
    @StateObject private var autoName = AutoNameController()
    @ObservedObject private var models = ModelManager.shared
    @State private var previewItem: MediaPreviewItem?
    @State private var confirmingDelete = false
    @State private var exportedArchive: ExportedArchive?
    @State private var isExporting = false
    @State private var blendFilter = BlendListFilter()
    /// Whole project by default; an interval project can scope to one frame.
    @State private var metadataScope: AppModel.MetadataScope = .project
    /// The Presets row: collapsed by default, and left as the person set it
    /// for the panel's life — not persisted, and not reset by a selection
    /// change on the Mac, where the panel stays up across them.
    @State private var presetsExpanded = Self.presetsInitiallyExpanded
    /// A preset tile tap held back for confirmation, because applying it
    /// from Edited would throw the project's manual adjustments away.
    @State private var pendingPresetApply: PresetApplyRequest?
    /// A tap on something this device cannot do yet — the originals or a
    /// blend are on PicPlace — asking whether to fetch them (FetchPrompt.swift).
    @State private var fetchRequest: FetchPromptRequest?
    /// The Presets tiles' renders, kept for the panel's life so re-opening
    /// the row shows pictures at once.
    @StateObject private var presetThumbnails = PresetThumbnailCache()

    /// `LL_PANEL=presets` — the Presets row open from the start, for
    /// screenshots of the expanded group; pair with `LL_SELECT`.
    private static var presetsInitiallyExpanded: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["LL_PANEL"] == "presets"
        #else
        return false
        #endif
    }

    private var blends: [AppModel.BlendProject] {
        model.blends(for: capture)
    }

    private var fieldNotes: [FieldNote] {
        model.fieldNotes(for: capture)
    }

    private var thumbnailURL: URL? { model.thumbnailURL(for: capture) }
    private var mediaKind: AppModel.MediaKind { model.mediaKind(for: capture) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if style == .pane {
                    thumbnail
                        .padding(.top, 22)
                        .padding(.horizontal, 14)

                    titleSection
                        .padding(.top, 12)
                        .padding(.horizontal, 14)

                    actionGrid
                        .padding(.top, 16)
                        .padding(.horizontal, 14)
                } else {
                    titleSection
                        .padding(.top, 18)
                        .padding(.horizontal, 14)
                }

                Divider()
                    .padding(.top, 16)

                VStack(alignment: .leading, spacing: 14) {
                    if !capture.isScannerCapture {
                        autoRenameRow
                    }
                    tagsSection
                    if style == .pane, !capture.isScannerCapture {
                        presetsSection
                    }
                    // The project's copy on PicPlace, above the management
                    // rows (macOS/gallery.item.picplace.svg drew it below
                    // them). The pane shows it only once the library is
                    // bound; the inspector always has.
                    if style == .inspector || model.picplace.binding != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            LLSectionHeader("PicPlace")
                            PicPlaceStatusCard(picplace: model.picplace, captureID: capture.id, style: .narrow)
                        }
                    }
                }
                .padding(.top, 12)
                .padding(.horizontal, 14)

                // Management before what the files said: the rows, then
                // Rename / Share / Finder / Delete.
                metadataSection
                    .padding(.horizontal, 14)

                Divider()
                    .padding(.top, 4)

                footerRow
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                Divider()

                recordSections
                    .padding(.top, 12)
                    .padding(.horizontal, 14)

                if style == .inspector {
                    Divider()
                        .padding(.top, 16)

                    outputSection
                        .padding(.horizontal, 14)
                        .padding(.top, 16)
                } else if !blends.isEmpty {
                    Divider()
                        .padding(.top, 16)

                    blendedClipsSection
                        .padding(.horizontal, 14)
                        .padding(.top, 16)
                }

                Color.clear.frame(height: 82) // floating tab bar clearance
            }
        }
        .scrollContentBackground(.hidden)
        .background(LL.cardBackground)
        .fetchPrompt($fetchRequest)
        .task(id: capture.id) {
            metadataScope = .project
            model.loadHoldings(for: [capture.id])
            if let bytes = await model.storageBytes(for: capture) {
                storageBytes = bytes
            }
        }
        .sheet(item: $previewItem) { item in
            ProjectMediaPreviewSheet(item: item)
        }
        .exportedArchiveSheet($exportedArchive)
        .autoNamePresentation(autoName, captureID: capture.id)
        .confirmationDialog(
            "Delete this project?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \u{201C}\(capture.displayTitle)\u{201D}", role: .destructive) {
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: $isRenaming) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { model.renameProject(capture, to: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(item: $pendingPresetApply) { request in
            Alert(
                title: Text(request.confirmationTitle),
                message: Text(request.confirmationMessage),
                primaryButton: .destructive(Text(request.confirmationButton)) {
                    applyPreset(request)
                },
                secondaryButton: .cancel())
        }
    }

    // MARK: Thumbnail

    private var thumbnail: some View {
        let grade = model.photoGrade(for: capture)
        return ProjectThumbnailView(
            url: thumbnailURL, kind: mediaKind, cornerRadius: 10,
            grade: grade.isIdentity ? nil : grade, fitsPicture: true)
            .frame(maxWidth: .infinity)
            .onTapGesture {
                let url = capture.isPhotoCapture
                    ? model.heroImageURL(for: capture)
                    : model.mediaURL(for: capture)
                guard let url else { return }
                previewItem = MediaPreviewItem(
                    title: capture.displayTitle,
                    subtitle: model.formatLine(for: capture),
                    url: url,
                    kind: model.mediaKind(for: capture)
                )
            }
    }

    // MARK: Title + date + size

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(capture.displayTitle)
                .font(.system(size: 16, weight: .bold))
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(capture.createdAt.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if let bytes = storageBytes {
                    Text("·").foregroundStyle(.tertiary)
                    Text(LLFormat.bytes(bytes))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Actions

    /// Open, full width and alone. It lands in the editor — the item view on
    /// the Mac, the pager on iOS — so the Edit / Text / Shapes / New clip row
    /// that sat under it until 2026-09-27 only repeated it, and those pages
    /// are one tab away inside. New clip is with the blended clips. A project
    /// whose picture is not here opens on the editor's preview page, as
    /// everywhere else (docs/connected-asset-states-plan.md §4).
    private var actionGrid: some View {
        actionButton("Open", icon: "arrow.up.forward.square", filled: true) {
            onOpen()
        }
    }

    /// `action` when this device holds what `capability` needs, else the
    /// question — and `action` once the files are here.
    private func ask(_ capability: ProjectCapability, _ subject: String, then action: @escaping () -> Void) {
        fetchRequest = model.request(capability, for: capture, subject: subject, then: action)
    }

    @ViewBuilder
    private func actionButton(
        _ label: String,
        icon: String,
        filled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                filled ? LL.accent : Color.primary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .foregroundStyle(filled ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: Auto rename & tag

    /// Directly above TAGS (2026-09-16), the batch panel's row on one
    /// project: the existing Auto rename & tag sheet, through the cached
    /// engine — the thumbnail's frame analysed once and kept beside the
    /// project. The subtitle is the run's own status while one is in flight.
    private var autoRenameRow: some View {
        Button {
            Task { await autoName.run(capture: capture, model: model) }
        } label: {
            HStack(spacing: 8) {
                if autoName.isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(autoName.status ?? "Auto rename & tag")
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(models.isReady ? LL.accent : Color.secondary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!models.isReady || autoName.isRunning)
        .accessibilityLabel("Auto rename & tag")
    }

    // MARK: Tags

    /// The project's keywords in the shared tag editor, first under the
    /// action grid. Tags ARE keywords (Part 2 §4.5): one list, kept in the
    /// manifest's `sceneTags` — what the sidebar, search and the picker read
    /// — and in the record's `dc:subject`, which an export writes; a change
    /// here lands in both with no Apply step. Always the whole project's:
    /// the scope switch below does not reach it, and METADATA has no
    /// Keywords row (a frame's own keywords are kept and exported, not
    /// edited here — Steven, 2026-09-13). The origin marker and its revert
    /// sit on the header line, as on every METADATA row.
    private var tagsSection: some View {
        let _ = model.metadataRevision
        let origin = model.resolvedMetadata(for: capture, scope: .project).origin(.keywords)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                LLSectionHeader("Tags")
                MetadataOriginMarker(origin: origin, fieldLabel: "Tags") {
                    model.revertMetadata(.keywords, on: capture, scope: .project)
                }
            }
            TagField(
                tags: Binding(
                    get: { model.resolvedKeywords(for: capture) },
                    set: { model.setMetadata(.list($0), for: .keywords, on: capture, scope: .project) }),
                libraryTags: model.libraryTags)
        }
    }

    // MARK: Presets

    /// A disclosure row — the header, the state pill trailing, a chevron —
    /// that opens into the editor's Presets group: the same tiles
    /// (`EditorPresetsContext.tiles`), the same render cache, this project's
    /// hero through every preset alone, so a look can go on a project
    /// without opening the editor. A tap applies through the model's
    /// `applyPreset` / `applyCustomPreset`, which keep the project's own
    /// rotation, crop and owned white — a preset never carries geometry —
    /// after the shared confirmation when the project is Edited. No Save as
    /// Preset row and no Lightroom card here: nothing is being graded.
    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { presetsExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    LLSectionHeader("Presets")
                    PresetStatePill(state: model.presetState(for: capture))
                    Image(systemName: presetsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Presets")
            .accessibilityValue(presetsExpanded ? "expanded" : "collapsed")

            if presetsExpanded {
                presetTiles
            }
        }
    }

    /// The tiles as the editor lays them out on each surface: the Mac rail's
    /// 3-column grid, the iPhone sheet's horizontal strip (on this light
    /// card rather than the editor's dark one), the iPad taking the Mac's
    /// grid since its column is the Mac's.
    @ViewBuilder private var presetTiles: some View {
        #if os(macOS)
        presetGrid
        #else
        if horizontalSizeClass == .compact {
            presetStrip
        } else {
            presetGrid
        }
        #endif
    }

    private var presetGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
            spacing: 8
        ) {
            presetsContext.tiles(style: .macGrid, accent: LL.accent)
        }
    }

    private var presetStrip: some View {
        // Bleeds edge to edge under the panel's 14 pt sides, the tiles inset
        // back by 14 — the editor sheet's own device at its 16.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                presetsContext.tiles(style: .phone, accent: LL.accent, isOnDark: false)
            }
            .padding(.horizontal, 14)
        }
        .padding(.horizontal, -14)
    }

    /// The frame is this project's own — `presetPreviewFrame` falls back to
    /// the newest edited project for an id it cannot find, which a Scanner
    /// capture (excluded there, and given no Presets row here) would hit.
    private var presetsContext: EditorPresetsContext {
        let frame = model.presetPreviewFrame(preferring: capture.id)
        return EditorPresetsContext(
            frame: frame?.captureID == capture.id ? frame : nil,
            presetState: model.presetState(for: capture),
            basePreset: PhotoPreset.resolve(capture.selectedPreset),
            customPresets: presetStore.presets,
            cache: presetThumbnails,
            onSelect: { requestPreset($0) },
            onDelete: { presetStore.delete($0) },
            onSaveAsPreset: {})
    }

    /// A tile tap. From Edited it is destructive — manual adjustments the
    /// person made deliberately would be thrown away, and with no playhead
    /// to aim at a keyframed grade is flattened — so it confirms first; from
    /// anywhere else it applies straight away. The same rule as the project
    /// screen's chip strip.
    private func requestPreset(_ target: PresetApplyRequest.Target) {
        // A preset is a pixel edit (rule 6): it waits for the originals,
        // which re-render the look — applied here without them, the grade
        // synced with a poster that could not follow (2026-09-25).
        guard model.isAvailable(.pixelEdit, for: capture) else {
            ask(.pixelEdit, "Presets") { requestPreset(target) }
            return
        }
        let request = PresetApplyRequest(
            target: target,
            discardsMoments: model.gradeTimeline(for: capture).keyframes.count)
        guard model.presetState(for: capture).isEdited else {
            applyPreset(request)
            return
        }
        pendingPresetApply = request
    }

    private func applyPreset(_ request: PresetApplyRequest) {
        switch request.target {
        case .builtIn(let preset):
            model.applyPreset(preset, for: capture)
        case .custom(let preset):
            model.applyCustomPreset(preset, for: capture)
        }
    }

    // MARK: Info + Metadata

    /// The asset record, in two groups: Info (read-only, from the files) and
    /// Metadata (editable, IPTC Core), under TAGS and PRESETS. An interval
    /// project gets the scope switch above both, so a five-star frame in a
    /// 5,000-frame set can be rated without rating the shoot.
    private var recordSections: some View {
        VStack(alignment: .leading, spacing: 14) {
            MetadataScopeControl(capture: capture, scope: $metadataScope)
            MetadataInfoSection(capture: capture, scope: metadataScope)
            MetadataEditSection(capture: capture, scope: metadataScope)
        }
    }

    // MARK: Metadata rows

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let elements = capture.sceneElements, !elements.isEmpty {
                metaRow("In frame") {
                    Text(elements.prefix(4).joined(separator: ", "))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let bytes = storageBytes {
                metaRow("Storage") {
                    Text(LLFormat.bytes(bytes))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            // What this device holds of the project, in words — the tiles
            // badge only what is not the norm (connected asset states §4.3).
            HoldingsHereRow(holdings: model.holdingsStore, capture: capture)
            if !fieldNotes.isEmpty {
                metaRow("Field notes") {
                    Text("\(fieldNotes.count) note\(fieldNotes.count == 1 ? "" : "s")")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private func metaRow<V: View>(
        _ label: String,
        @ViewBuilder content: () -> V
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    // MARK: Blended clips
    //
    // Lists this project's blends, image results and time-sliced exports —
    // the same shared BlendedClipRow the iOS project-detail screens use
    // (see docs/design/components/blended-clip-row.<state>.<width>.svg).
    // Replaces the old one-line "Variations · N blended clips" meta row
    // (2026-09-07) with the actual list, at the foot of the panel. The
    // Blends/Slices/Image/Video tick-chip filter (see BlendListFilter.swift)
    // is the same one ProjectDetailView uses — the header count is the
    // FILTERED count, not the project's.

    private var blendedClipsSection: some View {
        let visible = blends.filter(blendFilter.matches)
        return VStack(alignment: .leading, spacing: 12) {
            LLSectionHeader("Blended clips · \(visible.count)")
            BlendListFilterBar(filter: $blendFilter)

            if visible.isEmpty {
                BlendListEmptyState()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, blend in
                        if index > 0 {
                            Divider().padding(.leading, 84)
                        }
                        BlendedClipRow(
                            blend: blend,
                            model: model,
                            // Each asks first when what it needs is on
                            // PicPlace: the clip's file to play, the
                            // originals to open its result screen.
                            onPlay: { ask(.blend(blend.id), "Playing the clip") { playBlend(blend) } },
                            onOpen: { ask(.newBlend, "Opening the clip") { model.openBlend(blend) } }
                        )
                    }
                }
                .llCard()
            }
        }
    }

    private func playBlend(_ blend: AppModel.BlendProject) {
        previewItem = MediaPreviewItem(
            title: capture.displayTitle,
            subtitle: nil,
            url: model.mediaURL(for: blend),
            kind: model.mediaKind(for: blend)
        )
    }

    // MARK: Output (inspector only)

    /// What comes of the project, at the foot of the inspector: New clip (an
    /// interval or video project — a Photo capture is one photo, nothing to
    /// blend), Share project (the .lapse archive the pane's Share footer
    /// button makes), and the blended-clips list under them. Export lands
    /// here too when there is one to offer (Steven, 2026-09-13).
    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LLSectionHeader("Output")
            HStack(spacing: 8) {
                if !capture.isPhotoCapture {
                    actionButton("New clip", icon: "plus.circle") {
                        ask(.newBlend, "A new clip") { onNewClip() }
                    }
                    .opacity(model.isAvailable(.newBlend, for: capture) ? 1 : 0.45)
                }
                actionButton(isExporting ? "Sharing…" : "Share project",
                             icon: "square.and.arrow.up") {
                    // A `.lapse` carries every file: the originals and the
                    // blends must be here first (it failed silently).
                    ask(.exportProject, "Sharing the project") { exportShare() }
                }
                .disabled(isExporting)
            }
            if !blends.isEmpty {
                blendedClipsSection
                    .padding(.top, 4)
            }
        }
    }

    // MARK: Footer

    private var footerRow: some View {
        HStack(spacing: 0) {
            footerButton("Rename", icon: "pencil.line") {
                renameText = capture.displayTitle
                isRenaming = true
            }
            if style == .pane {
                Divider().frame(height: 20)
                footerButton("Share", icon: "square.and.arrow.up") {
                    exportShare()
                }
            }
            #if os(macOS)
            Divider().frame(height: 20)
            footerButton("Finder", icon: "folder") {
                // The hero file when there is one; the project's folder
                // otherwise (a preview-only project has a poster and its
                // records there) — never a button that does nothing.
                if let url = model.heroImageURL(for: capture) {
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([model.projectFolderURL(for: capture)])
                }
            }
            #endif
            Divider().frame(height: 20)
            footerButton("Delete\u{2026}", icon: "trash", tint: .red) {
                confirmingDelete = true
            }
        }
    }

    @ViewBuilder
    private func footerButton(
        _ label: String,
        icon: String,
        tint: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Share / export

    private func exportShare() {
        guard !isExporting else { return }
        isExporting = true
        Task {
            do {
                let url = try await model.exportProject(capture)
                await MainActor.run {
                    exportedArchive = ExportedArchive(url: url)
                    isExporting = false
                }
            } catch {
                await MainActor.run { isExporting = false }
            }
        }
    }
}

/// The panel's **Here** row: what this device holds of the project, in words
/// — observing the holdings store, so it fills in when the walk lands
/// without re-rendering the whole panel through the model.
private struct HoldingsHereRow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var holdings: ProjectHoldingsStore
    let capture: AppModel.CaptureProject

    var body: some View {
        Group {
            if let known = model.shownHoldings(for: capture.id) {
                HStack(alignment: .top, spacing: 10) {
                    Text("Here")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)
                    Text(line(known))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
            }
        }
        // Asks again whenever the answer is dropped (a removal, a download),
        // as the holdings pill does.
        .task(id: model.cachedHoldings(for: capture.id) == nil ? holdings.revision : -1) {
            model.requestHoldings(capture.id)
        }
    }

    /// The holdings pill in words (plan §4.3): what is here, then where
    /// the originals are — "Originals and blends · backed up on PicPlace" ·
    /// "Originals · 1 of 3 blends · not backed up" · "Blends only (2 of 3)
    /// — originals on PicPlace · 2.4 GB" · "Preview only — originals not on
    /// PicPlace yet" (the project is; its originals are on the device that
    /// made it) · "… — originals missing" when PicPlace has neither.
    private func line(_ holdings: ProjectHoldings) -> String {
        let blends = holdings.blends.count
        let blendsHere = holdings.blendsHere
        let record = model.picplace.records[model.originID(of: capture)]
        let onPicPlace = record.map { $0.revision > 0 || $0.policy == "pull" } ?? false
        switch holdings.tier {
        case .originals:
            var line = blends == 0 || blendsHere == blends
                ? (blends == 0 ? "Originals" : "Originals and blends")
                : "Originals · \(blendsHere) of \(blends) blends"
            if let record, onPicPlace {
                line += AppModel.isBackedUp(record, holdings: holdings) ? " · backed up on PicPlace" : " · not backed up"
            }
            return line
        case .blends, .preview:
            let originalsThere = record.map { ($0.serverHeavyFiles ?? 0) > 0 || $0.heavyDigest != nil } ?? false
            let originals: String
            if originalsThere {
                let short = holdings.shortfall(for: .originals)
                originals = "originals on PicPlace" + (short.map { $0.bytes > 0 ? " · \(LLFormat.bytes($0.bytes))" : "" } ?? "")
            } else if onPicPlace {
                originals = "originals not on PicPlace yet"
            } else {
                originals = "originals missing"
            }
            return holdings.tier == .blends ? "Blends only (\(blendsHere) of \(blends)) — \(originals)" : "Preview only — \(originals)"
        }
    }
}

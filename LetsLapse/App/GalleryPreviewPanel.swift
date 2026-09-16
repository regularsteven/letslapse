import SwiftUI

// MARK: - Gallery preview panel

/// The 330pt right-hand panel that slides in when a tile is selected — and,
/// in its `.inspector` dress, the left column of the Gallery's item view on
/// the Mac (2026-09-13), where the editor beside it does the tuning and this
/// column keeps to management and what comes after.
///
/// Contains (`.pane`):
/// - Thumbnail (150pt height)
/// - Title, date, size
/// - Actions: Open, then Edit / Text / Shapes / New clip (see `actionGrid`)
/// - Tags: the project's keywords in the shared tag editor (`TagField`) —
///   first, above everything the files said, because they are the metadata
///   a person actually manages (Steven, 2026-09-13)
/// - Presets: a collapsed row that opens into the editor's own Presets
///   grid, so a look goes on a project without opening the editor
/// - Info: what the files said — camera, lens, exposure, captured, GPS, size
/// - Metadata: the editable IPTC Core record; an interval project scopes
///   Info and Metadata to the whole shoot or one frame
///   (`MetadataPanelSections.swift`)
/// - Metadata rows: In frame, Storage, Field notes
/// - Footer: Rename, Share, Show in Finder, Delete…
///
/// `.inspector` reads top to bottom as the project's life: no thumbnail (the
/// picture is on screen), no action grid and no Presets (the editor is right
/// there) — title and date, then Tags, Info and Metadata, the footer with
/// Rename / Finder / Delete, and an OUTPUT group at the foot: New clip, Share
/// project and the blended-clips list. Steven's three phases (2026-09-13):
/// tags / titles / metadata are management, the editor is craft, blends /
/// export / share are what comes next — phases one and three share this
/// column, in that order.
struct GalleryPreviewPanel: View {
    enum Style {
        /// The Gallery's right-hand pane over a selected tile.
        case pane
        /// The item view's left column, beside the editor.
        case inspector
    }

    @EnvironmentObject var model: AppModel
    @ObservedObject private var presetStore = CustomPresetStore.shared
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #else
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
    /// Edit / Text / Shapes, when the host has a place of its own for the
    /// editor (the Gallery's item view on the Mac); nil opens the editor the
    /// way the panel always did — a window on the Mac, a cover on iOS.
    var onEdit: ((RailTab) -> Void)? = nil

    // Async loads
    @State private var storageBytes: Int64?
    #if os(iOS)
    /// The editor Edit / Text / Shapes present — a full-screen cover from
    /// this very view, so it lands above the panel even when the panel is a
    /// sheet. On the Mac the editor is a window instead.
    @State private var editorRequest: EditorOpenRequest?
    #endif
    @State private var isRenaming = false
    @State private var renameText = ""
    /// Auto rename & tag on this one project (2026-09-16): the same sheet the
    /// project screen presents, from the row above TAGS.
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
                    if style == .pane, !capture.isScannerCapture {
                        autoRenameRow
                    }
                    tagsSection
                    if style == .pane, !capture.isScannerCapture {
                        presetsSection
                    }
                    recordSections
                }
                .padding(.top, 12)
                .padding(.horizontal, 14)

                metadataSection
                    .padding(.horizontal, 14)

                // The project's copy on PicPlace, between the info rows and
                // the footer — inspector only (macOS/gallery.item.picplace.svg).
                if style == .inspector {
                    VStack(alignment: .leading, spacing: 4) {
                        LLSectionHeader("PicPlace")
                        PicPlaceStatusCard(picplace: model.picplace, captureID: capture.id, style: .narrow)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                }

                Divider()
                    .padding(.top, 4)

                footerRow
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                if style == .inspector {
                    Divider()

                    outputSection
                        .padding(.horizontal, 14)
                        .padding(.top, 16)
                } else if !blends.isEmpty {
                    Divider()

                    blendedClipsSection
                        .padding(.horizontal, 14)
                        .padding(.top, 16)
                }

                Color.clear.frame(height: 82) // floating tab bar clearance
            }
        }
        .scrollContentBackground(.hidden)
        .background(LL.cardBackground)
        #if os(iOS)
        .editorCover($editorRequest)
        #endif
        .task(id: capture.id) {
            metadataScope = .project
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
            grade: grade.isIdentity ? nil : grade)
            .frame(height: 150)
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

    /// Open leads, full width. The row under it goes straight to the editor —
    /// Edit on its grading page, Text on its Text page, Shapes on its Masks
    /// page, where a project's shapes are drawn and managed — and New clip
    /// starts a blend from the project. Two rows either way, so the panel
    /// keeps the height the old 2×2 grid had. (Until 2026-09-11 Edit and Text
    /// were wired to the New clip flow — see EditorLaunch.swift.)
    ///
    /// Shapes is left out for a video project: the movie editor has no Masks
    /// page, and Find shapes skips movies. New clip is left out for a Photo
    /// capture: it is one photo, with nothing to blend — the rule the project
    /// screen and the tile menu already apply.
    ///
    /// Provisional layout (Steven, 2026-09-11): the five buttons are to become
    /// a shared design component; the row here is what the code shows until
    /// that component is drawn.
    private var actionGrid: some View {
        // A preview-only project (its sources are not on this device, v2
        // plan D7) has nothing to edit: the buttons say so instead of doing
        // nothing (libraries plan L20).
        let missing = model.sourcesMissing(capture)
        return VStack(spacing: 8) {
            actionButton("Open", icon: "arrow.up.forward.square", filled: true) {
                onOpen()
            }
            HStack(spacing: 8) {
                actionButton("Edit", icon: "pencil") {
                    openEditor(page: .editor)
                }
                .disabled(missing)
                actionButton("Text", icon: "textformat") {
                    openEditor(page: .text)
                }
                .disabled(missing)
                if capture.kind == .photos {
                    actionButton("Shapes", icon: "circle.square") {
                        openEditor(page: .masks)
                    }
                    .disabled(missing)
                }
                if !capture.isPhotoCapture {
                    actionButton("New clip", icon: "plus.circle") {
                        onNewClip()
                    }
                    .disabled(missing)
                }
            }
            .opacity(missing ? 0.45 : 1)
            if missing {
                Text("Preview only — download the originals to edit")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The editor, straight from here, on the page named: the host's own
    /// place for it when it has one (the item view), else a full-screen cover
    /// on iOS/iPadOS, a window on the Mac (fronted if it is already open —
    /// the page request moves it).
    private func openEditor(page: RailTab) {
        if let onEdit { onEdit(page); return }
        guard let request = model.stageEditor(for: capture, page: page) else { return }
        #if os(macOS)
        request.open(with: openWindow)
        #else
        editorRequest = request
        #endif
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
                            onPlay: { playBlend(blend) },
                            onOpen: { model.openBlend(blend) }
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
                        onNewClip()
                    }
                }
                actionButton(isExporting ? "Sharing…" : "Share project",
                             icon: "square.and.arrow.up") {
                    exportShare()
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

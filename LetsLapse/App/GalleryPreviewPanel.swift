import SwiftUI

// MARK: - Gallery preview panel

/// The 300pt right-hand panel that slides in when a tile is selected.
///
/// Contains:
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
struct GalleryPreviewPanel: View {
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
                thumbnail
                    .padding(.top, 22)
                    .padding(.horizontal, 14)

                titleSection
                    .padding(.top, 12)
                    .padding(.horizontal, 14)

                actionGrid
                    .padding(.top, 16)
                    .padding(.horizontal, 14)

                Divider()
                    .padding(.top, 16)

                VStack(alignment: .leading, spacing: 14) {
                    tagsSection
                    if !capture.isScannerCapture {
                        presetsSection
                    }
                    recordSections
                }
                .padding(.top, 12)
                .padding(.horizontal, 14)

                metadataSection
                    .padding(.horizontal, 14)

                Divider()
                    .padding(.top, 4)

                footerRow
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                if !blends.isEmpty {
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
        ProjectThumbnailView(url: thumbnailURL, kind: mediaKind, cornerRadius: 10)
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
        VStack(spacing: 8) {
            actionButton("Open", icon: "arrow.up.forward.square", filled: true) {
                onOpen()
            }
            HStack(spacing: 8) {
                actionButton("Edit", icon: "pencil") {
                    openEditor(page: .editor)
                }
                actionButton("Text", icon: "textformat") {
                    openEditor(page: .text)
                }
                if capture.kind == .photos {
                    actionButton("Shapes", icon: "circle.square") {
                        openEditor(page: .masks)
                    }
                }
                if !capture.isPhotoCapture {
                    actionButton("New clip", icon: "plus.circle") {
                        onNewClip()
                    }
                }
            }
        }
    }

    /// The editor, straight from here, on the page named: a full-screen cover
    /// on iOS/iPadOS, a window on the Mac (fronted if it is already open —
    /// the page request moves it).
    private func openEditor(page: RailTab) {
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

    // MARK: Footer

    private var footerRow: some View {
        HStack(spacing: 0) {
            footerButton("Rename", icon: "pencil.line") {
                renameText = capture.displayTitle
                isRenaming = true
            }
            Divider().frame(height: 20)
            footerButton("Share", icon: "square.and.arrow.up") {
                exportShare()
            }
            #if os(macOS)
            Divider().frame(height: 20)
            footerButton("Finder", icon: "folder") {
                if let url = model.heroImageURL(for: capture) {
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
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

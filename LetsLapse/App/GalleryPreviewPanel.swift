import SwiftUI

// MARK: - Gallery preview panel

/// The 300pt right-hand panel that slides in when a tile is selected.
///
/// Contains:
/// - Thumbnail (150pt height)
/// - Title, date, size
/// - Actions: Open, then Edit / Text / Shapes / New clip (see `actionGrid`)
/// - Tags: the shared tag editor (`TagField`), full width
/// - Metadata rows: In frame, Storage, Field notes
/// - Footer: Rename, Share, Show in Finder, Delete…
struct GalleryPreviewPanel: View {
    @EnvironmentObject var model: AppModel
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
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

                tagsSection
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

    /// The shared tag editor, promoted out of the metaRow grid to the panel's own column.
    ///
    /// Was `SceneTagLine` in a 72pt-label row: up to three tiny capsules and a "+N", read-only.
    /// `SceneTagLine` stays exactly as it is elsewhere — it is a summary for a list row, not an
    /// editor — but here, beside the project it describes, it was the only view of a project's
    /// tags that a person could reach and could do nothing with.
    ///
    /// Full width rather than in the label grid because at the 190pt a metaRow leaves, a single
    /// "Sky & weather" chip is nearly the whole row. This costs the panel real height when a
    /// project carries several tags; the panel scrolls, and the blended-clips list below it moves
    /// down accordingly — see docs/design/macOS/INDEX.md.
    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            LLSectionHeader("Tags")
            TagField(tags: tagsBinding, libraryTags: model.libraryTags)
        }
        .padding(.top, 12)
    }

    /// Writes straight through to the library, with no Apply step — the same bargain the rename
    /// alert makes, and the reason the picker sheet carries Done and no Cancel.
    private var tagsBinding: Binding<[String]> {
        Binding(
            get: { model.captures.first { $0.id == capture.id }?.sceneTags ?? [] },
            set: { model.setSceneTags($0, on: capture) })
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

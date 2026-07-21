import SwiftUI
import LetsLapseKit

/// The management layer the old app was missing: play the original, make new
/// versions, rename, see per-project storage, and delete safely.
struct ProjectDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let captureID: UUID

    @State private var previewItem: MediaPreviewItem?
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var confirmingProjectDelete = false
    @State private var versionPendingDelete: AppModel.BlendProject?
    @State private var deletionFailure: String?
    @State private var storageBytes: Int64?

    private var capture: AppModel.CaptureProject? {
        model.captures.first { $0.id == captureID }
    }

    var body: some View {
        Group {
            if let capture {
                content(for: capture)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "questionmark.folder")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Project not found")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LL.screenBackground)
            }
        }
        .sheet(item: $previewItem) { item in
            ProjectMediaPreviewSheet(item: item)
        }
        .alert("Rename project", isPresented: $isRenaming) {
            TextField("Project name", text: $renameText)
            Button("Save") {
                if let capture {
                    model.renameProject(capture, to: renameText)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete project?", isPresented: $confirmingProjectDelete) {
            Button("Delete", role: .destructive) { deleteProject() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteProjectMessage)
        }
        .alert(item: $versionPendingDelete) { blend in
            Alert(
                title: Text("Delete v\(model.versionNumber(for: blend))?"),
                message: Text("This permanently deletes the generated clip. The original stays in the project."),
                primaryButton: .destructive(Text("Delete")) { delete(blend) },
                secondaryButton: .cancel()
            )
        }
        .alert(
            "Couldn't delete",
            isPresented: Binding(
                get: { deletionFailure != nil },
                set: { if !$0 { deletionFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionFailure ?? "")
        }
        .task(id: model.blends.count) {
            guard let capture else { return }
            storageBytes = await model.storageBytes(for: capture)
        }
    }

    // MARK: - Content

    private func content(for capture: AppModel.CaptureProject) -> some View {
        let versions = model.blends(for: capture)
        let sourceClips = model.sourceClipURLs(for: capture)

        return ScrollView {
            VStack(spacing: 14) {
                heroCard(for: capture)

                if sourceClips.count > 1 {
                    sourceClipsSection(for: capture, clips: sourceClips)
                }

                Button {
                    model.openCapture(capture)
                } label: {
                    Label("New version", systemImage: "plus")
                }
                .buttonStyle(LLPrimaryButtonStyle())

                VStack(alignment: .leading, spacing: 8) {
                    LLSectionHeader(versions.isEmpty ? "Versions" : "Versions · \(versions.count)")

                    if versions.isEmpty {
                        Text("No versions yet — tap New version to make the first clip from this original.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .llCard()
                    } else {
                        VStack(spacing: 0) {
                            ForEach(versions) { blend in
                                versionRow(blend)
                                if blend.id != versions.last?.id {
                                    Divider().padding(.leading, 84)
                                }
                            }
                        }
                        .llCard()
                    }
                }

                managementCard(for: capture)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(LL.screenBackground)
        .navigationTitle(capture.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        startRename(capture)
                    } label: {
                        Label("Rename project", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        confirmingProjectDelete = true
                    } label: {
                        Label("Delete project…", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private func heroCard(for capture: AppModel.CaptureProject) -> some View {
        ZStack {
            ProjectThumbnailView(url: model.mediaURL(for: capture), kind: model.mediaKind(for: capture))
                .frame(height: 210)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Button {
                playOriginal(capture)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play original")
        }
        .overlay(alignment: .topLeading) {
            MediaBadge(text: originalBadge(for: capture))
                .padding(12)
        }
        .overlay(alignment: .bottomTrailing) {
            MediaBadge(text: formatBadge(for: capture))
                .padding(12)
        }
    }

    private func sourceClipsSection(for capture: AppModel.CaptureProject, clips: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LLSectionHeader("Source Clips · \(clips.count)")

            VStack(spacing: 0) {
                ForEach(Array(clips.enumerated()), id: \.element) { index, url in
                    SourceClipRow(index: index, url: url) {
                        previewClip(for: capture, index: index, url: url)
                    }
                    if url != clips.last {
                        Divider().padding(.leading, 84)
                    }
                }
            }
            .llCard()
        }
    }

    private func versionRow(_ blend: AppModel.BlendProject) -> some View {
        HStack(spacing: 12) {
            ProjectThumbnailView(url: model.mediaURL(for: blend), kind: model.mediaKind(for: blend))
                .frame(width: 58, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(versionTitle(blend))
                    .font(.system(size: 14.5, weight: .semibold))
                    .lineLimit(1)
                Text(versionSubtitle(blend))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Open") {
                model.openBlend(blend)
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(LL.accent)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                model.openBlend(blend)
            } label: {
                Label("Open", systemImage: "arrow.up.forward.app")
            }
            Button {
                model.openBlend(blend)
                model.stage = .configure
            } label: {
                Label("New version from these settings", systemImage: "slider.horizontal.3")
            }
            Button(role: .destructive) {
                versionPendingDelete = blend
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeToDelete {
            versionPendingDelete = blend
        }
    }

    private func managementCard(for capture: AppModel.CaptureProject) -> some View {
        VStack(spacing: 0) {
            Button {
                startRename(capture)
            } label: {
                LLRow(title: "Rename project") {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            LLRow(title: "Storage", subtitle: "original + versions") {
                Text(storageBytes.map { LLFormat.bytes($0) } ?? "—")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            Button {
                confirmingProjectDelete = true
            } label: {
                LLRow(title: "Delete project…", titleColor: .red, showsDivider: false) {
                    EmptyView()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .llCard()
    }

    // MARK: - Labels

    private func originalBadge(for capture: AppModel.CaptureProject) -> String {
        if capture.kind == .photos {
            return "ORIGINAL · \(capture.sourceMediaCount) photos"
        }
        if let duration = capture.sourceDurationSeconds {
            return "ORIGINAL · \(DurationFormatter.recordingTime(from: duration))"
        }
        return "ORIGINAL"
    }

    private func formatBadge(for capture: AppModel.CaptureProject) -> String {
        var parts: [String] = []
        if let width = capture.sourceWidth, let height = capture.sourceHeight {
            parts.append(AppModel.CaptureProject.resolutionLabel(width: width, height: height))
        }
        if let fps = capture.sourceFPS {
            parts.append("\(Int(fps.rounded())) fps")
        }
        if parts.isEmpty {
            parts.append(capture.kind == .photos ? "Interval" : "Video")
        }
        return parts.joined(separator: " · ")
    }

    private func versionTitle(_ blend: AppModel.BlendProject) -> String {
        var parts = ["v\(model.versionNumber(for: blend))", blend.speedLabel]
        if let seconds = blend.outputSeconds {
            parts.append(SpeedMath.clipLength(seconds))
        }
        return parts.joined(separator: " · ")
    }

    private func versionSubtitle(_ blend: AppModel.BlendProject) -> String {
        var parts: [String] = []
        if blend.kind == .video, let fps = blend.outputFPS {
            parts.append("\(fps) fps")
        }
        if blend.linearLight {
            parts.append("true-light")
        }
        parts.append(blend.createdAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    private var deleteProjectMessage: String {
        guard let capture else { return "" }
        let count = model.blends(for: capture).count
        let versionText = count == 1 ? "1 version" : "\(count) versions"
        return "This permanently deletes the original and \(versionText). There's no undo."
    }

    // MARK: - Actions

    private func playOriginal(_ capture: AppModel.CaptureProject) {
        guard let url = model.mediaURL(for: capture) else { return }
        previewItem = MediaPreviewItem(
            title: capture.displayTitle,
            subtitle: capture.formatLine,
            url: url,
            kind: model.mediaKind(for: capture)
        )
    }

    private func previewClip(for capture: AppModel.CaptureProject, index: Int, url: URL) {
        previewItem = MediaPreviewItem(
            title: "Clip \(index + 1)",
            subtitle: capture.formatLine,
            url: url,
            kind: .video
        )
    }

    private func startRename(_ capture: AppModel.CaptureProject) {
        renameText = capture.name ?? capture.displayTitle
        isRenaming = true
    }

    private func deleteProject() {
        guard let capture else { return }
        do {
            try model.deleteCapture(capture)
            dismiss()
        } catch {
            deletionFailure = error.localizedDescription
        }
    }

    private func delete(_ blend: AppModel.BlendProject) {
        do {
            try model.deleteBlend(blend)
        } catch {
            deletionFailure = error.localizedDescription
        }
    }
}

// MARK: - Source clip row

/// One row in the Source Clips section: a tappable thumbnail, the clip's
/// number and size, and a per-clip Save to Photos control (iOS only).
private struct SourceClipRow: View {
    @EnvironmentObject var model: AppModel
    let index: Int
    let url: URL
    var onPlay: () -> Void

    @State private var fileSize: Int64?
    @State private var isSaving = false
    @State private var isConverting = false
    @State private var isProRes = false
    @State private var saveState: SaveState = .idle

    private enum SaveState: Equatable {
        case idle
        case saved
        case failed(String)

        var isError: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                ProjectThumbnailView(url: url, kind: .video)
                    .frame(width: 58, height: 42)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play clip \(index + 1)")

            VStack(alignment: .leading, spacing: 2) {
                Text("Clip \(index + 1)")
                    .font(.system(size: 14.5, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(saveState.isError ? Color.red : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            saveControl
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .task(id: url) {
            fileSize = await Task.detached(priority: .utility) {
                AppModel.directorySize(url)
            }.value
        }
        .task(id: url) {
            isProRes = await AppModel.sourceClipIsProRes(at: url)
        }
    }

    private var subtitle: String {
        if isConverting { return "Converting…" }
        switch saveState {
        case .saved: return "Saved to Photos"
        case .failed(let message): return message
        case .idle:
            let size = fileSize.map { LLFormat.bytes($0) }
            if isProRes {
                return size.map { "ProRes · \($0)" } ?? "ProRes clip"
            }
            return size ?? "Video clip"
        }
    }

    @ViewBuilder private var saveControl: some View {
        #if os(iOS)
        if isSaving || isConverting {
            ProgressView()
                .controlSize(.small)
        } else if saveState == .saved {
            Label("Saved", systemImage: "checkmark")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
        } else if isProRes {
            // ProRes clips are huge; offer smaller re-encodes alongside Save.
            Menu {
                Button {
                    save()
                } label: {
                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                }
                Divider()
                Button {
                    convert(to: .h264)
                } label: {
                    Label("Convert to H.264", systemImage: "arrow.triangle.2.circlepath")
                }
                Button {
                    convert(to: .hevc)
                } label: {
                    Label("Convert to HEVC", systemImage: "arrow.triangle.2.circlepath")
                }
            } label: {
                Text(saveState.isError ? "Retry" : "Save")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(LL.accent)
            }
        } else {
            Button(saveState.isError ? "Retry" : "Save") {
                save()
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(LL.accent)
            .buttonStyle(.plain)
        }
        #endif
    }

    private func save() {
        #if os(iOS)
        isSaving = true
        saveState = .idle
        Task {
            do {
                try await model.saveSourceClip(at: url)
                saveState = .saved
            } catch {
                saveState = .failed(error.localizedDescription)
            }
            isSaving = false
        }
        #endif
    }

    /// Re-encode this ProRes clip to a smaller codec, then drop the result into
    /// Photos so it can be shared or offloaded.
    private func convert(to codec: OutputCodec) {
        #if os(iOS)
        isConverting = true
        saveState = .idle
        Task {
            do {
                let converted = try await model.convertSourceClip(at: url, to: codec)
                try await model.saveSourceClip(at: converted)
                saveState = .saved
            } catch {
                saveState = .failed(error.localizedDescription)
            }
            isConverting = false
        }
        #endif
    }
}

// MARK: - Swipe to delete (outside List)

/// Reveals a delete action on leading drag, for rows living in custom cards.
private struct SwipeToDeleteModifier: ViewModifier {
    var onDelete: () -> Void
    @State private var offset: CGFloat = 0
    @GestureState private var isDragging = false

    private let actionWidth: CGFloat = 72

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background(alignment: .trailing) {
                if offset < 0 {
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                            offset = 0
                        }
                        onDelete()
                    }) {
                        Image(systemName: "trash.fill")
                            .foregroundStyle(.white)
                            .frame(width: actionWidth)
                            .frame(maxHeight: .infinity)
                            .background(Color.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            .clipped()
            .highPriorityGesture(
                DragGesture(minimumDistance: 24, coordinateSpace: .local)
                    .updating($isDragging) { _, state, _ in state = true }
                    .onChanged { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        offset = min(0, max(-actionWidth, value.translation.width + (offset < -actionWidth / 2 ? -actionWidth : 0)))
                    }
                    .onEnded { value in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                            offset = value.translation.width < -actionWidth / 2 ? -actionWidth : 0
                        }
                    }
            )
    }
}

private extension View {
    func swipeToDelete(onDelete: @escaping () -> Void) -> some View {
        modifier(SwipeToDeleteModifier(onDelete: onDelete))
    }
}

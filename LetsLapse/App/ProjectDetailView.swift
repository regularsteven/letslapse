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
    @State private var isExportingArchive = false
    @State private var exportedArchive: ExportedArchive?
    @State private var exportFailure: String?

    private struct ExportedArchive: Identifiable {
        let url: URL
        var id: String { url.path }
    }
    @State private var storageBytes: Int64?
    @State private var confirmingPurge = false
    @State private var isPurging = false
    @State private var isRotating = false
    @State private var rotateFailure: String?

    /// Save-to-Photos progress, tracked separately for the photo asset and
    /// the originals row so one export doesn't repaint the other.
    private enum AssetSaveState: Equatable {
        case idle, saving, saved, failed(String)
    }
    @State private var photoSaveState: AssetSaveState = .idle
    @State private var originalsSaveState: AssetSaveState = .idle

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
        .alert(
            "Couldn't share project",
            isPresented: Binding(
                get: { exportFailure != nil },
                set: { if !$0 { exportFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportFailure ?? "")
        }
        .alert(
            "Couldn't rotate",
            isPresented: Binding(
                get: { rotateFailure != nil },
                set: { if !$0 { rotateFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(rotateFailure ?? "") Some files may already be rotated — tapping Rotate again completes the pass once the problem is fixed.")
        }
        .sheet(item: $exportedArchive) { archive in
            VStack(spacing: 14) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text(archive.url.lastPathComponent)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if let size = archiveSizeLabel(archive.url) {
                    Text(size)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ShareLink(item: archive.url) {
                    Label("Share archive", systemImage: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button("Done") { exportedArchive = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            #if os(macOS)
            .frame(minWidth: 340)
            #endif
        }
        .alert("Convert all ProRes to H.264?", isPresented: $confirmingPurge) {
            Button("Convert & delete originals", role: .destructive) { purgeProRes() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every ProRes clip is re-encoded to H.264 and the ProRes original is deleted to reclaim space. This can't be undone.")
        }
        .task(id: storageToken) {
            guard let capture else { return }
            storageBytes = await model.storageBytes(for: capture)
        }
    }

    /// Recompute storage whenever versions or per-clip encodings change.
    private var storageToken: Int {
        var hasher = Hasher()
        hasher.combine(model.blends.count)
        if let capture {
            hasher.combine(capture.sourceFileNames.count)
            hasher.combine(capture.clipEncodings?.count ?? 0)
            for list in (capture.clipEncodings ?? [:]).values {
                hasher.combine(list.count)
            }
        }
        return hasher.finalize()
    }

    // MARK: - Content

    private func content(for capture: AppModel.CaptureProject) -> some View {
        let versions = model.blends(for: capture)
        let clipNames = model.sourceClipNames(for: capture)

        return ScrollView {
            VStack(spacing: 14) {
                // A photo capture leads with its graded preview + preset strip;
                // everything else keeps the plain hero.
                if capture.isPhotoCapture {
                    PhotoGradingCard(captureID: capture.id) { url in
                        previewGradedPhoto(capture, url: url)
                    }
                } else {
                    heroCard(for: capture)
                }

                // A Photo-mode capture is ONE photo — no clip list, no
                // versions, no re-processing. Just save, share, manage.
                if capture.isPhotoCapture {
                    photoActions(for: capture)
                } else {
                    if capture.kind == .video, !clipNames.isEmpty {
                        sourceClipsSection(for: capture, clipNames: clipNames)
                    }
                    // Interval frames are stacking material, not clips — one
                    // compact row stands in for the whole set, with the export
                    // path to Photos the originals never had.
                    if capture.kind == .photos {
                        originalsSection(for: capture)
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
                    Button {
                        rotateProject()
                    } label: {
                        Label("Rotate 90°", systemImage: "rotate.right")
                    }
                    .disabled(isRotating || isPurging)
                    #if os(iOS)
                    if capture.kind == .video {
                        Button {
                            confirmingPurge = true
                        } label: {
                            Label("Convert ProRes → H.264, delete originals", systemImage: "arrow.down.circle")
                        }
                        .disabled(isPurging || isRotating)
                    }
                    #endif
                    Button {
                        exportArchive(capture)
                    } label: {
                        Label("Share project", systemImage: "square.and.arrow.up")
                    }
                    .disabled(isExportingArchive)
                    Button(role: .destructive) {
                        confirmingProjectDelete = true
                    } label: {
                        Label("Delete project…", systemImage: "trash")
                    }
                } label: {
                    if isPurging || isExportingArchive || isRotating {
                        ProgressView()
                    } else {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private func heroCard(for capture: AppModel.CaptureProject) -> some View {
        ZStack {
            ProjectThumbnailView(url: heroMediaURL(for: capture), kind: model.mediaKind(for: capture))
                .frame(height: 210)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Button {
                playOriginal(capture)
            } label: {
                Image(systemName: capture.isPhotoCapture
                        ? "arrow.up.left.and.arrow.down.right" : "play.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(capture.isPhotoCapture ? "View photo" : "Play original")
        }
        .overlay(alignment: .topLeading) {
            MediaBadge(text: originalBadge(for: capture))
                .padding(12)
        }
        .overlay(alignment: .bottomTrailing) {
            if let badge = formatBadge(for: capture) {
                MediaBadge(text: badge)
                    .padding(12)
            }
        }
    }

    /// What the hero shows: for a photo capture, the photo itself; otherwise
    /// the source media.
    private func heroMediaURL(for capture: AppModel.CaptureProject) -> URL? {
        capture.isPhotoCapture ? model.heroImageURL(for: capture) : model.mediaURL(for: capture)
    }

    private func sourceClipsSection(for capture: AppModel.CaptureProject, clipNames: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LLSectionHeader(clipNames.count == 1 ? "Source Clip" : "Source Clips · \(clipNames.count)")

            VStack(spacing: 0) {
                ForEach(Array(clipNames.enumerated()), id: \.element) { index, clipName in
                    SourceClipRow(captureID: capture.id, index: index, clipName: clipName) { url in
                        previewClip(for: capture, index: index, url: url)
                    }
                    if clipName != clipNames.last {
                        Divider().padding(.leading, 84)
                    }
                }
            }
            .llCard()
        }
    }

    /// The one-photo action row: Save to Photos — the export path originals
    /// never had — and the system share sheet.
    private func photoActions(for capture: AppModel.CaptureProject) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                #if os(iOS)
                Button {
                    savePhoto(capture)
                } label: {
                    switch photoSaveState {
                    case .idle:
                        Text("Save to Photos")
                    case .saving:
                        Text("Saving…")
                    case .saved:
                        Label("Saved to Photos", systemImage: "checkmark")
                    case .failed:
                        Text("Retry Save")
                    }
                }
                .buttonStyle(LLPrimaryButtonStyle())
                .disabled(photoSaveState == .saving || photoSaveState == .saved)
                #endif

                if let url = model.heroImageURL(for: capture) {
                    ShareLink(item: url) {
                        Text("Share")
                            .font(.system(size: 15.5, weight: .bold))
                            .foregroundStyle(LL.accent)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                }
            }
            if case .failed(let message) = photoSaveState {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Interval shoots: every source frame the camera kept, exportable to
    /// Photos in one batched library change.
    private func originalsSection(for capture: AppModel.CaptureProject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LLSectionHeader("Originals")
            VStack(spacing: 0) {
                LLRow(
                    title: "Source photos",
                    subtitle: originalsSubtitle(for: capture),
                    showsDivider: false
                ) {
                    originalsControl(for: capture)
                }
            }
            .llCard()
        }
    }

    private func originalsSubtitle(for capture: AppModel.CaptureProject) -> String {
        if case .failed(let message) = originalsSaveState { return message }
        return "\(capture.sourceMediaCount) photos"
    }

    @ViewBuilder private func originalsControl(for capture: AppModel.CaptureProject) -> some View {
        #if os(iOS)
        switch originalsSaveState {
        case .saving:
            ProgressView()
                .controlSize(.small)
        case .saved:
            Label("Saved", systemImage: "checkmark")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
        case .idle, .failed:
            Button(originalsSaveState == .idle ? "Save all to Photos" : "Retry") {
                saveOriginals(capture)
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(LL.accent)
            .buttonStyle(.plain)
        }
        #else
        EmptyView()
        #endif
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
            // Photo results are single stacked shots — no re-processing, so
            // the settings-based "New version" path stays off for them.
            if model.capture(for: blend)?.isPhotoCapture != true {
                Button {
                    model.openBlend(blend)
                    model.stage = .configure
                } label: {
                    Label("New version from these settings", systemImage: "slider.horizontal.3")
                }
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

            LLRow(title: "Storage", subtitle: storageSubtitle(for: capture)) {
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

    private func storageSubtitle(for capture: AppModel.CaptureProject) -> String {
        if capture.isPhotoCapture {
            // The burst frames stay on disk as stacking material; own that in
            // the storage line instead of surfacing them as media.
            return capture.sourceMediaCount > 1 ? "photo + burst frames" : "photo"
        }
        return "original + versions"
    }

    private func originalBadge(for capture: AppModel.CaptureProject) -> String {
        // One photo, one badge — never a frame count.
        if capture.isPhotoCapture {
            return "PHOTO"
        }
        if capture.kind == .photos {
            return "ORIGINAL · \(capture.sourceMediaCount) photos"
        }
        if let duration = capture.sourceDurationSeconds {
            return "ORIGINAL · \(DurationFormatter.recordingTime(from: duration))"
        }
        return "ORIGINAL"
    }

    private func formatBadge(for capture: AppModel.CaptureProject) -> String? {
        if capture.isPhotoCapture {
            // Pixel size when the stacked version recorded it; otherwise no
            // second badge — "PHOTO" already says it all.
            if let blend = model.blends(for: capture).first(where: { $0.kind == .image }),
               let width = blend.width, let height = blend.height {
                return AppModel.CaptureProject.resolutionLabel(width: width, height: height)
            }
            return nil
        }
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
        if let codecLabel = blend.sourceCodecLabel {
            parts.append("from \(codecLabel)")
        }
        if blend.linearLight {
            parts.append("true-light")
        }
        parts.append(blend.createdAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    private var deleteProjectMessage: String {
        guard let capture else { return "" }
        if capture.isPhotoCapture {
            return "This permanently deletes the photo. There's no undo."
        }
        let count = model.blends(for: capture).count
        let versionText = count == 1 ? "1 version" : "\(count) versions"
        return "This permanently deletes the original and \(versionText). There's no undo."
    }

    // MARK: - Actions

    private func playOriginal(_ capture: AppModel.CaptureProject) {
        guard let url = heroMediaURL(for: capture) else { return }
        previewItem = MediaPreviewItem(
            title: capture.displayTitle,
            subtitle: capture.formatLine,
            url: url,
            kind: model.mediaKind(for: capture)
        )
    }

    private func savePhoto(_ capture: AppModel.CaptureProject) {
        #if os(iOS)
        photoSaveState = .saving
        Task {
            do {
                // Bakes in the selected grade; Original saves the raw bytes.
                try await model.saveGradedPhoto(for: capture)
                photoSaveState = .saved
            } catch {
                photoSaveState = .failed(error.localizedDescription)
            }
        }
        #endif
    }

    /// Full-screen the photo. The preview sheet shows the untouched original —
    /// the grade lives in the detail preview and the export.
    private func previewGradedPhoto(_ capture: AppModel.CaptureProject, url: URL) {
        previewItem = MediaPreviewItem(
            title: capture.displayTitle,
            subtitle: capture.formatLine,
            url: url,
            kind: .image
        )
    }

    private func saveOriginals(_ capture: AppModel.CaptureProject) {
        #if os(iOS)
        originalsSaveState = .saving
        Task {
            do {
                try await model.saveOriginalsToPhotos(for: capture)
                originalsSaveState = .saved
            } catch {
                originalsSaveState = .failed(error.localizedDescription)
            }
        }
        #endif
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

    private func exportArchive(_ capture: AppModel.CaptureProject) {
        isExportingArchive = true
        Task { @MainActor in
            defer { isExportingArchive = false }
            do {
                let url = try await model.exportProject(capture)
                exportedArchive = ExportedArchive(url: url)
            } catch {
                exportFailure = error.localizedDescription
            }
        }
    }

    private func archiveSizeLabel(_ url: URL) -> String? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let bytes = (attributes?[.size] as? NSNumber)?.int64Value else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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

    private func purgeProRes() {
        guard let capture else { return }
        isPurging = true
        Task {
            do {
                try await model.convertAllProResToH264Purging(for: capture)
            } catch {
                deletionFailure = error.localizedDescription
            }
            isPurging = false
        }
    }

    private func rotateProject() {
        guard let capture else { return }
        isRotating = true
        Task {
            do {
                try await model.rotateProjectMedia(capture)
            } catch {
                rotateFailure = error.localizedDescription
            }
            isRotating = false
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

// MARK: - Photo grading card

/// A photo capture's graded preview with the preset strip beneath it. The
/// image renders the selected `PhotoPreset` live off the original file; tapping
/// a chip re-grades in place and persists the choice. The stored original is
/// never modified — the grade is re-derived each time and only baked in on
/// export.
private struct PhotoGradingCard: View {
    @EnvironmentObject var model: AppModel
    let captureID: UUID
    var onExpand: (URL) -> Void

    /// The graded preview, downscaled for speed; nil until the first render.
    @State private var rendered: CGImage?
    /// Re-renders after a rotate rewrites the original in place (same URL, so
    /// the path/preset id alone can't retrigger; PhotoGrader's own cache is
    /// mtime-keyed and self-heals).
    @ObservedObject private var thumbnailCache = ProjectThumbnailCache.shared

    private var capture: AppModel.CaptureProject? {
        model.captures.first { $0.id == captureID }
    }

    var body: some View {
        if let capture, let url = model.heroImageURL(for: capture) {
            let preset = model.photoPreset(for: capture)
            VStack(spacing: 10) {
                imageCard(url: url)
                    .task(id: "\(url.path)|\(preset.rawValue)|\(thumbnailCache.generation)") {
                        await render(url: url, preset: preset)
                    }
                presetStrip(capture: capture, active: preset)
            }
        }
    }

    private func imageCard(url: URL) -> some View {
        ZStack {
            Group {
                if let rendered {
                    Image(decorative: rendered, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    // Falls back to the ungraded thumbnail while the first
                    // grade renders.
                    ProjectThumbnailView(url: url, kind: .image)
                }
            }
            .frame(height: 210)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Button {
                onExpand(url)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 19))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View photo")
        }
        .overlay(alignment: .topLeading) {
            MediaBadge(text: "PHOTO")
                .padding(12)
        }
    }

    private func presetStrip(capture: AppModel.CaptureProject, active: PhotoPreset) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PhotoPreset.strip) { preset in
                    let isActive = preset == active
                    Button {
                        model.setPhotoPreset(preset, for: capture)
                    } label: {
                        Text(preset.displayName)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(isActive ? Color.white : Color.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(isActive ? LL.accent : LL.cardBackground)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(preset.displayName) grade")
                    .accessibilityAddTraits(isActive ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    private func render(url: URL, preset: PhotoPreset) async {
        let cgImage = await Task.detached(priority: .userInitiated) {
            PhotoGrader.render(url: url, preset: preset, maxDimension: 1400)
        }.value
        // Ignore a nil render (e.g. missing file) so the thumbnail fallback
        // stays visible rather than blanking out.
        if let cgImage { rendered = cgImage }
    }
}

// MARK: - Source clip row

/// One row in the Source Clips section. Non-ProRes clips get a plain Save;
/// ProRes clips (or clips with several encodings) get a Manage control that
/// opens the encodings sheet. The row always reflects the clip's active file.
private struct SourceClipRow: View {
    @EnvironmentObject var model: AppModel
    let captureID: UUID
    let index: Int
    let clipName: String
    var onPlay: (URL) -> Void

    @State private var totalSize: Int64?
    @State private var isSaving = false
    @State private var originalIsProRes = false
    @State private var saveState: SaveState = .idle
    @State private var showingManage = false

    private enum SaveState: Equatable {
        case idle
        case saved
        case failed(String)

        var isError: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    private var capture: AppModel.CaptureProject? { model.captures.first { $0.id == captureID } }

    var body: some View {
        if let capture, let displayURL = model.activeEncodingURL(for: capture, clip: clipName) {
            rowContent(capture: capture, displayURL: displayURL)
        }
    }

    private func rowContent(capture: AppModel.CaptureProject, displayURL: URL) -> some View {
        let stored = capture.clipEncodings?[clipName] ?? []
        let manage = originalIsProRes || stored.count > 1
        return HStack(spacing: 12) {
            Button { onPlay(displayURL) } label: {
                ProjectThumbnailView(url: displayURL, kind: .video)
                    .frame(width: 58, height: 42)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play clip \(index + 1)")

            VStack(alignment: .leading, spacing: 2) {
                Text("Clip \(index + 1)")
                    .font(.system(size: 14.5, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle(capture: capture, manage: manage))
                    .font(.system(size: 11.5))
                    .foregroundStyle(saveState.isError ? Color.red : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            control(manage: manage, displayURL: displayURL)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .task(id: storageKey(capture)) {
            let urls = model.encodings(for: capture, clip: clipName)
                .map { model.encodingURL(for: capture, $0) }
            totalSize = await Task.detached(priority: .utility) {
                urls.reduce(Int64(0)) { $0 + AppModel.directorySize($1) }
            }.value
        }
        .task(id: displayURL) {
            let originalURL = model.encodingURL(
                for: capture, AppModel.ClipEncoding(codec: "", fileName: clipName))
            originalIsProRes = await AppModel.sourceClipIsProRes(at: originalURL)
        }
        .sheet(isPresented: $showingManage) {
            ManageClipSheet(captureID: captureID, clipName: clipName, clipIndex: index)
        }
    }

    private func storageKey(_ capture: AppModel.CaptureProject) -> String {
        clipName + "|" + (capture.clipEncodings?[clipName]?.map { $0.fileName }.joined(separator: ",") ?? "")
    }

    private func subtitle(capture: AppModel.CaptureProject, manage: Bool) -> String {
        if isSaving { return "Saving…" }
        switch saveState {
        case .saved: return "Saved to Photos"
        case .failed(let message): return message
        case .idle:
            let size = totalSize.map { LLFormat.bytes($0) }
            guard manage else { return size ?? "Video clip" }
            let existing = model.encodings(for: capture, clip: clipName).filter {
                FileManager.default.fileExists(atPath: model.encodingURL(for: capture, $0).path)
            }
            let lead: String
            if existing.count > 1 {
                lead = "\(existing.count) formats"
            } else if originalIsProRes {
                lead = "ProRes"
            } else {
                lead = existing.first?.codecLabel ?? "Video"
            }
            return size.map { "\(lead) · \($0)" } ?? lead
        }
    }

    @ViewBuilder private func control(manage: Bool, displayURL: URL) -> some View {
        #if os(iOS)
        if isSaving {
            ProgressView().controlSize(.small)
        } else if manage {
            Button("Manage") { showingManage = true }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LL.accent)
                .buttonStyle(.plain)
        } else if saveState == .saved {
            Label("Saved", systemImage: "checkmark")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
        } else {
            Button(saveState.isError ? "Retry" : "Save") { save(displayURL) }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LL.accent)
                .buttonStyle(.plain)
        }
        #endif
    }

    private func save(_ url: URL) {
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
}

// MARK: - Manage clip sheet

/// Per-clip encoding manager: list the clip's encodings (ProRes original plus
/// any conversions), Save any to Photos, delete individual ones (including the
/// ProRes original once a conversion exists), and convert from ProRes.
private struct ManageClipSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let captureID: UUID
    let clipName: String
    let clipIndex: Int

    @State private var busyCodec: String?
    @State private var isBusy = false
    @State private var originalIsProRes = false
    @State private var errorMessage: String?
    @State private var encodingPendingDelete: AppModel.ClipEncoding?

    private var capture: AppModel.CaptureProject? { model.captures.first { $0.id == captureID } }

    var body: some View {
        NavigationStack {
            Form {
                if let capture {
                    encodingsSection(capture)
                    convertSection(capture)
                }
            }
            .navigationTitle("Clip \(clipIndex + 1)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            guard let capture else { return }
            let originalURL = model.encodingURL(
                for: capture, AppModel.ClipEncoding(codec: "", fileName: clipName))
            originalIsProRes = await AppModel.sourceClipIsProRes(at: originalURL)
        }
        .alert(
            "Couldn't complete",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(
            "Delete ProRes original?",
            isPresented: Binding(
                get: { encodingPendingDelete != nil },
                set: { if !$0 { encodingPendingDelete = nil } }
            )
        ) {
            Button("Delete ProRes", role: .destructive) {
                if let capture, let encoding = encodingPendingDelete {
                    performDelete(capture, encoding)
                }
                encodingPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { encodingPendingDelete = nil }
        } message: {
            Text("ProRes is the highest-quality original and can't be re-created from a converted copy. Your H.264/HEVC versions stay.")
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private func encodingsSection(_ capture: AppModel.CaptureProject) -> some View {
        let encodings = existingEncodings(capture)
        return Section("Formats") {
            ForEach(encodings) { encoding in
                encodingRow(capture, encoding, canDelete: encodings.count > 1)
            }
        }
    }

    private func encodingRow(
        _ capture: AppModel.CaptureProject,
        _ encoding: AppModel.ClipEncoding,
        canDelete: Bool
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label(for: encoding))
                    .font(.system(size: 15, weight: .semibold))
                Text(LLFormat.bytes(AppModel.directorySize(model.encodingURL(for: capture, encoding))))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            #if os(iOS)
            Button {
                save(capture, encoding)
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .disabled(isBusy)
            .accessibilityLabel("Save \(label(for: encoding)) to Photos")
            #endif
            if canDelete {
                Button(role: .destructive) {
                    delete(capture, encoding)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(isBusy)
                .accessibilityLabel("Delete \(label(for: encoding))")
            }
        }
    }

    @ViewBuilder private func convertSection(_ capture: AppModel.CaptureProject) -> some View {
        if hasProResOriginal(capture) {
            Section {
                convertButton(capture, .h264)
                convertButton(capture, .hevc)
            } header: {
                Text("Convert from ProRes")
            } footer: {
                Text("ProRes is a capture format, not a distribution one. Convert to H.264 or HEVC to shrink storage, then delete the ProRes original.")
            }
        }
    }

    @ViewBuilder private func convertButton(
        _ capture: AppModel.CaptureProject,
        _ codec: OutputCodec
    ) -> some View {
        let exists = existingEncodings(capture).contains { $0.codec == codec.rawValue }
        Button {
            convert(capture, codec)
        } label: {
            HStack {
                Label(codec == .h264 ? "Convert to H.264" : "Convert to HEVC",
                      systemImage: "arrow.triangle.2.circlepath")
                Spacer()
                if busyCodec == codec.rawValue {
                    ProgressView()
                } else if exists {
                    Image(systemName: "checkmark").foregroundStyle(.secondary)
                }
            }
        }
        .disabled(isBusy || exists)
    }

    // MARK: helpers

    private func existingEncodings(_ capture: AppModel.CaptureProject) -> [AppModel.ClipEncoding] {
        model.encodings(for: capture, clip: clipName).filter {
            FileManager.default.fileExists(atPath: model.encodingURL(for: capture, $0).path)
        }
    }

    private func hasProResOriginal(_ capture: AppModel.CaptureProject) -> Bool {
        if existingEncodings(capture).contains(where: { $0.isProRes }) { return true }
        let originalURL = model.encodingURL(
            for: capture, AppModel.ClipEncoding(codec: "", fileName: clipName))
        return originalIsProRes && FileManager.default.fileExists(atPath: originalURL.path)
    }

    private func label(for encoding: AppModel.ClipEncoding) -> String {
        if encoding.fileName == clipName, encoding.codec.isEmpty {
            return originalIsProRes ? "ProRes" : "Original"
        }
        return encoding.codecLabel
    }

    private func convert(_ capture: AppModel.CaptureProject, _ codec: OutputCodec) {
        busyCodec = codec.rawValue
        isBusy = true
        Task {
            do {
                try await model.addEncoding(for: capture, clip: clipName, codec: codec)
            } catch {
                errorMessage = error.localizedDescription
            }
            busyCodec = nil
            isBusy = false
        }
    }

    private func delete(_ capture: AppModel.CaptureProject, _ encoding: AppModel.ClipEncoding) {
        // Deleting the irreplaceable ProRes original needs a confirmation;
        // converted copies can go without ceremony.
        if encoding.isProRes {
            encodingPendingDelete = encoding
        } else {
            performDelete(capture, encoding)
        }
    }

    private func performDelete(_ capture: AppModel.CaptureProject, _ encoding: AppModel.ClipEncoding) {
        do {
            try model.deleteEncoding(for: capture, clip: clipName, encoding)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save(_ capture: AppModel.CaptureProject, _ encoding: AppModel.ClipEncoding) {
        #if os(iOS)
        isBusy = true
        Task {
            do {
                try await model.saveSourceClip(at: model.encodingURL(for: capture, encoding))
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
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

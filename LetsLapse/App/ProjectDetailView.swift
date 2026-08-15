import SwiftUI
import LetsLapseKit

/// The management layer the old app was missing: play the original, make new
/// versions, rename, see per-project storage, and delete safely.
struct ProjectDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    let captureID: UUID

    /// What the fullscreen player is showing. Every in-app playback path on this
    /// screen — the hero's play button, a source clip row, a version row — goes
    /// through it.
    @State private var fullscreenMedia: FullscreenMediaRequest?
    /// The photo opened in the grading viewer (iOS sheet only — on macOS the
    /// viewer opens as its own window). Separate from `fullscreenMedia` because
    /// the viewer is the grading *editor*, not playback.
    @State private var gradingPhoto: GradingPhoto?
    @State private var isRenaming = false
    /// On-device naming: the run in flight and the proposal it produced.
    @StateObject private var autoName = AutoNameController()
    @ObservedObject private var models = ModelManager.shared

    private struct GradingPhoto: Identifiable {
        let url: URL
        var id: String { url.path }
    }
    /// The movie opened in the video editor (iOS sheet only — on macOS the
    /// editor opens as its own window, like the photo editor).
    @State private var editingVideo: GradingPhoto?
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
    @State private var isBrowsingOriginals = false
    /// Save-to-Photos progress, tracked separately for the photo asset and
    /// the originals row so one export doesn't repaint the other.
    private enum AssetSaveState: Equatable {
        case idle, saving, saved, failed(String)
    }
    @State private var photoSaveState: AssetSaveState = .idle
    @State private var originalsSaveState: AssetSaveState = .idle
    /// Collection confirmations ("Added to City set", refusals, creations).
    @State private var collectionToast: String?

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
        .fullscreenMedia($fullscreenMedia, model: model)
        .llToast($collectionToast)
        #if os(iOS)
        // macOS has no grading sheet: `previewGradedPhoto` opens the viewer in
        // its own resizable window instead (see the scene in `LetsLapseApp`).
        .sheet(item: $gradingPhoto) { photo in
            PhotoViewerView(
                captureID: captureID,
                url: photo.url,
                title: capture?.displayTitle ?? "Photo"
            )
            .environmentObject(model)
        }
        .sheet(item: $editingVideo) { video in
            VideoEditorView(
                captureID: captureID,
                url: video.url,
                title: capture?.displayTitle ?? "Video"
            )
            .environmentObject(model)
        }
        #endif
        .sheet(item: $autoName.proposal) { proposal in
            AutoNameSheet(proposal: proposal) { metadata in
                if let capture {
                    model.applySceneMetadata(metadata, to: capture)
                }
            }
        }
        .alert(
            "Couldn't analyse this project",
            isPresented: Binding(
                get: { autoName.failure != nil },
                set: { if !$0 { autoName.failure = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(autoName.failure ?? "")
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
                title: Text("Delete blended clip \(model.versionNumber(for: blend))?"),
                message: Text(deleteVersionMessage(blend)),
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
        .sheet(isPresented: $isBrowsingOriginals) {
            if let capture {
                CapturePhotoGrid(
                    title: capture.displayTitle,
                    urls: model.sourceFrameURLs(for: capture),
                    captureID: capture.id
                )
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 480)
                #endif
            }
        }
        .task(id: storageToken) {
            guard let capture else { return }
            if let bytes = await model.storageBytes(for: capture) {
                storageBytes = bytes
            }
        }
        #if DEBUG
        // `LL_VIEWER=1` opens the grading viewer straight away and
        // `LL_VIEWER=expanded` opens it with the Customise panel down, so both
        // states can be screenshot-verified against their SVG without tap
        // automation — the same trick as the other LL_* hooks in LetsLapseApp.
        // Works for a photo capture and for an interval shoot's first frame,
        // which are the two kinds that have a frame file to open.
        .task {
            let hook = ProcessInfo.processInfo.environment["LL_VIEWER"]
            guard hook == "1" || hook == "expanded",
                  let capture, capture.kind == .photos,
                  let url = capture.isPhotoCapture
                    ? model.heroImageURL(for: capture)
                    : model.sourceFrameURLs(for: capture).first else { return }
            previewGradedPhoto(capture, url: url)
        }
        #endif
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
                // Every mode leads with its graded preview and preset strip —
                // the grade is non-destructive and applies to photo, interval
                // and video alike, and every hero carries the same edit pill:
                // stills open the grading viewer, a movie opens the video
                // editor with the player beside the same controls.
                GradingCard(
                    captureID: capture.id,
                    badge: originalBadge(for: capture),
                    // A Photo capture's card carries the one PHOTO pill and
                    // nothing else — its pixel size is a property of the stack,
                    // not of the asset the card is showing.
                    formatBadge: capture.isPhotoCapture ? nil : formatBadge(for: capture),
                    onOpenViewer: { url in previewGradedPhoto(capture, url: url) },
                    onPlay: { playOriginal(capture) },
                    onEditVideo: { url in editVideo(capture, url: url) },
                    // Interval only: the shoot has frames to play as motion, so
                    // its card leads with Play and keeps the editor as a second
                    // affordance. Photo has one still and video has a movie —
                    // neither has a sequence to preview.
                    onPlaySequence: capture.kind == .photos && !capture.isPhotoCapture
                        ? { previewSequence(capture) } : nil
                )

                // A Photo-mode capture is ONE photo — no clip list, no
                // versions, no re-processing. Just save, share, manage.
                if capture.isPhotoCapture {
                    photoActions(for: capture)
                    // A blended Photo shot stacks a burst into its one asset and
                    // keeps the frames on disk. They stay stacking material —
                    // no versions, no re-processing — but they are reachable
                    // now, one frame at a time. An unblended shot captured a
                    // single frame, which *is* the photo above: nothing to open.
                    if capture.sourceMediaCount > 1 {
                        originalsSection(for: capture)
                    }
                } else {
                    // Results lead: the blended clips already made, then the
                    // button that makes the next one, then the source material
                    // they're made from. No clips yet hides the section — the
                    // button right under the hero is the empty state.
                    if !versions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            LLSectionHeader("Blended clips · \(versions.count)")

                            VStack(spacing: 0) {
                                ForEach(versions) { blend in
                                    versionRow(blend, in: capture)
                                    if blend.id != versions.last?.id {
                                        Divider().padding(.leading, 84)
                                    }
                                }
                            }
                            .llCard()
                        }
                    }

                    Button {
                        model.openCapture(capture)
                    } label: {
                        Label("New blended clip", systemImage: "plus")
                    }
                    .buttonStyle(LLPrimaryButtonStyle())

                    // An experimental side-step into the SAME flow: a survey
                    // that authors the warp + reframe as states and
                    // transitions instead of a timeline. It must never
                    // displace the primary button above.
                    if capture.kind == .video {
                        Button {
                            model.openCapture(capture)
                            model.guidedBuilderFocused = true
                        } label: {
                            Label("Guided clip (experimental)", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(LLSecondaryButtonStyle())
                    }

                    // The other door into the SAME flow: a punch-in move on
                    // top of the speed warp. It opens the blended-clip editor
                    // with the reframe lane already expanded — one process,
                    // two entry points. Video only — a photo stack has no
                    // frame to crop into over time.
                    if capture.kind == .video {
                        Button {
                            model.openCapture(capture)
                            model.reframeLaneFocused = true
                        } label: {
                            Label("Punch-in reframe", systemImage: "viewfinder")
                        }
                        .buttonStyle(LLSecondaryButtonStyle())
                    }

                    if capture.kind == .video, !clipNames.isEmpty {
                        sourceClipsSection(for: capture, clipNames: clipNames)
                    }
                    // Interval frames are stacking material, not clips — one
                    // compact row stands in for the whole set, with the export
                    // path to Photos the originals never had.
                    if capture.kind == .photos {
                        originalsSection(for: capture)
                    }
                }

                managementCard(for: capture)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            #if os(iOS)
            // Clearance for the floating tab bar, so Delete project stays
            // visible and tappable at the end of the scroll.
            .padding(.bottom, 96)
            #else
            .padding(.bottom, 24)
            #endif
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
                        startAutoName(capture)
                    } label: {
                        Label("Auto rename & tag", systemImage: "sparkles")
                    }
                    .disabled(!models.isReady || autoName.isRunning)
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
                    #if os(macOS)
                    Button {
                        revealInFinder(capture)
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    #endif
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

    #if os(macOS)
    /// Opens the project's folder in Finder with it selected, so the UUID the
    /// files actually live under is right there rather than something you have
    /// to work out from the library.
    ///
    /// Falls back to the Projects folder if the project's own is missing —
    /// revealing nothing at all would look like a menu item that does nothing,
    /// when the interesting fact is that the folder has gone.
    private func revealInFinder(_ capture: AppModel.CaptureProject) {
        let folder = model.projectFolderURL(for: capture)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            NSWorkspace.shared.activateFileViewerSelecting([model.projectsFolderURL])
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
    #endif

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
                        previewClip(for: capture, url: url)
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

    /// Every source frame the camera kept — exportable to Photos in one batched
    /// library change, and browsable one frame at a time (the batch export used
    /// to be the only way to reach them).
    ///
    /// Interval shoots call these the originals. A Photo-mode shot calls them
    /// burst frames: they are the stacking material behind its one photo, not a
    /// set of photos in their own right.
    private func originalsSection(for capture: AppModel.CaptureProject) -> some View {
        let isBurst = capture.isPhotoCapture
        return VStack(alignment: .leading, spacing: 8) {
            LLSectionHeader(isBurst ? "Burst frames" : "Originals")
            VStack(spacing: 0) {
                LLRow(
                    title: isBurst ? "Frames behind this photo" : "Source photos",
                    subtitle: originalsSubtitle(for: capture)
                ) {
                    originalsControl(for: capture)
                }

                Button {
                    isBrowsingOriginals = true
                } label: {
                    LLRow(title: isBurst ? "View all frames" : "View all photos", showsDivider: false) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(capture.sourceMediaCount == 0)
            }
            .llCard()
        }
    }

    private func originalsSubtitle(for capture: AppModel.CaptureProject) -> String {
        if case .failed(let message) = originalsSaveState { return message }
        let count = capture.sourceMediaCount
        return capture.isPhotoCapture ? "\(count) frames" : "\(count) photos"
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

    private func versionRow(_ blend: AppModel.BlendProject, in capture: AppModel.CaptureProject) -> some View {
        HStack(spacing: 12) {
            // The row plays; Open still goes to the result screen, where the
            // version's settings and its export paths live.
            Button {
                previewVersion(blend, in: capture)
            } label: {
                HStack(spacing: 12) {
                    ProjectThumbnailView(
                        url: model.mediaURL(for: blend), kind: model.mediaKind(for: blend))
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
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play blended clip \(model.versionNumber(for: blend))")

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
            // the settings-based "New blended clip" path stays off for them.
            if model.capture(for: blend)?.isPhotoCapture != true {
                Button {
                    model.openBlend(blend)
                    model.stage = .configure
                } label: {
                    Label("New blended clip from these settings", systemImage: "slider.horizontal.3")
                }
            }
            // Collections are video-only in v1 — a long-exposure image
            // has no place on a timeline, so no menu for it.
            if blend.kind == .video {
                Menu {
                    ForEach(model.collections) { collection in
                        Button("\(collection.name) · \(collection.clipCountLabel)") {
                            addToCollection(blend, collection)
                        }
                    }
                    if !model.collections.isEmpty {
                        Divider()
                    }
                    Button {
                        newCollectionWith(blend)
                    } label: {
                        Label("New collection…", systemImage: "plus")
                    }
                } label: {
                    Label("Add to collection", systemImage: "film.stack")
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
            autoNameRow(for: capture)

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

            if let tags = capture.sceneTags, !tags.isEmpty {
                LLRow(title: "Tags") {
                    Text(tags.map { SceneMetadata.label(for: $0) }.joined(separator: ", "))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            // The analysis's own wording for what was in frame. Kept because it is what
            // Projects search matches on most specifically — "waterfall" finds this project
            // when no tag in the closed taxonomy would have.
            if let elements = capture.sceneElements, !elements.isEmpty {
                LLRow(title: "In frame") {
                    Text(elements.joined(separator: ", "))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

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

    // MARK: - Auto rename & tag

    /// Names and tags the project from the frames themselves.
    ///
    /// With no model installed the row stays visible but inert, and its caption is the fix: it
    /// deep-links to Settings › AI Models rather than describing where to go. A feature that can't
    /// run is more useful as a signpost than as a hidden row.
    @ViewBuilder
    private func autoNameRow(for capture: AppModel.CaptureProject) -> some View {
        let isReady = models.isReady

        Button {
            startAutoName(capture)
        } label: {
            LLRow(
                title: "Auto rename & tag",
                subtitle: autoNameSubtitle(isReady: isReady),
                titleColor: isReady ? .primary : .secondary
            ) {
                if autoName.isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else if isReady {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LL.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isReady || autoName.isRunning)

        // Disabled buttons swallow taps, so the "go and fix it" affordance is its own control
        // under the row rather than the row's own caption.
        if !isReady {
            Button {
                model.requestedSettingsDestination = .aiModels
            } label: {
                LLRow(title: "Open AI Models in Settings", titleColor: LL.accent) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func autoNameSubtitle(isReady: Bool) -> String {
        if let status = autoName.status { return status }
        if !isReady { return "Choose a model in Settings to enable" }
        // Vision tags but cannot name, and the row is called "Auto rename & tag" — say which half
        // is actually on offer rather than promising a name that arrives unchanged.
        if models.activeModel?.isBuiltIn == true {
            return "Tags this project from its own frames · Apple Vision doesn't suggest names"
        }
        return "Names and tags this project from its own frames, on this device"
    }

    private func startAutoName(_ capture: AppModel.CaptureProject) {
        guard let source = model.sceneSource(for: capture) else {
            autoName.failure = "This project has no frames to analyse."
            return
        }
        let locationFile = model.sourceClipURLs(for: capture).first
            ?? model.sourceFrameURLs(for: capture).first
        Task {
            await autoName.run(
                source: source,
                capturedAt: capture.createdAt,
                duration: capture.sourceDurationSeconds ?? 0,
                locationFile: locationFile,
                fallbackTitle: capture.displayTitle)
        }
    }

    // MARK: - Labels

    private func storageSubtitle(for capture: AppModel.CaptureProject) -> String {
        if capture.isPhotoCapture {
            // The burst frames stay on disk as stacking material; own that in
            // the storage line instead of surfacing them as media.
            return capture.sourceMediaCount > 1 ? "photo + burst frames" : "photo"
        }
        return "original + blended clips"
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
        var parts = ["Blended clip \(model.versionNumber(for: blend))", blend.speedLabel]
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
        let versionText = count == 1 ? "1 blended clip" : "\(count) blended clips"
        return "This permanently deletes the original and \(versionText). There's no undo."
    }

    // MARK: - Actions

    /// Plays the capture's own footage.
    ///
    /// A recording written as several segments plays as the one take it was:
    /// the player stitches them into an in-memory composition. Only the first
    /// segment used to play, silently, which read as a shoot that had lost most
    /// of itself.
    private func playOriginal(_ capture: AppModel.CaptureProject) {
        // The original is ungraded on disk, so the player applies the project's
        // grade live — the same grade the card above it is previewing.
        let grade = model.photoGrade(for: capture)
        guard capture.kind == .video else {
            guard let url = heroMediaURL(for: capture) else { return }
            fullscreenMedia = FullscreenMediaRequest(
                .photo(url: url), captureID: capture.id, title: capture.displayTitle)
            return
        }
        // Already resolved to each clip's active encoding, so what plays is what
        // the source-clip rows are showing.
        let segments = model.sourceClipURLs(for: capture)
        let content: FullscreenContent
        if segments.count > 1 {
            content = .videoSequence(urls: segments, grade: grade)
        } else if let url = segments.first ?? heroMediaURL(for: capture) {
            content = .video(url: url, grade: grade)
        } else {
            return
        }
        fullscreenMedia = FullscreenMediaRequest(
            content, captureID: capture.id, title: capture.displayTitle)
    }

    /// Plays an interval shoot as motion, straight from its frames — what it
    /// will look like as a clip, without spending a render to find out.
    private func previewSequence(_ capture: AppModel.CaptureProject) {
        let frames = model.sourceFrameURLs(for: capture)
        guard !frames.isEmpty else { return }
        fullscreenMedia = FullscreenMediaRequest(
            .intervalMotion(frames: frames, fps: previewFPS(for: capture)),
            captureID: capture.id,
            title: capture.displayTitle)
    }

    /// The rate the motion preview runs at: the frame rate this project's newest
    /// rendered version used, so the preview matches what the shoot has already
    /// been made into. Nothing rendered yet — a plain 12 fps, fast enough to
    /// read as motion and slow enough to see each frame.
    private func previewFPS(for capture: AppModel.CaptureProject) -> Double {
        if let fps = model.blends(for: capture).first(where: { $0.kind == .video })?.outputFPS,
           fps > 0 {
            return Double(fps)
        }
        return 12
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

    /// Opens the grading viewer: the photo at size, rendered through its
    /// current grade, with the preset strip and the adjustment sliders.
    /// A sheet on iOS/iPadOS; a freely resizable window on macOS.
    private func previewGradedPhoto(_ capture: AppModel.CaptureProject, url: URL) {
        #if os(macOS)
        openWindow(value: PhotoEditorWindowRequest(
            captureID: captureID, url: url, title: capture.displayTitle))
        #else
        gradingPhoto = GradingPhoto(url: url)
        #endif
    }

    /// Opens the video editor: the movie playing at its true aspect ratio with
    /// the same preset strip and adjustment sections the photo editor has.
    /// A sheet on iOS/iPadOS; a freely resizable window on macOS.
    private func editVideo(_ capture: AppModel.CaptureProject, url: URL) {
        #if os(macOS)
        openWindow(value: VideoEditorWindowRequest(
            captureID: captureID, url: url, title: capture.displayTitle))
        #else
        editingVideo = GradingPhoto(url: url)
        #endif
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

    /// Opens a source clip in the player, with the project's other clips as the
    /// swipeable set. The siblings are resolved the same way the rows are — by
    /// active encoding — so what plays is the file the row is showing.
    private func previewClip(for capture: AppModel.CaptureProject, url: URL) {
        let grade = model.photoGrade(for: capture)
        let urls = model.sourceClipNames(for: capture).compactMap {
            model.activeEncodingURL(for: capture, clip: $0)
        }
        let items = (urls.isEmpty ? [url] : urls).map {
            FullscreenContent.video(url: $0, grade: grade)
        }
        fullscreenMedia = FullscreenMediaRequest(
            items: items,
            index: urls.firstIndex(of: url) ?? 0,
            captureID: capture.id,
            title: capture.displayTitle)
    }

    /// Opens a rendered version in the player.
    ///
    /// Deliberately **ungraded**: a version has the grade that produced it baked
    /// in at render time (`AppModel` bakes stills frame by frame and video with
    /// `VideoGrader.bakedCopy`), so re-applying the project's current grade here
    /// would show it twice — and twice over the *wrong* grade for a version made
    /// before the grade last changed.
    private func previewVersion(_ blend: AppModel.BlendProject, in capture: AppModel.CaptureProject) {
        let versions = model.blends(for: capture).filter { $0.kind == blend.kind }
        let urls = versions.map { model.mediaURL(for: $0) }
        let url = model.mediaURL(for: blend)
        let items: [FullscreenContent] = urls.map {
            blend.kind == .video ? .video(url: $0, grade: nil) : .photo(url: $0)
        }
        fullscreenMedia = FullscreenMediaRequest(
            items: items.isEmpty ? [.video(url: url, grade: nil)] : items,
            index: urls.firstIndex(of: url) ?? 0,
            title: capture.displayTitle)
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

    // MARK: - Collections

    private func addToCollection(_ blend: AppModel.BlendProject, _ collection: LapseCollection) {
        if collection.entry(for: blend.id) != nil {
            collectionToast = "Already in \(collection.name) — one appearance per collection"
            return
        }
        model.addBlends([blend.id], to: collection.id)
        collectionToast = "Added to \(collection.name)"
    }

    private func newCollectionWith(_ blend: AppModel.BlendProject) {
        let collection = model.createCollection(named: model.suggestedCollectionName)
        model.addBlends([blend.id], to: collection.id)
        collectionToast = "Created “\(collection.name)” with this clip"
    }

    /// The delete warning names the collections that use this clip — deleting
    /// also removes it from them.
    private func deleteVersionMessage(_ blend: AppModel.BlendProject) -> String {
        let used = model.collectionsUsing(blendID: blend.id)
        guard !used.isEmpty else {
            return "This permanently deletes the blended clip. The original stays in the project."
        }
        let names = used.map { "“\($0.name)”" }
        let list = names.count == 1
            ? names[0]
            : names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        let pronoun = used.count == 1 ? "that collection" : "those collections"
        return "It’s used in \(list). Deleting also removes it from \(pronoun). Your original is safe."
    }
}

// MARK: - Grading card

/// A capture's graded preview with the preset strip beneath it, for every mode.
///
/// The preview renders the project's `PhotoPreset` and `PhotoAdjustments` live —
/// off the photo for a Photo capture, off the first source frame for an interval
/// shoot, and off a frame pulled out of the movie for a video capture. Tapping a
/// chip re-grades in place and persists the choice. Nothing on disk is modified:
/// the grade is re-derived each time and baked in only where a new file is
/// written (a rendered version, or an export).
///
/// Photo and interval captures have frame files, so their preview opens the
/// grading viewer — presets, sliders and white balance at size. A video project
/// has no such viewer (its preview button plays the movie), so it carries the
/// Customise controls in the card itself: inline below the strip in a narrow
/// layout, and in a sheet once the card is wide enough that an inline panel
/// would push the preview off a short screen.
private struct GradingCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var presetStore = CustomPresetStore.shared
    let captureID: UUID
    /// The ORIGINAL/PHOTO pill over the top-left of the preview.
    var badge: String
    /// The resolution/fps pill over the bottom-right, when there is one.
    var formatBadge: String?
    /// Photo and interval: open the grading viewer on this frame.
    var onOpenViewer: (URL) -> Void
    /// Video: play the original.
    var onPlay: () -> Void
    /// Video: open the video editor on this movie — the player beside the
    /// grading controls, the video sibling of `onOpenViewer`.
    var onEditVideo: (URL) -> Void
    /// Interval: play the shoot as motion from its frames. When this is set the
    /// card shows two affordances — Play in the middle, Edit photo below it —
    /// because an interval project has both a sequence to watch and a frame to
    /// grade. nil leaves the single-button card every other mode has.
    var onPlaySequence: (() -> Void)?

    /// The graded preview, downscaled for speed; nil until the first render.
    @State private var rendered: CGImage?
    /// Re-renders after a rotate rewrites the original in place (same URL, so
    /// the path/preset id alone can't retrigger; PhotoGrader's own cache is
    /// mtime-keyed and self-heals).
    @ObservedObject private var thumbnailCache = ProjectThumbnailCache.shared

    /// How long a preset change has to be still before the preview re-renders.
    private let renderDebounce: Duration = .milliseconds(100)

    private var capture: AppModel.CaptureProject? {
        model.captures.first { $0.id == captureID }
    }

    /// What the card previews, and how it has to be decoded.
    private enum Preview: Equatable {
        case still(URL)
        case movie(URL)

        var url: URL {
            switch self {
            case .still(let url), .movie(let url): return url
            }
        }

        var isMovie: Bool {
            if case .movie = self { return true }
            return false
        }
    }

    var body: some View {
        if let capture {
            // A project whose files have gone missing has no frame to grade;
            // the card still draws, with the placeholder hero and no button, so
            // the screen doesn't lose its top card.
            let preview = preview(for: capture)
            let grade = PhotoGrade(
                preset: model.photoPreset(for: capture),
                adjustments: adjustments(for: capture))
            VStack(spacing: 10) {
                imageCard(preview: preview)
                presetStrip(capture: capture, active: grade.preset, adjustments: grade.adjustments)
            }
            .task(id: "\(preview?.url.path ?? "-")|\(grade.cacheToken)|\(thumbnailCache.generation)") {
                // Debounce: chip taps and editor writes re-key this task, so a
                // burst collapses into one render.
                try? await Task.sleep(for: renderDebounce)
                guard !Task.isCancelled else { return }
                if let preview {
                    await render(preview, grade: grade)
                }
            }
        }
    }

    /// The frame the grade is previewed on.
    ///
    /// An interval project previews its **first source frame**, not its hero:
    /// once it has a stacked image version that version becomes the hero, and it
    /// is a finished render that already carries whatever grade produced it —
    /// grading it again on screen would show the grade twice.
    private func preview(for capture: AppModel.CaptureProject) -> Preview? {
        switch capture.kind {
        case .video:
            return model.mediaURL(for: capture).map(Preview.movie)
        case .photos:
            if capture.isPhotoCapture {
                return model.heroImageURL(for: capture).map(Preview.still)
            }
            return model.sourceFrameURLs(for: capture).first.map(Preview.still)
        }
    }

    /// The adjustments on screen: always the project's stored values — every
    /// mode's sliders live in an editor now (photo viewer or video editor),
    /// and this card follows whatever those wrote.
    private func adjustments(for capture: AppModel.CaptureProject) -> PhotoAdjustments {
        model.photoAdjustments(for: capture)
    }

    private func imageCard(preview: Preview?) -> some View {
        ZStack {
            Group {
                if let rendered {
                    // True aspect ratio, never cropped: the hero presents the
                    // asset as it actually is, capped in height so a portrait
                    // frame doesn't swallow the screen.
                    Image(decorative: rendered, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 340)
                } else {
                    // Falls back to the ungraded thumbnail while the first
                    // grade renders.
                    ProjectThumbnailView(
                        url: preview?.url, kind: preview?.isMovie == true ? .video : .image)
                        .frame(height: 210)
                        .frame(maxWidth: .infinity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            if let preview {
                heroButton(preview: preview)
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottomLeading) {
            // Every project edits from its hero: the still modes get Edit
            // photo, a movie gets Edit video — same pill, same place.
            switch preview {
            case .still(let url):
                editPill(title: "Edit photo") { onOpenViewer(url) }
            case .movie(let url):
                editPill(title: "Edit video") { onEditVideo(url) }
            case nil:
                EmptyView()
            }
        }
        .overlay(alignment: .topLeading) {
            MediaBadge(text: badge)
                .padding(12)
        }
        .overlay(alignment: .bottomTrailing) {
            if let formatBadge {
                MediaBadge(text: formatBadge)
                    .padding(12)
            }
        }
    }

    /// The middle of the preview: play the movie, play the sequence, or open the
    /// still — whichever this project's material actually is.
    @ViewBuilder private func heroButton(preview: Preview) -> some View {
        switch preview {
        case .movie:
            heroCircle(systemImage: "play.fill", label: "Play original", action: onPlay)
        case .still(let url):
            if let onPlaySequence {
                heroCircle(
                    systemImage: "play.fill", label: "Preview sequence", action: onPlaySequence)
            } else {
                heroCircle(
                    systemImage: "arrow.up.left.and.arrow.down.right",
                    label: "View photo") { onOpenViewer(url) }
            }
        }
    }

    private func heroCircle(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 19))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// The bottom-left edit affordance every hero carries — Edit photo on the
    /// still modes, Edit video on a movie.
    private func editPill(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "slider.horizontal.3")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.black.opacity(0.45), in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(12)
    }

    private func presetStrip(
        capture: AppModel.CaptureProject,
        active: PhotoPreset,
        adjustments: PhotoAdjustments
    ) -> some View {
        // A saved grade owns the highlight when the project matches it exactly,
        // so its base preset's chip doesn't light up alongside it.
        let activeCustom = presetStore.matching(basePreset: active, adjustments: adjustments)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PhotoPreset.strip) { preset in
                    chip(
                        label: preset.displayName,
                        isActive: preset == active && activeCustom == nil,
                        accessibilityLabel: "\(preset.displayName) grade"
                    ) {
                        model.setPhotoPreset(preset, for: capture)
                    }
                }
                ForEach(presetStore.presets) { custom in
                    chip(
                        label: custom.name,
                        isActive: activeCustom?.id == custom.id,
                        accessibilityLabel: "\(custom.name) saved grade"
                    ) {
                        model.applyCustomPreset(custom, for: capture)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            presetStore.delete(custom)
                        } label: {
                            Label("Delete preset", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    private func chip(
        label: String,
        isActive: Bool,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(isActive ? Color.white : Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(isActive ? LL.accent : LL.cardBackground))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    /// Renders the preview: a still through the image grader, a movie through one
    /// graded frame pulled out with `AVAssetImageGenerator`.
    private func render(_ preview: Preview, grade: PhotoGrade) async {
        let cgImage = await MediaWorkQueue.shared.run { () -> CGImage? in
            switch preview {
            case .still(let url):
                return PhotoGrader.render(
                    url: url, preset: grade.preset, adjustments: grade.adjustments,
                    maxDimension: 1400)
            case .movie(let url):
                return VideoGrader.gradedFrame(at: url, grade: grade, maxDimension: 1400)
            }
        }
        // Ignore a nil render (missing file, or the view went away mid-decode)
        // so the thumbnail fallback stays visible rather than blanking out.
        if let cgImage, let image = cgImage { rendered = image }
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
            // The whole row plays, not just the thumbnail. Save/Manage stays a
            // sibling button rather than living inside this one's label — a
            // button nested in another button's label doesn't get the tap.
            Button { onPlay(displayURL) } label: {
                HStack(spacing: 12) {
                    ProjectThumbnailView(url: displayURL, kind: .video)
                        .frame(width: 58, height: 42)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clip \(index + 1)")
                            .font(.system(size: 14.5, weight: .semibold))
                            .lineLimit(1)
                        Text(subtitle(capture: capture, manage: manage))
                            .font(.system(size: 11.5))
                            .foregroundStyle(saveState.isError ? Color.red : .secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play clip \(index + 1)")

            control(manage: manage, displayURL: displayURL)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .task(id: storageKey(capture)) {
            let urls = model.encodings(for: capture, clip: clipName)
                .map { model.encodingURL(for: capture, $0) }
            if let bytes = await MediaWorkQueue.shared.run({
                urls.reduce(Int64(0)) { $0 + AppModel.directorySize($1) }
            }) {
                totalSize = bytes
            }
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

    /// Saves the clip to Photos with the project's grade baked into a temporary
    /// copy. An ungraded project still hands Photos the clip's own bytes.
    private func save(_ url: URL) {
        #if os(iOS)
        guard let capture else { return }
        isSaving = true
        saveState = .idle
        Task {
            do {
                try await model.saveGradedAsset(at: url, for: capture)
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
            Text("ProRes is the highest-quality original and can't be re-created from a converted copy. Your H.264/HEVC copies stay.")
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
                try await model.saveGradedAsset(
                    at: model.encodingURL(for: capture, encoding), for: capture)
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
        #endif
    }
}

import AVFoundation
import Foundation
import LetsLapseKit
import UniformTypeIdentifiers

// MARK: - Approved assets and edit renders (2026-11-05, docs/approved-assets.md)
//
// A project is a source and what a person made of it. **Approved** is the
// person saying which of those is cleared for use downstream — the thing
// PicPlace hands on. What can be approved:
//
// - a Photo capture's picture, as the editor shows it (`CaptureProject.approvedAt`).
//   The approval follows the edit: the app keeps one downstream file current
//   (`approvedFile`) — the source itself while it is untouched and a browser
//   can show it, else a full-size JPEG of the finished picture, rendered
//   again whenever the picture changes;
// - a video's source clip, as it is (`CaptureProject.approvedAt`) — a stock
//   clip that needs nothing. A graded clip is approved through its render;
// - any output in the project's lists (`BlendProject.approvedAt`): a blended
//   clip, an image result, and an **edited clip** — Render Edits, the source
//   at 1× with the edits baked in and the sound kept (`role` = `edit`).
//
// An interval shoot's source is frames, so only its outputs can be approved.
// Several approvals per project are fine (a colour render and a black and
// white one).
//
// Nothing here talks to a server: an approval is an edit to `project.json`,
// which is the manifest every push sends, and each approved file is a
// `source/` or `blends/` file the existing uploads carry
// (`PicPlaceController.noteApprovalChanged`, App/PicPlace/PicPlaceApproved.swift).

/// What made an output that is not a blend — `BlendProject.role`.
enum BlendRole: String {
    /// Render Edits: the source at 1×, edits baked, sound kept.
    case edit
    /// An approved Photo capture's full-size finished picture.
    case picture
}

extension AppModel.BlendProject {
    /// Made by Render Edits — listed as an *Edited clip*.
    var isEditRender: Bool { role == BlendRole.edit.rawValue }
    /// The render behind a Photo capture's approval — never listed.
    var isApprovedPicture: Bool { role == BlendRole.picture.rawValue }
    var isApproved: Bool { approvedAt != nil }
}

/// One approved output of one project: what a tile in the Gallery's Approved
/// view stands for, and one row of what PicPlace is told.
struct ApprovedAsset: Identifiable, Hashable {
    enum Target: Hashable {
        /// The project's own picture (a Photo capture) or source clip (a video).
        case source
        /// One of its outputs — a blended clip, an image result, an edited clip.
        case blend(UUID)
    }

    var captureID: UUID
    var target: Target
    var approvedAt: Date

    /// Stable across removals and re-approvals: the project and what of it.
    var id: String {
        switch target {
        case .source: return "\(captureID.uuidString)/source"
        case .blend(let blendID): return "\(captureID.uuidString)/\(blendID.uuidString)"
        }
    }
}

/// A Render Edits run for one project.
enum EditRenderState: Equatable {
    case rendering(Double)
    case failed(String)
}

/// What the approvals work keeps between gestures — observed by the panel
/// for a render's progress. Not the approvals themselves, which are in each
/// project's document.
@MainActor
final class ApprovedAssetsStore: ObservableObject {
    /// Render Edits runs in flight or failed, by project.
    @Published var renders: [UUID: EditRenderState] = [:]
    var renderTasks: [UUID: Task<Void, Never>] = [:]
    /// Approved pictures waiting to be brought up to date, by project.
    var settleTasks: [UUID: Task<Void, Never>] = [:]
    /// The Approved row's count, per question, until the index changes.
    var totals: [ProjectListQuery: (revision: Int, total: Int)] = [:]
}

enum EditRenderError: LocalizedError {
    case sourceMissing
    case nothingToRender
    case notAVideo

    var errorDescription: String? {
        switch self {
        case .sourceMissing: return "The clip is not on this device."
        case .nothingToRender: return "There are no edits to render — the clip is as it was shot."
        case .notAVideo: return "Render Edits works on a video project."
        }
    }
}

extension AppModel {

    // MARK: - What can be approved

    /// Whether the project's own picture or clip can be approved: a Photo
    /// capture and a video, never an interval shoot (its source is frames —
    /// a blended clip is its output) or a scan.
    func canApproveSource(_ capture: CaptureProject) -> Bool {
        guard !isScannerProject(capture) else { return false }
        return capture.kind == .video || capture.isPhotoCapture
    }

    func isApproved(_ capture: CaptureProject) -> Bool {
        capture.approvedAt != nil
    }

    /// The project's approved outputs: its own picture or clip first, then
    /// its approved outputs, newest first.
    func approvedAssets(for capture: CaptureProject) -> [ApprovedAsset] {
        var assets: [ApprovedAsset] = []
        if let at = capture.approvedAt {
            assets.append(ApprovedAsset(captureID: capture.id, target: .source, approvedAt: at))
        }
        for blend in blends(for: capture) {
            if let at = blend.approvedAt {
                assets.append(ApprovedAsset(captureID: capture.id, target: .blend(blend.id), approvedAt: at))
            }
        }
        return assets
    }

    /// Whether anything of the project is approved — the tile's mark.
    func hasApproval(_ capture: CaptureProject) -> Bool {
        capture.approvedAt != nil || blends(for: capture).contains { $0.approvedAt != nil }
    }

    /// The files the approvals stand on, relative to the project folder —
    /// what must be on PicPlace for the approvals to mean anything there.
    func approvedFiles(for capture: CaptureProject) -> [String] {
        var files: [String] = []
        if capture.approvedAt != nil, let file = capture.approvedFile { files.append(file) }
        files.append(contentsOf: blends(for: capture).filter { $0.approvedAt != nil }.map(\.outputFileName))
        return files
    }

    /// Every approved output the list question's projects hold, in the
    /// list's order — the Gallery's Approved view, one tile each.
    func approvedAssets(for query: ProjectListQuery) -> [ApprovedAsset] {
        var question = query
        question.approved = true
        return (listRows(for: question) ?? []).flatMap { row in
            capture(id: row.id).map(approvedAssets(for:)) ?? []
        }
    }

    /// How many approved outputs the question's projects hold — the
    /// sidebar row's number, which is what lighting the row shows.
    func approvedTotal(for query: ProjectListQuery) -> Int {
        guard let index = libraryIndex else { return 0 }
        var question = query
        question.approved = true
        if let cached = approvals.totals[question], cached.revision == indexRevision { return cached.total }
        let total = (try? index.approvedTotal(question.indexQuery)) ?? 0
        approvals.totals[question] = (indexRevision, total)
        return total
    }

    // MARK: - Approving

    /// Approves the project's own picture or clip, or takes the approval
    /// away. An edit: it stamps the project and rides its next push.
    func setApproved(_ approved: Bool, for capture: CaptureProject) {
        guard canApproveSource(capture), isApproved(capture) != approved else { return }
        let retired = approved ? nil : approvedPictureBlend(for: capture)
        let untouchedFile = approved ? untouchedDownstreamFile(for: capture) : nil
        updateCapture(capture.id) { record in
            if approved {
                record.approvedAt = Date()
                record.approvedBy = DeviceIdentity.id
                // The file as it is, when that is the whole answer; an
                // edited picture's render follows (`settleApprovedPicture`).
                record.approvedFile = untouchedFile
                record.approvedToken = untouchedFile == nil ? nil : Self.approvedSourceToken
            } else {
                record.approvedAt = nil
                record.approvedBy = nil
                record.approvedFile = nil
                record.approvedToken = nil
            }
        }
        // The library may have refused the write (opened read-only beside
        // another LetsLapse, a full disk): nothing is approved until the
        // document says so, and nothing is retired or sent on a refusal.
        guard let written = self.capture(id: capture.id), isApproved(written) == approved else {
            LLog("approved: \(capture.displayTitle) — the library did not take the change; \(approved ? "not approved" : "still approved")")
            return
        }
        noteIndexChanged()
        LLog("approved: \(capture.displayTitle) — \(approved ? "approved\(untouchedFile.map { " as \($0)" } ?? ", its picture to be rendered")" : "approval removed")")
        if approved {
            if capture.isPhotoCapture, untouchedFile == nil { scheduleApprovedPictureSettle(capture.id, after: 0) }
            picplace.noteApprovalChanged(capture.id)
        } else if let retired {
            // The approval's own render has nothing left to stand for.
            try? deleteBlend(retired)
        }
    }

    /// Approves one output — a blended clip, an image result, an edited
    /// clip — or takes the approval away.
    func setApproved(_ approved: Bool, for blend: BlendProject) {
        guard !blend.isApprovedPicture, blend.isApproved != approved else { return }
        let now = Date()
        do {
            try store.update(blend.captureID) { document in
                for i in document.blends.indices where document.blends[i].id == blend.id {
                    document.blends[i].approvedAt = approved ? now : nil
                    document.blends[i].approvedBy = approved ? DeviceIdentity.id : nil
                }
                // A person changed this project — see CaptureProject.modifiedAt.
                document.capture.modifiedAt = now
                document.capture.modifiedBy = DeviceIdentity.id
            }
        } catch {
            LLog("approved: could not write the approval of \(blend.outputFileName) — \(error.localizedDescription)")
            return
        }
        noteIndexChanged()
        if let capture = capture(id: blend.captureID) {
            LLog("approved: \(capture.displayTitle) — \(blend.outputFileName) \(approved ? "approved" : "approval removed")")
        }
        if approved { picplace.noteApprovalChanged(blend.captureID) }
    }

    func setApproved(_ approved: Bool, for asset: ApprovedAsset) {
        switch asset.target {
        case .source:
            if let capture = capture(id: asset.captureID) { setApproved(approved, for: capture) }
        case .blend(let id):
            if let blend = blend(id: id) { setApproved(approved, for: blend) }
        }
    }

    // MARK: - The approved picture's downstream file

    /// `approvedToken` for a source that goes downstream as it is.
    static let approvedSourceToken = "source"

    /// Picture formats a browser shows — the ones a downstream page can
    /// take as they are (Readia's rule too: JPEG, PNG, WebP, AVIF, GIF).
    private static let downstreamPictureExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "avif", "gif"]

    /// The source file that IS the approved asset, relative to the project
    /// folder — a video's clip always; a photo's picture only while nothing
    /// has been done to it and a browser can show the file. nil when a
    /// render has to stand for it (an edited, turned, raw or HEIC photo).
    private func untouchedDownstreamFile(for capture: CaptureProject) -> String? {
        if capture.kind == .video {
            return mediaURL(for: capture).flatMap { relativeName(of: $0, in: capture) }
        }
        guard capture.isPhotoCapture, let hero = heroImageURL(for: capture),
              Self.downstreamPictureExtensions.contains(hero.pathExtension.lowercased()),
              pictureIsUntouched(capture) else { return nil }
        return relativeName(of: hero, in: capture)
    }

    /// Nothing a person did shows in the picture: no look, no level, no
    /// crop, no turn, no text, shape or masked grade.
    private func pictureIsUntouched(_ capture: CaptureProject) -> Bool {
        guard QuarterTurns.normalized(capture.quarterTurns ?? 0) == 0 else { return false }
        let grade = photoGrade(for: capture)
        guard grade.isIdentity, !grade.hasRotation, !grade.hasCrop else { return false }
        let document = overlayDocument(for: capture)
        return document.overlays.isEmpty && !document.maskGrades.contains(where: \.isActive)
    }

    /// The fingerprint `approvedFile` should carry right now: `source` for
    /// the file as it is, else the finished picture's — the poster's token,
    /// so whatever re-renders the poster re-renders this.
    private func approvedPictureToken(for capture: CaptureProject) -> String {
        untouchedDownstreamFile(for: capture) != nil ? Self.approvedSourceToken : picplace.currentPosterToken(for: capture)
    }

    /// The render behind the project's approval, if a render stands for it.
    func approvedPictureBlend(for capture: CaptureProject) -> BlendProject? {
        guard let file = capture.approvedFile else { return nil }
        return store.allBlends(for: capture.id).first {
            $0.deletedAt == nil && $0.isApprovedPicture && $0.outputFileName == file
        }
    }

    /// An approved Photo capture was written: bring its downstream file up
    /// to date once the edits have settled. Only for an edit made here — a
    /// pulled update carries its own file, made by the device that edited.
    func noteApprovedProjectWritten(_ id: UUID) {
        guard let capture = capture(id: id), capture.isPhotoCapture, capture.approvedAt != nil,
              capture.deletedAt == nil, capture.modifiedBy == DeviceIdentity.id else { return }
        scheduleApprovedPictureSettle(id, after: 2.5)
    }

    func scheduleApprovedPictureSettle(_ id: UUID, after seconds: Double) {
        approvals.settleTasks[id]?.cancel()
        approvals.settleTasks[id] = Task { [weak self] in
            if seconds > 0 {
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
            }
            guard let self, !Task.isCancelled else { return }
            await self.settleApprovedPicture(id)
            self.approvals.settleTasks[id] = nil
        }
    }

    /// Every approved Photo capture whose picture moved since its file was
    /// made — a render the app was closed before, or one iOS stopped in the
    /// background. Asked once the library is up.
    func settleStaleApprovedPictures() {
        guard let index = libraryIndex else { return }
        var query = LibraryIndex.ProjectQuery()
        query.approved = true
        query.category = .photo
        query.limit = 100_000
        for row in (try? index.projects(query).rows) ?? [] {
            guard let capture = capture(id: row.id), capture.approvedAt != nil,
                  capture.modifiedBy == nil || capture.modifiedBy == DeviceIdentity.id,
                  capture.approvedToken != approvedPictureToken(for: capture) else { continue }
            scheduleApprovedPictureSettle(capture.id, after: 1)
        }
    }

    /// Makes `approvedFile` what the picture is now: the source as it is,
    /// or a fresh full-size JPEG of the finished picture in `blends/` (a
    /// blend record of role `picture`), the one before it retired.
    /// Unoptimised by decision (Steven, 2026-11-05): full size, quality
    /// 0.95, one render per settled edit.
    func settleApprovedPicture(_ id: UUID) async {
        guard let capture = capture(id: id), capture.isPhotoCapture, capture.approvedAt != nil else { return }
        let token = approvedPictureToken(for: capture)
        guard capture.approvedToken != token || capture.approvedFile == nil else { return }
        let previous = approvedPictureBlend(for: capture)

        if let file = untouchedDownstreamFile(for: capture) {
            // Back to the file as it is (the edits were reset).
            updateCapture(id) { $0.approvedFile = file; $0.approvedToken = Self.approvedSourceToken }
            guard self.capture(id: id)?.approvedFile == file else {
                LLog("approved: \(capture.displayTitle) — the library did not take its picture's new file; left as it was")
                return
            }
            if let previous { try? deleteBlend(previous) }
            LLog("approved: \(capture.displayTitle) — its picture is the source again (\(file))")
            picplace.noteApprovalChanged(id)
            return
        }
        // Full-size pixels: the originals' picture, else a working copy.
        guard let pixels = workingPictureURL(for: capture), FileManager.default.fileExists(atPath: pixels.path) else {
            LLog("approved: \(capture.displayTitle) — its picture changed, but neither its originals nor a working copy are on this device to render from")
            return
        }
        do {
            let rendered = try await renderFinishedPicture(of: capture, from: pixels)
            defer { try? FileManager.default.removeItem(at: rendered) }
            // The picture may have moved again while this one rendered.
            guard let now = self.capture(id: id), now.approvedAt != nil else { return }
            let blend = try storeRender(
                rendered, for: now, kind: .image, role: .picture,
                summary: "Approved picture · full size", stampsEdit: false)
            updateCapture(id) { $0.approvedFile = blend.outputFileName; $0.approvedToken = token }
            guard self.capture(id: id)?.approvedFile == blend.outputFileName else {
                // The render is stored but the approval could not be
                // pointed at it: it goes again, and the one before stands.
                try? deleteBlend(blend)
                LLog("approved: \(capture.displayTitle) — the library did not take its picture's new render; the one before stands")
                return
            }
            if let previous { try? deleteBlend(previous) }
            LLog("approved: \(capture.displayTitle) — picture rendered at \(blend.width ?? 0)×\(blend.height ?? 0) → \(blend.outputFileName)")
            picplace.noteApprovalChanged(id)
            // An edit landed during the render: once more, for it.
            if let after = self.capture(id: id), approvedPictureToken(for: after) != token {
                scheduleApprovedPictureSettle(id, after: 1)
            }
        } catch {
            LLog("approved: \(capture.displayTitle) — its picture could not be rendered (\(error.localizedDescription)); the next edit or launch tries again")
        }
    }

    /// The finished picture as a full-size JPEG in the temporary folder —
    /// the export's own render when the export would render one, else the
    /// same renderer asked outright (a raw or a HEIC nobody touched, a
    /// picture that is only turned).
    private func renderFinishedPicture(of capture: CaptureProject, from pixels: URL) async throws -> URL {
        let exported = try await gradedExportCopy(of: pixels, for: capture)
        if exported.isTemporary { return exported.url }
        let isCopy = ProjectFileRegistry.isProxyPicture(fileName: pixels.lastPathComponent)
        let grade = photoGrade(for: capture)
        let exportGrade = isCopy ? PhotoGrade(preset: .original, adjustments: grade.adjustments.geometryOnly) : grade
        let inputs = FinishedPicture.inputs(for: capture, source: pixels, grade: exportGrade, in: self)
        guard let image = await FinishedPicture.render(inputs, maxDimension: nil) else {
            throw PhotoGrader.GradeError.renderFailed
        }
        return try PhotoGrader.writeJPEG(image, carryingMetadataFrom: pixels)
    }

    // MARK: - Render Edits

    /// Whether the editor's clip differs from the file — whether Render
    /// Edits has anything to bake.
    func hasEditsToRender(_ capture: CaptureProject) -> Bool {
        guard capture.kind == .video else { return false }
        if QuarterTurns.normalized(capture.quarterTurns ?? 0) != 0 { return true }
        let grade = photoGrade(for: capture)
        guard !presetState(for: capture).isOriginal || grade.hasRotation || grade.hasCrop else { return false }
        return !grade.isIdentity
    }

    /// The project's edited clips — Render Edits' outputs — newest first.
    func editRenders(for capture: CaptureProject) -> [BlendProject] {
        blends(for: capture).filter(\.isEditRender)
    }

    /// An edited clip's place among its project's, oldest = 1.
    func editNumber(for blend: BlendProject) -> Int {
        let siblings = store.blends(for: blend.captureID).filter(\.isEditRender).sorted { $0.createdAt < $1.createdAt }
        return (siblings.firstIndex { $0.id == blend.id } ?? 0) + 1
    }

    /// Render Edits: the video's clip at 1× with the project's edits baked
    /// in — look, white balance, level, crop, turn — and its sound kept,
    /// stored beside the blended clips as an edited clip. Runs on its own,
    /// outside the blend flow; the panel shows its progress.
    func renderEdits(for capture: CaptureProject) {
        guard approvals.renderTasks[capture.id] == nil else { return }
        let id = capture.id
        approvals.renders[id] = .rendering(0)
        approvals.renderTasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let blend = try await self.makeEditRender(of: capture)
                self.approvals.renders[id] = nil
                LLog("render edits: \(capture.displayTitle) → \(blend.outputFileName) (\(blend.summary))")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.approvals.renders[id] = .failed(message)
                LLog("render edits: \(capture.displayTitle) failed — \(message)")
            }
            self.approvals.renderTasks[id] = nil
        }
    }

    /// Stops a run in flight, or clears a failed one's message.
    func cancelEditRender(for id: UUID) {
        approvals.renderTasks[id]?.cancel()
        approvals.renderTasks[id] = nil
        approvals.renders[id] = nil
    }

    private func makeEditRender(of capture: CaptureProject) async throws -> BlendProject {
        guard capture.kind == .video else { throw EditRenderError.notAVideo }
        guard let source = mediaURL(for: capture), FileManager.default.fileExists(atPath: source.path) else {
            throw EditRenderError.sourceMissing
        }
        let id = capture.id
        let exported = try await gradedExportCopy(of: source, for: capture) { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .rendering = self.approvals.renders[id] else { return }
                self.approvals.renders[id] = .rendering(min(max(fraction, 0), 1))
            }
        }
        var file = exported.url
        var owned = exported.isTemporary
        if !owned {
            // Nothing to grade, but the project is turned: the turn is an
            // edit too, written the way the format carries one.
            let turned = await TurnedMedia.shareableCopy(of: source)
            if turned != source { file = turned; owned = true }
        }
        guard owned else { throw EditRenderError.nothingToRender }
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()

        let sourceHasSound = await Self.hasSound(source)
        let hasSound = await Self.hasSound(file)
        if sourceHasSound, !hasSound {
            LLog("render edits: ALARM \(capture.displayTitle) — the source has sound and the render has none")
        }
        let sound = hasSound ? "sound kept" : (sourceHasSound ? "sound lost" : "no sound in the source")
        return try storeRender(file, for: capture, kind: .video, role: .edit, summary: "Edits rendered at 1× · \(sound)", stampsEdit: true)
    }

    nonisolated private static func hasSound(_ url: URL) async -> Bool {
        let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        return !(tracks ?? []).isEmpty
    }

    /// Files a render in the project's `blends/` and adds its record — the
    /// blend flow's `storeBlend` for an output no blend made. The file is
    /// copied; the caller still owns `file`.
    private func storeRender(
        _ file: URL, for capture: CaptureProject, kind: BlendKind, role: BlendRole,
        summary: String, stampsEdit: Bool
    ) throws -> BlendProject {
        let id = UUID()
        let ext = file.pathExtension.isEmpty ? (kind == .video ? "mp4" : "jpg") : file.pathExtension.lowercased()
        let outputFileName = "blends/\(id.uuidString).\(ext)"
        let destination = projectFolderURL(for: capture).appendingPathComponent(outputFileName)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: destination)

        let probe = Self.probeRender(at: destination, kind: kind)
        let turns = QuarterTurns.normalized(capture.quarterTurns ?? 0)
        var blend = BlendProject(
            id: id, captureID: capture.id, kind: kind, createdAt: Date(),
            outputFileName: outputFileName,
            summary: [summary, probe.size.map { "\($0.width)×\($0.height)" }, probe.fps.map { "\($0) fps" }]
                .compactMap { $0 }.joined(separator: " · "),
            compressionRatio: kind == .video ? 1 : nil,
            outputFPS: probe.fps,
            linearLight: false, useRamp: false, rampStart: 1, rampEnd: 1,
            curve: BlendCurve.linear.rawValue,
            width: probe.size?.width, height: probe.size?.height,
            inputFrames: probe.frames, outputFrames: probe.frames)
        // The project's turn is in these pixels, as in a blend's.
        blend.renderedQuarterTurns = turns == 0 ? nil : turns
        blend.role = role.rawValue

        do {
            try store.update(capture.id) { document in
                document.blends.append(blend)
                if stampsEdit {
                    // A new edited clip is an edit, as a new blend is.
                    document.capture.modifiedAt = Date()
                    document.capture.modifiedBy = DeviceIdentity.id
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        noteFilesChanged(for: capture.id)
        if let current = self.capture(id: capture.id) {
            recordAssets(for: current, extractMetadata: false)
        }
        noteIndexChanged()
        return blend
    }

    /// The stored render's size, rate and frame count, read off the file.
    nonisolated private static func probeRender(at url: URL, kind: BlendKind) -> (size: (width: Int, height: Int)?, fps: Int?, frames: Int?) {
        switch kind {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return (nil, nil, 1) }
            // A JPEG's own orientation tag turns what a viewer shows.
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            return ((5...8).contains(orientation) ? (height, width) : (width, height), nil, 1)
        case .video:
            let asset = AVURLAsset(url: url)
            guard let track = asset.tracks(withMediaType: .video).first else { return (nil, nil, nil) }
            let oriented = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
            let fps = track.nominalFrameRate > 0 ? Int(track.nominalFrameRate.rounded()) : nil
            let seconds = asset.duration.seconds
            let frames = fps.flatMap { seconds.isFinite && seconds > 0 ? Int((seconds * Double($0)).rounded()) : nil }
            return ((Int(abs(oriented.width).rounded()), Int(abs(oriented.height).rounded())), fps, frames)
        }
    }

    /// `url`'s path inside the project folder, or nil when it is not in it.
    private func relativeName(of url: URL, in capture: CaptureProject) -> String? {
        let folder = projectFolderURL(for: capture).standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}

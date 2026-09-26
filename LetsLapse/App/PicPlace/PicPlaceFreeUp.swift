import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import LetsLapseKit

/// Free up space (2026-09-23): a device lets go of the heavy files PicPlace
/// holds, so a phone can be a capture device — shoot, upload, free the space
/// for the next shoot. Three doors, one test:
///
/// - the project card's **Remove originals** (the `source/` media) and
///   **Remove blends** (`blends/`), each with its confirm;
/// - Settings' **Remove originals already on PicPlace**, a button pressed
///   now and then — never a switch, never automatic;
/// - (the library's *Remove from this iPhone* reads the marker this leaves,
///   `PicPlaceSyncRecord.heavyDigest`, instead of a count).
///
/// The rules:
///
/// - **Per file, from the server, at the moment of removal.** The project's
///   write claim is taken (no other device can delete it on PicPlace while
///   it is held), the asset list is read fresh, and a file goes only when
///   PicPlace lists it at the same path, confirmed, at the same size, with
///   the same SHA-256 (`PicPlaceOriginalsCheck`). Never a count, never "the
///   originals were uploaded once".
/// - **All or nothing per project and kind.** One file of a kind not on
///   PicPlace keeps every file of that kind, and the card says why.
/// - **Only heavy files go.** `project.json`, the sidecars, `assets.ndjson`
///   and `poster.jpg` stay, so the project still shows (as a preview) and
///   nothing that syncs is written: no revision moves, no tombstone —
///   removing files from a device is not deleting a project. Presence says
///   `preview` once the source media are gone.
/// - **A blend a collection uses stays** (its render reads the file); every
///   blend removed leaves a still behind (`posters/<blend id>.jpg`) for its row.
/// - Download brings any of it back (`downloadOriginals(_:kinds:)`).
///
/// Server asks that make "safe" stronger (checksums verified by storage, a
/// recently-deleted window): docs/picplace-free-up-space-server-asks.md.
extension PicPlaceController {

    // MARK: Types

    /// What a removal takes: the source media, or the blends.
    enum RemovalScope: String, Equatable {
        case originals
        case blends

        var kind: PicPlaceOriginalsCheck.Kind { self == .originals ? .source : .blend }
        var noun: String { self == .originals ? "originals" : "blends" }
    }

    /// The card's two rows — Originals and Blends: what is here, what of it
    /// PicPlace lacks, and what only PicPlace has.
    struct OriginalsStatus: Equatable {
        struct Part: Equatable {
            var files = 0
            var bytes: Int64 = 0
            var isEmpty: Bool { files == 0 }

            init(files: Int = 0, bytes: Int64 = 0) {
                self.files = files
                self.bytes = bytes
            }

            init(_ list: [PicPlaceOriginalsCheck.LocalFile]) {
                files = list.count
                bytes = list.reduce(0) { $0 + $1.bytes }
            }
        }

        struct Row: Equatable {
            /// On this device.
            var here = Part()
            /// Here, and different from PicPlace's copy at the same path
            /// (a refused upload, or a removal's check) — PicPlace keeps its own.
            var divergent = Part()
            /// Of those, the ones PicPlace provably holds as recorded at
            /// capture: the line offers to replace them with PicPlace's.
            var replaceable: [String] = []
            /// Here, and not on PicPlace at that path and size — what an
            /// upload sends. Measured against the server's list when the card
            /// has read it this session; otherwise inferred from the record.
            var notUp = Part()
            /// On PicPlace and not here — what a download brings.
            var onlyThere = Part()

            /// Here and all of it on PicPlace: the row offers Remove.
            var isOnBothSides: Bool { !here.isEmpty && notUp.isEmpty && divergent.isEmpty }
        }

        var originals = Row()
        var blends = Row()
        /// Whether the rows were measured against the server's list.
        var measured = false

        func row(_ scope: RemovalScope) -> Row { scope == .originals ? originals : blends }
    }

    /// What one removal did, or why it did nothing.
    struct RemovalOutcome: Equatable {
        var removedFiles = 0
        var removedBytes: Int64 = 0
        /// Blends kept because a collection uses them.
        var keptForCollections = 0
        /// Why nothing was removed — nil when the removal ran.
        var refusal: String?
        /// Why it stopped part way (a person's Stop, a file that would not go).
        var stopped: String?

        var didRemove: Bool { removedFiles > 0 }

        @MainActor func caption(_ scope: RemovalScope) -> String {
            if let refusal { return refusal }
            var line = "Removed \(removedFiles.formatted()) file\(removedFiles == 1 ? "" : "s") · \(LLFormat.bytes(removedBytes)) from \(PicPlaceController.deviceWord)"
            if keptForCollections > 0 {
                line += " · \(keptForCollections) blend\(keptForCollections == 1 ? "" : "s") kept — \(keptForCollections == 1 ? "a collection uses it" : "collections use them")"
            }
            if let stopped { line += " · then stopped: \(stopped)" }
            return line
        }
    }

    /// Settings' run: the estimate before it, the run, the result after.
    struct FreeUpState: Equatable {
        struct Estimate: Equatable {
            /// Projects whose originals look fully on PicPlace, and the space
            /// their source media take here.
            var projects = 0
            var bytes: Int64 = 0
            /// Projects on PicPlace whose originals are not (all) there yet.
            var notUpProjects = 0
            var notUpBytes: Int64 = 0
            var measuredAt = Date()
        }

        struct Run: Equatable {
            var done = 0
            var total = 0
            var freedBytes: Int64 = 0
            var current: String?
        }

        struct Result: Equatable {
            var projects = 0
            var freedBytes: Int64 = 0
            /// Projects that kept their originals, and the first reasons.
            var kept = 0
            var reasons: [String] = []
            var stopped: String?
            var finishedAt = Date()
        }

        var estimate: Estimate?
        var isEstimating = false
        var run: Run?
        var result: Result?
    }

    // MARK: What is here

    /// This device's heavy files in a project folder — path, kind and size,
    /// by the same classification a push uses. No hashes.
    nonisolated static func heavyFiles(in folder: URL) -> [PicPlaceOriginalsCheck.LocalFile] {
        heavyFiles((try? PicPlaceSyncRun.listFiles(in: folder)) ?? [])
    }

    /// The heavy files of a folder already listed.
    nonisolated static func heavyFiles(_ entries: [PicPlaceSyncRun.FolderEntry]) -> [PicPlaceOriginalsCheck.LocalFile] {
        PicPlaceSyncInventory.classify(entries).compactMap { item in
            guard case .heavy(let kind) = item.role, let heavy = PicPlaceOriginalsCheck.Kind(rawValue: kind) else { return nil }
            return PicPlaceOriginalsCheck.LocalFile(name: item.relativePath, kind: heavy, bytes: item.bytes)
        }
    }

    /// The server's heavy assets out of a project detail.
    static func remoteHeavy(_ assets: [PPAsset]?) -> [PicPlaceOriginalsCheck.RemoteAsset] {
        (assets ?? []).filter { PicPlaceSyncInventory.isHeavy($0.name) }.map {
            PicPlaceOriginalsCheck.RemoteAsset(name: $0.name, bytes: $0.bytes, sha256: $0.sha256,
                                               isConfirmed: $0.status == "confirmed", isVerified: $0.verified == true)
        }
    }

    /// Walks the project folder again (off the main actor) — after a card
    /// appears, a sync, a download or a removal.
    func refreshHeavyListing(for capture: AppModel.CaptureProject) {
        guard heavyListingTasks[capture.id] == nil else { return }
        let folder = model.projectFolderURL(for: capture)
        let id = capture.id
        heavyListingTasks[id] = Task { [weak self] in
            let listing = await Task.detached(priority: .utility) { Self.heavyFiles(in: folder) }.value
            guard let self else { return }
            self.heavyListings[id] = listing
            self.heavyListingTasks[id] = nil
        }
    }

    // MARK: The card's rows

    /// The Originals and Blends rows for a project — nil when the card shows
    /// neither (not connected, a sync or removal under way, never on
    /// PicPlace, a failed push, nothing heavy anywhere).
    func originalsStatus(for capture: AppModel.CaptureProject) -> OriginalsStatus? {
        guard canSync, progress[capture.id] == nil, !removingProjects.contains(capture.id) else { return nil }
        let key = model.originID(of: capture)
        guard let record = records[key], record.elsewhereLibrary == nil else { return nil }
        let previewOnly = isPreviewOnly(capture)
        if !previewOnly {
            guard record.lastError == nil || record.failedHeavyOnly else { return nil }
        }
        guard let local = heavyListings[capture.id] else {
            refreshHeavyListing(for: capture)
            return nil
        }
        var status = OriginalsStatus()
        let remote = serverHeavy[key]
        for kind in PicPlaceOriginalsCheck.Kind.allCases {
            let here = local.filter { $0.kind == kind }
            var row = OriginalsStatus.Row(here: .init(here))
            if let remote {
                row.notUp = .init(PicPlaceOriginalsCheck.notCovered(here, by: remote))
                let names = Set(here.map(\.name))
                let there = remote.filter { $0.isConfirmed && !names.contains($0.name) && PicPlaceSyncInventory.heavyKind($0.name) == kind }
                row.onlyThere = .init(files: there.count, bytes: there.reduce(0) { $0 + ($1.bytes ?? 0) })
            } else if record.heavyDigest != nil, record.heavyDigest == PicPlaceOriginalsCheck.digest(local) {
                // The set verified on PicPlace, unchanged since.
                row.notUp = .init()
            } else if let serverFiles = record.serverHeavyFiles, let serverBytes = record.serverHeavyBytes,
                      serverFiles >= local.count, serverBytes >= local.reduce(0, { $0 + $1.bytes }) {
                // A record from before the marker: PicPlace holds at least as
                // much. Good enough for a label — a removal reads the list first.
                row.notUp = .init()
            } else {
                row.notUp = row.here
            }
            // Copies known to differ from PicPlace's; PicPlace's own replace
            // them only where it provably holds what was recorded here.
            let divergentNames = Set(record.divergentFiles ?? [])
            let divergent = here.filter { divergentNames.contains($0.name) }
            if !divergent.isEmpty {
                // No Replace offered: a copy that differs may be a deliberate
                // edit (a scan re-correction, a re-conversion — or a rotation
                // by a build from before 2026-09-24, which wrote into the
                // file), and replacing it would undo that.
                row.divergent = .init(divergent)
            }
            if kind == .source { status.originals = row } else { status.blends = row }
        }
        status.measured = remote != nil
        // A preview-only project with no heavy knowledge yet: the counts the
        // record kept stand in for the download row until the card reads the list.
        if remote == nil, previewOnly, status.originals.onlyThere.isEmpty {
            let files = record.serverHeavyFiles ?? record.heavyFiles ?? 0
            if files > 0 { status.originals.onlyThere = .init(files: files, bytes: record.serverHeavyBytes ?? record.heavyBytes ?? 0) }
        }
        return status
    }

    /// Whether the card's *Download originals* has anything to bring.
    func hasOriginalsToDownload(_ capture: AppModel.CaptureProject) -> Bool {
        guard let status = originalsStatus(for: capture) else { return false }
        // A Photo capture's picture is its stack, which is a blend: its
        // originals come down with it (plan T3, 2026-09-25).
        return !status.originals.onlyThere.isEmpty || (capture.isPhotoCapture && !status.blends.onlyThere.isEmpty)
    }

    /// What the card's *Download originals* brings: the source media — and
    /// for a Photo capture its stack too, the picture it is edited on (it
    /// was unreachable: the card hides a Photo's Blends line).
    func originalsDownloadKinds(for capture: AppModel.CaptureProject) -> Set<PicPlaceOriginalsCheck.Kind> {
        capture.isPhotoCapture ? [.source, .blend] : [.source]
    }

    // MARK: Removal — one project

    /// A person's press on the card: remove this project's originals or
    /// blends from this device, after the check. The card shows the check
    /// and the removal as its progress; Cancel stops between files.
    func removeFromDevice(_ capture: AppModel.CaptureProject, scope: RemovalScope) {
        guard removalTasks[capture.id] == nil, freeUpTask == nil else { return }
        removalNotes[capture.id] = nil
        removalTasks[capture.id] = Task { [weak self] in
            guard let self else { return }
            let activity = PicPlaceBackgroundActivity("PicPlace — removing the \(scope.noun) of \(capture.displayTitle)")
            defer { activity.end() }
            let outcome = await self.performRemoval(capture, scope: scope)
            self.removalNotes[capture.id] = outcome.caption(scope)
            LLog("picplace: free up — \(capture.displayTitle) (\(scope.noun)): \(outcome.caption(scope))")
            self.removalTasks[capture.id] = nil
            if self.freeUp.estimate != nil { self.refreshFreeUpEstimate() }
        }
    }

    /// Why `scope` cannot be removed from this project now, or nil.
    func removalBlocker(for capture: AppModel.CaptureProject, scope: RemovalScope) -> String? {
        if !canSync {
            return isSignedIn ? "Connect this library to PicPlace first — nothing can be checked until then" : "Sign in to PicPlace first — nothing can be checked until then"
        }
        let key = model.originID(of: capture)
        guard let record = records[key], record.recordsReachedServer else { return "This project isn't on PicPlace yet" }
        if record.elsewhereLibrary != nil { return "PicPlace files this project under another library" }
        if conflicts.contains(where: { $0.originID == key }) { return "This project needs your decision on PicPlace first" }
        if syncTasks[capture.id] != nil || removingProjects.contains(capture.id) { return "PicPlace is busy with this project — try again when it's done" }
        if let busy = projectInUse(capture) { return busy }
        switch scope {
        case .originals:
            if model.posterURL(for: capture) == nil { return "This project has no preview yet — sync it once, then remove the originals" }
        case .blends:
            if capture.isPhotoCapture { return "A photo's blend is the photo itself — it stays" }
        }
        return nil
    }

    /// Whether something on this device is using the project's files.
    private func projectInUse(_ capture: AppModel.CaptureProject) -> String? {
        if model.currentCaptureID == capture.id, model.stage != .home { return "This project is open for blending — close it first" }
        if model.activeLibraryActivities.contains(.exportingArchive(capture.id)) { return "This project is being exported" }
        if model.activeLibraryActivities.contains(.servingTransfer) { return "A project is being sent to another device — try again when it's done" }
        return nil
    }

    /// The check, then the removal — the core every door shares. On the
    /// main actor; the hashing and the deleting run off it.
    func performRemoval(_ capture: AppModel.CaptureProject, scope: RemovalScope) async -> RemovalOutcome {
        if let blocker = removalBlocker(for: capture, scope: scope) { return RemovalOutcome(refusal: blocker) }
        let id = capture.id
        let key = model.originID(of: capture)
        let uuid = key.uuidString.lowercased()
        let folder = model.projectFolderURL(for: capture)
        let kind = scope.kind
        removingProjects.insert(id)
        progress[id] = PicPlaceSyncProgress(phase: .verifying)
        defer {
            removingProjects.remove(id)
            progress[id] = nil
        }

        // 1. What is here, and a first look at PicPlace's list: a project
        //    whose files are plainly not all there costs no hashing.
        let listed = await Task.detached(priority: .utility) { Self.heavyFiles(in: folder) }.value
        heavyListings[id] = listed
        var targets = listed.filter { $0.kind == kind }
        guard !targets.isEmpty else { return RemovalOutcome(refusal: "No \(scope.noun) on \(Self.deviceWord) to remove") }
        let first: PPProjectDetail
        do {
            first = try await client.get("projects/\(uuid)")
        } catch {
            return RemovalOutcome(refusal: "Couldn't check with PicPlace — nothing was removed (\(Self.describe(error)))")
        }
        if first.project.isTombstone { return RemovalOutcome(refusal: "Deleted on PicPlace — nothing was removed") }
        let uncovered = PicPlaceOriginalsCheck.notCovered(targets, by: Self.remoteHeavy(first.assets))
        serverHeavy[key] = Self.remoteHeavy(first.assets)
        guard uncovered.isEmpty else {
            return RemovalOutcome(refusal: "Kept the \(scope.noun): \(uncovered.count.formatted()) file\(uncovered.count == 1 ? " isn't" : "s aren't") on PicPlace yet · \(LLFormat.bytes(uncovered.reduce(0) { $0 + $1.bytes })) — upload \(uncovered.count == 1 ? "it" : "them") first")
        }

        // 2. Blends a collection uses stay; the others each leave a still.
        var keptForCollections = 0
        if scope == .blends {
            let collected = model.collectionBlendFileNames(for: capture)
            let before = targets.count
            targets.removeAll { collected.contains($0.name) }
            keptForCollections = before - targets.count
            guard !targets.isEmpty else {
                return RemovalOutcome(keptForCollections: keptForCollections, refusal: "Every blend here is in a collection, which needs its file — nothing was removed")
            }
            let posters = await model.ensureBlendPosters(for: capture, fileNames: Set(targets.map(\.name)))
            let before2 = targets.count
            targets.removeAll { !posters.contains($0.name) }
            if targets.count < before2 { LLog("picplace: free up — \(before2 - targets.count) blend(s) of \(capture.displayTitle) kept: no still could be made for the row") }
            guard !targets.isEmpty else { return RemovalOutcome(refusal: "No still could be made for the blends' rows — nothing was removed") }
        }

        // 3. The hashes: the capture-time ones where the file is as hashed, the rest now.
        let hashed: [PicPlaceOriginalsCheck.LocalFile]
        do {
            let toHash = targets
            hashed = try await Task.detached(priority: .utility) { try Self.hashed(toHash, in: folder) }.value
        } catch {
            return RemovalOutcome(refusal: "Couldn't read the \(scope.noun) to check them — nothing was removed (\(error.localizedDescription))")
        }
        if Task.isCancelled { return RemovalOutcome(refusal: "Stopped — nothing was removed") }

        // 4. The claim (no other device can delete the project on PicPlace
        //    while this device holds it), the list read fresh, the full test.
        do {
            let _: [String: PPClaim] = try await client.post("projects/\(uuid)/claim", json: ["ttl_seconds": 600])
        } catch {
            return RemovalOutcome(refusal: "PicPlace is busy with this project — \(Self.describe(error))")
        }
        defer {
            Task { [client] in let _: [String: PPClaim?]? = try? await client?.delete("projects/\(uuid)/claim") }
        }
        let detail: PPProjectDetail
        do {
            detail = try await client.get("projects/\(uuid)")
        } catch {
            return RemovalOutcome(refusal: "Couldn't check with PicPlace — nothing was removed (\(Self.describe(error)))")
        }
        let remote = Self.remoteHeavy(detail.assets)
        serverHeavy[key] = remote
        let verdict = PicPlaceOriginalsCheck.verify(hashed, against: remote)
        guard verdict.passes else {
            LLog("picplace: free up — kept the \(scope.noun) of \(capture.displayTitle): \(verdict.counts())")
            return RemovalOutcome(keptForCollections: keptForCollections, refusal: Self.refusal(verdict, scope: scope))
        }

        // 5. The last look: nothing here started using the files meanwhile.
        if Task.isCancelled { return RemovalOutcome(refusal: "Stopped — nothing was removed") }
        if let busy = projectInUse(capture) { return RemovalOutcome(refusal: busy) }
        if syncTasks[id] != nil { return RemovalOutcome(refusal: "PicPlace is busy with this project — try again when it's done") }

        // 6. The removal, a batch at a time, stoppable between batches.
        let total = verdict.verified.reduce(Int64(0)) { $0 + $1.bytes }
        progress[id] = PicPlaceSyncProgress(phase: .removing, filesDone: 0, filesTotal: verdict.verified.count, bytesDone: 0, bytesTotal: total)
        var outcome = RemovalOutcome(keptForCollections: keptForCollections)
        var removedNames = Set<String>()
        for batch in verdict.verified.chunked(200) {
            if Task.isCancelled { outcome.stopped = "you stopped it"; break }
            let done = await Task.detached(priority: .userInitiated) { Self.remove(batch, in: folder) }.value
            for file in done.removed {
                removedNames.insert(file.name)
                outcome.removedFiles += 1
                outcome.removedBytes += file.bytes
            }
            progress[id]?.filesDone = outcome.removedFiles
            progress[id]?.bytesDone = outcome.removedBytes
            if let failure = done.failure { outcome.stopped = failure; break }
        }

        // 7. What this device now knows: PicPlace's numbers from the read
        //    just made, the marker of what is left here (every heavy file
        //    left is verified, or the set is re-checked next time), and —
        //    so the check does not take a copy that simply went preview-only
        //    for news — the confirmed count it read.
        model.noteFilesChanged(for: id)
        model.noteIndexChanged()
        let remaining = listed.filter { !removedNames.contains($0.name) }
        heavyListings[id] = remaining
        summaries[id] = nil
        if var record = records[key] {
            let confirmed = (detail.assets ?? []).filter { $0.status == "confirmed" }
            let heavy = confirmed.filter { PicPlaceSyncInventory.isHeavy($0.name) }
            record.serverHeavyFiles = heavy.count
            record.serverHeavyBytes = heavy.reduce(0) { $0 + ($1.bytes ?? 0) }
            record.serverSourceFiles = heavy.filter { PicPlaceSyncInventory.heavyKind($0.name) == .source }.count
            record.serverConfirmedSeen = confirmed.count
            // The marker a library's Remove trusts: only for files PicPlace
            // has read back.
            let covered = PicPlaceOriginalsCheck.notCovered(remaining, by: remote, verifiedOnly: true).isEmpty
            record.heavyDigest = covered ? PicPlaceOriginalsCheck.digest(remaining) : nil
            if outcome.didRemove { record.removedAt = Date() }
            records[key] = record
            saveSyncState()
        }
        if outcome.didRemove, model.sourcesMissing(capture) {
            let revision = records[key]?.revision ?? revision(of: capture)
            let _: [String: [PPPresence]]? = try? await client.post("projects/\(uuid)/presence", json: ["revision": revision, "tier": "preview"])
        }
        LLog("picplace: free up — removed \(outcome.removedFiles) \(scope.noun) file(s), \(outcome.removedBytes) bytes, of \(capture.displayTitle) (\(uuid.prefix(8)))\(outcome.stopped.map { "; stopped: \($0)" } ?? "")\(keptForCollections > 0 ? "; \(keptForCollections) kept for collections" : "")")
        return outcome
    }

    /// The card's sentence for a failed test.
    static func refusal(_ verdict: PicPlaceOriginalsCheck.Verdict, scope: RemovalScope) -> String {
        let counts = verdict.counts()
        let missing = (counts[.notOnPicPlace] ?? 0) + (counts[.notConfirmed] ?? 0)
        let differs = (counts[.sizeDiffers] ?? 0) + (counts[.contentDiffers] ?? 0)
        let unread = counts[.notHashed] ?? 0
        let checking = counts[.notVerified] ?? 0
        var parts: [String] = []
        if missing > 0 { parts.append("\(missing.formatted()) file\(missing == 1 ? " isn't" : "s aren't") on PicPlace yet — upload \(missing == 1 ? "it" : "them") first") }
        if differs > 0 { parts.append("\(differs.formatted()) file\(differs == 1 ? " here differs" : "s here differ") from PicPlace's \(differs == 1 ? "copy" : "copies")") }
        if unread > 0 { parts.append("\(unread.formatted()) file\(unread == 1 ? "" : "s") couldn't be read") }
        // PicPlace reads every upload back before it counts as kept; nothing
        // is let go of until it has.
        if checking > 0 { parts.append("PicPlace is still checking \(checking.formatted()) file\(checking == 1 ? "" : "s") it received — try again in a minute or two") }
        return "Kept the \(scope.noun): " + parts.joined(separator: "; ")
    }

    /// Hashes for `files`: the capture-time one from `assets.ndjson` where
    /// the file is the size it was hashed at and has not changed since,
    /// computed otherwise (streamed, `AssetHash`).
    nonisolated static func hashed(_ files: [PicPlaceOriginalsCheck.LocalFile], in folder: URL) throws -> [PicPlaceOriginalsCheck.LocalFile] {
        let records = AssetRecords.load(inProjectFolder: folder)
        return try files.map { file in
            var file = file
            let url = folder.appendingPathComponent(file.name, isDirectory: false)
            // The push's rule: a file rewritten after it was hashed is hashed again.
            if let recorded = PicPlaceSyncRun.recordedHash(records[file.name], url: url, bytes: file.bytes) {
                file.sha256 = recorded
            } else {
                file.sha256 = PicPlaceOriginalsCheck.normalized(try AssetHash.sha256(of: url))
            }
            return file
        }
    }

    /// Deletes `files` under `folder`, in order, until one will not go.
    nonisolated static func remove(_ files: [PicPlaceOriginalsCheck.LocalFile], in folder: URL) -> (removed: [PicPlaceOriginalsCheck.LocalFile], failure: String?) {
        var removed: [PicPlaceOriginalsCheck.LocalFile] = []
        for file in files {
            let url = folder.appendingPathComponent(file.name, isDirectory: false)
            do {
                try FileManager.default.removeItem(at: url)
                removed.append(file)
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                return (removed, "\(file.name): \(error.localizedDescription)")
            }
        }
        return (removed, nil)
    }

    // MARK: Settings — every project's originals

    /// The estimate behind *Remove originals already on PicPlace*: a folder
    /// walk of every project whose records are on PicPlace (off the main
    /// actor), judged with what this device knows — the server's list where
    /// the card read it, the verified marker, else the record's counts.
    /// "About": the run checks every project file by file.
    func refreshFreeUpEstimate() {
        guard canSync, freeUpTask == nil, freeUpEstimateTask == nil, let libraryIndex = model.libraryIndex else { return }
        var query = LibraryIndex.ProjectQuery()
        query.limit = 100_000
        let rows = (try? libraryIndex.projects(query).rows) ?? []
        let candidates: [(id: UUID, folder: URL)] = rows.compactMap { row in
            guard let capture = model.capture(id: row.id), capture.deletedAt == nil,
                  let record = records[model.originID(of: capture)], record.recordsReachedServer, record.elsewhereLibrary == nil
            else { return nil }
            return (row.id, model.projectFolderURL(for: capture))
        }
        freeUp.isEstimating = true
        freeUpEstimateTask = Task { [weak self] in
            let listings = await Task.detached(priority: .utility) { () -> [(UUID, [PicPlaceOriginalsCheck.LocalFile])] in
                candidates.map { ($0.id, Self.heavyFiles(in: $0.folder)) }
            }.value
            guard let self else { return }
            var estimate = FreeUpState.Estimate()
            for (id, listing) in listings {
                self.heavyListings[id] = listing
                let source = listing.filter { $0.kind == .source }
                guard !source.isEmpty, let capture = self.model.capture(id: id) else { continue }
                let bytes = source.reduce(Int64(0)) { $0 + $1.bytes }
                if self.looksOnPicPlace(capture, source: source, listing: listing) {
                    estimate.projects += 1
                    estimate.bytes += bytes
                } else {
                    estimate.notUpProjects += 1
                    estimate.notUpBytes += bytes
                }
            }
            self.freeUp.estimate = estimate
            self.freeUp.isEstimating = false
            self.freeUpEstimateTask = nil
        }
    }

    /// Whether a project's source media look fully on PicPlace — the
    /// estimate's judgement, never the removal's.
    private func looksOnPicPlace(_ capture: AppModel.CaptureProject, source: [PicPlaceOriginalsCheck.LocalFile],
                                 listing: [PicPlaceOriginalsCheck.LocalFile]) -> Bool {
        let key = model.originID(of: capture)
        if let remote = serverHeavy[key] { return PicPlaceOriginalsCheck.notCovered(source, by: remote, verifiedOnly: true).isEmpty }
        guard let record = records[key] else { return false }
        if let digest = record.heavyDigest, digest == PicPlaceOriginalsCheck.digest(listing) { return true }
        guard let files = record.serverHeavyFiles, let bytes = record.serverHeavyBytes else { return false }
        return files >= source.count && bytes >= source.reduce(0) { $0 + $1.bytes }
    }

    /// *Remove originals already on PicPlace*: every project with source
    /// media here and records on PicPlace, oldest first, one at a time,
    /// each through the same check as the card's button. Stoppable; the
    /// space frees as it goes.
    func freeUpSpace() {
        guard canSync, freeUpTask == nil, removalTasks.isEmpty, let libraryIndex = model.libraryIndex else { return }
        var query = LibraryIndex.ProjectQuery()
        query.limit = 100_000
        query.sort = .created
        query.ascending = true
        let rows = (try? libraryIndex.projects(query).rows) ?? []
        let ids = rows.map(\.id).filter { id in
            guard let capture = model.capture(id: id), capture.deletedAt == nil,
                  let record = records[model.originID(of: capture)], record.recordsReachedServer, record.elsewhereLibrary == nil
            else { return false }
            // Nothing heavy of its own here: nothing to check.
            if let listing = heavyListings[id], !listing.contains(where: { $0.kind == .source }) { return false }
            return !model.sourcesMissing(capture)
        }
        freeUp.result = nil
        freeUp.run = FreeUpState.Run(done: 0, total: ids.count)
        LLog("picplace: free up — checking \(ids.count) project(s) for originals already on PicPlace")
        freeUpTask = Task { [weak self] in
            guard let self else { return }
            let activity = PicPlaceBackgroundActivity("PicPlace — removing originals already on PicPlace")
            defer { activity.end() }
            var result = FreeUpState.Result()
            for id in ids {
                if Task.isCancelled { result.stopped = "Stopped"; break }
                guard let capture = self.model.capture(id: id) else { self.freeUp.run?.done += 1; continue }
                self.freeUp.run?.current = capture.displayTitle
                let outcome = await self.performRemoval(capture, scope: .originals)
                LLog("picplace: free up — \(capture.displayTitle): \(outcome.caption(.originals))")
                self.freeUp.run?.done += 1
                if outcome.didRemove {
                    result.projects += 1
                    result.freedBytes += outcome.removedBytes
                    self.freeUp.run?.freedBytes = result.freedBytes
                }
                if let refusal = outcome.refusal, !refusal.hasPrefix("No originals") {
                    result.kept += 1
                    if result.reasons.count < 3 { result.reasons.append("\(capture.displayTitle): \(refusal)") }
                    // PicPlace out of reach: the rest would fail the same way.
                    if refusal.hasPrefix("Couldn't check with PicPlace"), self.lastSyncFailedOffline || !self.canSync {
                        result.stopped = "PicPlace can't be reached"
                        break
                    }
                }
                if let stopped = outcome.stopped { result.stopped = stopped; break }
            }
            result.finishedAt = Date()
            LLog("picplace: free up — \(result.projects) project(s), \(result.freedBytes) bytes freed; \(result.kept) kept\(result.stopped.map { "; stopped: \($0)" } ?? "")")
            self.freeUp.run = nil
            self.freeUp.result = result
            self.freeUpTask = nil
            self.refreshFreeUpEstimate()
        }
    }

    func stopFreeUp() {
        freeUpTask?.cancel()
    }

    /// *Upload now* beside the estimate: the originals queue once, by a
    /// person's press — whatever the automatic switch says, on any network.
    func uploadRemainingOriginals() {
        runOriginalsQueueManually()
    }

    // MARK: Deleting a project whose files are only on PicPlace

    /// The line a delete confirm adds when this device does not hold what
    /// the delete will destroy on PicPlace: the originals (a preview-only
    /// project) or blends removed here. A delete here reaches PicPlace at
    /// the next check, and PicPlace purges the files at once (server asks,
    /// Ask 2) — nil when the originals and blends are all here, or the
    /// project is not on PicPlace at all.
    func deletionWarning(for capture: AppModel.CaptureProject) -> String? {
        let key = model.originID(of: capture)
        guard binding != nil, let record = records[key], record.recordsReachedServer || record.policy == "pull" else { return nil }
        let originalsElsewhere = model.sourcesMissing(capture)
        let blendsElsewhere = !capture.isPhotoCapture && model.blends(for: capture).contains { model.blendFileMissing($0) }
        guard originalsElsewhere || blendsElsewhere else { return nil }
        let what = originalsElsewhere && blendsElsewhere ? "Its originals and some blends are"
            : originalsElsewhere ? "Its originals are" : "Some of its blends are"
        return "\(what) only on PicPlace, not on \(Self.deviceWord). Deleting the project deletes \(originalsElsewhere ? "them" : "those") from PicPlace too — for good."
    }
}

// MARK: - The model's side

extension AppModel {

    /// `posters/<blend id>.jpg` — a blend's still, made when the blend's
    /// file leaves this device (free up space), so its row still shows a
    /// picture; travels in the records bundle like the other sidecars.
    func blendPosterURL(for blend: BlendProject) -> URL {
        projectFolderURL(for: blend.captureID)
            .appendingPathComponent(ProjectFileRegistry.blendPostersFolder, isDirectory: true)
            .appendingPathComponent("\(blend.id.uuidString).jpg", isDirectory: false)
    }

    /// True when the blend's file is not on this device (removed to free
    /// space, or a preview pulled from PicPlace). One stat.
    func blendFileMissing(_ blend: BlendProject) -> Bool {
        !FileManager.default.fileExists(atPath: mediaURL(for: blend).path)
    }

    /// True when some of the project's heavy files — its source media or a
    /// blend — are not on this device. An export or a transfer refuses
    /// then: the far side would install records without files.
    func heavyFilesMissing(_ capture: CaptureProject) -> Bool {
        sourcesMissing(capture) || blends(for: capture).contains { blendFileMissing($0) }
    }

    /// The project-relative names (`blends/<file>`) of the blends a
    /// collection uses — they stay when blends are removed.
    func collectionBlendFileNames(for capture: CaptureProject) -> Set<String> {
        let used = Set(collections.flatMap { $0.entries.map(\.blendID) })
        return Set(blends(for: capture).filter { used.contains($0.id) }.map(\.outputFileName))
    }

    /// Makes a still for each named blend that lacks one; returns the names
    /// (`blends/<file>`) that have one afterwards.
    func ensureBlendPosters(for capture: CaptureProject, fileNames: Set<String>) async -> Set<String> {
        let wanted = blends(for: capture).filter { fileNames.contains($0.outputFileName) }
        let jobs = wanted.map { (name: $0.outputFileName, source: mediaURL(for: $0), poster: blendPosterURL(for: $0), isVideo: $0.kind == .video) }
        var made = Set<String>()
        for job in jobs {
            if FileManager.default.fileExists(atPath: job.poster.path) { made.insert(job.name); continue }
            if await BlendPoster.render(source: job.source, isVideo: job.isVideo, to: job.poster) { made.insert(job.name) }
        }
        return made
    }
}

/// A blend's still: the middle frame of a video blend, the image itself for
/// an image blend — 960 px on the long edge, JPEG at 0.75.
enum BlendPoster {
    static let maxDimension: CGFloat = 960

    static func render(source: URL, isVideo: Bool, to destination: URL) async -> Bool {
        let image: CGImage?
        if isVideo {
            let asset = AVURLAsset(url: source)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
            let duration = (try? await asset.load(.duration)) ?? .zero
            let time = duration.seconds.isFinite && duration.seconds > 0 ? CMTime(seconds: duration.seconds / 2, preferredTimescale: 600) : .zero
            image = try? await generator.image(at: time).image
        } else {
            image = await MediaWorkQueue.shared.run { () -> CGImage? in
                guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
                return CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
            } ?? nil
        }
        guard let image else {
            LLog("picplace: no still for blend \(source.lastPathComponent)")
            return false
        }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let target = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
            CGImageDestinationAddImage(target, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
            return CGImageDestinationFinalize(target)
        } catch {
            LLog("picplace: could not write the still for blend \(source.lastPathComponent): \(error)")
            return false
        }
    }
}

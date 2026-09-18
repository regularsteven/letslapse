import Foundation
import Combine
import LetsLapseKit

/// The first connection's cases and the pull (v2 plan §4.1, §4.3), and the
/// rows of the merge table that need no base (§4.4): a project the server
/// has and this library does not comes here as its records and poster; a
/// project this library has and the server does not goes up under the
/// minimal policy; a project on both sides at the same revision is noted
/// as in step. Rows where both sides moved, or where this library never
/// agreed a base, are counted and left for stage 4.
extension PicPlaceController {

    struct InitialSyncProgress: Equatable {
        enum Phase: Equatable { case waiting(String), deciding, pulling, pushing, done, failed(String) }
        var phase: Phase = .deciding
        var pulled = 0
        var pushed = 0
        var inStep = 0
        var deferred = 0
        /// Previews this library cannot account for, removed (L23).
        var evicted = 0
        var total = 0
        var failures: [String] = []
    }

    /// The case an unbound library is in (§4.1), with the numbers.
    struct ConnectCase {
        var serverCount: Int
        var localCount: Int
        var isMerge: Bool { serverCount > 0 && localCount > 0 }
        /// The question's copy: what arrives here and what goes up, in
        /// numbers (libraries plan L18).
        var text: String {
            let local = "\(localCount) project\(localCount == 1 ? "" : "s")"
            let server = "\(serverCount) project\(serverCount == 1 ? "" : "s")"
            switch (serverCount, localCount) {
            case (0, _):
                return "Nothing is on PicPlace yet. This library's \(local) go up — records and a preview each; originals stay here until you upload them. Nothing arrives."
            case (_, 0):
                return "PicPlace holds \(server) and this library is empty. All \(serverCount) arrive here as previews; originals download per project. Nothing goes up."
            default:
                return "PicPlace holds \(server), this library \(local). Everything on PicPlace that isn't here arrives as previews, everything here that isn't on PicPlace goes up, and projects on both sides stay in step."
            }
        }
    }

    /// Computed from the server's count and this library's; nil when the
    /// server cannot be reached or nobody is signed in.
    func describeConnectCase() async -> ConnectCase? {
        guard isSignedIn else { return nil }
        // Only what can go up counts (L24): the projects with originals here.
        var localCount = 0
        if let libraryIndex = model.libraryIndex {
            var query = LibraryIndex.ProjectQuery()
            query.limit = 100_000
            for row in (try? libraryIndex.projects(query))?.rows ?? [] {
                if let capture = model.capture(id: row.id), !model.sourcesMissing(capture) { localCount += 1 }
            }
        }
        guard let status: PPStatus = try? await client.get("status") else { return nil }
        return ConnectCase(serverCount: status.projects?.count ?? 0, localCount: localCount)
    }

    /// Runs the pending first connection once the library is loaded and the
    /// session is up — at launch, and right after an in-place connect on iOS.
    /// The card's Try again: a first connection that could not start goes
    /// again; one that finished with failed pushes hands them to a check,
    /// which retries every failed push at once (a person's check ignores
    /// the backoff).
    func retryFirstConnection() {
        if binding?.initialSync.state == .pending {
            runInitialSyncIfPending()
        } else {
            checkForChanges(reason: "manual")
        }
    }

    func runInitialSyncIfPending() {
        guard !isShutDown, let binding, canSync, initialSyncTask == nil else { return }
        guard binding.initialSync.state == .pending else {
            // Connected before: this launch checks what changed (stage 4).
            Task { [weak self] in
                guard let self else { return }
                if !model.isLibraryLoaded {
                    for await loaded in model.$isLibraryLoaded.values where loaded { break }
                }
                #if DEBUG
                // `LL_PICPLACE_DELETE=<uuid>[,<uuid>…]` deletes projects before
                // the launch check, so the check's push-delete row is
                // exercised; `all-local` deletes every project whose sources
                // are on this device — never a preview pulled from the
                // server, which is some other device's project — and only
                // on a SCRATCH root: how a bench run's throwaways are tombstoned.
                if let raw = ProcessInfo.processInfo.environment["LL_PICPLACE_DELETE"] {
                    var targets: [AppModel.CaptureProject] = []
                    if raw == "all-local" {
                        #if os(macOS)
                        if StorageRoot.rootCameFromArguments, let rows = try? model.libraryIndex?.projects({ var q = LibraryIndex.ProjectQuery(); q.limit = 100_000; return q }()).rows {
                            targets = rows.compactMap { model.capture(id: $0.id) }.filter { !model.sourcesMissing($0) }
                            LLog("picplace hook: deleting \(targets.count) local project(s) of \(rows.count) on this scratch root")
                        } else {
                            LLog("picplace hook: LL_PICPLACE_DELETE=all-local refused — not a scratch root")
                        }
                        #endif
                    } else {
                        targets = raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) }.compactMap { model.capture(id: $0) }
                    }
                    for capture in targets {
                        do { try model.deleteCapture(capture); LLog("picplace hook: deleted \(capture.displayTitle) locally") }
                        catch { LLog("picplace hook: delete failed: \(error)") }
                    }
                }
                #endif
                checkForChanges(reason: "launch")
            }
            return
        }
        if wifiOnly, !isOnWiFi {
            // The records of a whole library are not a mobile-data transfer;
            // the network change re-runs this.
            initialSyncProgress = InitialSyncProgress(phase: .waiting("Waiting for Wi-Fi"))
            return
        }
        initialSyncTask = Task { [weak self] in
            guard let self else { return }
            // The launch walk first: a project it has not indexed yet would
            // read as absent and be pulled a second time.
            if !model.isLibraryLoaded {
                for await loaded in model.$isLibraryLoaded.values where loaded { break }
            }
            let activity = PicPlaceBackgroundActivity("PicPlace first connection")
            defer { activity.end() }
            await runInitialSync()
            initialSyncTask = nil
        }
    }

    private func runInitialSync() async {
        var progress = InitialSyncProgress()
        initialSyncProgress = progress
        do {
            let index: PPProjectIndex = try await client.get("projects")
            // Stage C: only the rows of the library this one is a copy of;
            // a row of the account filed elsewhere is noted on its local
            // twin (nothing is pushed or pulled for it) and otherwise left
            // to whichever library it belongs to.
            let allRows = index.projects
            let rows = allRows.filter { inScope($0) }
            guard let libraryIndex = model.libraryIndex else { throw PicPlaceSyncRun.Failed(caption: "The library index is not open.") }

            // Every live local project, by origin id.
            var localByOrigin: [UUID: UUID] = [:]
            var query = LibraryIndex.ProjectQuery()
            query.limit = 100_000
            for row in (try libraryIndex.projects(query)).rows {
                localByOrigin[row.originID ?? row.id] = row.id
            }
            // A local twin of a row filed elsewhere is noted on its record —
            // when its originals are here. A PREVIEW of one is removed below
            // (L23): it belongs to the library that holds its originals.
            var elsewhere = Set<UUID>()
            for row in allRows where !inScope(row) {
                guard let origin = UUID(uuidString: row.uuid), let localID = localByOrigin[origin],
                      let capture = model.capture(id: localID), !isPreviewOnly(capture) else { continue }
                elsewhere.insert(origin)
                noteElsewhere(origin, library: row.library)
            }

            var toPull: [PPProject] = []
            var serverOrigins = Set<UUID>()
            for row in rows {
                guard let origin = UUID(uuidString: row.uuid) else { continue }
                serverOrigins.insert(origin)
                if let localID = localByOrigin[origin], let capture = model.capture(id: localID) {
                    let localRevision = revision(of: capture)
                    if localRevision == row.revision {
                        // In step. Make sure the base is recorded.
                        if records[origin] == nil {
                            records[origin] = PicPlaceSyncRecord(syncedAt: Date(), revision: row.revision, files: row.assets.confirmed, bytes: row.assets.bytes,
                                                                 uploaded: 0, alsoOn: [], server: profile?.server ?? serverString, lastError: nil, policy: "in-step")
                        }
                        progress.inStep += 1
                    } else {
                        // Both sides differ: the merge's business (stage 4).
                        progress.deferred += 1
                        LLog("picplace: initial sync — \(capture.displayTitle) differs from the server (local \(localRevision), server \(row.revision)); left for the merge")
                    }
                } else {
                    toPull.append(row)
                }
            }
            // What goes up (L24): a project with its originals here that
            // PicPlace holds nowhere. A preview this library cannot account
            // for — filed elsewhere, or gone from PicPlace — is removed here:
            // its folder and index row, never a tombstone (L23). A project
            // whose files simply went missing is neither, and stays.
            var toPush: [AppModel.CaptureProject] = []
            for (origin, localID) in localByOrigin where !serverOrigins.contains(origin) {
                guard let capture = model.capture(id: localID) else { continue }
                if isPreviewOnly(capture) {
                    do {
                        try model.evictPreview(capture)
                        records[origin] = nil
                        progress.evicted += 1
                    } catch {
                        progress.failures.append("\(capture.displayTitle): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                    }
                    continue
                }
                if elsewhere.contains(origin) { continue }
                guard !model.sourcesMissing(capture) else {
                    LLog("picplace: initial sync — \(capture.displayTitle) (\(origin.uuidString.prefix(8))) has no sources on this device and is not a preview; not pushed")
                    continue
                }
                toPush.append(capture)
            }
            if progress.evicted > 0 {
                saveSyncState()
                LLog("picplace: initial sync — \(progress.evicted) preview(s) removed: not this library's on PicPlace (folders and index rows only; no tombstones)")
            }
            progress.total = toPull.count + toPush.count
            let caseName: PicPlaceBindingRecord.InitialSync.Case = rows.isEmpty ? .clean : (localByOrigin.isEmpty ? .fresh : .merge)
            LLog("picplace: initial sync (\(caseName.rawValue)) — \(toPull.count) to pull, \(toPush.count) to push, \(progress.inStep) in step, \(progress.deferred) deferred\(elsewhere.isEmpty ? "" : ", \(elsewhere.count) filed in another library on PicPlace")\(progress.evicted == 0 ? "" : ", \(progress.evicted) preview(s) removed")")
            noteInitialSyncCase(caseName)

            progress.phase = .pulling
            initialSyncProgress = progress
            for row in toPull {
                do {
                    try await pull(row)
                    progress.pulled += 1
                } catch {
                    LLog("picplace: pull of \(row.name) (\(row.uuid.prefix(8))) failed: \(error)")
                    progress.failures.append("\(row.name): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                }
                initialSyncProgress = progress
                if Task.isCancelled { return }
            }

            progress.phase = .pushing
            initialSyncProgress = progress
            for capture in toPush {
                await syncAndWait(capture)
                if let record = records[model.originID(of: capture)], record.lastError == nil {
                    progress.pushed += 1
                } else {
                    progress.failures.append("\(capture.displayTitle): \(records[model.originID(of: capture)]?.lastError ?? "not synced")")
                }
                initialSyncProgress = progress
                if Task.isCancelled { return }
            }

            saveSyncState()
            progress.phase = .done
            initialSyncProgress = progress
            // Done means the comparison ran and every row had its turn —
            // not that every push landed. A project whose push failed keeps
            // its `lastError` and the check retries it with its backoff
            // (handover §7); the rows that differ are the merge's. Until
            // 2026-09-18 a single failure kept the library "pending", and
            // pending hides the switches, the check and its retries: one
            // lost poster out of 670 hid the whole of auto-sync.
            markInitialSyncDone()
            if !progress.failures.isEmpty {
                LLog("picplace: initial sync finished with \(progress.failures.count) failure(s) — Try again, or the check, retries them")
            }
            autoSyncSettingChanged()
            refreshUsage()
        } catch {
            LLog("picplace: initial sync failed: \(error)")
            progress.phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            initialSyncProgress = progress
        }
    }

    /// A local project the server holds in another library of the account
    /// (stage C): its record says where, and every pass leaves it alone.
    func noteElsewhere(_ origin: UUID, library: String?) {
        var record = records[origin] ?? PicPlaceSyncRecord(syncedAt: .distantPast, revision: 0, files: 0, bytes: 0, uploaded: 0, alsoOn: [],
                                                            server: profile?.server ?? serverString, lastError: nil, policy: "elsewhere")
        if record.elsewhereLibrary?.lowercased() != library?.lowercased() {
            LLog("picplace: \(origin.uuidString.prefix(8)) is in \(libraryName(for: library) ?? "another library") on PicPlace, not in this one — left alone here")
        }
        record.elsewhereLibrary = library ?? "default"
        record.elsewhereName = libraryName(for: library)
        record.lastError = nil
        records[origin] = record
    }

    /// The opposite: the server has it in THIS library again (moved back, or
    /// the note was stale).
    func clearElsewhere(_ origin: UUID) {
        guard var record = records[origin], record.elsewhereLibrary != nil else { return }
        record.elsewhereLibrary = nil
        record.elsewhereName = nil
        if record.policy == "elsewhere" { records[origin] = nil } else { records[origin] = record }
    }

    private func noteInitialSyncCase(_ caseName: PicPlaceBindingRecord.InitialSync.Case) {
        guard var record = binding, record.initialSync.case != caseName else { return }
        record.initialSync.case = caseName
        try? record.write(inRoot: root)
        binding = record
    }

    private func markInitialSyncDone() {
        guard var record = binding else { return }
        record.initialSync.state = .done
        record.initialSync.completedAt = Date()
        do {
            try record.write(inRoot: root)
            binding = record
            LLog("picplace: initial sync done (\(record.initialSync.case?.rawValue ?? "?"))")
        } catch {
            LLog("picplace: could not mark the initial sync done: \(error)")
        }
    }

    // MARK: The pull

    /// One project from the server onto this device (§4.3): its records
    /// bundle and poster into `Projects/<originID>/`, the document registered
    /// with `id == originID`, the sync record's base set to the server's
    /// revision, presence posted at tier `preview`. No `source/` media: the
    /// project is preview-only by rule (§3.6). A failure leaves no folder.
    func pull(_ row: PPProject) async throws {
        let uuid = row.uuid.lowercased()
        guard let originID = UUID(uuidString: uuid) else { throw PicPlaceSyncRun.Failed(caption: "PicPlace named a project without a valid id.") }
        let folder = model.projectFolderURL(for: originID)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw PicPlaceSyncRun.Failed(caption: "A folder for \(row.name) already exists here.")
        }

        // One read: the typed detail and the raw manifest come from the same body.
        let raw = try await client.getData("projects/\(uuid)")
        let detail = try PicPlaceClient.decoder.decode(PPProjectDetail.self, from: raw)
        guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              var manifest = object["manifest"] as? [String: Any] else {
            throw PicPlaceSyncRun.Failed(caption: "PicPlace sent no manifest for \(row.name).")
        }
        let assets = (detail.assets ?? []).filter { $0.status == "confirmed" }
        // The overflow shape: the manifest is an asset the stub points at.
        if let manifestAssetID = manifest["manifest_asset"] as? String {
            let data = try await download(assetID: manifestAssetID, projectUUID: uuid)
            guard let real = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw PicPlaceSyncRun.Failed(caption: "The manifest asset of \(row.name) is not a project document.")
            }
            manifest = real
        }
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.withoutEscapingSlashes])
        let document = try ProjectDocumentFormat.makeDecoder().decode(ProjectDocument.self, from: manifestData)
        guard (1...ProjectDocumentFormat.current).contains(document.formatVersion) else {
            throw PicPlaceSyncRun.Failed(caption: "\(row.name) needs a newer LetsLapse (document format \(document.formatVersion)).")
        }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            var files = 0
            var bytes: Int64 = 0
            if let bundle = assets.first(where: { $0.kind == PicPlaceSyncInventory.bundleKind && $0.name == PicPlaceSyncInventory.bundleName }) {
                let data = try await download(assetID: bundle.id, projectUUID: uuid)
                let tmp = folder.appendingPathComponent("tmp", isDirectory: true)
                try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                let archive = tmp.appendingPathComponent(PicPlaceSyncInventory.bundleName)
                try data.write(to: archive, options: .atomic)
                try DirectoryArchive.extract(archive, to: folder)
                try? FileManager.default.removeItem(at: tmp)
                files += 1; bytes += Int64(data.count)
            }
            else {
                // A project pushed before the bundle existed (v1) holds its
                // records as loose objects (kinded by their folder then —
                // `note` at the root, `source` under source/): collect the
                // ones the registry knows as records or sidecars, into place.
                for loose in assets where PicPlaceSyncInventory.role(for: loose.name) == .bundle {
                    let data = try await download(assetID: loose.id, projectUUID: uuid)
                    let destination = folder.appendingPathComponent(loose.name)
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: destination, options: .atomic)
                    files += 1; bytes += Int64(data.count)
                }
            }
            if let poster = assets.first(where: { $0.kind == PicPlaceSyncInventory.posterKind && $0.name == ProjectFileRegistry.posterName }) {
                let data = try await download(assetID: poster.id, projectUUID: uuid)
                try data.write(to: folder.appendingPathComponent(ProjectFileRegistry.posterName), options: .atomic)
                files += 1; bytes += Int64(data.count)
            }
            let capture = try model.registerPulledProject(capture: document.capture, blends: document.blends, originID: originID)
            let heavy = assets.filter { PicPlaceSyncInventory.isHeavy($0.name) }
            records[originID] = PicPlaceSyncRecord(
                syncedAt: Date(), revision: row.revision, files: files, bytes: bytes, uploaded: 0,
                alsoOn: row.presence.compactMap(\.device).filter { $0.id != profile?.deviceID }.map(\.name),
                server: profile?.server ?? serverString, lastError: nil, policy: "pull",
                heavyFiles: heavy.count, heavyBytes: heavy.reduce(0) { $0 + ($1.bytes ?? 0) },
                serverHeavyFiles: heavy.count, serverHeavyBytes: heavy.reduce(0) { $0 + ($1.bytes ?? 0) },
                serverConfirmedSeen: assets.count)
            saveSyncState()
            let _: [String: [PPPresence]]? = try? await client.post("projects/\(uuid)/presence", json: ["revision": row.revision, "tier": "preview"])
            LLog("picplace: pulled \(capture.displayTitle) (\(uuid.prefix(8))) — \(files) object(s), \(bytes) bytes; \(heavy.count) heavy file(s) stay on PicPlace")
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// One asset's bytes through a presigned GET minted for it.
    func download(assetID: String, projectUUID: String) async throws -> Data {
        let urls: [String: [PPDownloadURL]] = try await client.post("projects/\(projectUUID)/assets/urls", json: ["assets": [assetID]])
        guard let item = urls["assets"]?.first else { throw PicPlaceSyncRun.Failed(caption: "PicPlace minted no download URL.") }
        if let error = item.error { throw PicPlaceSyncRun.Failed(caption: item.message ?? error) }
        guard let string = item.url, let url = URL(string: string) else { throw PicPlaceSyncRun.Failed(caption: "PicPlace minted an unusable download URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = item.method ?? "GET"
        do {
            return try await PicPlaceTransfer.withRetries("GET \(assetID.prefix(8))") {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200 ..< 300).contains(status) else { throw PicPlaceTransfer.Refused(status: status, detail: "") }
                return data
            }
        } catch let refused as PicPlaceTransfer.Refused {
            throw PicPlaceSyncRun.Failed(caption: "Storage refused the download (\(refused.status)).")
        }
    }
}

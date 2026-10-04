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
        // Only what can go up counts (L24): the projects with originals here
        // — every document, read off the main actor (`LibraryPass`).
        var localCount = 0
        if let snapshot = await model.libraryPass(name: "picplace connect case") {
            localCount = snapshot.projects.filter { !$0.sourcesMissing }.count
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
                    // The launch check must carry these deletes: it is not
                    // skipped for a check that finished a moment ago.
                    if !targets.isEmpty { lastCheck = nil }
                }
                #endif
                checkForChanges(reason: "launch")
                // Uploads that were running when the app last stopped, or
                // were interrupted, carry on where they got to.
                resumeUploadJobs(reason: "launch")
                #if DEBUG
                runUploadHookOnce()
                #endif
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
            // The first connection scopes by library too: it asks which
            // libraries the account has when this session has not heard yet
            // (see `librariesKnown`), and does not run without the answer.
            if !librariesKnown, let status: PPStatus = try? await client.get("status") { noteLibraries(status) }
            if scope != nil, !librariesKnown {
                throw PicPlaceSyncRun.Failed(caption: "PicPlace has not said which libraries the account has yet.")
            }
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
                            records[origin] = PicPlaceSyncRecord(syncedAt: Date(), revision: row.revision, files: row.accountedConfirmed, bytes: row.assets.bytes,
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
            if serverHasRenditionBatches {
                // Stage 3: a hundred projects' downloads minted in one request.
                for page in toPull.chunked(100) {
                    let (pulled, failures) = await pullPage(page) { initialSyncProgress = progress }
                    progress.pulled += pulled
                    progress.failures.append(contentsOf: failures)
                    initialSyncProgress = progress
                    if Task.isCancelled { return }
                }
            } else {
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
    func planPull(_ row: PPProject) async throws -> PullPlan {
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
        // What devices pushed: the server's own tile (picture tiers) is not
        // among the objects this device accounts for — it is fetched beside
        // the poster from `confirmedAll` when it is cut from that poster.
        let confirmedAll = (detail.assets ?? []).filter { $0.status == "confirmed" }
        let assets = confirmedAll.accounted
        // The overflow shape: the manifest is an asset the stub points at.
        if let manifestAssetID = manifest["manifest_asset"] as? String {
            let data = try await download(assetID: manifestAssetID, projectUUID: uuid, name: "manifest.json")
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
        let bundleAsset = assets.first(where: { $0.kind == PicPlaceSyncInventory.bundleKind && $0.name == PicPlaceSyncInventory.bundleName })
        let posterAsset = assets.first(where: { $0.kind == PicPlaceSyncInventory.posterKind && $0.name == ProjectFileRegistry.posterName })
        let tileAsset = Self.freshTile(in: confirmedAll, poster: posterAsset)
        let looseAssets = bundleAsset == nil ? assets.filter { PicPlaceSyncInventory.role(for: $0.name) == .bundle } : []
        // Stage 3, lazy posters: with a tile to draw the grid from, the poster
        // waits for the day the project is opened (`fetchPosterOnOpen`).
        let wantsPoster = !(serverHasTiles && tileAsset != nil)
        return PullPlan(row: row, uuid: uuid, originID: originID, folder: folder, document: document, assets: assets,
                        bundleAsset: bundleAsset, posterAsset: wantsPoster ? posterAsset : nil, tileAsset: tileAsset,
                        looseAssets: looseAssets)
    }

    /// The half of a pull that reads PicPlace: the row's detail and manifest,
    /// the document decoded, and which assets to fetch — so a page of pulls
    /// can mint every URL in one request before any bytes move (stage 3).
    struct PullPlan {
        var row: PPProject
        var uuid: String
        var originID: UUID
        var folder: URL
        var document: ProjectDocument
        var assets: [PPAsset]
        var bundleAsset: PPAsset?
        var posterAsset: PPAsset?
        var tileAsset: PPAsset?
        var looseAssets: [PPAsset]

        var assetIDs: [String] {
            [bundleAsset?.id, posterAsset?.id, tileAsset?.id].compactMap { $0 } + looseAssets.map(\.id)
        }
    }

    /// A new project on the server, pulled whole: plan, one mint, the bytes.
    func pull(_ row: PPProject) async throws {
        let plan = try await planPull(row)
        let minted = await mintDownloads(plan.assetIDs, projectUUID: plan.uuid)
        try await completePull(plan, minted: minted)
    }

    /// Up to a hundred new projects: every plan first (one `GET
    /// projects/{uuid}` each, unavoidable — the manifest lives there), then
    /// ONE `POST assets/urls` for all their downloads, then the bytes. The
    /// per-project mint is what a 100,000-library's first pull could not
    /// afford. `tick` is called after each project for the progress line.
    func pullPage(_ rows: [PPProject], tick: () -> Void = {}) async -> (pulled: Int, failures: [String]) {
        var plans: [PullPlan] = []
        var failures: [String] = []
        for row in rows {
            do { plans.append(try await planPull(row)) }
            catch {
                LLog("picplace: pull of \(row.name) (\(row.uuid.prefix(8))) failed: \(error)")
                failures.append("\(row.name): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            }
            if Task.isCancelled { return (0, failures) }
        }
        let minted = await mintRenditionURLs(plans.flatMap(\.assetIDs))
        var pulled = 0
        for plan in plans {
            do {
                try await completePull(plan, minted: minted)
                pulled += 1
            } catch {
                LLog("picplace: pull of \(plan.row.name) (\(plan.uuid.prefix(8))) failed: \(error)")
                failures.append("\(plan.row.name): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            }
            tick()
            if Task.isCancelled { break }
        }
        return (pulled, failures)
    }

    /// The half of a pull that writes: the bundle (or the loose records),
    /// the poster when the plan wants it, the tile, the registration and
    /// the record.
    func completePull(_ plan: PullPlan, minted: [String: PPDownloadURL]) async throws {
        let row = plan.row, uuid = plan.uuid, originID = plan.originID, folder = plan.folder, document = plan.document
        let assets = plan.assets, bundleAsset = plan.bundleAsset, posterAsset = plan.posterAsset
        let tileAsset = plan.tileAsset, looseAssets = plan.looseAssets
        do {
            var files = 0
            var bytes: Int64 = 0
            if let bundle = bundleAsset {
                let data = try await download(assetID: bundle.id, projectUUID: uuid, name: "records.aar", minted: minted)
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
                for loose in looseAssets {
                    let data = try await download(assetID: loose.id, projectUUID: uuid, name: loose.name, minted: minted)
                    let destination = folder.appendingPathComponent(loose.name)
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: destination, options: .atomic)
                    files += 1; bytes += Int64(data.count)
                }
            }
            if let poster = posterAsset {
                let data = try await download(assetID: poster.id, projectUUID: uuid, name: "poster.jpg", minted: minted)
                try data.write(to: folder.appendingPathComponent(ProjectFileRegistry.posterName), options: .atomic)
                files += 1; bytes += Int64(data.count)
            }
            // The server's tile beside the poster (stage 2) — the grid's picture
            // here; not one of the objects this device accounts for.
            if let tile = tileAsset {
                let data = try await download(assetID: tile.id, projectUUID: uuid, name: tile.name, minted: minted)
                try Self.writeTile(data, name: tile.name, in: folder)
            }
            let capture = try model.registerPulledProject(capture: document.capture, blends: document.blends, originID: originID)
            let heavy = assets.filter { PicPlaceSyncInventory.isHeavy($0.name) }
            records[originID] = PicPlaceSyncRecord(
                syncedAt: Date(), revision: row.revision, files: files, bytes: bytes, uploaded: 0,
                alsoOn: row.presence.otherDeviceNames(excluding: profile?.deviceID),
                originalsOn: row.presence.originalsHolders(excluding: profile?.deviceID),
                server: profile?.server ?? serverString, lastError: nil, policy: "pull",
                heavyFiles: heavy.count, heavyBytes: heavy.reduce(0) { $0 + ($1.bytes ?? 0) },
                serverHeavyFiles: heavy.count, serverHeavyBytes: heavy.reduce(0) { $0 + ($1.bytes ?? 0) },
                serverConfirmedSeen: assets.count)
            records[originID]?.serverRowAccounted = row.accountedConfirmed
            records[originID]?.serverSourceFiles = heavy.filter { PicPlaceSyncInventory.heavyKind($0.name) == .source }.count
            records[originID]?.tileSHA256 = tileAsset?.sha256
            records[originID]?.posterSHA256 = posterAsset?.sha256
            saveSyncState()
            let _: [String: [PPPresence]]? = try? await client.post("projects/\(uuid)/presence", json: ["revision": row.revision, "tier": "preview"])
            LLog("picplace: pulled \(capture.displayTitle) (\(uuid.prefix(8))) — \(files) object(s), \(bytes) bytes; \(heavy.count) heavy file(s) stay on PicPlace")
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// The server's tile for `poster` among `assets`, when it was cut from
    /// that very poster (the contract's freshness rule: the tile's
    /// `derived_from_sha256` equals the poster's `sha256`). nil for a tile
    /// cut from an earlier poster — the grid then cuts from the poster until
    /// the server's job catches up — and from a server before tiles.
    static func freshTile(in assets: [PPAsset], poster: PPAsset?) -> PPAsset? {
        guard let posterSHA = poster?.sha256 else { return nil }
        return assets.first {
            $0.status == "confirmed" && $0.isServerMade && ProjectFileRegistry.isTile(fileName: $0.name)
                && $0.derivedFromSha256 == posterSHA
        }
    }

    /// Writes the tile under the server's name and removes any other tile
    /// in the folder (a format the server moved away from).
    static func writeTile(_ data: Data, name: String, in folder: URL) throws {
        for other in ProjectFileRegistry.tileCandidates where other != name {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(other))
        }
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    /// Every tile in the folder — for a poster the server has no fresh tile of.
    static func removeTiles(in folder: URL) {
        for name in ProjectFileRegistry.tileCandidates {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Download URLs for several of a project's assets in ONE request, by
    /// asset id (2026-10-01: a pull minted one URL per request — the bundle,
    /// then the poster — which was one of the four API requests every pulled
    /// project cost). Empty on any failure or for fewer than two ids: each
    /// download then mints its own, as before.
    func mintDownloads(_ assetIDs: [String], projectUUID: String) async -> [String: PPDownloadURL] {
        guard assetIDs.count > 1 else { return [:] }
        guard let urls: [String: [PPDownloadURL]] = try? await client.post("projects/\(projectUUID)/assets/urls", json: ["assets": assetIDs]),
              let items = urls["assets"], items.count == assetIDs.count else { return [:] }
        var minted: [String: PPDownloadURL] = [:]
        // By the id each answer carries; by position for a server that sends none.
        for (asked, item) in zip(assetIDs, items) { minted[item.id ?? asked] = item }
        return minted
    }

    /// One asset's bytes through a presigned GET — minted for it here, or
    /// taken from `minted` when the caller asked for several at once.
    func download(assetID: String, projectUUID: String, name: String = "", minted: [String: PPDownloadURL] = [:]) async throws -> Data {
        let single: PPDownloadURL?
        if let ready = minted[assetID], ready.error == nil, ready.url != nil {
            single = ready
        } else {
            let urls: [String: [PPDownloadURL]] = try await client.post("projects/\(projectUUID)/assets/urls", json: ["assets": [assetID]])
            single = urls["assets"]?.first
        }
        guard let item = single else { throw PicPlaceSyncRun.Failed(caption: "PicPlace minted no download URL.") }
        if let error = item.error { throw PicPlaceSyncRun.Failed(caption: item.message ?? error) }
        guard let string = item.url, let url = URL(string: string) else { throw PicPlaceSyncRun.Failed(caption: "PicPlace minted an unusable download URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = item.method ?? "GET"
        do {
            return try await PicPlaceTransfer.withRetries("GET \(assetID.prefix(8))") {
                #if DEBUG
                let started = Date()
                #endif
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                #if DEBUG
                PicPlaceTransfer.trace("GET", name.isEmpty ? assetID : name, status: status, bytes: data.count, since: started)
                #endif
                guard (200 ..< 300).contains(status) else { throw PicPlaceTransfer.Refused(status: status, detail: "") }
                return data
            }
        } catch let refused as PicPlaceTransfer.Refused {
            throw PicPlaceSyncRun.Failed(caption: "Storage refused the download (\(refused.status)).")
        }
    }
}

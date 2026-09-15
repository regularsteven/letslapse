import Foundation
import LetsLapseKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Stage 4 (v2 plan §4.4): the merge table run continuously. A **check**
/// reads the account's index since the last watermark (`updated_since`,
/// tombstones included) and applies every row that has a base — pull the
/// records where only the server moved, push where only this device moved,
/// bring new server projects here and new local ones up, push local
/// deletes — and collects the rest as **conflicts** for a person: both sides
/// moved, a project deleted on the server that this device still holds, a
/// project this device deleted that the server changed since. Checks run
/// at launch (after the first connection), whenever the app comes to the
/// front, every few minutes while auto-sync is on, and on demand.
///
/// The check is also **the recovery path**: a push that failed — refused
/// by the rate limit, cut off, a claim held elsewhere — leaves a record
/// with `lastError`, and the check sends it again once its backoff has
/// passed (a person's own *Check PicPlace now* does not wait). Every push
/// the check makes goes one project at a time through the paced client,
/// so a check that has a hundred projects to send takes the minutes it
/// takes rather than being refused.
extension PicPlaceController {

    /// One row a person has to decide.
    struct Conflict: Identifiable, Equatable {
        enum Kind: Equatable {
            /// Edited on both sides since the base.
            case bothEdited
            /// No base — this library never agreed a revision with the server —
            /// and the two differ (a twin from a `.lapse` or a LAN transfer).
            case unrelated
            /// Deleted on PicPlace; this device still holds a copy.
            case deletedOnServer
            /// Deleted here; PicPlace changed it since.
            case deletedHereEditedThere
        }
        var id: UUID { originID }
        var originID: UUID
        var localID: UUID?
        var name: String
        var kind: Kind
        var localEditedAt: Date?
        var serverEditedAt: Date?
        var serverDevice: String?
        var serverRevision: Int
        var localRevision: Int?
    }

    enum Resolution { case keepLocal, keepServer, keepBoth }

    struct CheckOutcome: Equatable {
        var pulled = 0
        var pushed = 0
        var updated = 0
        var deletedHere = 0
        var deletedThere = 0
        var conflicts = 0
        /// Failed pushes this check sent again, and those still waiting for their backoff.
        var retried = 0
        var waiting = 0
        var failures: [String] = []
        var checkedAt = Date()
    }

    // MARK: Triggers

    /// Subscribes the controller to the app coming to the front; called once
    /// from init. The launch check itself follows the first connection.
    func armChangeChecks() {
        #if os(macOS)
        let name = NSApplication.didBecomeActiveNotification
        #else
        let name = UIApplication.didBecomeActiveNotification
        #endif
        foregroundObserver = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.checkForChanges(reason: "foreground") }
        }
    }

    /// A check, unless one runs, the first connection is still pending, or
    /// a shoot is being written (its project must not be pushed mid-write).
    func checkForChanges(reason: String) {
        guard canSync, binding?.initialSync.state == .done, checkTask == nil, initialSyncTask == nil else { return }
        if model.stage == .processing { LLog("picplace: check (\(reason)) skipped — a capture is running"); return }
        // Only a person's press runs on mobile data; every automatic reason
        // waits for Wi-Fi and is picked up when the network changes.
        if reason != "manual", !autoAllowed {
            heldCheck = true
            LLog("picplace: check (\(reason)) held — \(autoHold ?? "auto-sync off")")
            return
        }
        // Foreground checks are rate-limited: the Mac fires didBecomeActive
        // on every window switch.
        if reason == "foreground", let last = lastCheckAt, Date().timeIntervalSince(last) < 60 { return }
        lastCheckAt = Date()
        checkTask = Task { [weak self] in
            guard let self else { return }
            await runCheck(reason: reason)
            checkTask = nil
        }
    }

    // MARK: The check

    private func runCheck(reason: String) async {
        isChecking = true
        defer { isChecking = false }
        var outcome = CheckOutcome()
        // A person's press retries every failed push now; the automatic
        // checks wait for each one's backoff.
        let now = Date()
        func retryDue(_ record: PicPlaceSyncRecord?) -> Bool {
            guard let record, record.lastError != nil else { return false }
            if reason == "manual" { return true }
            return (record.retryDueAt ?? .distantPast) <= now
        }
        do {
            // The whole index, tombstones included, every time: the merge
            // table needs every row — a project only THIS device edited sits
            // beside a server row that `updated_since` would not list. The
            // watermark is kept for a later, incremental pass at scale.
            let index: PPProjectIndex = try await client.get("projects", query: ["include_deleted": "1"])
            guard let libraryIndex = model.libraryIndex else { throw PicPlaceSyncRun.Failed(caption: "The library index is not open.") }

            var localByOrigin: [UUID: UUID] = [:]
            var listQuery = LibraryIndex.ProjectQuery()
            listQuery.limit = 100_000
            for row in (try libraryIndex.projects(listQuery)).rows { localByOrigin[row.originID ?? row.id] = row.id }
            let localTombstones = Set((try? libraryIndex.deletedProjects().map(\.id)) ?? [])

            var conflicts: [Conflict] = []
            var seen = Set<UUID>()
            for row in index.projects {
                guard let origin = UUID(uuidString: row.uuid) else { continue }
                seen.insert(origin)
                let base = records[origin]?.revision
                if row.isTombstone {
                    guard let localID = localByOrigin[origin], let capture = model.capture(id: localID) else { continue }
                    // Deleted there, still here. A copy that never moved past
                    // the server's last revision loses nothing by going — to
                    // the trash, reversible — so it goes; a copy edited since
                    // is the person's to decide.
                    let localRevision = revision(of: capture)
                    if localRevision == row.revision || localRevision == base {
                        do {
                            try model.deleteCapture(capture)
                            records[origin] = nil
                            outcome.deletedHere += 1
                            LLog("picplace: \(capture.displayTitle) was deleted on PicPlace\(row.deletedBy.map { " from \($0.name)" } ?? "") — moved to the trash here")
                        } catch {
                            outcome.failures.append("\(capture.displayTitle): \(Self.describe(error))")
                        }
                        continue
                    }
                    conflicts.append(Conflict(originID: origin, localID: localID, name: capture.displayTitle, kind: .deletedOnServer,
                                              localEditedAt: model.lastEdited(capture), serverEditedAt: row.deletedAt,
                                              serverDevice: row.deletedBy?.name, serverRevision: row.revision,
                                              localRevision: localRevision))
                    continue
                }
                if localTombstones.contains(origin) {
                    // Deleted here. Unchanged there since the base → push the delete; changed → a person decides.
                    if let base, row.revision == base {
                        do { try await deleteOnServer(origin); outcome.deletedThere += 1 }
                        catch { outcome.failures.append("\(row.name): \(Self.describe(error))") }
                    } else {
                        conflicts.append(Conflict(originID: origin, localID: nil, name: row.name, kind: .deletedHereEditedThere,
                                                  localEditedAt: nil, serverEditedAt: row.updatedAt, serverDevice: row.updatedBy?.name,
                                                  serverRevision: row.revision, localRevision: nil))
                    }
                    continue
                }
                guard let localID = localByOrigin[origin], let capture = model.capture(id: localID) else {
                    // New on the server.
                    do { try await pull(row); outcome.pulled += 1 }
                    catch { outcome.failures.append("\(row.name): \(Self.describe(error))") }
                    continue
                }
                let localRevision = revision(of: capture)
                if localRevision == row.revision {
                    if records[origin]?.revision != row.revision {
                        var record = records[origin] ?? PicPlaceSyncRecord(syncedAt: Date(), revision: row.revision, files: 0, bytes: 0, uploaded: 0, alsoOn: [], server: profile?.server ?? serverString, lastError: nil, policy: "in-step")
                        record.revision = row.revision
                        records[origin] = record
                    }
                    let record = records[origin]
                    let failedRecords = record?.lastError != nil && record?.failedPolicy != PicPlaceSyncPolicy.originals.rawValue
                    if !model.sourcesMissing(capture), failedRecords, syncTasks[capture.id] == nil {
                        // The manifest got through and the rest of the push
                        // did not (the bundle, the poster, the confirms):
                        // the same push again finishes it — a replay of the
                        // manifest, uploads of what is still missing.
                        if retryDue(record) {
                            await syncAndWait(capture)
                            if records[origin]?.lastError == nil { outcome.retried += 1; LLog("picplace: \(capture.displayTitle) — push retried, done") }
                            else { outcome.failures.append("\(capture.displayTitle): \(records[origin]?.lastError ?? "push failed")") }
                        } else {
                            outcome.waiting += 1
                        }
                        continue
                    }
                    // In step — but the poster? A project this device holds
                    // whole and has never pushed with one (a v1 push, the
                    // first connection's "in step") gets one push; a
                    // preview-only project takes the server's records again
                    // whenever the server's asset count moved since it last
                    // did (a push that finished after the pull, a poster
                    // that arrived), else asks for a poster it lacks once
                    // per change there.
                    if !model.sourcesMissing(capture), record?.posterToken == nil, syncTasks[capture.id] == nil {
                        await syncAndWait(capture)
                        if records[origin]?.lastError == nil { outcome.pushed += 1; LLog("picplace: \(capture.displayTitle) — in step, poster sent") }
                    } else if model.sourcesMissing(capture), record?.policy == "pull" || record?.serverConfirmedSeen != nil,
                              record?.serverConfirmedSeen != row.assets.confirmed {
                        do {
                            try await pullUpdate(row, into: capture)
                            outcome.updated += 1
                            LLog("picplace: \(capture.displayTitle) — records fetched again (the server holds \(row.assets.confirmed) confirmed asset(s), this device had seen \(record?.serverConfirmedSeen.map(String.init) ?? "none"))")
                        } catch {
                            outcome.failures.append("\(row.name): \(Self.describe(error))")
                        }
                    } else if model.sourcesMissing(capture), model.posterURL(for: capture) == nil,
                              (record?.posterCheckedAt).map({ ($0 < (row.updatedAt ?? .distantFuture)) }) ?? true {
                        do {
                            if try await fetchPoster(row, into: capture) { outcome.updated += 1 }
                        } catch {
                            outcome.failures.append("\(row.name): \(Self.describe(error))")
                        }
                    }
                    continue
                }
                let localMoved = base.map { localRevision != $0 } ?? true
                let serverMoved = base.map { row.revision != $0 } ?? true
                switch (base != nil, localMoved, serverMoved) {
                case (true, true, false):
                    if records[origin]?.lastError != nil, !retryDue(records[origin]) { outcome.waiting += 1; continue }
                    let wasFailed = records[origin]?.lastError != nil
                    await syncAndWait(capture)
                    if records[origin]?.lastError == nil { if wasFailed { outcome.retried += 1 } else { outcome.pushed += 1 } }
                    else { outcome.failures.append("\(capture.displayTitle): \(records[origin]?.lastError ?? "push failed")") }
                case (true, false, true):
                    do { try await pullUpdate(row, into: capture); outcome.updated += 1 }
                    catch { outcome.failures.append("\(row.name): \(Self.describe(error))") }
                default:
                    conflicts.append(Conflict(originID: origin, localID: localID, name: capture.displayTitle,
                                              kind: base == nil ? .unrelated : .bothEdited,
                                              localEditedAt: model.lastEdited(capture), serverEditedAt: row.updatedAt,
                                              serverDevice: row.updatedBy?.name, serverRevision: row.revision, localRevision: localRevision))
                }
            }

            // New here since the last check: up they go (records and a poster).
            // A record whose every push failed is not a push: the project
            // is still new to the server, and goes when its backoff allows.
            for (origin, localID) in localByOrigin where !seen.contains(origin) {
                guard let capture = model.capture(id: localID) else { continue }
                if let record = records[origin] {
                    if record.recordsReachedServer || record.policy == "pull" {
                        // Pushed (or pulled) before, gone from the server without a tombstone (purged): leave it be.
                        continue
                    }
                    if !retryDue(record) { outcome.waiting += 1; continue }
                }
                let wasFailed = records[origin]?.lastError != nil
                await syncAndWait(capture)
                if records[origin]?.lastError == nil { if wasFailed { outcome.retried += 1 } else { outcome.pushed += 1 } }
                else { outcome.failures.append("\(capture.displayTitle): \(records[origin]?.lastError ?? "push failed")") }
            }

            outcome.conflicts = conflicts.count
            self.conflicts = conflicts
            syncMeta.serverTime = index.serverTime.map { ISO8601DateFormatter().string(from: $0) }
            syncMeta.checkedAt = Date()
            saveSyncState()
            lastCheck = outcome
            updateAutoError()
            LLog("picplace: check (\(reason)) — \(outcome.pulled) pulled, \(outcome.updated) updated, \(outcome.pushed) pushed, \(outcome.retried) retried, \(outcome.waiting) waiting to retry, \(outcome.deletedThere) deleted there, \(outcome.deletedHere) removed here, \(conflicts.count) conflict(s)\(outcome.failures.isEmpty ? "" : ", failures (\(outcome.failures.count)): \(outcome.failures.prefix(5).joined(separator: "; "))\(outcome.failures.count > 5 ? "; …" : "")")")
            for conflict in conflicts {
                LLog("picplace: conflict — \(conflict.name) (\(conflict.originID.uuidString.prefix(8))) \(conflict.kind): local \(conflict.localRevision.map(String.init) ?? "-") vs server \(conflict.serverRevision)\(conflict.serverDevice.map { " from \($0)" } ?? "")")
            }
            // The index was read a moment ago: the usage line needs only /status.
            refreshUsage(rows: index.projects)
            scheduleOriginalsQueue()
            #if DEBUG
            // `LL_PICPLACE_DOWNLOAD=<uuid>` / `LL_PICPLACE_UPLOAD=<uuid>` move a
            // project's originals after the check (stage 5).
            if let raw = ProcessInfo.processInfo.environment["LL_PICPLACE_DOWNLOAD"], let id = UUID(uuidString: raw), let capture = model.capture(id: id) {
                downloadOriginals(capture)
            }
            if let raw = ProcessInfo.processInfo.environment["LL_PICPLACE_UPLOAD"], let id = UUID(uuidString: raw), let capture = model.capture(id: id) {
                uploadOriginals(capture)
            }
            // `LL_PICPLACE_REVIEW=1` opens the conflicts sheet after the check.
            if ProcessInfo.processInfo.environment["LL_PICPLACE_REVIEW"] != nil, !conflicts.isEmpty { isReviewingConflicts = true }
            // `LL_PICPLACE_RESOLVE=newest|local|server|both` decides every
            // conflict the check found, the way the sheet's buttons would.
            if let how = ProcessInfo.processInfo.environment["LL_PICPLACE_RESOLVE"], !conflicts.isEmpty {
                switch how {
                case "newest": await resolveAllByNewest()
                case "local": for c in conflicts { await resolve(c, .keepLocal) }
                case "server": for c in conflicts { await resolve(c, .keepServer) }
                case "both": for c in conflicts { await resolve(c, .keepBoth) }
                default: break
                }
                LLog("picplace hook: resolved by \(how) — \(self.conflicts.count) left\(lastResolveError.map { "; \($0)" } ?? "")")
            }
            #endif
        } catch {
            outcome.failures.append(Self.describe(error))
            lastCheck = outcome
            LLog("picplace: check (\(reason)) failed: \(error)")
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? PicPlaceAPIError)?.cardCaption ?? (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Rows with a base

    /// The server's newer records onto a project this library holds: the
    /// bundle's members and the poster refreshed on disk, then the record.
    func pullUpdate(_ row: PPProject, into capture: AppModel.CaptureProject) async throws {
        let uuid = row.uuid.lowercased()
        let originID = model.originID(of: capture)
        let folder = model.projectFolderURL(for: capture)
        // One read: the typed detail and the raw manifest come from the same body.
        let raw = try await client.getData("projects/\(uuid)")
        let detail = try PicPlaceClient.decoder.decode(PPProjectDetail.self, from: raw)
        guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              var manifest = object["manifest"] as? [String: Any] else {
            throw PicPlaceSyncRun.Failed(caption: "PicPlace sent no manifest for \(row.name).")
        }
        let assets = (detail.assets ?? []).filter { $0.status == "confirmed" }
        if let manifestAssetID = manifest["manifest_asset"] as? String {
            let data = try await download(assetID: manifestAssetID, projectUUID: uuid)
            guard let real = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw PicPlaceSyncRun.Failed(caption: "The manifest asset of \(row.name) is not a project document.")
            }
            manifest = real
        }
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.withoutEscapingSlashes])
        let document = try ProjectDocumentFormat.makeDecoder().decode(ProjectDocument.self, from: manifestData)

        if let bundle = assets.first(where: { $0.kind == PicPlaceSyncInventory.bundleKind && $0.name == PicPlaceSyncInventory.bundleName }) {
            let data = try await download(assetID: bundle.id, projectUUID: uuid)
            let tmp = folder.appendingPathComponent("tmp", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let archive = tmp.appendingPathComponent(PicPlaceSyncInventory.bundleName)
            try data.write(to: archive, options: .atomic)
            try DirectoryArchive.extract(archive, to: folder)
            try? FileManager.default.removeItem(at: tmp)
        }
        if let poster = assets.first(where: { $0.kind == PicPlaceSyncInventory.posterKind && $0.name == ProjectFileRegistry.posterName }) {
            let data = try await download(assetID: poster.id, projectUUID: uuid)
            try data.write(to: folder.appendingPathComponent(ProjectFileRegistry.posterName), options: .atomic)
        }
        try model.applyPulledUpdate(originID: originID, capture: document.capture, blends: document.blends)
        model.noteFilesChanged(for: capture.id)
        var record = records[originID] ?? PicPlaceSyncRecord(syncedAt: Date(), revision: row.revision, files: 0, bytes: 0, uploaded: 0, alsoOn: [], server: profile?.server ?? serverString, lastError: nil)
        record.syncedAt = Date()
        record.revision = row.revision
        record.clearFailure()
        record.alsoOn = row.presence.compactMap(\.device).filter { $0.id != profile?.deviceID }.map(\.name)
        record.posterToken = nil
        record.serverConfirmedSeen = assets.count
        let heavy = assets.filter { PicPlaceSyncInventory.isHeavy($0.name) }
        record.serverHeavyFiles = heavy.count
        record.serverHeavyBytes = heavy.reduce(0) { $0 + ($1.bytes ?? 0) }
        if model.sourcesMissing(capture) {
            record.heavyFiles = heavy.count
            record.heavyBytes = record.serverHeavyBytes
        }
        records[originID] = record
        let _: [String: [PPPresence]]? = try? await client.post("projects/\(uuid)/presence", json: ["revision": row.revision])
        LLog("picplace: updated \(row.name) (\(uuid.prefix(8))) from the server (revision \(row.revision))")
    }

    /// The poster of a preview-only project that has none here — fetched
    /// when the server holds one. Remembers the look, so an absent poster
    /// costs one GET per change on the server, not one per check.
    private func fetchPoster(_ row: PPProject, into capture: AppModel.CaptureProject) async throws -> Bool {
        let uuid = row.uuid.lowercased()
        let originID = model.originID(of: capture)
        let detail: PPProjectDetail = try await client.get("projects/\(uuid)")
        var record = records[originID] ?? PicPlaceSyncRecord(syncedAt: Date(), revision: row.revision, files: 0, bytes: 0, uploaded: 0, alsoOn: [], server: profile?.server ?? serverString, lastError: nil, policy: "pull")
        record.posterCheckedAt = Date()
        record.serverConfirmedSeen = (detail.assets ?? []).filter { $0.status == "confirmed" }.count
        records[originID] = record
        guard let poster = (detail.assets ?? []).first(where: { $0.kind == PicPlaceSyncInventory.posterKind && $0.name == ProjectFileRegistry.posterName && $0.status == "confirmed" }) else { return false }
        let data = try await download(assetID: poster.id, projectUUID: uuid)
        try data.write(to: model.projectFolderURL(for: capture).appendingPathComponent(ProjectFileRegistry.posterName), options: .atomic)
        model.noteFilesChanged(for: capture.id)
        model.noteIndexChanged()
        LLog("picplace: poster of \(row.name) (\(uuid.prefix(8))) fetched")
        return true
    }

    /// A delete made here, pushed: claim, delete (the server leaves a
    /// tombstone), forget the record.
    func deleteOnServer(_ originID: UUID) async throws {
        let uuid = originID.uuidString.lowercased()
        do {
            let _: [String: PPClaim] = try await client.post("projects/\(uuid)/claim", json: ["ttl_seconds": 300])
        } catch let error as PicPlaceAPIError where error.status == 404 || (error.status == 409 && error.code == "project_deleted") {
            records[originID] = nil
            return
        }
        struct Deleted: Decodable { var deleted: Bool? }
        let _: Deleted = try await client.delete("projects/\(uuid)")
        records[originID] = nil
        LLog("picplace: deleted \(uuid.prefix(8)) on the server")
    }

    // MARK: Resolutions

    /// Applies a person's decision to one conflict row.
    func resolve(_ conflict: Conflict, _ resolution: Resolution) async {
        var remaining = conflicts.filter { $0.id != conflict.id }
        defer { conflicts = remaining; saveSyncState() }
        do {
            switch (conflict.kind, resolution) {
            case (.deletedOnServer, .keepServer):
                // Delete here too.
                if let localID = conflict.localID, let capture = model.capture(id: localID) {
                    try model.deleteCapture(capture)
                    records[conflict.originID] = nil
                }
            case (.deletedOnServer, .keepLocal), (.deletedOnServer, .keepBoth):
                // Restore: the push resurrects the tombstone.
                if let localID = conflict.localID, let capture = model.capture(id: localID) {
                    model.markEdited(localID)
                    if let fresh = model.capture(id: localID) { await syncAndWait(fresh) } else { await syncAndWait(capture) }
                }
            case (.deletedHereEditedThere, .keepLocal):
                try await deleteOnServer(conflict.originID)
            case (.deletedHereEditedThere, .keepServer), (.deletedHereEditedThere, .keepBoth):
                // Bring the server's version back (a fresh pull; the local trash copy stays in the trash).
                let detail: PPProjectDetail = try await client.get("projects/\(conflict.originID.uuidString.lowercased())")
                try await pullReplacingTombstone(detail.project)
            case (.bothEdited, .keepLocal), (.unrelated, .keepLocal):
                if let localID = conflict.localID, let capture = model.capture(id: localID) {
                    // A fresh stamp, so the server accepts it and other devices see it move.
                    model.markEdited(localID)
                    if let fresh = model.capture(id: localID) { await syncAndWait(fresh) } else { await syncAndWait(capture) }
                    if let error = records[conflict.originID]?.lastError { throw PicPlaceSyncRun.Failed(caption: error) }
                }
            case (.bothEdited, .keepServer), (.unrelated, .keepServer):
                if let localID = conflict.localID, let capture = model.capture(id: localID) {
                    let detail: PPProjectDetail = try await client.get("projects/\(conflict.originID.uuidString.lowercased())")
                    try await pullUpdate(detail.project, into: capture)
                }
            case (.bothEdited, .keepBoth), (.unrelated, .keepBoth):
                if let localID = conflict.localID {
                    // This device's version becomes a fork; the original takes the server's.
                    let forkID = try model.forkProjectForKeepBoth(localID)
                    if let fork = model.capture(id: forkID) { await syncAndWait(fork) }
                    let detail: PPProjectDetail = try await client.get("projects/\(conflict.originID.uuidString.lowercased())")
                    try await pull(detail.project)
                }
            }
        } catch {
            LLog("picplace: resolving \(conflict.name) failed: \(error)")
            var failed = conflict
            failed.name = conflict.name
            remaining.append(failed)
            lastResolveError = "\(conflict.name): \(Self.describe(error))"
        }
    }

    /// "Use the most recent edit" for every open conflict.
    func resolveAllByNewest() async {
        for conflict in conflicts {
            let serverIsNewer: Bool
            switch conflict.kind {
            case .deletedOnServer: serverIsNewer = (conflict.serverEditedAt ?? .distantPast) > (conflict.localEditedAt ?? .distantPast)
            case .deletedHereEditedThere: serverIsNewer = true
            default: serverIsNewer = conflict.serverRevision > (conflict.localRevision ?? 0)
            }
            await resolve(conflict, serverIsNewer ? .keepServer : .keepLocal)
        }
    }

    /// A pull of a project whose trash folder this library still holds
    /// under the same id: the trash copy is moved aside first.
    private func pullReplacingTombstone(_ row: PPProject) async throws {
        guard let originID = UUID(uuidString: row.uuid) else { return }
        let trashed = model.trashURL.appendingPathComponent(originID.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: trashed.path) {
            let aside = model.trashURL.appendingPathComponent("\(originID.uuidString)-replaced-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
            try FileManager.default.moveItem(at: trashed, to: aside)
        }
        model.store.remove(id: originID)
        try await pull(row)
    }
}

import CryptoKit
import Foundation
import LetsLapseKit

/// Where a sync is: the card's caption and bar come from this.
struct PicPlaceSyncProgress: Equatable {
    /// `verifying` and `removing` are free up space's (2026-09-23): the
    /// file-by-file check with PicPlace, then the removal from this device.
    enum Phase: Equatable { case claiming, preparing, manifest, negotiating, uploading, confirming, finishing, downloading, verifying, removing }
    var phase: Phase = .claiming
    var filesDone = 0
    var filesTotal = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0

    var fraction: Double {
        guard bytesTotal > 0 else { return 0 }
        return min(1, Double(bytesDone) / Double(bytesTotal))
    }
}

/// What a finished sync recorded — the library's truth behind the card
/// (v2: `PicPlace/sync-state.json`, keyed by origin id). `revision` is the
/// merge base; the optional fields arrived with the minimal policy and are
/// absent on v1 records.
struct PicPlaceSyncRecord: Codable, Equatable {
    var syncedAt: Date
    var revision: Int
    /// Objects the sync accounted for (the bundle counts as one) and their bytes.
    var files: Int
    var bytes: Int64
    var uploaded: Int
    var alsoOn: [String]
    var server: String
    var lastError: String?
    /// The policy that produced the record (`minimal` · `originals` · `everything`).
    var policy: String?
    /// The heavy set — source frames and blends — that stayed on this device
    /// under the minimal policy, for the card's "originals stay here" line.
    var heavyFiles: Int?
    var heavyBytes: Int64?
    /// The grade token `poster.jpg` was rendered at; a different token means
    /// the poster is stale and is rendered again before the next push.
    var posterToken: String?
    /// Stage 5: the originals — source media and blends — this device last
    /// knew to be on the server (from the project detail), and when this
    /// device last uploaded or downloaded them.
    var serverHeavyFiles: Int?
    var serverHeavyBytes: Int64?
    var originalsMovedAt: Date?
    /// When a preview-only project last asked the server for a poster it
    /// lacks — asked again only once the server's row moved.
    var posterCheckedAt: Date?
    /// The index row's confirmed-asset count when this device last took
    /// the server's records (a pull, a pull-update). A different count
    /// means the server holds something this device has not fetched — the
    /// bundle and poster of a push that completed after the pull, or the
    /// originals — and the check fetches the records again.
    var serverConfirmedSeen: Int?
    /// The failure behind `lastError`: when, how many times in a row, and
    /// which policy was being sent. The check retries a failed push once
    /// `failedAt` plus the backoff for `failures` has passed; a person's
    /// own press ignores the wait.
    var failedAt: Date?
    var failures: Int?
    var failedPolicy: String?
    /// Stage C: the server holds this project in ANOTHER library of the
    /// account (uuid, and its name when known) — a departure notice, or a
    /// local twin of a project filed elsewhere. Nothing is pushed or pulled
    /// for it from this library; the card says where it is.
    var elsewhereLibrary: String?
    var elsewhereName: String?
    /// Free up space (2026-09-23): the heavy set here — every source file
    /// and blend, by path and size (`PicPlaceOriginalsCheck.digest`) — as it
    /// was when this device last saw PicPlace hold all of it, file by file:
    /// an originals push, or the check before a removal. A different set
    /// here now means something was added or rewritten since, and is not
    /// known to be on PicPlace. nil: never verified (a push from before).
    var heavyDigest: String?
    /// When this device last removed originals or blends PicPlace holds.
    var removedAt: Date?
    /// Heavy files here that PicPlace would not take because its confirmed
    /// copy at that path differs (a server that keeps originals immutable,
    /// free-up server asks round 2) — PicPlace keeps its own; the card says
    /// so and, where PicPlace's copy is provably the recorded original,
    /// offers to replace these with it. Set by the last originals push.
    var divergentFiles: [String]?
    /// Heavy files the last originals push found changed since
    /// `assets.ndjson` recorded them: they went up as they are now, and the
    /// card says so.
    var changedFiles: [String]?

    /// Whether the records — bundle and poster — of a push by THIS device
    /// reached the server: a record that has only ever failed has none.
    var recordsReachedServer: Bool { revision > 0 && (lastError == nil || failedPolicy == PicPlaceSyncPolicy.originals.rawValue) }

    /// When the failed push may be tried again on its own: three minutes
    /// after the first failure, doubling, an hour at most.
    var retryDueAt: Date? {
        guard lastError != nil, let failedAt else { return nil }
        let count = max(1, failures ?? 1)
        let wait = min(60 * 60, 3 * 60 * pow(2, Double(count - 1)))
        return failedAt.addingTimeInterval(wait)
    }

    mutating func noteFailure(_ caption: String, policy: PicPlaceSyncPolicy) {
        lastError = caption
        failedAt = Date()
        failures = (failures ?? 0) + 1
        failedPolicy = policy.rawValue
    }

    mutating func clearFailure() {
        lastError = nil
        failedAt = nil
        failures = nil
        failedPolicy = nil
    }
}

/// One push of one project (docs/picplace-sync-v1.md §2, v2 plan §4.2):
/// claim → manifest → negotiate what the policy sends → PUT straight to
/// storage → confirm → presence → release. Runs off the main actor; reports
/// progress back to it.
struct PicPlaceSyncRun {

    struct Project {
        /// The project's identity on the server — its `originID` (v2 plan D11).
        var serverID: UUID
        var folder: URL
        var name: String
        var type: String          // photo · interval · video
        var revision: Int
        var capturedAt: Date
        var policy: PicPlaceSyncPolicy
        /// `derivedFromOriginID`, for the server's `origin_uuid` (a fork's provenance).
        var originUUID: UUID?
        /// The server's inline-manifest cap (`limits.manifest_max_bytes`);
        /// 1 MB until a `/status` has reported one.
        var manifestMaxBytes: Int64
        /// What this device holds of the project, for presence: `original`
        /// when the sources are here, `preview` when only the poster is.
        var tier: String
        /// The library this device syncs (stage C): sent on a PUT that may
        /// CREATE the project — a first push, a resurrection — and never on
        /// an ordinary update, which would move a project back after another
        /// device moved it (agreed with the server, asks §6 Q2).
        var library: UUID?
    }

    struct Failed: LocalizedError {
        var caption: String
        var errorDescription: String? { caption }
    }

    struct FileItem {
        var name: String          // path within the project
        var kind: String
        var url: URL
        var bytes: Int64
        var sha256: String
        /// Hashed afresh and found different from what `assets.ndjson`
        /// recorded: the file changed since it was recorded.
        var changedSinceRecorded = false

        /// The item as a heavy file (a source frame or a blend), else nil —
        /// the heavy kinds are the check's own (`source`, `blend`).
        var heavyFile: PicPlaceOriginalsCheck.LocalFile? {
            guard let heavy = PicPlaceOriginalsCheck.Kind(rawValue: kind) else { return nil }
            return .init(name: name, kind: heavy, bytes: bytes, sha256: sha256)
        }
    }

    /// What the policy sends, and what it counted on the way.
    private struct Inventory {
        var files: [FileItem]
        var summary: PicPlaceSyncInventory.Summary
        /// The records bundle under `tmp/`, to remove when the run ends.
        var bundleURL: URL?
    }

    private struct PendingUpload {
        var item: FileItem
        var assetID: String
        var upload: PPUpload
    }

    /// What one PUT ended as.
    private struct Uploaded {
        var name: String
        var bytes: Int64
        var assetID: String
        var sha256: String
        /// The file no longer matched the hash `assets.ndjson` held: it went
        /// up under its fresh hash (storage refused the recorded one).
        var changed = false
        /// PicPlace refused it at the re-negotiation: its confirmed copy at
        /// this path differs and it keeps its own. Not uploaded.
        var divergent = false
    }

    let client: PicPlaceClient
    let project: Project
    let thisDeviceID: String?
    /// Where a file found changed since it was hashed gets its fresh record.
    var assetStore: AssetRecordStore? = nil
    let progress: @MainActor (PicPlaceSyncProgress) -> Void

    private static let batchSize = 100
    private static let concurrentUploads = 4
    private static let claimTTL = 3600
    private static let reclaimAfter: TimeInterval = 20 * 60

    private static let uploadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 6 * 3600
        config.httpMaximumConnectionsPerHost = concurrentUploads
        return URLSession(configuration: config)
    }()

    private var uuid: String { project.serverID.uuidString.lowercased() }

    func run() async throws -> PicPlaceSyncRecord {
        var state = PicPlaceSyncProgress()
        func report(_ change: (inout PicPlaceSyncProgress) -> Void) async {
            change(&state)
            let snapshot = state
            await progress(snapshot)
        }
        var bundleURL: URL?
        defer { if let bundleURL { try? FileManager.default.removeItem(at: bundleURL) } }

        // 1. The write claim. Held elsewhere → the card says who until when.
        // A project the server has never seen has nothing to claim yet: the
        // PUT below creates it and grants the claim to this device.
        await report { $0.phase = .claiming }
        var lastClaim = Date()
        var mayCreate = false
        do {
            let _: [String: PPClaim] = try await client.post("projects/\(uuid)/claim", json: ["ttl_seconds": Self.claimTTL])
        } catch let error as PicPlaceAPIError where error.status == 404 {
            // New to the server.
            mayCreate = true
        } catch let error as PicPlaceAPIError where error.status == 409 && error.code == "project_deleted" {
            // Tombstoned on the server: the PUT below resurrects it (a
            // device that still holds the project is pushing it on purpose).
            LLog("picplace: \(uuid) is a tombstone on the server — the push resurrects it")
            mayCreate = true
        }

        do {
            // 2. What the policy sends, with hashes (assets.ndjson first,
            // computed otherwise); the records bundle is built here.
            await report { $0.phase = .preparing }
            let inventory = try await Self.inventory(of: project.folder, policy: project.policy)
            bundleURL = inventory.bundleURL
            var files = inventory.files
            try Task.checkCancellation()

            // Copies PicPlace refuses to replace (its write-once rule for
            // confirmed originals — a per-server switch, off until every
            // device runs a build whose originals never change) are named
            // here. Rotate 90° no longer writes to a file (a record since
            // 2026-09-24); a re-conversion and a scan re-correction still
            // rewrite theirs in place (TODO "Rotate 90° as a project record",
            // the write-once companions) and are what would be refused.
            var divergent: [String] = []
            let totalBytes = files.reduce(Int64(0)) { $0 + $1.bytes }
            await report { $0.filesTotal = files.count; $0.bytesTotal = totalBytes }

            // 3. The manifest: project.json verbatim, with the index fields
            // beside it — inline under the server's cap, as a `manifest`
            // asset over it (the server's own overflow shape).
            await report { $0.phase = .manifest }
            let documentURL = project.folder.appendingPathComponent(ProjectFileRegistry.projectDocumentName)
            let manifest = try Self.sharedManifest(Data(contentsOf: documentURL))
            let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes])
            // The overflow asset is the sent document, written beside the bundle.
            let manifestURL = project.folder.appendingPathComponent("tmp/\(ProjectFileRegistry.projectDocumentName)")
            var body: [String: Any] = [
                "name": project.name,
                "type": project.type,
                "revision": project.revision,
                "captured_at": ISO8601DateFormatter().string(from: project.capturedAt),
            ]
            if let origin = project.originUUID { body["origin_uuid"] = origin.uuidString.lowercased() }
            if mayCreate, let library = project.library { body["library"] = library.uuidString.lowercased() }
            let compactBytes = Int64((try? JSONSerialization.data(withJSONObject: manifest, options: [.withoutEscapingSlashes]).count) ?? manifestData.count)
            if compactBytes <= project.manifestMaxBytes {
                body["manifest"] = manifest
                let _: [String: PPProject] = try await client.put("projects/\(uuid)", json: body)
            } else {
                // A first PUT (a stub) creates the project and grants the
                // claim the upload needs; the second carries the asset's id.
                LLog("picplace: manifest of \(uuid) is \(compactBytes) bytes, over the \(project.manifestMaxBytes)-byte cap — sending it as an asset")
                body["manifest"] = ["manifest_asset": NSNull()]
                let _: [String: PPProject] = try await client.put("projects/\(uuid)", json: body)
                try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manifestData.write(to: manifestURL, options: .atomic)
                let item = FileItem(name: ProjectFileRegistry.projectDocumentName, kind: "manifest", url: manifestURL,
                                    bytes: Int64(manifestData.count), sha256: try Self.sha256(of: manifestURL))
                let negotiated: [String: [PPNegotiation]] = try await client.post("projects/\(uuid)/assets", json: ["assets": [Self.negotiateFields(item)]])
                guard let result = negotiated["assets"]?.first, let manifestAsset = result.asset else {
                    throw Failed(caption: negotiated["assets"]?.first?.message ?? "PicPlace did not negotiate the manifest.")
                }
                if let upload = result.upload {
                    let sent = try await self.upload(PendingUpload(item: item, assetID: manifestAsset.id, upload: upload))
                    let confirmed: [String: [PPConfirmResult]] = try await client.post("projects/\(uuid)/assets/confirm", json: ["assets": [["id": sent.assetID, "sha256": sent.sha256]]])
                    if let failure = (confirmed["assets"] ?? []).first(where: { $0.error != nil }) {
                        throw Failed(caption: failure.message ?? failure.error!)
                    }
                }
                body["manifest"] = ["manifest_asset": manifestAsset.id]
                let _: [String: PPProject] = try await client.put("projects/\(uuid)", json: body)
            }

            // 4. Negotiate in batches; unchanged files come back without an
            //    upload. An original PicPlace will not replace — its confirmed
            //    copy at that path differs (free-up server asks, round 2 Q2) —
            //    is set aside and named on the record: not a failed push to
            //    retry, a difference for the person to see.
            await report { $0.phase = .negotiating }
            var pending: [PendingUpload] = []
            // Heavy files whose PicPlace copy has not been read back yet
            // (`verified`): the set's marker waits for them.
            var unverifiedHeavy = Set<String>()
            for batch in files.chunked(Self.batchSize) {
                try Task.checkCancellation()
                lastClaim = try await reclaimIfStale(lastClaim)
                let request: [String: Any] = ["assets": batch.map(Self.negotiateFields)]
                let response: [String: [PPNegotiation]] = try await client.post("projects/\(uuid)/assets", json: request)
                let results = response["assets"] ?? []
                for (item, result) in zip(batch, results) {
                    if let error = result.error {
                        if PPNegotiation.isImmutableRefusal(error), item.heavyFile != nil {
                            divergent.append(item.name)
                            await report { $0.filesDone += 1; $0.bytesDone += item.bytes }
                            continue
                        }
                        throw Failed(caption: "\(item.name): \(result.message ?? error)")
                    }
                    guard let asset = result.asset else { throw Failed(caption: "PicPlace did not negotiate \(item.name).") }
                    if let upload = result.upload {
                        pending.append(PendingUpload(item: item, assetID: asset.id, upload: upload))
                    } else {
                        if item.heavyFile != nil, asset.verified != true { unverifiedHeavy.insert(item.name) }
                        await report { $0.filesDone += 1; $0.bytesDone += item.bytes }
                    }
                }
            }

            // 5. PUT straight to object storage, a few at a time, exactly the headers the server signed.
            await report { $0.phase = .uploading }
            var uploaded: [Uploaded] = []
            try await withThrowingTaskGroup(of: Uploaded.self) { group in
                var iterator = pending.makeIterator()
                var inFlight = 0
                func enqueue() {
                    guard let next = iterator.next() else { return }
                    inFlight += 1
                    group.addTask { try await self.upload(next) }
                }
                for _ in 0 ..< Self.concurrentUploads { enqueue() }
                while inFlight > 0 {
                    let done = try await group.next()!
                    inFlight -= 1
                    uploaded.append(done)
                    await report { $0.filesDone += 1; $0.bytesDone += done.bytes }
                    try Task.checkCancellation()
                    enqueue()
                }
            }
            divergent += uploaded.filter(\.divergent).map(\.name)
            // A file that had changed since it was recorded — seen before the
            // upload (hashed afresh) or after storage refused its recorded
            // hash — went up as it is now, unless PicPlace kept its own copy:
            // its record follows, so the next look trusts it again.
            let rehashed = Dictionary(uploaded.filter(\.changed).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            var changedHashes: [(name: String, bytes: Int64, sha256: String)] = []
            for item in files where item.heavyFile != nil {
                if let file = rehashed[item.name] {
                    changedHashes.append((file.name, file.bytes, file.sha256))
                } else if item.changedSinceRecorded {
                    changedHashes.append((item.name, item.bytes, item.sha256))
                }
            }
            // Not for a copy PicPlace kept its own of: that record is the
            // capture-time witness the card's Replace is judged by.
            let divergentNames = Set(divergent)
            changedHashes.removeAll { divergentNames.contains($0.name) }
            try? assetStore?.noteHashes(changedHashes, inProjectFolder: project.folder)
            let changed = changedHashes.map(\.name)
            if !changed.isEmpty {
                LLog("picplace: \(project.name) — \(changed.count) file(s) had changed since they were recorded and went up as they are now: \(changed.prefix(5).joined(separator: ", "))")
            }
            if !divergent.isEmpty {
                LLog("picplace: \(project.name) — \(divergent.count) original(s) here differ from PicPlace's confirmed copies; PicPlace keeps its own: \(divergent.prefix(5).joined(separator: ", "))\(divergent.count > 5 ? ", …" : "")")
            }

            // 6. Confirm in batches; the server checks each object's size and records it.
            await report { $0.phase = .confirming }
            var failures: [String] = []
            var confirmations: [(id: String, sha256: String)] = uploaded.filter { !$0.divergent }.map { ($0.assetID, $0.sha256) }
            let heavyNames = Set(files.filter { $0.heavyFile != nil }.map(\.name))
            let heavyByAssetID = Dictionary(
                uploaded.filter { !$0.divergent && heavyNames.contains($0.name) }.map { ($0.assetID, $0.name) },
                uniquingKeysWith: { first, _ in first })
            for batch in confirmations.chunked(Self.batchSize) {
                try Task.checkCancellation()
                lastClaim = try await reclaimIfStale(lastClaim)
                let request: [String: Any] = ["assets": batch.map { ["id": $0.id, "sha256": $0.sha256] }]
                let response: [String: [PPConfirmResult]] = try await client.post("projects/\(uuid)/assets/confirm", json: request)
                for result in response["assets"] ?? [] {
                    if let error = result.error {
                        failures.append(result.message ?? error)
                    } else if let name = heavyByAssetID[result.id], result.asset?.verified != true {
                        // picplace.co reads it back within a minute or two.
                        unverifiedHeavy.insert(name)
                    }
                }
            }
            confirmations.removeAll()
            if !failures.isEmpty {
                throw Failed(caption: failures.count == 1 ? failures[0] : "\(failures.count) files could not be confirmed")
            }

            // 7. Presence, then let go of the claim.
            await report { $0.phase = .finishing }
            let presence: [String: [PPPresence]] = try await client.post("projects/\(uuid)/presence", json: ["revision": project.revision, "tier": project.tier])
            let alsoOn = (presence["presence"] ?? [])
                .compactMap(\.device)
                .filter { $0.id != thisDeviceID }
                .map(\.name)
            // Best effort: the push is complete; a claim this device could
            // not release expires on its own and this device may re-claim it.
            let _: [String: PPClaim?]? = try? await client.delete("projects/\(uuid)/claim")

            var record = PicPlaceSyncRecord(syncedAt: Date(), revision: project.revision, files: files.count, bytes: totalBytes,
                                            uploaded: pending.count, alsoOn: alsoOn,
                                            server: (try? await client.currentTokens().server) ?? PicPlaceConfiguration.serverString, lastError: nil,
                                            policy: project.policy.rawValue,
                                            heavyFiles: project.policy.sendsHeavy ? 0 : inventory.summary.heavyFiles,
                                            heavyBytes: project.policy.sendsHeavy ? 0 : inventory.summary.heavyBytes)
            // Every heavy file here was negotiated by hash and is confirmed
            // (uploaded now, or already there): the set's marker — unless
            // PicPlace kept its own copy of some, which then differ, or has
            // yet to read some back (`verified`; the originals queue's next
            // look writes it once PicPlace has).
            if project.policy.sendsHeavy {
                if !unverifiedHeavy.isEmpty {
                    LLog("picplace: \(project.name) — \(unverifiedHeavy.count) original(s) confirmed, PicPlace still checking them")
                }
                record.heavyDigest = divergent.isEmpty && unverifiedHeavy.isEmpty
                    ? PicPlaceOriginalsCheck.digest(files.compactMap(\.heavyFile)) : nil
                record.divergentFiles = divergent.isEmpty ? nil : divergent
                record.changedFiles = changed.isEmpty ? nil : changed
            }
            return record
        } catch {
            // Whatever happened, do not leave the project locked for the next device.
            let _: [String: PPClaim?]? = try? await client.delete("projects/\(uuid)/claim")
            throw error
        }
    }

    private func reclaimIfStale(_ lastClaim: Date) async throws -> Date {
        guard Date().timeIntervalSince(lastClaim) > Self.reclaimAfter else { return lastClaim }
        let _: [String: PPClaim] = try await client.post("projects/\(uuid)/claim", json: ["ttl_seconds": Self.claimTTL])
        return Date()
    }

    /// PUT one file to its presigned URL. A URL that expired mid-run is
    /// re-negotiated once. A `400` from storage — once PicPlace signs the
    /// declared SHA-256 into the URL (free-up server asks, Ask 1), storage
    /// refusing bytes that do not hash to what was declared — re-hashes the
    /// file once: a file that changed since `assets.ndjson` recorded it is
    /// negotiated again under its fresh hash and goes up as it is now
    /// (`changed`, which the card reports); one that still matches was
    /// refused for another reason, which is the failure.
    private func upload(_ pending: PendingUpload, retrying: Bool = false, rehashed: Bool = false) async throws -> Uploaded {
        var request = URLRequest(url: URL(string: pending.upload.url)!)
        request.httpMethod = pending.upload.method
        for (name, value) in pending.upload.headers where name.lowercased() != "host" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response): (Data, URLResponse)
        do {
            // A dropped connection or a 5xx from storage goes again
            // (`PicPlaceTransfer`); the body is a file, so the same bytes
            // are sent each time.
            (data, response) = try await PicPlaceTransfer.withRetries("PUT \(pending.item.name)") {
                let (data, response) = try await Self.uploadSession.upload(for: request, fromFile: pending.item.url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 429 || (500 ..< 600).contains(status) {
                    throw PicPlaceTransfer.Refused(status: status, detail: String(data: data, encoding: .utf8).map { String($0.prefix(120)) } ?? "")
                }
                return (data, response)
            }
        } catch let refused as PicPlaceTransfer.Refused {
            throw Failed(caption: "Storage refused \(pending.item.name) (\(refused.status)) \(refused.detail)")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failed(caption: "Upload of \(pending.item.name) failed: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        #if DEBUG
        let forced400 = PicPlaceTransfer.forcesBadDigest(pending.item.name, rehashed: rehashed)
        #else
        let forced400 = false
        #endif
        if (200 ..< 300).contains(status), !forced400 {
            return Uploaded(name: pending.item.name, bytes: pending.item.bytes, assetID: pending.assetID,
                            sha256: pending.item.sha256, changed: rehashed)
        }
        if status == 403, !retrying, Date() >= pending.upload.expiresAt.addingTimeInterval(-60) {
            let fresh: [String: [PPNegotiation]] = try await client.post("projects/\(uuid)/assets", json: ["assets": [Self.negotiateFields(pending.item)]])
            if let upload = fresh["assets"]?.first?.upload {
                return try await self.upload(PendingUpload(item: pending.item, assetID: pending.assetID, upload: upload), retrying: true, rehashed: rehashed)
            }
        }
        if status == 400 || forced400, !rehashed {
            let url = pending.item.url
            let fresh = try await Task.detached(priority: .utility) { try Self.sha256(of: url) }.value
            if fresh != pending.item.sha256 {
                LLog("picplace: storage refused \(pending.item.name) — it no longer matches its recorded hash (\(pending.item.sha256.prefix(8)) → \(fresh.prefix(8))); sending it as it is now")
                var item = pending.item
                item.sha256 = fresh
                let negotiated: [String: [PPNegotiation]] = try await client.post("projects/\(uuid)/assets", json: ["assets": [Self.negotiateFields(item)]])
                guard let result = negotiated["assets"]?.first else { throw Failed(caption: "PicPlace did not negotiate \(item.name).") }
                if let error = result.error {
                    if PPNegotiation.isImmutableRefusal(error) {
                        return Uploaded(name: item.name, bytes: item.bytes, assetID: pending.assetID, sha256: fresh, changed: true, divergent: true)
                    }
                    throw Failed(caption: "\(item.name): \(result.message ?? error)")
                }
                guard let asset = result.asset else { throw Failed(caption: "PicPlace did not negotiate \(item.name).") }
                guard let upload = result.upload else {
                    // PicPlace already holds these exact bytes.
                    return Uploaded(name: item.name, bytes: item.bytes, assetID: asset.id, sha256: fresh, changed: true)
                }
                return try await self.upload(PendingUpload(item: item, assetID: asset.id, upload: upload), rehashed: true)
            }
            LLog("picplace: storage refused \(pending.item.name) (400) though it still matches its hash")
        }
        let detail = String(data: data, encoding: .utf8).map { $0.prefix(120) } ?? ""
        throw Failed(caption: "Storage refused \(pending.item.name) (\(forced400 ? 400 : status)) \(detail)")
    }

    // MARK: The folder

    static func negotiateFields(_ item: FileItem) -> [String: Any] {
        let fields: [String: Any?] = ["kind": item.kind, "name": item.name, "bytes": item.bytes, "sha256": item.sha256,
                                      "content_type": item.name == PicPlaceSyncInventory.bundleName
                                          ? PicPlaceSyncInventory.bundleContentType : contentType(for: item.url)]
        return fields.compactMapValues { $0 }
    }

    /// The objects the policy sends (v2 plan §3.4): every regular file under
    /// the project folder, classified by `ProjectFileRegistry` — the records
    /// and sidecars into one `records.aar`, the poster as its own object,
    /// the source frames and the blends as the heavy set —
    /// hashed from `assets.ndjson` where it has the file at that size and
    /// computed otherwise. Strays (files the table does not know) are logged
    /// and left.
    private static func inventory(of folder: URL, policy: PicPlaceSyncPolicy) async throws -> Inventory {
        let records = AssetRecords.load(inProjectFolder: folder)
        let items = PicPlaceSyncInventory.classify(try listFiles(in: folder))
        let summary = PicPlaceSyncInventory.summary(of: items, policy: policy)
        for stray in summary.strays { LLog("picplace: \(folder.lastPathComponent)/\(stray) is not a project file that travels — left out") }

        func hashed(_ item: PicPlaceSyncItem, kind: String) async throws -> FileItem {
            let sha: String
            var changed = false
            if let recorded = recordedHash(records[item.relativePath], url: item.url, bytes: item.bytes) {
                sha = recorded
            } else {
                let url = item.url
                sha = try await Task.detached(priority: .utility) { try sha256(of: url) }.value
                // A record that no longer describes the file: it changed
                // after it was recorded, and the run says so.
                if let old = PicPlaceOriginalsCheck.normalized(records[item.relativePath]?.hash), old != sha { changed = true }
            }
            return FileItem(name: item.relativePath, kind: kind, url: item.url, bytes: item.bytes, sha256: sha, changedSinceRecorded: changed)
        }

        var files: [FileItem] = []
        var bundleURL: URL?
        for item in items {
            switch item.role {
            case .object(let kind) where policy.sendsRecords:
                files.append(try await hashed(item, kind: kind))
            case .heavy(let kind) where policy.sendsHeavy:
                files.append(try await hashed(item, kind: kind))
            default:
                continue
            }
            try Task.checkCancellation()
        }
        if policy.sendsRecords {
            let members = items.filter { $0.role == .bundle }
            if !members.isEmpty {
                let archive = try await Task.detached(priority: .utility) {
                    try PicPlaceSyncInventory.buildBundle(members: members, in: folder)
                }.value
                let bytes = Int64((try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                let sha = try await Task.detached(priority: .utility) { try sha256(of: archive) }.value
                files.append(FileItem(name: PicPlaceSyncInventory.bundleName, kind: PicPlaceSyncInventory.bundleKind,
                                      url: archive, bytes: bytes, sha256: sha))
                bundleURL = archive
                LLog("picplace: records bundle for \(folder.lastPathComponent): \(members.count) members → \(bytes) bytes")
            }
        }
        return Inventory(files: files.sorted { $0.name < $1.name }, summary: summary, bundleURL: bundleURL)
    }

    struct FolderEntry {
        var name: String
        var url: URL
        var bytes: Int64
    }

    /// The project folder's regular files, keyed by their path within it —
    /// synchronous, because `DirectoryEnumerator` cannot be driven from an
    /// async context. Shared with the controller's folder summary. What each
    /// file IS is `PicPlaceSyncInventory.classify`'s to say.
    static func listFiles(in folder: URL) throws -> [FolderEntry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var entries: [FolderEntry] = []
        let base = folder.standardizedFileURL.path
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            let top = relative.split(separator: "/").first.map(String.init) ?? relative
            if top == "tmp" || top == ".trash" { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            entries.append(FolderEntry(name: relative, url: url, bytes: Int64(values.fileSize ?? 0)))
        }
        return entries
    }

    /// The hash `assets.ndjson` recorded for a file, while it still
    /// describes the file: the same size, and not modified after it was
    /// hashed (two seconds' grace). nil: hash the file now. The one rule the
    /// push, the originals queue and the free-up check share — a file
    /// rewritten in place at its old size would otherwise be declared under
    /// a stale hash (refused by storage once PicPlace signs it) and pass a
    /// removal's check.
    /// The project document as it goes to PicPlace: this device's own
    /// measurement of its folder (`capture.sizeBytes`, `sizeMeasuredAt` —
    /// the Projects list's size sort) left out. It describes this device's
    /// copy, not the project: a phone holding previews measures megabytes
    /// where one holding the originals measures gigabytes, and shared it
    /// would overwrite each device's number with another's (the PicPlace
    /// developer's catch, 2026-09-24). A pull keeps this device's
    /// (`AppModel.applyPulledUpdate`).
    static let deviceOnlyCaptureKeys = ["sizeBytes", "sizeMeasuredAt"]

    static func sharedManifest(_ data: Data) throws -> [String: Any] {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failed(caption: "The project document is not a JSON object.")
        }
        if var capture = object["capture"] as? [String: Any] {
            for key in deviceOnlyCaptureKeys { capture[key] = nil }
            object["capture"] = capture
        }
        return object
    }

    static func recordedHash(_ record: AssetRecord?, url: URL, bytes: Int64) -> String? {
        guard let record, record.bytes == bytes, let hash = PicPlaceOriginalsCheck.normalized(record.hash) else { return nil }
        if let hashedAt = record.hashedAt,
           let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           modified > hashedAt.addingTimeInterval(2) {
            return nil
        }
        return hash
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 4 * 1024 * 1024)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func contentType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "dng": return "image/x-adobe-dng"
        case "arw": return "image/x-sony-arw"
        case "mov": return "video/quicktime"
        case "mp4": return "video/mp4"
        case "json", "ndjson": return "application/json"
        case "aar": return "application/octet-stream"
        case "cube", "timestamps", "exposure", "whitebalance", "log", "txt", "gpx", "xmp": return "text/plain"
        default: return nil
        }
    }
}



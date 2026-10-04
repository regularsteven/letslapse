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
    /// The device the files come from, when it is a nearby one, not
    /// PicPlace ("iPhone 18 Pro") — the words say *Importing* then.
    var source: String?

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
    /// Of `alsoOn`, the devices PicPlace's presence says hold the originals,
    /// freshest first (2026-09-28). nil on a record from before: fall back
    /// to `alsoOn`.
    var originalsOn: [String]?
    var server: String
    var lastError: String?
    /// The policy that produced the record (`minimal` · `originals` ·
    /// `everything` · `blends`).
    var policy: String?
    /// The blends last seen on PicPlace by path and size, confirmed — the
    /// blends queue's "already there" (D1, 2026-09-25). Never the removal
    /// gate: that is `heavyDigest`, which a blends-only run leaves alone.
    var blendsDigest: String?
    /// The heavy set — source frames and blends — that stayed on this device
    /// under the minimal policy, for the card's "originals stay here" line.
    var heavyFiles: Int?
    var heavyBytes: Int64?
    /// The grade token `poster.jpg` was rendered at; a different token means
    /// the poster is stale and is rendered again before the next push.
    var posterToken: String?
    /// Picture tiers (docs/picture-tiers-plan.md §3.4): the proxy token the
    /// full-size working copy on PicPlace was rendered at (`PhotoGrade.proxyToken`,
    /// the crop left out), and when this device last opened the editor on a
    /// working copy it holds — the free-up rule's clock. nil until stage 1.
    var proxyToken: String?
    var workingCopyUsedAt: Date?
    /// The SHA-256 of the server's tile this device last wrote beside the
    /// poster (stage 2); the check fetches the row's tile when it differs.
    var tileSHA256: String?
    /// The SHA-256 of the poster this device last took from PicPlace: a
    /// confirmed-count move whose row names the same poster costs no poster
    /// fetch and, from the listing, no hashing (the developer's ask,
    /// 2026-10-03).
    var posterSHA256: String?
    /// Stage 5: the originals — source media and blends — this device last
    /// knew to be on the server (from the project detail), and when this
    /// device last uploaded or downloaded them.
    var serverHeavyFiles: Int?
    var serverHeavyBytes: Int64?
    /// Of those, the source media — the originals proper, without the
    /// blends (2026-09-25): what *Download available* means. nil on a record
    /// from before, which then falls back to the heavy count.
    var serverSourceFiles: Int?
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
    /// The index row's own accounted count (`PPProject.accountedConfirmed`)
    /// when this device last took or settled the records (2026-10-03): the
    /// move test compares the row with THIS, never with the listing's count
    /// — the row subtracts one working copy by its pointer while a listing
    /// leaves every copy out, so a project with two copies on PicPlace read
    /// as moved on every check and fetched its records each time (the Mac,
    /// three projects a check).
    var serverRowAccounted: Int?
    /// When the check last re-sent a poster PicPlace's row said it lacked
    /// (2026-10-03): once per `posterResendInterval` per project.
    var posterResentAt: Date?
    static let posterResendInterval: TimeInterval = 6 * 3600
    /// When a push last failed to render the poster here (2026-10-04: two
    /// DNG projects the iPad could not decode were queued as poster
    /// catch-ups on every 3-minute check, each PUT moving the sequence for
    /// every device) — the check asks again after `posterResendInterval`,
    /// and an edit's push, which renders anyway, clears it.
    var posterFailedAt: Date?
    /// A render failed here recently: the check does not queue a poster for
    /// it until the interval has passed.
    var posterFailedRecently: Bool {
        posterFailedAt.map { Date().timeIntervalSince($0) < Self.posterResendInterval } ?? false
    }
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
    /// A heavy push ended with every file confirmed and PicPlace still
    /// reading some back (2026-09-26): the pill says *checking*, not *needs
    /// uploading*, until the look right after the upload
    /// (`verifyAfterUpload`) or the blends queue's whole look writes the
    /// marker — or `verifyWindow` passes. nil: nothing waiting.
    var verifyPendingSince: Date?
    /// How long a push's *checking* lasts before the markers speak alone.
    static let verifyWindow: TimeInterval = 30 * 60
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
    var recordsReachedServer: Bool { revision > 0 && (lastError == nil || failedHeavyOnly) }

    /// The device to name in "only on … for now": one that holds the
    /// originals, else — on a record from before tiers were read — the
    /// first other device, as it always was. nil: none known.
    var originalsHolder: String? {
        guard let originalsOn else { return alsoOn.first }
        return originalsOn.first
    }

    /// Both lists from one presence answer.
    mutating func notePresence(_ presence: [PPPresence], excluding deviceID: String?) {
        alsoOn = presence.otherDeviceNames(excluding: deviceID)
        originalsOn = presence.originalsHolders(excluding: deviceID)
    }

    /// The failure on record was a heavy upload's — the originals, or the
    /// blends alone (D1) — which leaves the records where the last push put
    /// them.
    var failedHeavyOnly: Bool {
        failedPolicy == PicPlaceSyncPolicy.originals.rawValue || failedPolicy == PicPlaceSyncPolicy.blends.rawValue
    }

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
        /// The capture month in the person's calendar (`YYYY-MM`), sent on
        /// every PUT from push 2 (picture tiers §A); nil before it.
        var bucket: String? = nil
        /// The id of the working copy PicPlace holds under another name —
        /// a re-grade's old copy — named as `replaces` on the new copy's
        /// negotiate so it is retired when the new one confirms (2026-10-03:
        /// without it every re-grade left one more copy on the server, and
        /// every other device's count read as moved on each check).
        var replacesProxy: String? = nil
        /// `features.md5_uploads` (sync-cost step 2): every file the run
        /// sends declares its MD5 at negotiate, so the PUT carries
        /// `Content-MD5` and confirm verifies it without a read-back.
        var md5Uploads: Bool = false
        /// `features.records_inline` (§B, 2026-10-04): the PUT carries
        /// `metadata.json` and `assets.ndjson` as JSON beside the manifest,
        /// under `recordsMaxBytes` as stored — the server folds them into
        /// its index at once. The bundle still carries them.
        var recordsInline: Bool = false
        var recordsMaxBytes: Int64 = 8 * 1024 * 1024
    }

    struct Failed: LocalizedError {
        var caption: String
        /// A lost connection or busy storage, not a refusal: an upload job
        /// takes it as an interruption and goes again on its own.
        var interrupted = false
        var errorDescription: String? { caption }
    }

    /// The run stopped between files because it was asked to — a person's
    /// Pause, Wi-Fi lost with Wi-Fi only on. Everything that had finished was
    /// confirmed first, so the next run finds it unchanged and sends only
    /// what is left. Not a failure.
    struct Paused: Error {}

    struct FileItem {
        var name: String          // path within the project
        var kind: String
        var url: URL
        var bytes: Int64
        var sha256: String
        /// Hashed afresh and found different from what `assets.ndjson`
        /// recorded: the file changed since it was recorded.
        var changedSinceRecorded = false
        /// A confirmed asset of the same project and kind this one retires
        /// when it confirms (`replaces`, push 2) — a re-grade's old copy.
        var replaces: String?
        /// MD5 of the bytes (sync-cost step 2), from the same read as the
        /// SHA-256 when the file was hashed here; nil when the SHA-256 came
        /// from `assets.ndjson` (no read) — declared before the PUT then.
        var md5: String?

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

    /// What the upload group hears: a file done, or the stop signal.
    private enum UploadEvent {
        case done(Uploaded)
        case stopRequested
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
    /// A pause request, read between files (an originals upload's job).
    var stop: PicPlaceStopSignal? = nil
    let progress: @MainActor (PicPlaceSyncProgress) -> Void

    private static let batchSize = 100
    private static let concurrentUploads = 4
    /// Finished files are confirmed this many at a time while the upload
    /// runs, so an interruption costs at most this many plus those in flight.
    private static let confirmEvery = 8
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
        // The PUT says so in as many words (`"resurrect": true`, sync-cost
        // step 2): a server with `resurrect_required` refuses any other PUT
        // on a tombstone. The check decides which pushes of a deleted
        // project reach here at all (a deliberate import or restore wins;
        // every other push follows the deletion).
        var resurrects = false
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
            resurrects = true
        }

        do {
            // 2. What the policy sends, with hashes (assets.ndjson first,
            // computed otherwise); the records bundle is built here.
            await report { $0.phase = .preparing }
            var inventory = try await Self.inventory(of: project.folder, policy: project.policy)
            if let old = project.replacesProxy, let index = inventory.files.firstIndex(where: { $0.kind == PicPlaceSyncInventory.proxyKind }) {
                inventory.files[index].replaces = old
            }
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
            if let bucket = project.bucket { body["bucket"] = bucket }
            if resurrects { body["resurrect"] = true }
            if let origin = project.originUUID { body["origin_uuid"] = origin.uuidString.lowercased() }
            if mayCreate, let library = project.library { body["library"] = library.uuidString.lowercased() }
            // The records inline (§B): both documents as JSON, verbatim from
            // disk, when the server takes them and they fit its cap; `null`
            // when neither file exists. A `413 records_too_large` — the whole
            // PUT refused, nothing written — goes again without them, and
            // the bundle carries them as it always has.
            if project.recordsInline, let records = Self.inlineRecords(in: project.folder, cap: project.recordsMaxBytes) {
                body["records"] = records.value
                if records.bytes > 0 { LLog("picplace: \(project.name) — records inline: \(records.assets) asset record(s), \(records.bytes) bytes") }
            }
            func putProject(_ body: [String: Any]) async throws {
                do {
                    let _: [String: PPProject] = try await client.put("projects/\(uuid)", json: body)
                } catch let error as PicPlaceAPIError where error.status == 413 && error.code == "records_too_large" && body["records"] != nil {
                    LLog("picplace: \(project.name) — PicPlace refused the inline records as too large; sent again without them (the bundle carries them)")
                    var slim = body
                    slim["records"] = nil
                    let _: [String: PPProject] = try await client.put("projects/\(uuid)", json: slim)
                }
            }
            let compactBytes = Int64((try? JSONSerialization.data(withJSONObject: manifest, options: [.withoutEscapingSlashes]).count) ?? manifestData.count)
            if compactBytes <= project.manifestMaxBytes {
                body["manifest"] = manifest
                try await putProject(body)
            } else {
                // A first PUT (a stub) creates the project and grants the
                // claim the upload needs; the second carries the asset's id.
                LLog("picplace: manifest of \(uuid) is \(compactBytes) bytes, over the \(project.manifestMaxBytes)-byte cap — sending it as an asset")
                body["manifest"] = ["manifest_asset": NSNull()]
                try await putProject(body)
                try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manifestData.write(to: manifestURL, options: .atomic)
                let manifestHashes = try Self.hashes(of: manifestURL)
                let item = FileItem(name: ProjectFileRegistry.projectDocumentName, kind: "manifest", url: manifestURL,
                                    bytes: Int64(manifestData.count), sha256: manifestHashes.sha256, md5: project.md5Uploads ? manifestHashes.md5 : nil)
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
            // Old copies this run names as `replaces` (a re-grade's working
            // copy), by the new asset's id — retired by hand after the
            // confirms when PicPlace did not say it retired them (2026-10-03:
            // the per-project negotiate does not pass `replaces` on, only
            // the batch one does; the claim this run holds lets it DELETE).
            var toRetire: [String: String] = [:]
            var retireNames: [String: String] = [:]
            for batch in files.chunked(Self.batchSize) {
                try Task.checkCancellation()
                lastClaim = try await reclaimIfStale(lastClaim)
                let request: [String: Any] = ["assets": batch.map(Self.negotiateFields)]
                let response: [String: [PPNegotiation]] = try await client.post("projects/\(uuid)/assets", json: request)
                let results = response["assets"] ?? []
                for (item, var result) in zip(batch, results) {
                    if result.error == "replaces_not_found", item.replaces != nil {
                        // The old working copy this one was to retire is
                        // already gone (another device's sweep, a stale
                        // pointer): the item goes again on its own.
                        var plain = item
                        plain.replaces = nil
                        let again: [String: [PPNegotiation]] = try await client.post("projects/\(uuid)/assets", json: ["assets": [Self.negotiateFields(plain)]])
                        guard let retried = again["assets"]?.first else { throw Failed(caption: "PicPlace did not negotiate \(item.name).") }
                        result = retried
                    }
                    if let error = result.error {
                        if PPNegotiation.isImmutableRefusal(error), item.heavyFile != nil {
                            divergent.append(item.name)
                            await report { $0.filesDone += 1; $0.bytesDone += item.bytes }
                            continue
                        }
                        throw Failed(caption: "\(item.name): \(result.message ?? error)")
                    }
                    guard let asset = result.asset else { throw Failed(caption: "PicPlace did not negotiate \(item.name).") }
                    if let old = item.replaces, old != asset.id {
                        toRetire[asset.id] = old
                        retireNames[old] = item.name
                    }
                    if let upload = result.upload {
                        pending.append(PendingUpload(item: item, assetID: asset.id, upload: upload))
                    } else {
                        if item.heavyFile != nil, asset.verified != true { unverifiedHeavy.insert(item.name) }
                        await report { $0.filesDone += 1; $0.bytesDone += item.bytes }
                    }
                }
            }

            // 4b. The MD5 of every file about to go (sync-cost step 2): a
            //    file hashed from `assets.ndjson` was never read here, so it
            //    is read once now and negotiated again with its `md5` —
            //    PicPlace signs `Content-MD5` into the fresh URL and confirm
            //    verifies the object without a read-back. A re-sync, where
            //    nothing is pending, reads nothing.
            if project.md5Uploads {
                let undeclared = pending.indices.filter { pending[$0].item.md5 == nil }
                if !undeclared.isEmpty {
                    for index in undeclared {
                        let url = pending[index].item.url
                        pending[index].item.md5 = try await Task.detached(priority: .utility) { try Self.hashes(of: url).md5 }.value
                    }
                    for chunk in undeclared.chunked(Self.batchSize) {
                        try Task.checkCancellation()
                        lastClaim = try await reclaimIfStale(lastClaim)
                        let request: [String: Any] = ["assets": chunk.map { Self.negotiateFields(pending[$0].item) }]
                        let response: [String: [PPNegotiation]] = try await client.post("projects/\(uuid)/assets", json: request)
                        for (index, result) in zip(chunk, response["assets"] ?? []) {
                            guard result.error == nil, let asset = result.asset, let upload = result.upload else { continue }
                            pending[index].assetID = asset.id
                            pending[index].upload = upload
                        }
                    }
                    LLog("picplace: \(project.name) — md5 declared for \(undeclared.count) file(s) before sending")
                }
            }

            // 5. PUT straight to object storage, a few at a time, exactly the
            //    headers the server signed — and confirm what has finished as
            //    the run goes, `confirmEvery` files at a time. A pause, a lost
            //    network or a locked phone then costs only the files in flight:
            //    a later run finds the confirmed ones unchanged and sends the
            //    rest (2026-09-24 — every file was confirmed at the very end,
            //    so an upload stopped at 90 % started again from nothing).
            await report { $0.phase = .uploading }
            if !pending.isEmpty {
                // The one line a long upload writes before it ends — how
                // much is left, and how much a pause or a resume skipped.
                let bytes = pending.reduce(Int64(0)) { $0 + $1.item.bytes }
                LLog("picplace: \(project.name) — uploading \(pending.count) of \(files.count) file(s), \(LLFormat.bytes(bytes))\(files.count > pending.count ? "; \(files.count - pending.count) already on PicPlace" : "")")
            }
            var uploaded: [Uploaded] = []
            var unconfirmed: [Uploaded] = []
            var failures: [String] = []
            var stopped = false
            let heavyNames = Set(files.filter { $0.heavyFile != nil }.map(\.name))
            // A batch leaves `unconfirmed` only once PicPlace has answered, so
            // the error path's last try still covers one that failed to go.
            func confirmFinished() async throws {
                let batch = unconfirmed.filter { !$0.divergent }
                guard !batch.isEmpty else { unconfirmed.removeAll(); return }
                lastClaim = try await reclaimIfStale(lastClaim)
                for chunk in batch.chunked(Self.batchSize) {
                    let request: [String: Any] = ["assets": chunk.map { ["id": $0.assetID, "sha256": $0.sha256] }]
                    let response: [String: [PPConfirmResult]] = try await client.post("projects/\(uuid)/assets/confirm", json: request)
                    let heavyByAssetID = Dictionary(
                        chunk.filter { heavyNames.contains($0.name) }.map { ($0.assetID, $0.name) },
                        uniquingKeysWith: { first, _ in first })
                    for result in response["assets"] ?? [] {
                        if result.didReplace { toRetire[result.id] = nil }
                        if let error = result.error {
                            failures.append(result.message ?? error)
                        } else if let name = heavyByAssetID[result.id], result.asset?.verified != true {
                            // picplace.co reads it back within a minute or two.
                            unverifiedHeavy.insert(name)
                        }
                    }
                }
                unconfirmed.removeAll()
            }
            do {
                try await withThrowingTaskGroup(of: UploadEvent.self) { group in
                    var iterator = pending.makeIterator()
                    var inFlight = 0
                    func enqueue() {
                        guard let next = iterator.next() else { return }
                        inFlight += 1
                        group.addTask { .done(try await self.upload(next)) }
                    }
                    // A pause is heard within a third of a second, not when
                    // the next 40 MB file happens to finish.
                    if let stop {
                        group.addTask {
                            while !stop.isRequested { try await Task.sleep(nanoseconds: 300_000_000) }
                            return .stopRequested
                        }
                    }
                    for _ in 0 ..< Self.concurrentUploads { enqueue() }
                    while inFlight > 0 {
                        guard let event = try await group.next() else { break }
                        if case .done(let done) = event {
                            inFlight -= 1
                            uploaded.append(done)
                            unconfirmed.append(done)
                            await report { $0.filesDone += 1; $0.bytesDone += done.bytes }
                            if unconfirmed.count >= Self.confirmEvery { try await confirmFinished() }
                        }
                        if case .stopRequested = event { stopped = true }
                        if stopped || stop?.isRequested == true {
                            stopped = true
                            // The files in flight go again next time; one that
                            // finished as the pause landed is kept.
                            group.cancelAll()
                            while let result = await group.nextResult() {
                                if case .success(.done(let done)) = result {
                                    uploaded.append(done)
                                    unconfirmed.append(done)
                                    await report { $0.filesDone += 1; $0.bytesDone += done.bytes }
                                }
                            }
                            break
                        }
                        try Task.checkCancellation()
                        enqueue()
                    }
                    // The stop watcher, when there is one, is still waiting.
                    group.cancelAll()
                }
            } catch {
                // What finished is kept before the error goes up: a dropped
                // connection costs the files in flight, not the run.
                if !(error is CancellationError) { try? await confirmFinished() }
                throw error
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

            // 6. Confirm what is left (the server checks each object's size
            //    and records it) — or, paused, keep what finished and step aside.
            await report { $0.phase = .confirming }
            if stopped {
                try? await confirmFinished()
                LLog("picplace: \(project.name) — paused with \(uploaded.count) of \(pending.count) file(s) sent this run; the rest go when it resumes")
                throw Paused()
            }
            try await confirmFinished()
            if !failures.isEmpty {
                throw Failed(caption: failures.count == 1 ? failures[0] : "\(failures.count) files could not be confirmed")
            }
            // The old copies PicPlace did not retire for us, under the claim:
            // the one named as `replaces`, and — since a re-grade before this
            // build left one behind each time — every other confirmed copy
            // the project lists, by one read of its detail.
            if let sent = files.first(where: { $0.kind == PicPlaceSyncInventory.proxyKind }) {
                var old = Set(toRetire.values)
                if let detail: PPProjectDetail = try? await client.get("projects/\(uuid)") {
                    for asset in detail.assets ?? [] where asset.isWorkingCopy && asset.status == "confirmed" && asset.name != sent.name {
                        old.insert(asset.id)
                    }
                }
                for id in old {
                    do {
                        let reply: PPDeleted = try await client.delete("assets/\(id)")
                        LLog("picplace: \(project.name) — retired a previous working copy on PicPlace (\(id.prefix(8)))\(reply.deleted == true ? "" : " — PicPlace did not say deleted")")
                    } catch {
                        LLog("picplace: \(project.name) — could not retire the previous working copy \(id.prefix(8)) (\(retireNames[id] ?? sent.name) replaces it): \(error.localizedDescription)")
                    }
                }
            }

            // 7. Presence, then let go of the claim.
            await report { $0.phase = .finishing }
            let presence: [String: [PPPresence]] = try await client.post("projects/\(uuid)/presence", json: ["revision": project.revision, "tier": project.tier])
            let alsoOn = (presence["presence"] ?? []).otherDeviceNames(excluding: thisDeviceID)
            // Best effort: the push is complete; a claim this device could
            // not release expires on its own and this device may re-claim it.
            let _: [String: PPClaim?]? = try? await client.delete("projects/\(uuid)/claim")

            var record = PicPlaceSyncRecord(syncedAt: Date(), revision: project.revision, files: files.count, bytes: totalBytes,
                                            uploaded: pending.count, alsoOn: alsoOn,
                                            originalsOn: (presence["presence"] ?? []).originalsHolders(excluding: thisDeviceID),
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
            #if DEBUG
            // `LL_PICPLACE_PUT_DELAY=<ms>` slows every PUT, so a bench server
            // on this Mac is slow enough to pause mid-upload.
            if let ms = ProcessInfo.processInfo.environment["LL_PICPLACE_PUT_DELAY"].flatMap(UInt64.init) {
                try await Task.sleep(nanoseconds: ms * 1_000_000)
            }
            #endif
            (data, response) = try await PicPlaceTransfer.withRetries("PUT \(pending.item.name)") {
                #if DEBUG
                let started = Date()
                #endif
                let (data, response) = try await Self.uploadSession.upload(for: request, fromFile: pending.item.url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                #if DEBUG
                PicPlaceTransfer.trace("PUT", pending.item.name, status: status, bytes: Int(pending.item.bytes), since: started)
                #endif
                if status == 429 || (500 ..< 600).contains(status) {
                    throw PicPlaceTransfer.Refused(status: status, detail: String(data: data, encoding: .utf8).map { String($0.prefix(120)) } ?? "")
                }
                return (data, response)
            }
        } catch let refused as PicPlaceTransfer.Refused {
            throw Failed(caption: "Storage refused \(pending.item.name) (\(refused.status)) \(refused.detail)", interrupted: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // URLSession answers a cancelled task with `URLError(.cancelled)`:
            // that is the run being stopped, not the upload failing.
            if Task.isCancelled { throw CancellationError() }
            throw Failed(caption: "Upload of \(pending.item.name) failed: \(error.localizedDescription)",
                         interrupted: PicPlaceTransfer.isTransient(error))
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
            let freshHashes = try await Task.detached(priority: .utility) { try Self.hashes(of: url) }.value
            let fresh = freshHashes.sha256
            if fresh != pending.item.sha256 {
                LLog("picplace: storage refused \(pending.item.name) — it no longer matches its recorded hash (\(pending.item.sha256.prefix(8)) → \(fresh.prefix(8))); sending it as it is now")
                var item = pending.item
                item.sha256 = fresh
                if item.md5 != nil { item.md5 = freshHashes.md5 }
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

    /// `metadata.json` as an object and `assets.ndjson` as a list, one
    /// object per line, for the PUT's `records` (§B) — `NSNull` when
    /// neither file exists; nil when the pair, encoded, is over `cap`
    /// (the bundle carries them then) or a file does not parse.
    static func inlineRecords(in folder: URL, cap: Int64) -> (value: Any, assets: Int, bytes: Int)? {
        let metadataURL = folder.appendingPathComponent(ProjectFileRegistry.projectMetadataName)
        let assetsURL = folder.appendingPathComponent(ProjectFileRegistry.assetRecordsName)
        let metadataData = try? Data(contentsOf: metadataURL)
        let assetsData = try? Data(contentsOf: assetsURL)
        if metadataData == nil && assetsData == nil { return (NSNull(), 0, 0) }
        var metadata: Any = NSNull()
        if let metadataData {
            guard let object = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any] else { return nil }
            metadata = object
        }
        var assets: [Any] = []
        if let assetsData {
            for line in assetsData.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return nil }
                assets.append(object)
            }
        }
        let records: [String: Any] = ["metadata": metadata, "assets": assets]
        guard let encoded = try? JSONSerialization.data(withJSONObject: records) else { return nil }
        guard Int64(encoded.count) <= cap else {
            LLog("picplace: \(folder.lastPathComponent) — records of \(encoded.count) bytes over the \(cap)-byte inline cap; the bundle carries them")
            return nil
        }
        return (records, assets.count, encoded.count)
    }

    static func negotiateFields(_ item: FileItem) -> [String: Any] {
        let fields: [String: Any?] = ["kind": item.kind, "name": item.name, "bytes": item.bytes, "sha256": item.sha256,
                                      "content_type": item.name == PicPlaceSyncInventory.bundleName
                                          ? PicPlaceSyncInventory.bundleContentType : contentType(for: item.url),
                                      "replaces": item.replaces, "md5": item.md5]
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
            var md5: String?
            var changed = false
            if let recorded = recordedHash(records[item.relativePath], url: item.url, bytes: item.bytes) {
                sha = recorded
            } else {
                let url = item.url
                let both = try await Task.detached(priority: .utility) { try hashes(of: url) }.value
                sha = both.sha256
                md5 = both.md5
                // A record that no longer describes the file: it changed
                // after it was recorded, and the run says so.
                if let old = PicPlaceOriginalsCheck.normalized(records[item.relativePath]?.hash), old != sha { changed = true }
            }
            return FileItem(name: item.relativePath, kind: kind, url: item.url, bytes: item.bytes, sha256: sha, changedSinceRecorded: changed, md5: md5)
        }

        var files: [FileItem] = []
        var bundleURL: URL?
        for item in items {
            switch item.role {
            case .object(let kind) where policy.sendsRecords:
                files.append(try await hashed(item, kind: kind))
            case .heavy(let kind) where policy.sendsHeavy(kind: kind):
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
                let both = try await Task.detached(priority: .utility) { try hashes(of: archive) }.value
                files.append(FileItem(name: PicPlaceSyncInventory.bundleName, kind: PicPlaceSyncInventory.bundleKind,
                                      url: archive, bytes: bytes, sha256: both.sha256, md5: both.md5))
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

    /// SHA-256 and MD5 of a file from one read (sync-cost step 2): the MD5
    /// PicPlace signs into the PUT describes the same bytes the SHA-256 does.
    static func hashes(of url: URL) throws -> (sha256: String, md5: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha = SHA256()
        var md5 = Insecure.MD5()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 4 * 1024 * 1024)
            if chunk.isEmpty { return false }
            sha.update(data: chunk)
            md5.update(data: chunk)
            return true
        }) {}
        return (sha.finalize().map { String(format: "%02x", $0) }.joined(),
                md5.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// The twelve hex characters that name a working copy on PicPlace —
    /// SHA-256 of `PhotoGrade.proxyToken` (docs/picture-tiers-plan.md §3.2),
    /// so a device computes the expected name from the records it holds and
    /// compares it with the row's `renditions.proxy.name`: equal is fresh.
    static func proxyNameToken(for proxyToken: String) -> String {
        let digest = SHA256.hash(data: Data(proxyToken.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    private static func contentType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "heic", "heif": return "image/heic"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
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



/// A pause request a running upload reads between files: set from the main
/// actor (a person's Pause, the network rule), read on the run's tasks.
final class PicPlaceStopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    func request() {
        lock.lock()
        requested = true
        lock.unlock()
    }

    var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }
}

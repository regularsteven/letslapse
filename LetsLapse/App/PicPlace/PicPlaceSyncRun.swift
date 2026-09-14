import CryptoKit
import Foundation
import LetsLapseKit

/// Where a sync is: the card's caption and bar come from this.
struct PicPlaceSyncProgress: Equatable {
    enum Phase: Equatable { case claiming, preparing, manifest, negotiating, uploading, confirming, finishing, downloading }
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

    let client: PicPlaceClient
    let project: Project
    let thisDeviceID: String?
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
        do {
            let _: [String: PPClaim] = try await client.post("projects/\(uuid)/claim", json: ["ttl_seconds": Self.claimTTL])
        } catch let error as PicPlaceAPIError where error.status == 404 {
            // New to the server.
        } catch let error as PicPlaceAPIError where error.status == 409 && error.code == "project_deleted" {
            // Tombstoned on the server: the PUT below resurrects it (a
            // device that still holds the project is pushing it on purpose).
            LLog("picplace: \(uuid) is a tombstone on the server — the push resurrects it")
        }

        do {
            // 2. What the policy sends, with hashes (assets.ndjson first,
            // computed otherwise); the records bundle is built here.
            await report { $0.phase = .preparing }
            let inventory = try await Self.inventory(of: project.folder, policy: project.policy)
            bundleURL = inventory.bundleURL
            let files = inventory.files
            try Task.checkCancellation()
            let totalBytes = files.reduce(Int64(0)) { $0 + $1.bytes }
            await report { $0.filesTotal = files.count; $0.bytesTotal = totalBytes }

            // 3. The manifest: project.json verbatim, with the index fields
            // beside it — inline under the server's cap, as a `manifest`
            // asset over it (the server's own overflow shape).
            await report { $0.phase = .manifest }
            let manifestURL = project.folder.appendingPathComponent(ProjectFileRegistry.projectDocumentName)
            let manifestData = try Data(contentsOf: manifestURL)
            let manifest = try JSONSerialization.jsonObject(with: manifestData)
            var body: [String: Any] = [
                "name": project.name,
                "type": project.type,
                "revision": project.revision,
                "captured_at": ISO8601DateFormatter().string(from: project.capturedAt),
            ]
            if let origin = project.originUUID { body["origin_uuid"] = origin.uuidString.lowercased() }
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
                let item = FileItem(name: ProjectFileRegistry.projectDocumentName, kind: "manifest", url: manifestURL,
                                    bytes: Int64(manifestData.count), sha256: try Self.sha256(of: manifestURL))
                let negotiated: [String: [PPNegotiation]] = try await client.post("projects/\(uuid)/assets", json: ["assets": [Self.negotiateFields(item)]])
                guard let result = negotiated["assets"]?.first else { throw Failed(caption: "PicPlace did not negotiate the manifest.") }
                if let upload = result.upload {
                    _ = try await self.upload(PendingUpload(item: item, assetID: result.asset.id, upload: upload))
                    let confirmed: [String: [PPConfirmResult]] = try await client.post("projects/\(uuid)/assets/confirm", json: ["assets": [["id": result.asset.id, "sha256": item.sha256]]])
                    if let failure = (confirmed["assets"] ?? []).first(where: { $0.error != nil }) {
                        throw Failed(caption: failure.message ?? failure.error!)
                    }
                }
                body["manifest"] = ["manifest_asset": result.asset.id]
                let _: [String: PPProject] = try await client.put("projects/\(uuid)", json: body)
            }

            // 4. Negotiate in batches; unchanged files come back without an upload.
            await report { $0.phase = .negotiating }
            var pending: [PendingUpload] = []
            var assetIDs: [String: (id: String, sha256: String)] = [:]
            for batch in files.chunked(Self.batchSize) {
                try Task.checkCancellation()
                lastClaim = try await reclaimIfStale(lastClaim)
                let request: [String: Any] = ["assets": batch.map(Self.negotiateFields)]
                let response: [String: [PPNegotiation]] = try await client.post("projects/\(uuid)/assets", json: request)
                let results = response["assets"] ?? []
                for (item, result) in zip(batch, results) {
                    assetIDs[item.name] = (result.asset.id, item.sha256)
                    if let upload = result.upload {
                        pending.append(PendingUpload(item: item, assetID: result.asset.id, upload: upload))
                    } else {
                        await report { $0.filesDone += 1; $0.bytesDone += item.bytes }
                    }
                }
            }

            // 5. PUT straight to object storage, a few at a time, exactly the headers the server signed.
            await report { $0.phase = .uploading }
            var confirmations: [(id: String, sha256: String)] = pending.map { ($0.assetID, $0.item.sha256) }
            try await withThrowingTaskGroup(of: Int64.self) { group in
                var iterator = pending.makeIterator()
                var inFlight = 0
                func enqueue() {
                    guard let next = iterator.next() else { return }
                    inFlight += 1
                    group.addTask { try await self.upload(next) }
                }
                for _ in 0 ..< Self.concurrentUploads { enqueue() }
                while inFlight > 0 {
                    let bytes = try await group.next()!
                    inFlight -= 1
                    await report { $0.filesDone += 1; $0.bytesDone += bytes }
                    try Task.checkCancellation()
                    enqueue()
                }
            }

            // 6. Confirm in batches; the server checks each object's size and records it.
            await report { $0.phase = .confirming }
            var failures: [String] = []
            for batch in confirmations.chunked(Self.batchSize) {
                try Task.checkCancellation()
                lastClaim = try await reclaimIfStale(lastClaim)
                let request: [String: Any] = ["assets": batch.map { ["id": $0.id, "sha256": $0.sha256] }]
                let response: [String: [PPConfirmResult]] = try await client.post("projects/\(uuid)/assets/confirm", json: request)
                for result in response["assets"] ?? [] where result.error != nil {
                    failures.append(result.message ?? result.error!)
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
            let _: [String: PPClaim?] = try await client.delete("projects/\(uuid)/claim")

            return PicPlaceSyncRecord(syncedAt: Date(), revision: project.revision, files: files.count, bytes: totalBytes,
                                      uploaded: pending.count, alsoOn: alsoOn,
                                      server: (try? await client.currentTokens().server) ?? PicPlaceConfiguration.serverString, lastError: nil,
                                      policy: project.policy.rawValue,
                                      heavyFiles: project.policy.sendsHeavy ? 0 : inventory.summary.heavyFiles,
                                      heavyBytes: project.policy.sendsHeavy ? 0 : inventory.summary.heavyBytes)
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

    /// PUT one file to its presigned URL; a URL that expired mid-run is re-negotiated once.
    private func upload(_ pending: PendingUpload, retrying: Bool = false) async throws -> Int64 {
        var request = URLRequest(url: URL(string: pending.upload.url)!)
        request.httpMethod = pending.upload.method
        for (name, value) in pending.upload.headers where name.lowercased() != "host" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await Self.uploadSession.upload(for: request, fromFile: pending.item.url)
        } catch {
            throw Failed(caption: "Upload of \(pending.item.name) failed: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200 ..< 300).contains(status) { return pending.item.bytes }
        if status == 403, !retrying, Date() >= pending.upload.expiresAt.addingTimeInterval(-60) {
            let fresh: [String: [PPNegotiation]] = try await client.post("projects/\(uuid)/assets", json: ["assets": [Self.negotiateFields(pending.item)]])
            if let upload = fresh["assets"]?.first?.upload {
                return try await self.upload(PendingUpload(item: pending.item, assetID: pending.assetID, upload: upload), retrying: true)
            }
        }
        let detail = String(data: data, encoding: .utf8).map { $0.prefix(120) } ?? ""
        throw Failed(caption: "Storage refused \(pending.item.name) (\(status)) \(detail)")
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
    /// and sidecars into one `records.aar`, the poster and the LUTs as their
    /// own objects, the source frames and the blends as the heavy set —
    /// hashed from `assets.ndjson` where it has the file at that size and
    /// computed otherwise. Strays (files the table does not know) are logged
    /// and left.
    private static func inventory(of folder: URL, policy: PicPlaceSyncPolicy) async throws -> Inventory {
        let records = AssetRecords.load(inProjectFolder: folder)
        let items = PicPlaceSyncInventory.classify(try listFiles(in: folder))
        let summary = PicPlaceSyncInventory.summary(of: items, policy: policy)
        for stray in summary.strays { LLog("picplace: \(folder.lastPathComponent)/\(stray) is not a registered project file — left out") }

        func hashed(_ item: PicPlaceSyncItem, kind: String) async throws -> FileItem {
            let sha: String
            if let record = records[item.relativePath], let hash = record.hash, hash.hasPrefix("sha256:"), record.bytes == item.bytes {
                sha = String(hash.dropFirst("sha256:".count))
            } else {
                let url = item.url
                sha = try await Task.detached(priority: .utility) { try sha256(of: url) }.value
            }
            return FileItem(name: item.relativePath, kind: kind, url: item.url, bytes: item.bytes, sha256: sha)
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



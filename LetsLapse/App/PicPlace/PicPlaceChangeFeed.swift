import Foundation
import LetsLapseKit

// MARK: - The change feed (sync cost, step 3 — 2026-10-04)
//
// Every check used to read the account's whole index — a quarter megabyte
// on Steven's Mac, every few minutes, to find that nothing had moved.
// PicPlace now numbers every change on one account-wide sequence
// (`letslapse-api.md`, "Change feed"): `/status` carries each library's
// head, `GET /changes?since_seq=` returns the rows that moved since a
// watermark, and a `410 resync_required` says the watermark is older than a
// purged tombstone. The client keeps a VIRTUAL INDEX: the whole index once
// per launch (or whenever the feed cannot be trusted), then the feed's rows
// patched into it. The check's merge pass runs over the virtual index
// exactly as it ran over the real one, so a locally edited project is still
// found and queued, retries still come due, and nothing downstream changed.
// An idle check is one cached `/status`; a check after an edit elsewhere is
// `/status` plus one small `/changes` page.

/// `/status`'s `change_seq`: the account's sequence and each library's head
/// (`"null"` keys the default library; a library with no rows is absent).
struct PPChangeSeq: Decodable, Equatable {
    var account: Int
    var libraries: [String: Int]?

    func head(forLibrary key: String) -> Int { libraries?[key] ?? 0 }
}

/// One page of `GET /changes`.
struct PPChangeFeedPage: Decodable {
    var projects: [PPFeedRow]
    var next: String?
    var changeSeq: Int
}

/// A feed row: the index row made slim, devices by id.
struct PPFeedRow: Decodable {
    struct Claim: Decodable {
        var device: String
        var expiresAt: Date?
        var mine: Bool
    }
    struct Presence: Decodable {
        struct Mine: Decodable {
            var revision: Int?
            var tier: String?
        }
        var mine: Mine?
        var originals: [String]
    }
    var uuid: String
    var changeSeq: Int
    var name: String
    var type: String
    var revision: Int
    var capturedAt: Date?
    var bucket: String?
    var originUuid: String?
    var library: String?
    var libraryChangedAt: Date?
    var manifestBytes: Int64
    var assets: PPProject.Assets
    var renditions: PPRenditions?
    var claim: Claim?
    var presence: Presence
    var updatedBy: String?
    var createdAt: Date?
    var updatedAt: Date?
    var deletedAt: Date?
    var deletedBy: String?

    /// Every device id the row names — what the name table must know.
    var deviceIDs: [String] {
        var ids = presence.originals
        if let device = claim?.device { ids.append(device) }
        if let updatedBy { ids.append(updatedBy) }
        if let deletedBy { ids.append(deletedBy) }
        return ids
    }
}

/// `GET /devices`.
struct PPDeviceList: Decodable {
    var devices: [PPDeviceSummary]
}

/// The virtual index on disk — `PicPlace/index-cache.json` beside the sync
/// state — so a LAUNCH costs `/status` and at most a feed page, not the
/// whole index (a phone relaunches many times a day). Each row is kept as
/// the server sent it, tagged with its shape, and decoded on load the way
/// it was decoded when it arrived; the device names the feed rows need
/// travel with it. Trusted only when its scope and watermark are the sync
/// state's own.
struct PicPlaceIndexCache: Codable {
    static let format = 1
    struct Row: Codable {
        /// `index` (a `GET /projects` row) or `feed` (a `GET /changes` row).
        var shape: String
        var json: Data
    }
    struct Device: Codable {
        var id: String
        var name: String
        var platform: String?
    }
    var format = PicPlaceIndexCache.format
    var scope: String
    var watermark: Int
    var rows: [String: Row]
    var devices: [Device]
    var savedAt: Date

    static func url(inRoot root: URL) -> URL {
        PicPlaceBindingRecord.syncStateURL(inRoot: root).deletingLastPathComponent().appendingPathComponent("index-cache.json")
    }
}

extension PPProject {
    /// An index row from a feed row — the devices named through `names`
    /// (`GET /devices`, and every summary earlier index rows carried), this
    /// device's own presence from `presence.mine`. A feed row lists the
    /// devices holding the ORIGINALS, not every device with a presence row,
    /// so a row learned through the feed names only those in *Also on*.
    init(feed row: PPFeedRow, names: [String: PPDeviceSummary], thisDevice: PPDeviceSummary?, now: Date) {
        func summary(_ id: String) -> PPDeviceSummary {
            names[id] ?? PPDeviceSummary(id: id, name: "another device", platform: nil, revokedAt: nil)
        }
        var presence: [PPPresence] = row.presence.originals
            .filter { $0 != thisDevice?.id }
            .map { PPPresence(device: summary($0), revision: nil, tier: "original", confirmedAt: nil) }
        if let mine = row.presence.mine, let thisDevice {
            presence.append(PPPresence(device: thisDevice, revision: mine.revision, tier: mine.tier, confirmedAt: nil))
        }
        var claim: PPClaim?
        if let held = row.claim {
            claim = PPClaim(device: summary(held.device), claimedAt: nil, expiresAt: held.expiresAt,
                            active: held.expiresAt.map { $0 > now } ?? true, mine: held.mine)
        }
        self.init(
            uuid: row.uuid, name: row.name, type: row.type, revision: row.revision, capturedAt: row.capturedAt,
            manifestBytes: row.manifestBytes, assets: row.assets, claim: claim, presence: presence,
            updatedAt: row.updatedAt, updatedBy: row.updatedBy.map(summary), deletedAt: row.deletedAt,
            deletedBy: row.deletedBy.map(summary), originUuid: row.originUuid, library: row.library,
            libraryChangedAt: row.libraryChangedAt, renditions: row.renditions, bucket: row.bucket, changeSeq: row.changeSeq)
    }
}

extension PicPlaceController {

    /// The scope key the watermark belongs to — the bound library's uuid, or
    /// `"null"` for the default library — as `/status` keys its heads.
    var feedScopeKey: String { scope?.uuidString.lowercased() ?? "null" }

    /// `LL_PICPLACE_FEED=off` reads the whole index every check (the A/B
    /// bench); `=reset` forgets the watermark at launch (a full read, then
    /// the feed again).
    static var feedHook: String? { ProcessInfo.processInfo.environment["LL_PICPLACE_FEED"] }

    /// The index for this check (see the file's head): the real one when
    /// the feed cannot be trusted — no watermark, another scope's watermark,
    /// a server without the feed, `LL_PICPLACE_FEED=off` — else the virtual
    /// one, left alone when `/status` says the library has not moved and
    /// patched from `GET /changes` when it has. `status` is the check's own
    /// `/status` answer when it read one.
    func readIndex(status checkStatus: PPStatus?, reason: String) async throws -> PPProjectIndex {
        let key = feedScopeKey
        let feedOn = serverHasChangeFeed && Self.feedHook != "off"
        var status = checkStatus
        if feedOn, status == nil {
            // The heads live in `/status`; the feed needs them every check.
            status = try? await client.get("status")
        }
        if Self.feedHook == "reset", !feedResetApplied {
            feedResetApplied = true
            syncMeta.changeSeq = nil
            feedRows.removeAll()
            feedRaw.removeAll()
            try? FileManager.default.removeItem(at: PicPlaceIndexCache.url(inRoot: root))
            LLog("picplace hook: the feed's watermark and cache forgotten — a full index read")
        }
        let trusted = feedOn && syncMeta.changeSeq != nil && syncMeta.changeSeqScope == key && !feedRows.isEmpty
        guard trusted, let watermark = syncMeta.changeSeq else {
            return try await readWholeIndex(status: status, reason: feedOn ? (syncMeta.changeSeq == nil ? "no watermark" : "watermark is another library's or the rows are gone") : "feed off")
        }
        let head = status?.changeSeq?.head(forLibrary: key) ?? Int.max
        if head <= watermark {
            feedIdleChecks += 1
            LLog("picplace: feed — nothing changed in this library since seq \(watermark) (head \(head)); the index is not read")
            return virtualIndex(serverTime: status?.serverTime)
        }
        do {
            let took = try await applyFeed(since: watermark, key: key)
            LLog("picplace: feed — \(took.rows) row(s) changed since seq \(watermark) (\(took.pages) page(s)); watermark now \(took.watermark)")
            return virtualIndex(serverTime: status?.serverTime)
        } catch let error as PicPlaceAPIError where error.status == 410 {
            LLog("picplace: feed — resync required (the watermark \(watermark) is older than a purged tombstone); the whole index is read again")
            return try await readWholeIndex(status: status, reason: "resync required")
        }
    }

    /// The real index, every row; the virtual index becomes it and the
    /// watermark the account's sequence `/status` read a moment ago — so a
    /// change between the two reads is in the index AND comes again from
    /// the feed, which is harmless.
    private func readWholeIndex(status: PPStatus?, reason: String) async throws -> PPProjectIndex {
        // The body itself, so every row is kept as sent for the cache.
        let data = try await client.getData("projects", query: ["include_deleted": "1"])
        let index = try PicPlaceClient.decoder.decode(PPProjectIndex.self, from: data)
        feedRows.removeAll(keepingCapacity: true)
        feedRaw.removeAll(keepingCapacity: true)
        for row in index.projects {
            feedRows[row.uuid.lowercased()] = row
            noteDeviceNames(in: row)
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rows = object["projects"] as? [[String: Any]] {
            for row in rows {
                guard let uuid = (row["uuid"] as? String)?.lowercased(),
                      let json = try? JSONSerialization.data(withJSONObject: row) else { continue }
                feedRaw[uuid] = PicPlaceIndexCache.Row(shape: "index", json: json)
            }
        }
        if serverHasChangeFeed, let seq = status?.changeSeq?.account {
            syncMeta.changeSeq = seq
            syncMeta.changeSeqScope = feedScopeKey
            LLog("picplace: feed — the whole index read (\(reason)); \(index.projects.count) row(s), watermark \(seq)")
            saveIndexCache()
        } else {
            syncMeta.changeSeq = nil
            syncMeta.changeSeqScope = nil
            try? FileManager.default.removeItem(at: PicPlaceIndexCache.url(inRoot: root))
        }
        return index
    }

    /// Pages `GET /changes` for this library since `watermark`, patching the
    /// virtual index (the last copy of a row wins); the new watermark is the
    /// final page's `change_seq`.
    private func applyFeed(since watermark: Int, key: String) async throws -> (rows: Int, pages: Int, watermark: Int) {
        var rows = 0
        var pages = 0
        var cursor: String?
        var newWatermark = watermark
        let now = Date()
        repeat {
            let query: [String: String] = cursor.map { ["cursor": $0] }
                ?? ["since_seq": String(watermark), "library": key, "limit": "500"]
            let data = try await client.getData("changes", query: query)
            let page = try PicPlaceClient.decoder.decode(PPChangeFeedPage.self, from: data)
            pages += 1
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let raw = object["projects"] as? [[String: Any]] {
                for row in raw {
                    guard let uuid = (row["uuid"] as? String)?.lowercased(),
                          let json = try? JSONSerialization.data(withJSONObject: row) else { continue }
                    feedRaw[uuid] = PicPlaceIndexCache.Row(shape: "feed", json: json)
                }
            }
            // Names for devices the table does not know yet — one read.
            let unknown = Set(page.projects.flatMap(\.deviceIDs)).filter { deviceNames[$0] == nil }
            if !unknown.isEmpty, let list: PPDeviceList = try? await client.get("devices") {
                for device in list.devices { deviceNames[device.id] = device }
            }
            let me = profile.map { PPDeviceSummary(id: $0.deviceID, name: $0.deviceName, platform: nil, revokedAt: nil) }
            for row in page.projects {
                feedRows[row.uuid.lowercased()] = PPProject(feed: row, names: deviceNames, thisDevice: me, now: now)
                rows += 1
            }
            cursor = page.next
            if cursor == nil { newWatermark = page.changeSeq }
        } while cursor != nil && pages < 200
        syncMeta.changeSeq = newWatermark
        syncMeta.changeSeqScope = key
        saveIndexCache()
        return (rows, pages, newWatermark)
    }

    // MARK: The cache on disk

    /// Writes the virtual index beside the sync state, off the main actor.
    private func saveIndexCache() {
        guard let watermark = syncMeta.changeSeq, let scope = syncMeta.changeSeqScope else { return }
        let cache = PicPlaceIndexCache(
            scope: scope, watermark: watermark, rows: feedRaw,
            devices: deviceNames.values.map { PicPlaceIndexCache.Device(id: $0.id, name: $0.name, platform: $0.platform) },
            savedAt: Date())
        let url = PicPlaceIndexCache.url(inRoot: root)
        Task.detached(priority: .utility) {
            do {
                let data = try JSONEncoder().encode(cache)
                try data.write(to: url, options: .atomic)
            } catch {
                LLog("picplace: could not write the index cache: \(error)")
            }
        }
    }

    /// Reads the cache at launch (`init`), when its scope and watermark are
    /// the sync state's own; otherwise the first check reads the whole index.
    func loadIndexCache() {
        let url = PicPlaceIndexCache.url(inRoot: root)
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(PicPlaceIndexCache.self, from: data),
              cache.format == PicPlaceIndexCache.format,
              cache.scope == feedScopeKey, cache.watermark == syncMeta.changeSeq, syncMeta.changeSeqScope == cache.scope
        else { return }
        for device in cache.devices {
            deviceNames[device.id] = PPDeviceSummary(id: device.id, name: device.name, platform: device.platform, revokedAt: nil)
        }
        let me = profile.map { PPDeviceSummary(id: $0.deviceID, name: $0.deviceName, platform: nil, revokedAt: nil) }
        let now = Date()
        var rows: [String: PPProject] = [:]
        for (uuid, row) in cache.rows {
            if row.shape == "feed" {
                guard let feed = try? PicPlaceClient.decoder.decode(PPFeedRow.self, from: row.json) else { continue }
                rows[uuid] = PPProject(feed: feed, names: deviceNames, thisDevice: me, now: now)
            } else {
                guard let project = try? PicPlaceClient.decoder.decode(PPProject.self, from: row.json) else { continue }
                rows[uuid] = project
            }
        }
        guard rows.count == cache.rows.count else { return }
        feedRows = rows
        feedRaw = cache.rows
        LLog("picplace: feed — the index cache read: \(rows.count) row(s) at watermark \(cache.watermark)")
    }

    private func virtualIndex(serverTime: Date?) -> PPProjectIndex {
        PPProjectIndex(projects: Array(feedRows.values), serverTime: serverTime)
    }

    /// Every device summary an index row carries, remembered for the feed's
    /// rows, which name devices by id alone.
    private func noteDeviceNames(in row: PPProject) {
        for presence in row.presence { if let device = presence.device { deviceNames[device.id] = device } }
        if let device = row.claim?.device { deviceNames[device.id] = device }
        if let device = row.updatedBy { deviceNames[device.id] = device }
        if let device = row.deletedBy { deviceNames[device.id] = device }
    }
}

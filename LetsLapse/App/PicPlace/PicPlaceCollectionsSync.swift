import Foundation
import LetsLapseKit

// MARK: - A library's collections, through PicPlace (connected asset states D3, 2026-09-25)
//
// Rule 4 of Steven's brief: a collection can be authored and rendered on any
// device that has the blends. Until now a collection lived only on the
// device that made it. PicPlace keeps projects and their assets; the ask in
// docs/picplace-collections-ask.md adds one document per library — the
// library's collections, exactly as `collections.json` holds them (tombstones
// included) — behind a revision. This is the app's half, dormant until the
// server says it keeps them (`features["collections"]` in /status):
//
// - **Pull** at every check: PicPlace's document merged into this library's
//   collection by collection — the later change wins, a deletion counting
//   as a change (`LastEditMerge`) — written here if it moved, and sent back
//   if this side had newer changes.
// - **Push** a few seconds after a collection changes here, against the
//   revision last seen; a 409 (another device wrote first) pulls, merges and
//   sends again once.
//
// A collection names blends by id: a device that pulls a collection whose
// clips it does not hold shows them from their stills and fetches them when
// asked (the builder's missing-clip banner, stage 3).

extension PicPlaceController {

    /// PicPlace keeps this library's collections, and the session can talk
    /// to it.
    var syncsCollections: Bool { serverSyncsCollections && canSync && scope != nil }

    private var collectionsPath: String? {
        scope.map { "libraries/\($0.uuidString.lowercased())/collections" }
    }

    /// The check's pull. Quiet on failure: the next check tries again.
    func pullCollections() async {
        guard syncsCollections, let path = collectionsPath else { return }
        do {
            let data = try await client.getData(path)
            guard let remote = try Self.decodeCollections(data) else { return }
            await merge(remote: remote)
        } catch {
            LLog("picplace: collections — could not read PicPlace's copy: \(error.localizedDescription)")
        }
    }

    /// A collection changed here: sent a few seconds after the last change,
    /// so a drag across the timeline is one request, not one per tick.
    func collectionsChanged() {
        guard syncsCollections else { return }
        collectionsPushTask?.cancel()
        collectionsPushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            self.collectionsPushTask = nil
            await self.pushCollections(retrying: true)
        }
    }

    /// PicPlace's document and its revision, as the GET answers them.
    private struct RemoteCollections {
        var revision: Int
        var collections: [LapseCollection]
    }

    /// `{ "revision": n, "document": { …collections.json… } }` — the
    /// document decoded exactly as the library's own file is.
    private static func decodeCollections(_ data: Data) throws -> RemoteCollections? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let revision = object["revision"] as? Int else { return nil }
        guard let document = object["document"], !(document is NSNull) else {
            return RemoteCollections(revision: revision, collections: [])
        }
        let body = try JSONSerialization.data(withJSONObject: document)
        let decoded = try ProjectDocumentFormat.makeDecoder().decode(CollectionsDocument.self, from: body)
        return RemoteCollections(revision: revision, collections: decoded.collections)
    }

    /// Merges PicPlace's copy into this library's; writes here what moved
    /// and sends back what this side has newer.
    private func merge(remote: RemoteCollections) async {
        let local = model.allCollections
        let remoteByID = Dictionary(remote.collections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let outcome = LastEditMerge.merge(
            local: local.map { .init(id: $0.id, modifiedAt: $0.modifiedAt ?? $0.createdAt, deletedAt: $0.deletedAt) },
            remote: remote.collections.map { .init(id: $0.id, modifiedAt: $0.modifiedAt ?? $0.createdAt, deletedAt: $0.deletedAt) },
            equal: { id in localByID[id] == remoteByID[id] })
        syncMeta.collectionsRevision = remote.revision
        saveSyncState()
        if outcome.localChanged {
            let merged = outcome.choices.compactMap { id, side in side == .local ? localByID[id] : remoteByID[id] }
            model.applyRemoteCollections(merged)
            LLog("picplace: collections — took PicPlace's changes (\(remote.collections.count) on PicPlace, revision \(remote.revision))")
        }
        if outcome.remoteChanged {
            await pushCollections(retrying: true)
        }
    }

    /// Sends the library's collections against the revision last seen.
    private func pushCollections(retrying: Bool) async {
        guard syncsCollections, let path = collectionsPath else { return }
        do {
            let document = CollectionsDocument(collections: model.allCollections)
            let data = try ProjectDocumentFormat.makeEncoder().encode(document)
            let body: [String: Any] = [
                "base_revision": syncMeta.collectionsRevision ?? 0,
                "document": try JSONSerialization.jsonObject(with: data),
            ]
            let answer: [String: Int] = try await client.put(path, json: body)
            if let revision = answer["revision"] {
                syncMeta.collectionsRevision = revision
                saveSyncState()
            }
            LLog("picplace: collections — sent \(document.collections.count), revision \(answer["revision"].map(String.init) ?? "?")")
        } catch let error as PicPlaceAPIError where error.status == 409 && retrying {
            // Another device wrote first: take its changes, then send ours.
            LLog("picplace: collections — PicPlace moved on; merging before sending again")
            guard let data = try? await client.getData(path), let remote = try? Self.decodeCollections(data) else { return }
            await merge(remote: remote)
        } catch {
            LLog("picplace: collections — could not send: \(error.localizedDescription)")
        }
    }
}

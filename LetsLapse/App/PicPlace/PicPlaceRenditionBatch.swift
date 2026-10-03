import Foundation
import LetsLapseKit

// The unclaimed rendition batches (picture tiers, stage 3; the server's
// contract `letslapse-picture-tiers.md` §Ask 2, push 2): up to a hundred
// items of any projects per request, for the kinds in
// `limits.rendition_kinds` — a proxy up, a page of tiles down — with no
// claim, under the race rule (`stale_revision` per item when this device's
// presence revision is not the project's). Everything here keeps today's
// per-project path as its fallback while `features.rendition_batches` is
// false.

/// One rendition this device offers in a batch.
struct PicPlaceRenditionItem {
    /// The project's server id (its origin id).
    var origin: UUID
    var kind: String
    var name: String
    var url: URL
    var bytes: Int64
    var sha256: String
    var contentType: String
    /// The superseded asset of the same project and kind — the old proxy —
    /// deleted when this one confirms (`replaces`).
    var replaces: String?

    var key: String { "\(origin.uuidString.lowercased())|\(name)" }
}

extension PicPlaceController {

    enum RenditionOutcome {
        /// PicPlace held the bytes already (same hash under the name, or a
        /// dedupe copy): confirmed at once, nothing sent.
        case held
        case uploaded
        /// This device's copy of the project is not at the server's
        /// revision: pull, re-render, send again (the race rule).
        case staleRevision(current: Int)
        case failed(String)
    }

    /// Negotiates, PUTs and confirms `items` in pages of a hundred —
    /// `POST assets`, the presigned PUTs one after another, `POST
    /// assets/confirm` — and answers per item by `PicPlaceRenditionItem.key`.
    /// A request that fails as a whole fails its page's items; the caller
    /// keeps what it rendered on disk, so the next sweep sends them without
    /// rendering again.
    func sendRenditions(_ items: [PicPlaceRenditionItem]) async -> [String: RenditionOutcome] {
        var outcomes: [String: RenditionOutcome] = [:]
        for page in items.chunked(100) {
            let request: [String: Any] = ["assets": page.map { item -> [String: Any] in
                var fields: [String: Any] = [
                    "project": item.origin.uuidString.lowercased(), "kind": item.kind, "name": item.name,
                    "bytes": item.bytes, "sha256": item.sha256, "content_type": item.contentType,
                ]
                if let replaces = item.replaces { fields["replaces"] = replaces }
                return fields
            }]
            let answer: [String: [PPNegotiation]]
            do {
                answer = try await client.post("assets", json: request)
            } catch {
                for item in page { outcomes[item.key] = .failed(Self.describe(error)) }
                continue
            }
            var pending: [(item: PicPlaceRenditionItem, assetID: String, upload: PPUpload)] = []
            var toConfirm: [(id: String, sha256: String, key: String)] = []
            for (item, result) in zip(page, answer["assets"] ?? []) {
                if let error = result.error {
                    outcomes[item.key] = error == "stale_revision"
                        ? .staleRevision(current: result.currentRevision ?? 0)
                        : .failed(result.message ?? error)
                    continue
                }
                guard let asset = result.asset else { outcomes[item.key] = .failed("PicPlace did not negotiate \(item.name)"); continue }
                if let upload = result.upload {
                    pending.append((item, asset.id, upload))
                } else {
                    outcomes[item.key] = .held
                }
            }
            for entry in pending {
                if await Self.putRendition(entry.item, upload: entry.upload) {
                    toConfirm.append((entry.assetID, entry.item.sha256, entry.item.key))
                } else {
                    outcomes[entry.item.key] = .failed("the upload of \(entry.item.name) failed")
                }
            }
            for chunk in toConfirm.chunked(100) {
                let confirm: [String: Any] = ["assets": chunk.map { ["id": $0.id, "sha256": $0.sha256] }]
                do {
                    let results: [String: [PPConfirmResult]] = try await client.post("assets/confirm", json: confirm)
                    let keyByID = Dictionary(chunk.map { ($0.id, $0.key) }, uniquingKeysWith: { first, _ in first })
                    for result in results["assets"] ?? [] {
                        guard let key = keyByID[result.id] else { continue }
                        if let error = result.error {
                            outcomes[key] = .failed(result.message ?? error)
                        } else {
                            outcomes[key] = .uploaded
                            if let replaced = result.replaced {
                                LLog("picplace: \(key.suffix(from: key.index(after: key.firstIndex(of: "|") ?? key.startIndex))) replaced \(replaced.name ?? replaced.id) on PicPlace")
                            }
                        }
                    }
                } catch {
                    for entry in chunk { outcomes[entry.key] = .failed(Self.describe(error)) }
                }
            }
        }
        return outcomes
    }

    /// One rendition's bytes to its presigned URL, exactly the headers the
    /// server signed, with the transfer's own retries. False when storage
    /// refused it; the caller leaves the file for the next sweep.
    nonisolated static func putRendition(_ item: PicPlaceRenditionItem, upload: PPUpload) async -> Bool {
        guard let url = URL(string: upload.url) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = upload.method
        for (name, value) in upload.headers where name.lowercased() != "host" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let response: URLResponse = try await PicPlaceTransfer.withRetries("PUT \(item.name)") {
                #if DEBUG
                let started = Date()
                #endif
                let (data, response) = try await URLSession.shared.upload(for: request, fromFile: item.url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                #if DEBUG
                PicPlaceTransfer.trace("PUT", item.name, status: status, bytes: Int(item.bytes), since: started)
                #endif
                if status == 429 || (500 ..< 600).contains(status) {
                    throw PicPlaceTransfer.Refused(status: status, detail: String(data: data, encoding: .utf8).map { String($0.prefix(120)) } ?? "")
                }
                return response
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if !(200 ..< 300).contains(status) { LLog("picplace: storage refused \(item.name) (\(status))") }
            return (200 ..< 300).contains(status)
        } catch {
            LLog("picplace: upload of \(item.name) failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Presigned GET URLs for up to a hundred asset ids of any projects —
    /// `POST assets/urls` — by id. Empty on any failure: each download then
    /// mints its own, as before.
    func mintRenditionURLs(_ assetIDs: [String]) async -> [String: PPDownloadURL] {
        guard !assetIDs.isEmpty else { return [:] }
        var minted: [String: PPDownloadURL] = [:]
        for page in assetIDs.chunked(100) {
            guard let urls: [String: [PPDownloadURL]] = try? await client.post("assets/urls", json: ["assets": page]),
                  let items = urls["assets"] else { continue }
            for (asked, item) in zip(page, items) { minted[item.id ?? asked] = item }
        }
        return minted
    }

    /// The capture month in the person's own calendar, `YYYY-MM` — the
    /// `bucket` every PUT sends from push 2 (the server stores a UTC month
    /// for a row that never said; a later PUT with the field overrides).
    nonisolated static func bucket(for capturedAt: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month], from: capturedAt)
        return String(format: "%04d-%02d", parts.year ?? 1970, parts.month ?? 1)
    }
}

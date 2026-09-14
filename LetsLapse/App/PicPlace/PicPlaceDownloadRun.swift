import Foundation
import LetsLapseKit

/// Stage 5 (v2 plan §4.5): one project's originals — its `source/` media
/// and `blends/` — brought from PicPlace onto this device. The server's
/// asset list says what exists; a file already here at the listed size is
/// skipped (a resumed download costs nothing for what landed); URLs are
/// minted in pages of 100 as the download goes, since each lives fifteen
/// minutes; four transfers run at a time, straight from object storage to
/// the project folder. Runs off the main actor; reports progress back.
struct PicPlaceDownloadRun {

    struct Item {
        var id: String
        var name: String
        var bytes: Int64
    }

    let client: PicPlaceClient
    let projectUUID: String
    let folder: URL
    let progress: @MainActor (PicPlaceSyncProgress) -> Void

    private static let pageSize = 100
    private static let concurrentDownloads = 4

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 6 * 3600
        config.httpMaximumConnectionsPerHost = concurrentDownloads
        return URLSession(configuration: config)
    }()

    /// Downloads what is missing and returns how many files and bytes came.
    func run() async throws -> (files: Int, bytes: Int64) {
        var state = PicPlaceSyncProgress(phase: .downloading)
        func report(_ change: (inout PicPlaceSyncProgress) -> Void) async {
            change(&state)
            let snapshot = state
            await progress(snapshot)
        }
        await report { $0.phase = .downloading }

        let detail: PPProjectDetail = try await client.get("projects/\(projectUUID)")
        // By the registry's role, not the server's kind: a v1 push kinded
        // the sidecars under source/ as `source`, and they are not originals.
        let wanted = (detail.assets ?? [])
            .filter { $0.status == "confirmed" && PicPlaceSyncInventory.isHeavy($0.name) }
            .map { Item(id: $0.id, name: $0.name, bytes: $0.bytes ?? 0) }
        guard !wanted.isEmpty else { throw PicPlaceSyncRun.Failed(caption: "PicPlace holds no originals for this project.") }

        // What is already here at the right size stays.
        let fileManager = FileManager.default
        var pending: [Item] = []
        var have: Int64 = 0
        for item in wanted {
            let url = folder.appendingPathComponent(item.name)
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, Int64(size) == item.bytes {
                have += item.bytes
            } else {
                pending.append(item)
            }
        }
        let total = wanted.reduce(Int64(0)) { $0 + $1.bytes }
        await report { $0.filesTotal = wanted.count; $0.bytesTotal = total; $0.filesDone = wanted.count - pending.count; $0.bytesDone = have }
        let needed = pending.reduce(Int64(0)) { $0 + $1.bytes }
        try AppModel.checkStorageHeadroom(for: needed, at: folder)

        var downloaded = 0
        var downloadedBytes: Int64 = 0
        for page in pending.chunked(Self.pageSize) {
            try Task.checkCancellation()
            let minted: [String: [PPDownloadURL]] = try await client.post("projects/\(projectUUID)/assets/urls", json: ["assets": page.map(\.id)])
            let urls = Dictionary(uniqueKeysWithValues: (minted["assets"] ?? []).compactMap { item in item.id.map { ($0, item) } })
            try await withThrowingTaskGroup(of: Int64.self) { group in
                var iterator = page.makeIterator()
                var inFlight = 0
                func enqueue() {
                    guard let next = iterator.next() else { return }
                    inFlight += 1
                    group.addTask { try await self.fetch(next, urls[next.id]) }
                }
                for _ in 0 ..< Self.concurrentDownloads { enqueue() }
                while inFlight > 0 {
                    let bytes = try await group.next()!
                    inFlight -= 1
                    downloaded += 1
                    downloadedBytes += bytes
                    await report { $0.filesDone += 1; $0.bytesDone += bytes }
                    try Task.checkCancellation()
                    enqueue()
                }
            }
        }
        return (downloaded, downloadedBytes)
    }

    private func fetch(_ item: Item, _ minted: PPDownloadURL?) async throws -> Int64 {
        guard let minted else { throw PicPlaceSyncRun.Failed(caption: "PicPlace minted no URL for \(item.name).") }
        if let error = minted.error { throw PicPlaceSyncRun.Failed(caption: "\(item.name): \(minted.message ?? error)") }
        guard let string = minted.url, let url = URL(string: string) else { throw PicPlaceSyncRun.Failed(caption: "PicPlace minted an unusable URL for \(item.name).") }
        var request = URLRequest(url: url)
        request.httpMethod = minted.method ?? "GET"
        let (temporary, response) = try await Self.session.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            try? FileManager.default.removeItem(at: temporary)
            throw PicPlaceSyncRun.Failed(caption: "Storage refused \(item.name) (\(status)).")
        }
        let destination = folder.appendingPathComponent(item.name)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return item.bytes
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}

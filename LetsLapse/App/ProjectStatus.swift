import Combine
import LetsLapseKit
import SwiftUI

// MARK: - Every project's state, for the Gallery's PicPlace filters (2026-09-25)
//
// docs/connected-asset-states-plan.md §1b and §14: the Gallery sidebar's
// PICPLACE section filters the whole library by what this device holds and
// what PicPlace holds — "Needs uploading", "Download available" … A tile
// works out its own state as it scrolls in (`ProjectHoldingsStore`); a
// filter needs every project's at once. So one sweep walks the library off
// the main actor — each project's document and folder, the tile's own
// `ProjectHoldings` — and keeps a small summary per project, remembered
// between launches in `Index/local-status.json` beside the library's index
// and walked again only for a project whose folders or document moved.

/// What this device holds of one project, for the filters: the summary of
/// its `ProjectHoldings`, and the folder signature it was taken at.
struct ProjectLocalStatus: Codable, Equatable, Sendable {
    /// Every original here — the holdings tier, a Photo capture's picture
    /// counting as its original (the pill's camera).
    var originalsHere: Bool
    /// Blends here other than a Photo capture's picture (the pill's layers).
    var blendsHere: Int
    /// The heavy set here, fingerprinted as PicPlace's backed-up marker is.
    var heavyDigest: String
    var heavyFiles: Int
    /// The document's and the heavy folders' modification dates — a project
    /// whose signature moved is walked again.
    var signature: String

    init(_ holdings: ProjectHoldings, signature: String) {
        originalsHere = holdings.tier == .originals
        blendsHere = holdings.otherBlendsHere
        heavyDigest = holdings.localHeavyDigest ?? PicPlaceOriginalsCheck.digest([])
        heavyFiles = holdings.localHeavyFiles
        self.signature = signature
    }

    /// The folder's signature: `project.json`, `source/` and `blends/`'s
    /// modification dates. Adding or removing a frame or a blend moves the
    /// folder's date; a record change moves the document's.
    nonisolated static func signature(folder: URL) -> String {
        func stamp(_ url: URL) -> String {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return date.map { String(Int64($0.timeIntervalSince1970 * 1000)) } ?? "-"
        }
        return [
            stamp(ProjectDocumentFormat.url(inProjectFolder: folder)),
            stamp(folder.appendingPathComponent("source", isDirectory: true)),
            stamp(folder.appendingPathComponent("blends", isDirectory: true)),
        ].joined(separator: "|")
    }
}

/// The Gallery's PICPLACE filters — the brief's names, which the holdings
/// pill's VoiceOver labels and the Mac's tooltips share (plan §1b).
enum PicPlaceFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case onDevice
    case downloadAvailable
    case notAvailable
    case needsUploading
    case hasBlends
    case attention

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .onDevice: return "On this device"
        case .downloadAvailable: return "Download available"
        case .notAvailable: return "Not available to download"
        case .needsUploading: return "Needs uploading"
        case .hasBlends: return "Has blends"
        case .attention: return "Syncing / Needs attention"
        }
    }

    /// The pill's own glyphs where it has one for the state.
    var systemImage: String {
        switch self {
        case .all: return "icloud"
        case .onDevice: return "camera"
        case .downloadAvailable: return "icloud.and.arrow.down"
        case .notAvailable: return "icloud.slash"
        case .needsUploading: return "icloud.and.arrow.up"
        case .hasBlends: return HoldingsPillBody.blendsGlyph
        case .attention: return "exclamationmark.icloud"
        }
    }
}

/// Every project's summary, published in batches as the sweep lands them.
@MainActor final class ProjectStatusStore: ObservableObject {
    var summaries: [UUID: ProjectLocalStatus] = [:]
    /// Moves when summaries land or a PicPlace record or transfer that a
    /// filter reads changes — what the Gallery re-filters on.
    @Published private(set) var revision = 0
    /// The sweep's progress while it runs — the section's caption.
    @Published var sweeping: (done: Int, total: Int)?
    var sweep: Task<Void, Never>?
    /// Projects whose summary was dropped and are walked again shortly.
    var stale: Set<UUID> = []
    var staleFlush: Task<Void, Never>?
    var loadedFromDisk = false
    var observers: Set<AnyCancellable> = []
    /// A filtered list per question and filter, and the section's numbers
    /// per question — both kept until the store or the index moves: the
    /// Gallery's body asks for its rows many times a pass.
    var listCache: [ListKey: (revision: Int, indexRevision: Int, rows: [LibraryIndex.ProjectRow])] = [:]
    var countsCache: [ProjectListQuery: (revision: Int, indexRevision: Int, counts: [PicPlaceFilter: Int])] = [:]

    struct ListKey: Hashable {
        var query: ProjectListQuery
        var filter: PicPlaceFilter
    }

    func bump() { revision &+= 1 }
}

/// One project's PicPlace state, as the filters and the pill's labels read
/// it — nil pieces where nothing is known yet.
struct ProjectPicPlaceStatus: Equatable {
    var originalsHere: Bool
    var backedUp: Bool
    var originalsOnPicPlace: Bool
    var onPicPlace: Bool
    var transferring: Bool
    var needsAttention: Bool
}

extension AppModel {

    // MARK: Reading

    /// Where the summaries are remembered — beside the library's index.
    private var localStatusURL: URL {
        LibraryIndex.url(inRoot: StorageRoot.current)
            .deletingLastPathComponent()
            .appendingPathComponent("local-status.json")
    }

    /// One project's PicPlace state, or nil until its summary is known.
    func picplaceStatus(for id: UUID, originID: UUID?) -> ProjectPicPlaceStatus? {
        guard let local = statusStore.summaries[id] else { return nil }
        let origin = originID ?? id
        let record = picplace.records[origin]
        let onPicPlace = record.map { $0.revision > 0 || $0.policy == "pull" } ?? false
        var backedUp = false
        if let record, onPicPlace {
            if let marker = record.heavyDigest, marker == local.heavyDigest {
                backedUp = true
            } else if local.heavyFiles == 0 {
                backedUp = (record.serverHeavyFiles ?? 0) > 0
            }
        }
        return ProjectPicPlaceStatus(
            originalsHere: local.originalsHere,
            backedUp: backedUp,
            originalsOnPicPlace: onPicPlace && originalsOnPicPlace(origin: origin, record: record),
            onPicPlace: onPicPlace,
            transferring: picplace.progress[id] != nil,
            needsAttention: picplace.conflicts.contains { $0.originID == origin }
                || (picplace.canSync && record?.lastError != nil))
    }

    /// Whether PicPlace holds the project's originals — its own list when a
    /// card has read it, else the counts the last pull or look recorded,
    /// else the backed-up marker (this device saw its whole heavy set
    /// there), else the heavy count (sources and blends together — the
    /// best a record from before `serverSourceFiles` can say).
    private func originalsOnPicPlace(origin: UUID, record: PicPlaceSyncRecord?) -> Bool {
        if let remote = picplace.serverHeavy[origin] {
            return remote.contains { $0.isConfirmed && PicPlaceSyncInventory.heavyKind($0.name) == .source }
        }
        guard let record else { return false }
        if let sources = record.serverSourceFiles { return sources > 0 }
        if record.heavyDigest != nil { return true }
        return (record.serverHeavyFiles ?? 0) > 0
    }

    /// Whether a project (by its index row) passes `filter` — nil while its
    /// state is not known yet (the sweep has not reached it).
    func passes(_ filter: PicPlaceFilter, row: LibraryIndex.ProjectRow) -> Bool? {
        switch filter {
        case .all: return true
        case .hasBlends: return row.blendCount > 0
        default: break
        }
        guard let status = picplaceStatus(for: row.id, originID: row.originID) else { return nil }
        switch filter {
        case .all, .hasBlends: return true
        case .onDevice: return status.originalsHere
        case .downloadAvailable: return !status.originalsHere && status.originalsOnPicPlace
        case .notAvailable: return !status.originalsHere && !status.originalsOnPicPlace
        case .needsUploading: return status.originalsHere && !status.backedUp
        case .attention: return status.transferring || status.needsAttention
        }
    }

    /// The rows a list renders under a PicPlace filter, in the list's
    /// order — a project whose state is not known yet is left out until the
    /// sweep reaches it. `revision` is the caller's copy of the store's, so
    /// its body re-asks when it moves.
    func listRows(for query: ProjectListQuery, picplace filter: PicPlaceFilter, revision: Int) -> [LibraryIndex.ProjectRow]? {
        guard let rows = listRows(for: query) else { return nil }
        guard filter != .all else { return rows }
        let key = ProjectStatusStore.ListKey(query: query, filter: filter)
        if let cached = statusStore.listCache[key], cached.revision == statusStore.revision,
           cached.indexRevision == indexRevision {
            return cached.rows
        }
        let kept = rows.filter { passes(filter, row: $0) == true }
        statusStore.listCache[key] = (statusStore.revision, indexRevision, kept)
        return kept
    }

    /// How many of a list's projects each filter keeps — the section's
    /// numbers. A project whose state is not known yet counts under All only.
    func picplaceCounts(for query: ProjectListQuery, revision: Int) -> [PicPlaceFilter: Int] {
        if let cached = statusStore.countsCache[query], cached.revision == statusStore.revision,
           cached.indexRevision == indexRevision {
            return cached.counts
        }
        let rows = listRows(for: query) ?? []
        var counts: [PicPlaceFilter: Int] = [:]
        for filter in PicPlaceFilter.allCases {
            counts[filter] = rows.reduce(0) { $0 + (passes(filter, row: $1) == true ? 1 : 0) }
        }
        statusStore.countsCache[query] = (statusStore.revision, indexRevision, counts)
        return counts
    }

    // MARK: The sweep

    /// Walks every project whose summary is missing or stale, off the main
    /// actor, one at a time, publishing as it goes — the first time the
    /// PicPlace section is shown in a library, and again cheaply after (the
    /// remembered summaries are checked by signature, two stats a project).
    func startStatusSweep() {
        guard statusStore.sweep == nil, let rows = listRows(for: Self.statusSweepQuery) else { return }
        loadLocalStatusIfNeeded()
        let jobs = rows.map { (id: $0.id, folder: projectFolderURL(for: $0.id)) }
        let known = statusStore.summaries
        let file = localStatusURL
        statusStore.sweeping = (0, jobs.count)
        statusStore.observePicPlace(picplace)
        statusStore.sweep = Task { [weak self] in
            let started = CACurrentMediaTime()
            var walked = 0
            var batch: [UUID: ProjectLocalStatus] = [:]
            var index = 0
            while index < jobs.count {
                let chunk = Array(jobs[index..<min(index + 40, jobs.count)])
                index += chunk.count
                let made = await Task.detached(priority: .utility) { () -> [UUID: ProjectLocalStatus] in
                    var out: [UUID: ProjectLocalStatus] = [:]
                    for job in chunk {
                        let signature = ProjectLocalStatus.signature(folder: job.folder)
                        if let old = known[job.id], old.signature == signature { continue }
                        guard let summary = Self.walkStatus(folder: job.folder, signature: signature) else { continue }
                        out[job.id] = summary
                    }
                    return out
                }.value
                guard let self, !Task.isCancelled else { return }
                walked += made.count
                batch.merge(made) { $1 }
                for (id, summary) in made { self.statusStore.summaries[id] = summary }
                self.statusStore.sweeping = (index, jobs.count)
                self.statusStore.bump()
            }
            guard let self else { return }
            self.statusStore.sweeping = nil
            self.statusStore.sweep = nil
            let seconds = CACurrentMediaTime() - started
            LLog("status: swept \(jobs.count) project(s) in \(String(format: "%.2f", seconds)) s — \(walked) walked, \(jobs.count - walked) unchanged")
            if walked > 0 { self.saveLocalStatus(to: file) }
        }
    }

    /// Every project the Gallery can list — scans left out, as it does.
    static let statusSweepQuery = ProjectListQuery(
        sort: .capture, ascending: false, filter: .all, query: .empty, listsScans: false)

    /// One project's summary from its document and folder — no cache, no
    /// main actor: the tile's own holdings, built the tile's way.
    nonisolated static func walkStatus(folder: URL, signature: String) -> ProjectLocalStatus? {
        let url = ProjectDocumentFormat.url(inProjectFolder: folder)
        guard let data = try? Data(contentsOf: url),
              let document = try? ProjectDocumentFormat.makeDecoder().decode(ProjectDocument.self, from: data)
        else { return nil }
        let live = document.blends.filter { $0.deletedAt == nil }.sorted { $0.createdAt > $1.createdAt }
        let inputs = holdingsInputs(capture: document.capture, blends: live, folder: folder)
        return ProjectLocalStatus(buildHoldings(inputs), signature: signature)
    }

    /// A tile's holdings landed: the filter's summary follows them, so the
    /// grid and the filters never disagree about what they both just read.
    func noteHoldings(_ holdings: ProjectHoldings, for id: UUID, signature: String) {
        let summary = ProjectLocalStatus(holdings, signature: signature)
        guard statusStore.summaries[id] != summary else { return }
        statusStore.summaries[id] = summary
        statusStore.bump()
    }

    /// A project's files or record changed (`dropHoldings`): its summary is
    /// walked again a beat later, with any others that changed meanwhile.
    func noteStatusStale(_ id: UUID) {
        guard statusStore.summaries[id] != nil || statusStore.sweep != nil else { return }
        statusStore.stale.insert(id)
        guard statusStore.staleFlush == nil else { return }
        statusStore.staleFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self else { return }
            let ids = Array(self.statusStore.stale)
            self.statusStore.stale.removeAll()
            self.statusStore.staleFlush = nil
            let jobs = ids.map { (id: $0, folder: self.projectFolderURL(for: $0)) }
            let made = await Task.detached(priority: .utility) { () -> [UUID: ProjectLocalStatus?] in
                var out: [UUID: ProjectLocalStatus?] = [:]
                for job in jobs {
                    let signature = ProjectLocalStatus.signature(folder: job.folder)
                    out[job.id] = Self.walkStatus(folder: job.folder, signature: signature)
                }
                return out
            }.value
            for (id, summary) in made { self.statusStore.summaries[id] = summary }
            self.statusStore.bump()
        }
    }

    // MARK: Remembered between launches

    private struct LocalStatusFile: Codable {
        var version = 1
        var entries: [UUID: ProjectLocalStatus]
    }

    private func loadLocalStatusIfNeeded() {
        guard !statusStore.loadedFromDisk else { return }
        statusStore.loadedFromDisk = true
        guard let data = try? Data(contentsOf: localStatusURL),
              let file = try? JSONDecoder().decode(LocalStatusFile.self, from: data), file.version == 1
        else { return }
        // Nothing here is trusted until the sweep has checked its signature;
        // it only spares the walk of a project that did not move.
        for (id, summary) in file.entries where statusStore.summaries[id] == nil {
            statusStore.summaries[id] = summary
        }
    }

    private func saveLocalStatus(to url: URL) {
        let file = LocalStatusFile(entries: statusStore.summaries)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(file) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

extension ProjectStatusStore {
    /// The records and the transfers a filter reads move with PicPlace: the
    /// store's revision follows them (throttled — a transfer's progress
    /// ticks many times a second, and only which projects are moving
    /// matters here).
    func observePicPlace(_ picplace: PicPlaceController) {
        guard observers.isEmpty else { return }
        picplace.$records
            .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.bump() }
            .store(in: &observers)
        picplace.$progress
            .map { Set($0.keys) }
            .removeDuplicates()
            .sink { [weak self] _ in self?.bump() }
            .store(in: &observers)
        picplace.$conflicts
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] _ in self?.bump() }
            .store(in: &observers)
    }
}

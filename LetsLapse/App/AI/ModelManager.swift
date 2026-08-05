import Foundation

#if canImport(HuggingFace)
import HuggingFace
#endif

#if canImport(UIKit)
import UIKit
#endif

/// One installable model from the bundled catalog.
///
/// The revision is a pinned commit SHA rather than a branch: a Hub re-conversion of the same repo
/// can stop loading on the engine the app ships, so both halves of the contract are pinned and
/// revision bumps ride in through catalog updates (docs/ai/phase0-findings.md).
struct CatalogModel: Codable, Identifiable, Equatable, Sendable {
    enum Availability: String, Codable, Sendable {
        case recommended
        case experimental
        /// Already on the device because the OS ships it. Not downloadable, not deletable.
        case builtIn
    }

    /// What actually runs this entry. The distinction is not cosmetic: a built-in engine skips the
    /// whole download/disk/memory state machine, because there is nothing to fetch and no weights
    /// to find room for.
    enum Engine: String, Codable, Sendable {
        case mlx
        case visionFramework = "vision-framework"
    }

    /// Stable catalog identity, and the folder name under `Models/`.
    let id: String
    let engine: Engine
    /// Empty for a built-in entry — there is no repo behind it.
    let repoID: String
    let revision: String
    let name: String
    let quantization: String
    let availability: Availability
    let approxDownloadBytes: Int64
    /// The floor this model needs, measured against `DeviceCapability.physicalMemoryGB` — memory
    /// iOS hands userspace, not the number on the box. Fractional because the gap between the two
    /// is about a gigabyte, so a whole-number floor can only be set a whole device-class too high.
    let minUnifiedMemoryGB: Double
    /// Peak resident memory during inference, measured — not the download size and not the weight
    /// footprint. The weights load comfortably on devices that are then killed mid-generation, so
    /// this is the only figure that predicts the failure (docs/ai/phase0-findings.md).
    let approxPeakMemoryBytes: Int64
    /// How many frames this model can take in a single prompt on the shipping engine.
    let maxImagesPerPrompt: Int
    /// Glob patterns limiting what gets fetched from the repo.
    let matching: [String]
    let summary: String
    /// A known defect worth showing on the row before someone spends the download on it.
    let warning: String?

    /// Nothing to download, nothing to delete, nothing to check for room. Everything the download
    /// machinery does is skipped for these, and the UI shows them as permanently present.
    var isBuiltIn: Bool { engine != .mlx }

    /// Written by hand so a built-in entry can leave out every field that only means something to
    /// a downloaded model — a repo, a revision, a glob list. Filling those in with empty strings in
    /// the JSON would read as "unknown" rather than "not applicable".
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        // Defaulted rather than required so a catalog written before engines existed still decodes
        // as what it was: MLX.
        engine = try container.decodeIfPresent(Engine.self, forKey: .engine) ?? .mlx
        repoID = try container.decodeIfPresent(String.self, forKey: .repoID) ?? ""
        revision = try container.decodeIfPresent(String.self, forKey: .revision) ?? ""
        name = try container.decode(String.self, forKey: .name)
        quantization = try container.decode(String.self, forKey: .quantization)
        availability = try container.decode(Availability.self, forKey: .availability)
        approxDownloadBytes = try container.decodeIfPresent(Int64.self, forKey: .approxDownloadBytes) ?? 0
        minUnifiedMemoryGB = try container.decodeIfPresent(Double.self, forKey: .minUnifiedMemoryGB) ?? 0
        approxPeakMemoryBytes = try container.decodeIfPresent(Int64.self, forKey: .approxPeakMemoryBytes) ?? 0
        maxImagesPerPrompt = try container.decodeIfPresent(Int.self, forKey: .maxImagesPerPrompt) ?? 1
        matching = try container.decodeIfPresent([String].self, forKey: .matching) ?? []
        summary = try container.decode(String.self, forKey: .summary)
        warning = try container.decodeIfPresent(String.self, forKey: .warning)
    }
}

private struct ModelCatalogFile: Codable {
    struct Engine: Codable {
        let package: String
        let revision: String
        let notes: String?
    }

    let schemaVersion: Int
    let engine: Engine
    let models: [CatalogModel]
}

/// Owns the on-device model library: what the catalog offers, what is on disk, what is downloading,
/// and which one the analysis feature uses.
///
/// Models live in `Application Support/Models/<catalog-id>/`. Inside that folder the Hub client's
/// own Python-compatible layout is used verbatim (`models--<org>--<repo>/snapshots/<sha>/`) so the
/// download keeps its resume, integrity and de-duplication machinery — copying the snapshot back
/// out to a flat folder would mean carrying 3.5 GB twice on a phone.
@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    enum ModelState: Equatable {
        case notDownloaded
        /// `status` is what the row says next to the bar — "Downloading file 3 of 9…". A percentage
        /// alone can't distinguish a slow shard from a stalled one, which is the whole failure this
        /// download path was rewritten around.
        case downloading(progress: Double, status: String)
        case downloaded
        case failed(String)

        var isDownloading: Bool {
            if case .downloading = self { return true }
            return false
        }
    }

    @Published private(set) var catalog: [CatalogModel] = []
    @Published private(set) var states: [String: ModelState] = [:]
    /// Bytes on disk per model, refreshed after downloads and deletions.
    @Published private(set) var diskUsage: [String: Int64] = [:]
    /// Set when reading the bundled catalog itself fails — the screen has nothing to show then.
    @Published private(set) var catalogError: String?

    /// Which model the analysis feature uses. Nil until something is downloaded.
    @Published var activeModelID: String? {
        didSet {
            guard activeModelID != oldValue else { return }
            UserDefaults.standard.set(activeModelID, forKey: Self.activeModelDefaultsKey)
            // Evict on the switch, not on the next analysis. The outgoing model stays resident
            // otherwise — 2.8 GB of weights plus MLX's own buffer cache — and the incoming one
            // then has nowhere to load into. The analyser is serial, so this eviction is ordered
            // ahead of whatever load the new selection triggers.
            Task { await SceneAnalyser.shared.unload() }
        }
    }

    static let activeModelDefaultsKey = "ai.activeModelID"

    private var downloads: [String: Task<Void, Never>] = [:]

    init() {
        activeModelID = UserDefaults.standard.string(forKey: Self.activeModelDefaultsKey)
        loadCatalog()
        refreshStates()
        adoptDefaultActiveModel()
        Task { await refreshDiskUsage() }
    }

    // MARK: - Catalog

    private func loadCatalog() {
        guard let url = Bundle.main.url(forResource: "ModelCatalog", withExtension: "json") else {
            catalogError = "ModelCatalog.json is missing from the app bundle."
            return
        }
        do {
            let file = try JSONDecoder().decode(ModelCatalogFile.self, from: Data(contentsOf: url))
            catalog = file.models
            catalogError = nil
        } catch {
            catalogError = "Couldn't read the model catalog: \(error.localizedDescription)"
        }
    }

    func model(withID id: String) -> CatalogModel? {
        catalog.first { $0.id == id }
    }

    func state(of model: CatalogModel) -> ModelState {
        states[model.id] ?? .notDownloaded
    }

    /// Everything the user can pick right now — the models on disk, plus the built-ins, which are
    /// on disk in the only sense that matters.
    var downloadedModels: [CatalogModel] {
        catalog.filter { $0.isBuiltIn || states[$0.id] == .downloaded }
    }

    var availableModels: [CatalogModel] {
        catalog.filter { !$0.isBuiltIn && states[$0.id] != .downloaded }
    }

    var totalDiskUsed: Int64 {
        diskUsage.values.reduce(0, +)
    }

    // MARK: - Device fit

    /// Why this device can't take a model, when it can't.
    ///
    /// Split into "can it be installed" and "can it be run right now" because they fail at
    /// different moments and only one of them is the user's to fix: a 6 GB phone will never run the
    /// 4-bit model, while a phone that is merely busy will after something else quits.
    enum Blocker: Equatable {
        /// Installed memory is below the model's floor. Permanent for this device.
        case deviceMemory(requiredGB: Double, actualGB: Double)
        /// Not enough free storage for the download.
        case diskSpace(requiredBytes: Int64, freeBytes: Int64)
        /// This app's memory ceiling doesn't reach peak inference. Permanent for this build — the
        /// ceiling is per-process, so nothing the user quits will raise it.
        case memoryCeiling(requiredBytes: Int64, limitBytes: Int64)
        /// The ceiling is high enough but the app is currently holding too much of it. Recoverable
        /// by this app releasing memory, which is a thing the user can steer.
        case memoryInUse(requiredBytes: Int64, availableBytes: Int64, limitBytes: Int64)

        var message: String {
            switch self {
            case .deviceMemory(let required, let actual):
                // Phrased as *available* memory on purpose: iOS reports about a gigabyte less than
                // the marketing figure, so naming the spec-sheet number here reads as a lie to
                // anyone holding a phone whose box says it has enough.
                return "Requires ~\(Self.gigabytes(required)) GB of available memory — this device "
                    + "reports \(Self.gigabytes(actual)) GB."
            case .diskSpace(let required, let free):
                return "Needs \(LLFormat.bytes(required)) free — there's \(LLFormat.bytes(free)) available."
            case .memoryCeiling(let required, let limit):
                return "This device allows LetsLapse about \(LLFormat.bytes(limit)) of memory, and this "
                    + "model needs around \(LLFormat.bytes(required)) to run."
            case .memoryInUse(let required, let available, _):
                return "LetsLapse is using too much memory right now — this model needs about "
                    + "\(LLFormat.bytes(required)) and only \(LLFormat.bytes(available)) is free. "
                    + "Finish any export or close a preview, then try again."
            }
        }

        /// Whether trying again could plausibly succeed. A device that is simply too small, or a
        /// ceiling that will never rise, is not worth offering a Retry button to.
        var isTransient: Bool {
            switch self {
            case .deviceMemory, .memoryCeiling: return false
            case .diskSpace, .memoryInUse: return true
            }
        }

        /// One decimal place, with a trailing ".0" trimmed — "6.5 GB" and "8 GB", never "8.0 GB".
        private static func gigabytes(_ value: Double) -> String {
            let rounded = (value * 10).rounded() / 10
            return rounded == rounded.rounded()
                ? String(Int(rounded))
                : String(format: "%.1f", rounded)
        }
    }

    /// Whether this model can be installed at all — checked before the download starts, so a
    /// 3.6 GB fetch doesn't run to completion on a device that can never load it.
    func installBlocker(for model: CatalogModel) -> Blocker? {
        // A built-in has no bytes to land and no weights to hold — there is nothing here to fail.
        guard !model.isBuiltIn else { return nil }
        // Both sides are Double all the way down. Rounding either one to a whole gigabyte is what
        // turned an 8 GB iPhone 16 Pro's 7.1 into a 7 and refused it a model it can run.
        let memoryGB = DeviceCapability.physicalMemoryGB
        if memoryGB < model.minUnifiedMemoryGB {
            return .deviceMemory(requiredGB: model.minUnifiedMemoryGB, actualGB: memoryGB)
        }
        // Headroom on top of the download: the Hub layout symlinks snapshot entries at the blobs
        // rather than copying them, so the overhead is bookkeeping, not a second copy.
        let needed = Int64(Double(model.approxDownloadBytes) * 1.05)
        if let free = DeviceCapability.availableDiskBytes(at: Self.modelsRootURL), free < needed {
            return .diskSpace(requiredBytes: needed, freeBytes: free)
        }
        return nil
    }

    /// Whether this model can be loaded and run *now*. Checked immediately before load, because the
    /// answer depends on what else the device is doing.
    ///
    /// Returns nil where the question doesn't apply (macOS), which is not the same as "yes" — it is
    /// "this platform doesn't kill processes over it".
    func runtimeBlocker(for model: CatalogModel) -> Blocker? {
        // Vision's classifier is a system service measured in tens of megabytes; the peak-memory
        // gate exists for multi-gigabyte weights and would only ever produce a false refusal here.
        guard !model.isBuiltIn else { return nil }
        guard let budget = DeviceCapability.memoryBudget else { return nil }
        guard budget.availableBytes < model.approxPeakMemoryBytes else { return nil }

        // Which of the two it is decides whether the user is told to do something or told to stop
        // trying, so the ceiling and the current draw are distinguished rather than merged.
        if budget.limitBytes < model.approxPeakMemoryBytes {
            return .memoryCeiling(
                requiredBytes: model.approxPeakMemoryBytes, limitBytes: budget.limitBytes)
        }
        return .memoryInUse(
            requiredBytes: model.approxPeakMemoryBytes,
            availableBytes: budget.availableBytes,
            limitBytes: budget.limitBytes)
    }

    // MARK: - Readiness

    /// The active model, if there is one and it is on disk.
    var activeModel: CatalogModel? {
        guard let activeModelID, let model = model(withID: activeModelID) else { return nil }
        if model.isBuiltIn { return model }
        return states[model.id] == .downloaded ? model : nil
    }

    /// True when analysis can actually run: an active model is chosen, its snapshot is on disk and
    /// complete, and nothing has since failed to load it. A built-in is ready by definition.
    var isReady: Bool {
        guard let activeModel else { return false }
        if activeModel.isBuiltIn { return true }
        return snapshotDirectory(for: activeModel) != nil
    }

    /// Called when a load or an inference fails against a model that looked fine on disk, so the
    /// row stops claiming to be ready. Phase 0 showed load-time key/shape mismatches are a real
    /// failure class, not a theoretical one.
    func recordLoadFailure(_ message: String, for modelID: String) {
        states[modelID] = .failed(message)
    }

    /// Picks something usable when nothing is selected — a model nobody chose is a feature that
    /// silently does nothing.
    ///
    /// A built-in is the floor rather than the preference: it costs nothing and works on the first
    /// launch of a fresh install, but an installed VLM is the better answer and wins when there is
    /// one, because it is the only one of the two that can write a title.
    private func adoptDefaultActiveModel() {
        guard activeModel == nil else { return }
        activeModelID = downloadedModels.first { !$0.isBuiltIn }?.id
            ?? downloadedModels.first?.id
    }

    // MARK: - Locations

    /// `Application Support/Models`, excluded from backup — re-downloadable bytes have no business
    /// in an iCloud backup or a device transfer.
    static var modelsRootURL: URL {
        var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    func directory(for model: CatalogModel) -> URL {
        Self.modelsRootURL.appendingPathComponent(model.id, isDirectory: true)
    }

    /// Where the loadable snapshot for a model sits, or nil when it isn't (fully) there.
    ///
    /// A folder is only accepted when `config.json` and at least one weights file landed —
    /// an interrupted download leaves the directory in place, and Phase 0's device leg lost an
    /// afternoon to a truncated copy that reported success.
    func snapshotDirectory(for model: CatalogModel) -> URL? {
        let fileManager = FileManager.default
        let repoFolder = "models--" + model.repoID.replacingOccurrences(of: "/", with: "--")
        let snapshots = directory(for: model)
            .appendingPathComponent(repoFolder, isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)

        let pinned = snapshots.appendingPathComponent(model.revision, isDirectory: true)
        let candidates = [pinned] + ((try? fileManager.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }

        return candidates.first { candidate in
            guard fileManager.fileExists(
                atPath: candidate.appendingPathComponent("config.json").path) else { return false }
            let contents = (try? fileManager.contentsOfDirectory(
                at: candidate, includingPropertiesForKeys: nil)) ?? []
            return contents.contains { $0.pathExtension == "safetensors" }
        }
    }

    /// Recomputes every row's state from what is actually on disk, leaving in-flight downloads and
    /// recorded failures alone (a model that failed to *load* is still on disk — saying
    /// "Downloaded" again would just walk the user back into the same failure).
    func refreshStates() {
        for model in catalog {
            // Nothing on disk to consult, and no failure state worth remembering: a built-in that
            // errors on one capture is still there for the next one.
            if model.isBuiltIn {
                states[model.id] = .downloaded
                continue
            }
            switch states[model.id] {
            case .downloading, .failed:
                continue
            default:
                states[model.id] = snapshotDirectory(for: model) != nil ? .downloaded : .notDownloaded
            }
        }
    }

    // MARK: - Download

    func download(_ model: CatalogModel) {
        guard !model.isBuiltIn, downloads[model.id] == nil else { return }

        // Refuse before the bytes, not after them. Storage is re-checked here rather than only on
        // the row so a device that filled up while the screen was open still gets a straight answer.
        if let blocker = installBlocker(for: model) {
            states[model.id] = .failed(blocker.message)
            return
        }

        states[model.id] = .downloading(progress: 0, status: "Starting…")

        #if canImport(HuggingFace)
        let destination = directory(for: model)
        let downloader = SnapshotDownloader(model: model, destination: destination)
        downloads[model.id] = Task { [weak self] in
            do {
                try FileManager.default.createDirectory(
                    at: destination, withIntermediateDirectories: true)
                try await downloader.run { fraction, status in
                    self?.noteProgress(fraction, status: status, for: model.id)
                }
                await self?.finishDownload(of: model, error: nil)
            } catch is CancellationError {
                await self?.finishDownload(of: model, error: nil, cancelled: true)
            } catch {
                await self?.finishDownload(of: model, error: error)
            }
        }
        #else
        states[model.id] = .failed("Model downloads aren't available on this platform.")
        #endif
    }

    func cancelDownload(of model: CatalogModel) {
        guard !model.isBuiltIn else { return }
        downloads[model.id]?.cancel()
        downloads[model.id] = nil
        states[model.id] = snapshotDirectory(for: model) != nil ? .downloaded : .notDownloaded
    }

    private func noteProgress(_ fraction: Double, status: String, for modelID: String) {
        guard states[modelID]?.isDownloading == true else { return }
        states[modelID] = .downloading(progress: min(max(fraction, 0), 1), status: status)
    }

    private func finishDownload(of model: CatalogModel, error: Error?, cancelled: Bool = false) async {
        downloads[model.id] = nil

        if cancelled {
            states[model.id] = snapshotDirectory(for: model) != nil ? .downloaded : .notDownloaded
            await refreshDiskUsage()
            return
        }

        if let error {
            states[model.id] = .failed(error.localizedDescription)
            await refreshDiskUsage()
            return
        }

        // A clean return from the Hub client still doesn't prove the files are usable — verify the
        // snapshot rather than trusting the exit code.
        guard snapshotDirectory(for: model) != nil else {
            states[model.id] = .failed("The download finished but the model files are incomplete.")
            await refreshDiskUsage()
            return
        }

        states[model.id] = .downloaded
        // A model that just cost several gigabytes should be the one that runs. `activeModel` is
        // never nil once a built-in exists, so "adopt when nothing is chosen" would never fire
        // again — the built-in is treated as the placeholder it is and stepped over here.
        if activeModel == nil || activeModel?.isBuiltIn == true {
            activeModelID = model.id
        }
        await refreshDiskUsage()
    }

    // MARK: - Delete

    func delete(_ model: CatalogModel) {
        guard !model.isBuiltIn else { return }
        cancelDownload(of: model)
        try? FileManager.default.removeItem(at: directory(for: model))
        states[model.id] = .notDownloaded
        diskUsage[model.id] = nil
        if activeModelID == model.id {
            activeModelID = downloadedModels.first?.id
        }
        Task { await refreshDiskUsage() }
    }

    // MARK: - Disk usage

    func refreshDiskUsage() async {
        // Built-ins own no folder under `Models/`, so walking one would only ever return zero.
        let folders = catalog.filter { !$0.isBuiltIn }.map { ($0.id, directory(for: $0)) }
        let sizes = await Task.detached(priority: .utility) { () -> [String: Int64] in
            var result: [String: Int64] = [:]
            for (id, url) in folders {
                let bytes = Self.directorySize(at: url)
                if bytes > 0 { result[id] = bytes }
            }
            return result
        }.value
        diskUsage = sizes
    }

    /// Sums allocated sizes, skipping the symlinks the Hub layout uses to point snapshot entries at
    /// blobs — following them would count every weight twice.
    private nonisolated static func directorySize(at url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}

enum ModelDownloadError: LocalizedError {
    case invalidRepoID(String)
    case emptySnapshot(String)
    case transferFailed(what: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .invalidRepoID(let id):
            return "“\(id)” isn't a valid Hugging Face repository name."
        case .emptySnapshot(let id):
            return "“\(id)” has no model files at the pinned revision."
        case .transferFailed(let what, let underlying):
            return "Couldn't download \(what) after several tries: \(underlying.localizedDescription)"
        }
    }
}

#if canImport(HuggingFace)
/// Fetches a model snapshot one file at a time, with a deadline and retries on each.
///
/// Replaces `HubClient.downloadSnapshot`, which fans every shard out concurrently over one QUIC
/// connection and sets no per-request deadline. On device that showed up as a bar frozen at 1% with
/// `quic_conn_keepalive_handler … exceeding 2 outstanding keep-alives` and then
/// `nw_read_request_report … Operation timed out` in the log: the connection was up, one shard's
/// data never arrived, and nothing was ever going to give up and retry. Serially, a stalled shard
/// is a request that times out and is retried rather than one the whole download waits on forever.
///
/// The Hub client still does each individual transfer, so the on-disk result is byte-for-byte the
/// Python-compatible layout `ModelManager.snapshotDirectory(for:)` looks for — the blob/symlink
/// bookkeeping is not reimplemented here.
private struct SnapshotDownloader: Sendable {
    let model: CatalogModel
    let destination: URL

    /// Progress is counted in completed files, not bytes: a file is the unit that survives a
    /// restart, and per-byte totals aren't known until every file's metadata has been fetched.
    typealias ProgressHandler = @MainActor @Sendable (Double, String) -> Void

    /// One try plus three retries, backing off 2 s, 4 s, 8 s — long enough for a Hub rate limit
    /// to lapse, short enough that a genuinely dead link still reports before the user gives up.
    private static let maxAttempts = 4

    /// Caps the gap between packets, not the transfer. This is the one that catches the observed
    /// failure: a connection that stays open and stops delivering.
    private static let requestTimeout: TimeInterval = 60

    /// Deliberately not 5 minutes. A single Gemma shard is over a gigabyte, so a 300 s ceiling
    /// would abort honest downloads on any connection under ~50 Mbps — and since a retry restarts
    /// the file from zero, the retries would never converge either.
    private static let resourceTimeout: TimeInterval = 1800

    func run(progress: @escaping ProgressHandler) async throws {
        let client = Self.makeClient(cacheDirectory: destination)
        guard let repo = Repo.ID(rawValue: model.repoID) else {
            throw ModelDownloadError.invalidRepoID(model.repoID)
        }

        await progress(0, "Checking the model files…")
        let entries = try await Self.attempting("the file list") {
            try await client.listFiles(in: repo, revision: model.revision)
        }
        let wanted = entries
            .filter { $0.type == .file && matchesCatalogGlobs($0.path) }
            .sorted { $0.path < $1.path }
        guard !wanted.isEmpty else { throw ModelDownloadError.emptySnapshot(model.repoID) }

        let snapshot = snapshotDirectory
        for (index, entry) in wanted.enumerated() {
            try Task.checkCancellation()
            await progress(
                Double(index) / Double(wanted.count),
                "Downloading file \(index + 1) of \(wanted.count)…")

            // Resume: anything already on disk at its full length is left alone, so a download
            // picked up after a failure or a relaunch costs only the files that didn't land.
            if Self.isComplete(entry, in: snapshot) { continue }
            Self.discardPartial(entry, in: snapshot)

            _ = try await Self.attempting(entry.path) {
                try await client.downloadFile(entry, from: repo, revision: model.revision)
            }
        }

        await progress(1, "Finishing up…")
    }

    /// Where the pinned revision's files land inside the cache this download writes to.
    private var snapshotDirectory: URL {
        let repoFolder = "models--" + model.repoID.replacingOccurrences(of: "/", with: "--")
        return destination
            .appendingPathComponent(repoFolder, isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(model.revision, isDirectory: true)
    }

    /// Mirrors what `downloadSnapshot(matching:)` would have selected, so the catalog's `matching`
    /// globs keep meaning the same thing. `fnmatch` without `FNM_PATHNAME` matches Python's
    /// `fnmatch`, which is what the Hub's own filtering is modelled on.
    private func matchesCatalogGlobs(_ path: String) -> Bool {
        guard !model.matching.isEmpty else { return true }
        return model.matching.contains { fnmatch($0, path, 0) == 0 }
    }

    /// A session of this download's own. The stock one has no resource deadline and no request
    /// deadline worth the name, which is why the stall had nothing to trip it.
    private static func makeClient(cacheDirectory: URL) -> HubClient {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = true
        // One connection at a time. The files are fetched serially anyway, and holding a single
        // QUIC stream open is what keeps the Hub from throttling the app into the stall above.
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.shouldUseExtendedBackgroundIdleMode = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return HubClient(
            session: URLSession(configuration: configuration),
            cache: HubCache(cacheDirectory: cacheDirectory))
    }

    /// Retries a transfer a few times before giving up, backing off between tries.
    ///
    /// Cancellation is passed straight through: the user pressing Cancel is not a transient network
    /// failure and must not be slept on and tried again.
    private static func attempting<T>(
        _ what: String,
        _ work: () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await work()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < maxAttempts else {
                    throw ModelDownloadError.transferFailed(what: what, underlying: error)
                }
                try await Task.sleep(nanoseconds: UInt64(1 << attempt) * 1_000_000_000)
                attempt += 1
            }
        }
    }

    /// Whether this file is already fully on disk.
    ///
    /// Byte count, not existence: the Hub cache's own fast path accepts any file that is present,
    /// which is exactly how a shard truncated by a dropped connection gets adopted as finished and
    /// the model then fails to load with a shape error a long way from the cause.
    private static func isComplete(_ entry: Git.TreeEntry, in snapshot: URL) -> Bool {
        guard let expected = entry.size else { return false }
        let file = snapshot.appendingPathComponent(entry.path)
        // Snapshot entries are symlinks into `blobs/` — measure the target, not the link.
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: file.resolvingSymlinksInPath().path),
            let actual = attributes[.size] as? Int64
        else { return false }
        return actual == Int64(expected)
    }

    /// Clears a short or dangling file, along with the blob behind it, so the Hub client's
    /// existence-only fast path can't hand the same broken bytes back.
    private static func discardPartial(_ entry: Git.TreeEntry, in snapshot: URL) {
        let fileManager = FileManager.default
        let file = snapshot.appendingPathComponent(entry.path)
        // `attributesOfItem` doesn't follow symlinks, so a link pointing at nothing is still seen.
        guard let attributes = try? fileManager.attributesOfItem(atPath: file.path) else { return }
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink,
           let target = try? fileManager.destinationOfSymbolicLink(atPath: file.path) {
            let blob = URL(
                fileURLWithPath: target, relativeTo: file.deletingLastPathComponent())
            try? fileManager.removeItem(at: blob.standardizedFileURL)
        }
        try? fileManager.removeItem(at: file)
    }
}
#endif

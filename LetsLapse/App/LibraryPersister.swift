import Foundation
import LetsLapseKit

/// The one path every write of `Projects/library.json` takes (Phase 1 W6).
///
/// A serial utility queue; every caller snapshots the manifest on the main
/// actor, mints a monotonically increasing version for it and enqueues.
/// The queue writes a snapshot only when its version is above the last one
/// written (`VersionGate`), which is what closes Part 1 R3 — a queued
/// older snapshot can no longer land after a newer one and resurrect a
/// deleted blend. `persistAndWait` is for the callers that need the bytes
/// on disk before they carry on (a delete, a registration, an install);
/// `persist` is for a grade tick. Every failure is logged through `LLog`
/// and surfaced once per session through `onFailure`; nothing here is
/// `try?`-swallowed.
///
/// `refuseWrites` is the W7 guard: while the manifest on disk could not be
/// decoded, no snapshot may overwrite it — the set-aside file is the only
/// copy of every grade, tag and blend record, and a fresh manifest with one
/// new capture in it would be the data loss Part 1 R1 described.
///
/// Since Phase 2 every admitted snapshot is also handed to the
/// `ProjectDocumentWriter`, on this same queue, right after `library.json`
/// has landed: the per-project `project.json` documents follow the
/// manifest, which stays authoritative until Phase 3 makes it an index.
final class LibraryPersister: @unchecked Sendable {

    typealias Manifest = AppModel.LibraryManifest

    enum Reason {
        /// Files were added, converted, rotated or deleted — the size and
        /// existence caches are stale too.
        case filesChanged
        /// Only values changed (a grade, a name, a tag).
        case valuesChanged
    }

    enum PersistError: LocalizedError {
        case refused(String)
        var errorDescription: String? {
            switch self {
            case .refused(let why): return "The library wasn't saved: \(why)"
            }
        }
    }

    private let queue = DispatchQueue(label: "com.regularsteven.letslapse.library-persist", qos: .utility)
    private let lock = NSLock()
    private var gate = VersionGate()
    private var counter = VersionCounter()
    private var refusal: String?
    private var surfacedFailure = false

    /// Called on the main actor with the first failure of the session (and
    /// every refusal), so the person hears about it once rather than on
    /// every slider tick.
    var onFailure: (@MainActor (Error) -> Void)?

    /// The per-project document writer (Phase 2). Used only on `queue`.
    private let documents: ProjectDocumentWriter

    /// The library's SQLite index (Phase 3) — a cache the documents keep
    /// current; nil only when the database could not be opened even after
    /// being thrown away, in which case the app runs without one.
    let index: LibraryIndex?

    init(projectsRoot: URL, collectionsURL: URL, indexURL: URL) {
        index = Self.openIndex(at: indexURL)
        documents = ProjectDocumentWriter(projectsRoot: projectsRoot, collectionsURL: collectionsURL, index: index)
    }

    /// Opens the index, discarding a database that will not open — it is a
    /// cache, and the launch pass rebuilds it from the files.
    private static func openIndex(at url: URL) -> LibraryIndex? {
        do {
            return try LibraryIndex(at: url)
        } catch {
            LLog("index: could not open \(url.lastPathComponent) (\(error)) — starting a fresh one")
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
            do {
                return try LibraryIndex(at: url)
            } catch {
                LLog("index: could not create \(url.lastPathComponent): \(error) — running without an index")
                return nil
            }
        }
    }

    /// The reason every write is refused, or nil when writes are allowed.
    var refuseWrites: String? {
        get { lock.lock(); defer { lock.unlock() }; return refusal }
        set { lock.lock(); refusal = newValue; lock.unlock() }
    }

    /// Mints the version for a snapshot taken now. Main actor: the caller
    /// snapshots and mints in one breath, which is what makes the order of
    /// versions the order of the model's states.
    @MainActor func mint() -> Int {
        counter.mint()
    }

    /// Queues an encoded snapshot. Returns at once.
    func persist(_ manifest: Manifest, version: Int, to url: URL) {
        queue.async { [self] in
            do {
                try write(manifest, version: version, to: url)
            } catch {
                report(error)
            }
        }
    }

    /// Writes the snapshot and returns only when it is on disk (or throws).
    /// A snapshot older than the newest written is dropped silently — that
    /// is not a failure, it is the gate doing its job.
    func persistAndWait(_ manifest: Manifest, version: Int, to url: URL) throws {
        try queue.sync { [self] in
            do {
                try write(manifest, version: version, to: url)
            } catch {
                report(error)
                throw error
            }
        }
    }

    /// Blocks until every queued write has landed.
    func flush() {
        queue.sync {}
    }

    /// The one-time launch pass over the project documents (Phase 2): every
    /// project's `project.json` is brought up to `manifest` and remembered,
    /// so the persists that follow rewrite only what changes. Queued behind
    /// whatever is already waiting and ahead of whatever comes next, which
    /// is what keeps a persist from being overtaken by a stale pass. Skipped
    /// entirely while writes are refused.
    func reconcileDocuments(_ manifest: Manifest) {
        queue.async { [self] in
            guard refuseWrites == nil else { return }
            let started = Date()
            let outcome = documents.reconcile(manifest)
            LLog(String(format: "project documents: reconciled %d written · %d current · %d without a folder · %d failed in %.2f s",
                        outcome.written, outcome.unchanged, outcome.homeless, outcome.failed, Date().timeIntervalSince(started)))
            if index != nil {
                LLog(outcome.indexRebuilt
                     ? "index: rebuilt from the files — \(outcome.indexed) projects"
                     : "index: \(outcome.indexed) projects re-indexed · \(outcome.assetsReindexed) asset files re-indexed")
            }
        }
    }

    // MARK: - On the queue

    private func write(_ manifest: Manifest, version: Int, to url: URL) throws {
        if let why = refuseWrites {
            throw PersistError.refused(why)
        }
        lock.lock()
        let admitted = gate.admit(version)
        lock.unlock()
        guard admitted else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
        // The documents follow the manifest. A document that fails to
        // write is logged by the writer and tried again at the next
        // persist; it does not fail the persist, whose file is the truth.
        documents.sync(manifest)
    }

    private func report(_ error: Error) {
        LLog("library persist failed: \(error)")
        lock.lock()
        let first = !surfacedFailure
        surfacedFailure = true
        lock.unlock()
        // A refusal is always surfaced: the person has to know nothing is
        // being saved. Any other failure once.
        guard first || error is PersistError, let onFailure else { return }
        Task { @MainActor in onFailure(error) }
    }
}

import Foundation
import LetsLapseKit

/// The one path every write of the library takes (Phase 1 W6; per project
/// since M3).
///
/// A serial utility queue. A caller mints a monotonically increasing
/// version for the document it is about to hand over and enqueues; the
/// queue writes a document only when its version is above the last one
/// written FOR THAT PROJECT (`VersionGate`, one per project), which is what
/// closes Part 1 R3 — a queued older state can no longer land after a newer
/// one. `waiting` is for the callers that need the bytes on disk before
/// they carry on (a delete, a registration, an install, an export about to
/// read the file); a grade tick is queued. Every failure is logged through
/// `LLog` and surfaced once per session through `onFailure`; nothing here
/// is `try?`-swallowed.
///
/// `refuseWrites` is the W7 guard: while the library on disk could not be
/// read, no write may overwrite it.
///
/// What a persist writes (M3): the project's `project.json`, atomically,
/// then its index row and — when their files are newer than their rows —
/// its asset and shape rows. The collections document has its own gate.
/// `Projects/library.json`, the compatibility export an older build and
/// `lapse audit` still read, is regenerated from the documents at launch
/// when it is stale and at quit or background (`regenerateExport`) — not
/// after every persist, since nothing in memory holds the whole library
/// to write it from and reading every document per grade tick is not a
/// trade. M4 retires it.
final class LibraryPersister: @unchecked Sendable {

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
    private var gates: [UUID: VersionGate] = [:]
    private var collectionsGate = VersionGate()
    private var counter = VersionCounter()
    private var refusal: String?
    private var surfacedFailure = false

    /// Called on the main actor with the first failure of the session (and
    /// every refusal), so the person hears about it once rather than on
    /// every slider tick.
    var onFailure: (@MainActor (Error) -> Void)?

    /// Called on the queue after every export write with the file's new
    /// modification date — what the foreground check compares against.
    var onManifestWritten: (@Sendable (Date?) -> Void)?

    /// Called on the queue whenever the index's rows changed — a document
    /// written, a project removed — so the lists re-ask (M2).
    var onIndexChanged: (@Sendable () -> Void)?

    /// The per-document writer and indexer. Used on `queue` — and by the
    /// launch walk, before any persist is queued.
    let writer: ProjectDocumentWriter

    /// The library's SQLite index (Phase 3) — a cache the documents keep
    /// current; nil only when the database could not be opened even after
    /// being thrown away, in which case the app runs without one.
    let index: LibraryIndex?

    let projectsRoot: URL
    let collectionsURL: URL
    let exportURL: URL

    init(projectsRoot: URL, collectionsURL: URL, indexURL: URL) {
        self.projectsRoot = projectsRoot
        self.collectionsURL = collectionsURL
        exportURL = projectsRoot.appendingPathComponent(LibraryExportFormat.fileName)
        index = Self.openIndex(at: indexURL)
        writer = ProjectDocumentWriter(projectsRoot: projectsRoot, index: index)
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

    /// Mints the version for a state taken now. The caller takes the
    /// state and mints in one breath, which is what makes the order of
    /// versions the order of the model's states.
    func mint() -> Int {
        lock.lock(); defer { lock.unlock() }
        return counter.mint()
    }

    // MARK: - Documents

    /// Writes one project's document into `folder` and indexes it.
    /// `waiting` returns only when it is on disk (or throws); otherwise the
    /// write is queued and a failure is reported. A state older than the
    /// newest written for that project is dropped silently — that is not a
    /// failure, it is the gate doing its job.
    func persist(_ document: ProjectDocument, in folder: URL, version: Int, waiting: Bool) throws {
        if waiting {
            try queue.sync { [self] in
                do {
                    try write(document, in: folder, version: version)
                } catch {
                    report(error)
                    throw error
                }
            }
        } else {
            queue.async { [self] in
                do {
                    try write(document, in: folder, version: version)
                } catch {
                    report(error)
                }
            }
        }
    }

    /// The project's rows go (a purge, a rolled-back registration).
    func removeProject(id: UUID) {
        queue.async { [self] in
            guard let index else { return }
            do {
                try index.removeProject(id: id)
                onIndexChanged?()
            } catch {
                LLog("index: could not remove \(id.uuidString.prefix(8)): \(error)")
            }
        }
    }

    /// The collections document, under its own gate.
    func persistCollections(_ document: CollectionsDocument, version: Int, waiting: Bool) throws {
        let body = { [self] in
            if let why = refuseWrites { throw PersistError.refused(why) }
            lock.lock()
            let admitted = collectionsGate.admit(version)
            lock.unlock()
            guard admitted else { return }
            try writer.writeCollections(document, to: collectionsURL)
        }
        if waiting {
            try queue.sync {
                do { try body() } catch { report(error); throw error }
            }
        } else {
            queue.async {
                do { try body() } catch { self.report(error) }
            }
        }
    }

    /// Blocks until every queued write has landed.
    func flush() {
        queue.sync {}
    }

    /// The launch walk (M3), one block per folder on this queue so a write
    /// queued meanwhile lands between two of them; `completion` runs on the
    /// queue after the last.
    func enqueueWalk(_ steps: [() -> Void], completion: @escaping @Sendable () -> Void) {
        for step in steps { queue.async(execute: step) }
        queue.async(execute: completion)
    }

    // MARK: - The export

    /// `Projects/library.json` regenerated from the documents (M1's
    /// compatibility export, M3's cadence: at launch when stale, at quit
    /// and background). Queued behind whatever is waiting, so it describes
    /// what is on disk; `waiting` for the quit path.
    func regenerateExport(waiting: Bool = false) {
        let body = { [self] in
            guard refuseWrites == nil else { return }
            do {
                let started = Date()
                let data = try LibraryIndexRebuild.rebuiltManifest(root: projectsRoot)
                try data.write(to: exportURL, options: .atomic)
                onManifestWritten?((try? URL(fileURLWithPath: exportURL.path).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
                LLog(String(format: "library export: regenerated from the documents in %.2f s (%d bytes)", Date().timeIntervalSince(started), data.count))
            } catch {
                LLog("library export: could not regenerate \(exportURL.lastPathComponent): \(error)")
            }
        }
        if waiting { queue.sync(execute: body) } else { queue.async(execute: body) }
    }

    // MARK: - On the queue

    private func write(_ document: ProjectDocument, in folder: URL, version: Int) throws {
        if let why = refuseWrites {
            throw PersistError.refused(why)
        }
        let id = document.capture.id
        lock.lock()
        let admitted = gates[id, default: VersionGate()].admit(version)
        lock.unlock()
        guard admitted else { return }
        let url = ProjectDocumentFormat.url(inProjectFolder: folder)
        let data = try writer.write(document, to: url)
        var outcome = ProjectDocumentWriter.Outcome()
        writer.index(data, at: url, id: id, outcome: &outcome)
        if outcome.indexed > 0 { onIndexChanged?() }
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

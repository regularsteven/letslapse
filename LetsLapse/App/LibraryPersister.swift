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
final class LibraryPersister: @unchecked Sendable {

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

    init() {}

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
    func persist<Manifest: Encodable>(_ manifest: Manifest, version: Int, to url: URL) {
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
    func persistAndWait<Manifest: Encodable>(_ manifest: Manifest, version: Int, to url: URL) throws {
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

    // MARK: - On the queue

    private func write<Manifest: Encodable>(_ manifest: Manifest, version: Int, to url: URL) throws {
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

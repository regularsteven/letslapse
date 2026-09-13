import Foundation
import LetsLapseKit

/// `Projects/.lock` — the advisory lock a second instance of the Mac app
/// respects by opening the library read-only (data model Phase 4; Part 1
/// R6). Two instances writing one `library.json` was the normal state of
/// this project — a Debug build beside a Release one — and each rewrote
/// the whole manifest from its own memory, so whichever wrote last won and
/// the other's edits were gone.
///
/// The holder writes its pid, host, build and a heartbeat it refreshes
/// every minute. A lock is stale, and taken over, when its heartbeat is
/// older than `staleAfter`, or when it names a process on THIS host that no
/// longer exists; a fresh lock from another host (the library on a shared
/// volume) is honoured, since nothing here can ask that host whether its
/// process is alive. The `lapse` CLI writes only the index and never takes
/// the lock. iOS runs one instance and takes no lock.
enum LibraryLock {

    typealias Holder = LibraryLockRecord

    enum Outcome: Equatable {
        case acquired
        case heldBy(Holder)
    }

    static let heartbeatInterval = LibraryLockRecord.heartbeatInterval

    private static var thisBuild: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// Takes the lock unless another instance holds it. Never throws: a
    /// lock that cannot be written (a read-only volume) is logged, and the
    /// library opens as if acquired — the persister will refuse the writes
    /// on its own terms.
    static func acquire(projectsRoot: URL) -> Outcome {
        if let existing = Holder.read(projectsRoot: projectsRoot), existing.isLive() {
            return .heldBy(existing)
        }
        let now = Date()
        let holder = Holder(
            pid: ProcessInfo.processInfo.processIdentifier, host: Holder.thisHost, build: thisBuild,
            deviceID: DeviceIdentity.id, takenAt: now, heartbeatAt: now)
        write(holder, projectsRoot: projectsRoot)
        return .acquired
    }

    /// Refreshes the heartbeat. Only the holder calls this.
    static func heartbeat(projectsRoot: URL) {
        guard var holder = Holder.read(projectsRoot: projectsRoot), isOurs(holder) else { return }
        holder.heartbeatAt = Date()
        write(holder, projectsRoot: projectsRoot)
    }

    /// Removes the lock if this process holds it.
    static func release(projectsRoot: URL) {
        guard let holder = Holder.read(projectsRoot: projectsRoot), isOurs(holder) else { return }
        try? FileManager.default.removeItem(at: Holder.url(projectsRoot: projectsRoot))
    }

    private static func isOurs(_ holder: Holder) -> Bool {
        holder.pid == ProcessInfo.processInfo.processIdentifier && holder.host == Holder.thisHost
    }

    private static func write(_ holder: Holder, projectsRoot: URL) {
        do {
            try holder.write(projectsRoot: projectsRoot)
        } catch {
            LLog("library lock: could not write \(Holder.url(projectsRoot: projectsRoot).path): \(error)")
        }
    }
}

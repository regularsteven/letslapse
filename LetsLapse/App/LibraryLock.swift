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

    struct Holder: Codable, Equatable {
        var pid: Int32
        var host: String
        var build: String
        var deviceID: UUID
        var takenAt: Date
        var heartbeatAt: Date
    }

    enum Outcome: Equatable {
        case acquired
        case heldBy(Holder)
    }

    static let fileName = ".lock"
    static let heartbeatInterval: TimeInterval = 60
    static let staleAfter: TimeInterval = 5 * 60

    static func url(projectsRoot: URL) -> URL {
        projectsRoot.appendingPathComponent(fileName)
    }

    private static var thisHost: String {
        ProcessInfo.processInfo.hostName
    }

    private static var thisBuild: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    static func read(projectsRoot: URL) -> Holder? {
        guard let data = try? Data(contentsOf: url(projectsRoot: projectsRoot)) else { return nil }
        return try? NDJSONFile.makeDecoder().decode(Holder.self, from: data)
    }

    /// True when `holder` is a live claim: fresh, and — on this host — a
    /// process that still exists.
    static func isLive(_ holder: Holder, now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(holder.heartbeatAt) < staleAfter else { return false }
        guard holder.host == thisHost else { return true }
        if holder.pid == ProcessInfo.processInfo.processIdentifier { return false }
        // `kill(pid, 0)` delivers nothing and reports whether the process
        // exists (EPERM means it does, under another user).
        return kill(holder.pid, 0) == 0 || errno == EPERM
    }

    /// Takes the lock unless another instance holds it. Never throws: a
    /// lock that cannot be written (a read-only volume) is logged, and the
    /// library opens as if acquired — the persister will refuse the writes
    /// on its own terms.
    static func acquire(projectsRoot: URL) -> Outcome {
        if let existing = read(projectsRoot: projectsRoot), isLive(existing) {
            return .heldBy(existing)
        }
        let now = Date()
        let holder = Holder(
            pid: ProcessInfo.processInfo.processIdentifier, host: thisHost, build: thisBuild,
            deviceID: DeviceIdentity.id, takenAt: now, heartbeatAt: now)
        write(holder, projectsRoot: projectsRoot)
        return .acquired
    }

    /// Refreshes the heartbeat. Only the holder calls this.
    static func heartbeat(projectsRoot: URL) {
        guard var holder = read(projectsRoot: projectsRoot),
              holder.pid == ProcessInfo.processInfo.processIdentifier, holder.host == thisHost else { return }
        holder.heartbeatAt = Date()
        write(holder, projectsRoot: projectsRoot)
    }

    /// Removes the lock if this process holds it.
    static func release(projectsRoot: URL) {
        guard let holder = read(projectsRoot: projectsRoot),
              holder.pid == ProcessInfo.processInfo.processIdentifier, holder.host == thisHost else { return }
        try? FileManager.default.removeItem(at: url(projectsRoot: projectsRoot))
    }

    private static func write(_ holder: Holder, projectsRoot: URL) {
        do {
            let encoder = NDJSONFile.makeEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
            try encoder.encode(holder).write(to: url(projectsRoot: projectsRoot), options: .atomic)
        } catch {
            LLog("library lock: could not write \(url(projectsRoot: projectsRoot).path): \(error)")
        }
    }
}

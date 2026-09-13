import Foundation

/// The contents of `Projects/.lock` — who has the library open (data model
/// Phase 4). The Mac app takes and refreshes it (`LibraryLock` in the app);
/// the Kit knows the record so the `lapse` CLI can tell whether a library
/// is live before it writes anything into it.
public struct LibraryLockRecord: Codable, Equatable, Sendable {
    public var pid: Int32
    public var host: String
    public var build: String
    public var deviceID: UUID
    public var takenAt: Date
    public var heartbeatAt: Date

    public init(pid: Int32, host: String, build: String, deviceID: UUID, takenAt: Date, heartbeatAt: Date) {
        self.pid = pid
        self.host = host
        self.build = build
        self.deviceID = deviceID
        self.takenAt = takenAt
        self.heartbeatAt = heartbeatAt
    }

    public static let fileName = ".lock"
    public static let heartbeatInterval: TimeInterval = 60
    /// A lock whose heartbeat is older than this is nobody's.
    public static let staleAfter: TimeInterval = 5 * 60

    public static func url(projectsRoot: URL) -> URL {
        projectsRoot.appendingPathComponent(fileName)
    }

    public static var thisHost: String { ProcessInfo.processInfo.hostName }

    public static func read(projectsRoot: URL) -> LibraryLockRecord? {
        guard let data = try? Data(contentsOf: url(projectsRoot: projectsRoot)) else { return nil }
        return try? NDJSONFile.makeDecoder().decode(LibraryLockRecord.self, from: data)
    }

    public func write(projectsRoot: URL) throws {
        let encoder = NDJSONFile.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: Self.url(projectsRoot: projectsRoot), options: .atomic)
    }

    /// True when this is a live claim: a heartbeat under `staleAfter` old
    /// and — on this host — a process that still exists. A fresh claim from
    /// another host is honoured, since nothing here can ask that host.
    public func isLive(now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(heartbeatAt) < Self.staleAfter else { return false }
        guard host == Self.thisHost else { return true }
        if pid == ProcessInfo.processInfo.processIdentifier { return false }
        // `kill(pid, 0)` delivers nothing and reports whether the process
        // exists (EPERM means it does, under another user).
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// True when a live instance of the app holds `projectsRoot`.
    public static func isHeld(projectsRoot: URL) -> Bool {
        read(projectsRoot: projectsRoot)?.isLive() ?? false
    }
}

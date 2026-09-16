import Foundation

/// The contents of `<root>/PicPlace/account.json` — which PicPlace account a
/// LIBRARY belongs to (docs/picplace-sync-v2-plan.md §3.1, decisions D1–D2).
///
/// A library binds to at most one account on one server instance, and the
/// binding is a file in the library — never the folder's path (usernames
/// change, folders move, a second Mac adopts the volume) and never
/// `UserDefaults` (which names an install, not a library). The record keys
/// the account by `(server.id, user.uuid)`: the server's own instance id
/// once it reports one, the host and the user's uuid until then. `username`
/// and `name` are display only.
///
/// `initialSync` is the first-connection flow's state machine: the Mac's
/// nest-and-relaunch, a crash or a closed lid resume the flow at launch
/// from this record rather than losing it.
///
/// In the Kit so the `lapse` CLI and the audit can read it; the app owns the
/// sessions and the sync itself.
public struct PicPlaceBindingRecord: Codable, Equatable, Sendable {

    public struct Server: Codable, Equatable, Sendable {
        /// What the app dialled, normalised (`https://picplace.co`).
        public var url: String
        /// The instance id the server reports in `GET /status` — nil until
        /// the server ships it; then authoritative over the host.
        public var id: String?
        /// `local` | `production`, informational.
        public var environment: String?

        public init(url: String, id: String? = nil, environment: String? = nil) {
            self.url = url
            self.id = id
            self.environment = environment
        }

        /// The host alone — the folder name on the Mac, and the pre-`id` key.
        public var host: String {
            URL(string: url)?.host?.lowercased() ?? url.lowercased()
        }
    }

    public struct User: Codable, Equatable, Sendable {
        /// Minted once per server instance; the anchor of every object key.
        public var uuid: String
        public var username: String?
        public var name: String?

        public init(uuid: String, username: String? = nil, name: String? = nil) {
            self.uuid = uuid
            self.username = username
            self.name = name
        }

        /// What a folder and a card show: the username, else the name, else
        /// a stub of the uuid.
        public var displayHandle: String {
            if let username, !username.isEmpty { return username }
            if let name, !name.isEmpty { return name }
            return String(uuid.prefix(8))
        }
    }

    /// Which of the account's libraries this one is (docs/libraries-plan.md
    /// L9): the identity file's uuid and the name it had when it bound.
    /// Optional in format 1 — records written before 2026-09-16 have none,
    /// and the server ignores it until it learns what a library is (L8);
    /// then it is the key the requests are scoped by.
    public struct Library: Codable, Equatable, Sendable {
        public var uuid: UUID
        public var name: String

        public init(uuid: UUID, name: String) {
            self.uuid = uuid
            self.name = name
        }
    }

    public struct InitialSync: Codable, Equatable, Sendable {
        public enum State: String, Codable, Sendable { case pending, done }
        public enum Case: String, Codable, Sendable { case clean, fresh, merge }
        public var state: State
        public var `case`: Case?
        public var completedAt: Date?

        public init(state: State = .pending, case: Case? = nil, completedAt: Date? = nil) {
            self.state = state
            self.case = `case`
            self.completedAt = completedAt
        }
    }

    public static let format = 1
    public static let folderName = "PicPlace"
    public static let fileName = "account.json"
    /// The library-scoped sync records (this device's pushes and pulls, the
    /// merge base per project), beside the binding. Written by the app.
    public static let syncStateFileName = "sync-state.json"
    /// This library's auto-sync switches, one entry per device (libraries
    /// plan L7) — beside the binding, written by the app. (A `session.json`
    /// lived here for a day; the session is the Mac's, L13.)
    public static let settingsFileName = "settings.json"

    public var format: Int
    public var server: Server
    public var user: User
    public var boundAt: Date
    public var boundByDevice: UUID
    public var initialSync: InitialSync
    public var library: Library?

    public init(server: Server, user: User, boundAt: Date = Date(), boundByDevice: UUID,
                initialSync: InitialSync = InitialSync(), library: Library? = nil) {
        self.format = Self.format
        self.server = server
        self.user = user
        self.boundAt = boundAt
        self.boundByDevice = boundByDevice
        self.initialSync = initialSync
        self.library = library
    }

    // MARK: Keys

    /// The account key every per-account store uses (Keychain items, the
    /// session pointer): `<host>|<user uuid>`, lowercased.
    public static func accountKey(host: String, userUUID: String) -> String {
        "\(host.lowercased())|\(userUUID.lowercased())"
    }

    public var accountKey: String { Self.accountKey(host: server.host, userUUID: user.uuid) }

    /// Whether a session on `host` as `userUUID` — optionally on a server
    /// that reports `serverID` — is the account this library belongs to.
    /// The instance id wins when both sides know one; otherwise the host
    /// and the user's uuid decide.
    public func matches(host: String, userUUID: String, serverID: String? = nil) -> Bool {
        guard user.uuid.lowercased() == userUUID.lowercased() else { return false }
        if let mine = server.id, let theirs = serverID { return mine == theirs }
        return server.host == host.lowercased()
    }

    // MARK: Files

    public static func folderURL(inRoot root: URL) -> URL {
        root.appendingPathComponent(folderName, isDirectory: true)
    }

    public static func url(inRoot root: URL) -> URL {
        folderURL(inRoot: root).appendingPathComponent(fileName)
    }

    public static func syncStateURL(inRoot root: URL) -> URL {
        folderURL(inRoot: root).appendingPathComponent(syncStateFileName)
    }

    public static func settingsURL(inRoot root: URL) -> URL {
        folderURL(inRoot: root).appendingPathComponent(settingsFileName)
    }

    /// nil when the library is unbound — or when the file exists but cannot
    /// be read, which is reported by the caller, never repaired silently.
    public static func read(inRoot root: URL) -> PicPlaceBindingRecord? {
        guard let data = try? Data(contentsOf: url(inRoot: root)) else { return nil }
        return try? NDJSONFile.makeDecoder().decode(PicPlaceBindingRecord.self, from: data)
    }

    public static func exists(inRoot root: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(inRoot: root).path)
    }

    public func write(inRoot root: URL) throws {
        let encoder = NDJSONFile.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: Self.folderURL(inRoot: root), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: Self.url(inRoot: root), options: .atomic)
    }

    /// Removes the binding and the sync state — "Disconnect this library".
    /// The folder itself stays (it is a library item); the projects are
    /// untouched.
    public static func remove(inRoot root: URL) {
        try? FileManager.default.removeItem(at: url(inRoot: root))
        try? FileManager.default.removeItem(at: syncStateURL(inRoot: root))
    }
}

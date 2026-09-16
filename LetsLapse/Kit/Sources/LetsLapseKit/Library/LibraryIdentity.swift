import Foundation

/// The contents of `<root>/letslapse-library.json` — what makes a folder a
/// LetsLapse library (docs/libraries-plan.md, L1).
///
/// A library is identified by a uuid minted once, at creation, and never by
/// its folder: usernames change, folders move, drives get renamed. The name
/// is for humans and defaults to the folder's; renaming it never renames
/// the folder. The same uuid becomes the server's key for the library once
/// PicPlace learns what a library is (plan L8), exactly as a project's
/// `originID` is the project's.
///
/// Libraries that predate the file get one on their first launch — healed,
/// the way the export is regenerated — so `read` answering nil means "no
/// file", never "not a library": `detect(root:)` is the question to ask
/// about a folder.
///
/// In the Kit so the `lapse` CLI and the audit can read it; the app owns
/// the registry of known libraries and the flows that create and switch.
public struct LibraryIdentity: Codable, Equatable, Sendable {

    public static let format = 1
    public static let fileName = "letslapse-library.json"

    public var format: Int
    public var id: UUID
    public var name: String
    /// False for a library that predates the file and took its folder's
    /// name as a placeholder (libraries plan L16): the list shows it as
    /// unnamed, and connecting asks for a name — the server library needs
    /// one a person chose. Absent in files written before 2026-09-16
    /// evening, which were all healed: read as false.
    public var namedByPerson: Bool
    public var createdAt: Date
    public var createdByDevice: UUID
    /// The app version that wrote the file, informational.
    public var createdWith: String?

    public init(id: UUID = UUID(), name: String, namedByPerson: Bool = true, createdAt: Date = Date(), createdByDevice: UUID, createdWith: String? = nil) {
        self.format = Self.format
        self.id = id
        self.name = Self.cleanName(name)
        self.namedByPerson = namedByPerson
        // Rounded to the millisecond the file stores, so a record equals its
        // own read-back (the same rule as a sync revision).
        self.createdAt = Date(timeIntervalSince1970: (createdAt.timeIntervalSince1970 * 1000).rounded() / 1000)
        self.createdByDevice = createdByDevice
        self.createdWith = createdWith
    }

    private enum CodingKeys: String, CodingKey {
        case format, id, name, namedByPerson, createdAt, createdByDevice, createdWith
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(Int.self, forKey: .format)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        namedByPerson = try container.decodeIfPresent(Bool.self, forKey: .namedByPerson) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        createdByDevice = try container.decode(UUID.self, forKey: .createdByDevice)
        createdWith = try container.decodeIfPresent(String.self, forKey: .createdWith)
    }

    // MARK: Names

    /// A name as stored: trimmed, single-line, at most 120 characters.
    /// Empty stays empty — the caller substitutes the folder's name.
    public static func cleanName(_ raw: String) -> String {
        let oneLine = raw.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let trimmed = oneLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(120))
    }

    /// The name a library gets when nobody named it: the folder's own name.
    public static func defaultName(forRoot root: URL) -> String {
        let folder = root.standardizedFileURL.lastPathComponent
        return folder.isEmpty || folder == "/" ? "LetsLapse" : folder
    }

    /// The name to show: the stored one, else the folder's.
    public var displayName: String {
        name.isEmpty ? "Library" : name
    }

    // MARK: Files

    public static func url(inRoot root: URL) -> URL {
        root.appendingPathComponent(fileName)
    }

    public static func exists(inRoot root: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(inRoot: root).path)
    }

    /// nil when there is no file — or when it exists but cannot be read,
    /// which `ensure` reports rather than repairs.
    public static func read(inRoot root: URL) -> LibraryIdentity? {
        guard let data = try? Data(contentsOf: url(inRoot: root)) else { return nil }
        return try? NDJSONFile.makeDecoder().decode(LibraryIdentity.self, from: data)
    }

    public func write(inRoot root: URL) throws {
        let encoder = NDJSONFile.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: Self.url(inRoot: root), options: .atomic)
    }

    /// What `ensure` did.
    public enum Healing: Equatable, Sendable {
        /// The file was there and read.
        case existing
        /// No file: one was minted and written.
        case created
        /// A file is there and could not be read; it is left exactly as it
        /// is (the caller says so), and the library runs without an identity.
        case unreadable
    }

    /// Read the identity, or mint one for a library that predates the file.
    /// `name` is used only when minting and counts as the person's; empty
    /// means the folder's name, as a placeholder (`namedByPerson == false`).
    public static func ensure(inRoot root: URL, name: String = "", device: UUID, appVersion: String? = nil) throws -> (identity: LibraryIdentity?, healing: Healing) {
        if let existing = read(inRoot: root) { return (existing, .existing) }
        if exists(inRoot: root) { return (nil, .unreadable) }
        let cleaned = cleanName(name)
        let minted = LibraryIdentity(
            name: cleaned.isEmpty ? defaultName(forRoot: root) : cleaned,
            namedByPerson: !cleaned.isEmpty,
            createdByDevice: device, createdWith: appVersion)
        try minted.write(inRoot: root)
        return (minted, .created)
    }

    // MARK: Detection

    /// Whether a folder is a library, and how that was decided.
    public enum Detection: Equatable, Sendable {
        /// The identity file is there.
        case identity(LibraryIdentity)
        /// No identity file, but `Projects/` holds at least one project
        /// document (live or in `.trash`) — a library from before the file.
        case documents
        /// No identity file and no document, but `Projects/library.json`
        /// exists — the pre-M1 export on its own (an empty library that was
        /// only ever opened by an older build).
        case export
        /// Not a library.
        case none

        public var isLibrary: Bool {
            if case .none = self { return false }
            return true
        }
    }

    /// Ask this about a folder, never `read` alone: a library that predates
    /// the identity file is still a library (plan L2 — this is what closes
    /// the data-model M4 trap, where the retired export was the only test).
    public static func detect(root: URL) -> Detection {
        if let identity = read(inRoot: root) { return .identity(identity) }
        let fileManager = FileManager.default
        let projects = root.appendingPathComponent("Projects", isDirectory: true)
        let trash = projects.appendingPathComponent(".trash", isDirectory: true)
        for container in [projects, trash] {
            for name in (try? fileManager.contentsOfDirectory(atPath: container.path)) ?? []
            where !name.hasPrefix(".") && UUID(uuidString: name) != nil {
                let document = ProjectDocumentFormat.url(inProjectFolder: container.appendingPathComponent(name, isDirectory: true))
                if fileManager.fileExists(atPath: document.path) { return .documents }
            }
        }
        if fileManager.fileExists(atPath: projects.appendingPathComponent(LibraryExportFormat.fileName).path) { return .export }
        return .none
    }
}

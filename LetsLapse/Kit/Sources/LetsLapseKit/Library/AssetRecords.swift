import Foundation

/// One line of `Projects/<id>/assets.ndjson`: everything the library knows
/// about one asset, keyed by its relative file name (`source/frame-00042.dng`,
/// `blends/<uuid>.mp4`) — the key `framing.json` and `frames.whitebalance`
/// already use and the one that survives a transfer.
///
/// The line carries the content identity (`bytes`, `hash`, `hashedAt`; Phase
/// 1 W5) and, since Milestone 1 of the data-model work, the two metadata
/// layers (Part 2 §4.2): `imported` is what the file, its sidecar or a
/// catalogue said and is re-derivable by re-reading; `edited` is sparse and
/// holds only what a person changed here. `editedAt` stamps each edited
/// field, which is the per-field ordering the sync journal will need.
///
/// **Latest line per name wins.** An edit appends the WHOLE record again
/// rather than a delta, so a reader that keeps the last line it saw for a
/// name is always right; `AssetRecords.compact` rewrites one line per name
/// when the app is idle.
public struct AssetRecord: Codable, Equatable, Sendable {
    public var name: String
    public var bytes: Int64?
    /// `"sha256:<hex>"` over the whole file.
    public var hash: String?
    public var hashedAt: Date?
    public var imported: AssetMetadata?
    /// Where the imported layer came from: `file`, `sidecar` (the `.xmp`
    /// beside a raw contributed, and won), `catalogue`.
    public var importedSource: String?
    public var importedAt: Date?
    public var edited: AssetMetadata?
    /// Per edited field (its `MetadataField` raw value), when it was set.
    public var editedAt: [String: Date]?

    public init(name: String) {
        self.name = name
    }

    /// `edited` over `imported`.
    public var resolved: AssetMetadata {
        AssetMetadata.resolving(edited, over: imported)
    }

    /// True when a person changed `field` here.
    public func isEdited(_ field: MetadataField) -> Bool {
        edited?[field] != nil
    }
}

/// The per-project asset record file, in memory: latest line per name, in
/// first-seen order.
public struct AssetRecords: Equatable, Sendable {

    public static let fileName = ProjectFileRegistry.assetRecordsName

    private(set) public var records: [String: AssetRecord] = [:]
    private(set) public var order: [String] = []

    public init() {}

    public init(records: [AssetRecord]) {
        for record in records { put(record) }
    }

    public var isEmpty: Bool { records.isEmpty }
    public var count: Int { records.count }

    public subscript(name: String) -> AssetRecord? { records[name] }

    /// The records in first-seen order — the order compaction writes.
    public var ordered: [AssetRecord] { order.compactMap { records[$0] } }

    public mutating func put(_ record: AssetRecord) {
        if records[record.name] == nil { order.append(record.name) }
        records[record.name] = record
    }

    public mutating func remove(_ name: String) {
        guard records.removeValue(forKey: name) != nil else { return }
        order.removeAll { $0 == name }
    }

    // MARK: - Files

    public static func url(inProjectFolder folder: URL) -> URL {
        folder.appendingPathComponent(fileName)
    }

    /// Reads the file, torn-line tolerant, latest line per name winning. A
    /// missing file is an empty set, never an error.
    public static func load(from url: URL) -> AssetRecords {
        guard let data = try? Data(contentsOf: url) else { return AssetRecords() }
        return decode(data)
    }

    public static func load(inProjectFolder folder: URL) -> AssetRecords {
        load(from: url(inProjectFolder: folder))
    }

    public static func decode(_ data: Data) -> AssetRecords {
        AssetRecords(records: NDJSONFile.decode(AssetRecord.self, from: data))
    }

    /// Appends one record as a line. The line is the whole record.
    public static func append(_ record: AssetRecord, to url: URL) throws {
        try NDJSONFile.append(record, to: url)
    }

    /// Rewrites the file with one line per name, through a temp file and
    /// `replaceItemAt`. Only at idle — a reader mid-append sees either file.
    public func compact(to url: URL) throws {
        try NDJSONFile.rewrite(ordered, at: url)
    }

    /// True when the file holds more lines than names — worth compacting.
    public static func needsCompaction(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true).count
        return lines > decode(data).count
    }

    /// The names of the assets a project lists — its frames and blend outputs
    /// — that have no complete hash line yet, or whose recorded size no
    /// longer matches the file. What the backfill works through.
    public func namesNeedingHash(among names: [String], in folder: URL) -> [String] {
        names.filter { name in
            guard let size = try? folder.appendingPathComponent(name)
                .resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
            guard let record = records[name], record.hash != nil else { return true }
            return record.bytes != Int64(size)
        }
    }
}

/// The project-level record — `Projects/<id>/metadata.json`:
/// `{schemaVersion, project: {imported, edited, editedAt}}`.
///
/// Its own small file rather than a line in `assets.ndjson` because it is
/// the record a whole interval shoot's panel edits, rewritten atomically on
/// each edit; and not inside the manifest, because a 5,000-frame set's
/// Lightroom metadata must never make the library's index heavier.
public struct ProjectMetadata: Codable, Equatable, Sendable {
    public static let fileName = ProjectFileRegistry.projectMetadataName
    public static let currentSchema = 1

    public var schemaVersion: Int = currentSchema
    public var imported: AssetMetadata?
    public var importedSource: String?
    public var importedAt: Date?
    public var edited: AssetMetadata?
    public var editedAt: [String: Date]?

    public init() {}

    public var isEmpty: Bool {
        (imported?.isEmpty ?? true) && (edited?.isEmpty ?? true)
    }

    public static func url(inProjectFolder folder: URL) -> URL {
        folder.appendingPathComponent(fileName)
    }

    public static func load(inProjectFolder folder: URL) -> ProjectMetadata? {
        guard let data = try? Data(contentsOf: url(inProjectFolder: folder)) else { return nil }
        return try? NDJSONFile.makeDecoder().decode(ProjectMetadata.self, from: data)
    }

    public func write(inProjectFolder folder: URL) throws {
        let encoder = NDJSONFile.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: Self.url(inProjectFolder: folder), options: .atomic)
    }
}

import Foundation
import LetsLapseKit

/// The one owner of a project's `assets.ndjson` and `metadata.json` inside
/// the app: every read goes through its cache and every write through its
/// serial queue, so the panel's edit and the background hasher never
/// interleave half-lines in one file.
///
/// Two queues on purpose. `writeQueue` does nothing but short appends and
/// atomic rewrites, so an edit from the main actor (`update`, synchronous —
/// an edit is durable when the call returns) waits on at most one line.
/// `workQueue` does the slow part — hashing a 47 MB DNG, reading a raw's
/// header — and hops to `writeQueue` with the finished record. The hasher is
/// the W5 `HashBackfill`: utility QoS, one file at a time, resumable (a
/// killed run resumes from whatever lines landed), and paused while the
/// device is hot, on low power, or the library is busy shooting, rendering
/// or transferring.
final class AssetRecordStore: @unchecked Sendable {

    private let writeQueue = DispatchQueue(label: "com.regularsteven.letslapse.asset-records.write", qos: .utility)
    private let workQueue = DispatchQueue(label: "com.regularsteven.letslapse.asset-records.work", qos: .utility)
    private let lock = NSLock()
    private var recordCache: [String: AssetRecords] = [:]
    private var projectCache: [String: ProjectMetadata?] = [:]
    /// Folders with a hashing job queued or running, so a project is never
    /// walked twice at once.
    private var busyFolders: Set<String> = []

    /// Fired on the main actor when a project's records changed on disk —
    /// the panel re-reads. Throttled by the recorder to once per batch.
    var onChange: (@MainActor (URL) -> Void)?

    /// True while the recorder should hold back: a shoot, a render, a
    /// transfer, or a device that is hot or on low power.
    var shouldPause: @Sendable () -> Bool = { false }

    init() {}

    // MARK: - Reading

    func records(inProjectFolder folder: URL) -> AssetRecords {
        let key = folder.path
        lock.lock()
        if let cached = recordCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let loaded = AssetRecords.load(inProjectFolder: folder)
        lock.lock()
        recordCache[key] = loaded
        lock.unlock()
        return loaded
    }

    func projectMetadata(inProjectFolder folder: URL) -> ProjectMetadata? {
        let key = folder.path
        lock.lock()
        if let cached = projectCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let loaded = ProjectMetadata.load(inProjectFolder: folder)
        lock.lock()
        projectCache[key] = .some(loaded)
        lock.unlock()
        return loaded
    }

    /// Drops what is cached for a folder — after an install re-keys its
    /// blends, or a folder moves.
    func forget(projectFolder folder: URL) {
        lock.lock()
        recordCache[folder.path] = nil
        projectCache[folder.path] = nil
        lock.unlock()
    }

    // MARK: - Writing

    /// Changes one asset's record and appends the whole record as a new
    /// line. Synchronous: when this returns the line is on disk.
    func update(inProjectFolder folder: URL, name: String, _ mutate: (inout AssetRecord) -> Void) throws {
        var records = self.records(inProjectFolder: folder)
        var record = records[name] ?? AssetRecord(name: name)
        mutate(&record)
        records.put(record)
        try writeQueue.sync {
            try AssetRecords.append(record, to: AssetRecords.url(inProjectFolder: folder))
        }
        lock.lock()
        recordCache[folder.path] = records
        lock.unlock()
    }

    /// Changes the project-level record and rewrites `metadata.json`
    /// atomically. Synchronous, as `update` is.
    func updateProject(inProjectFolder folder: URL, _ mutate: (inout ProjectMetadata) -> Void) throws {
        var metadata = projectMetadata(inProjectFolder: folder) ?? ProjectMetadata()
        mutate(&metadata)
        try writeQueue.sync {
            try metadata.write(inProjectFolder: folder)
        }
        lock.lock()
        projectCache[folder.path] = .some(metadata)
        lock.unlock()
    }

    /// Rewrites `assets.ndjson` with the given set — the install path's
    /// re-keying of blend names, and the DNG clone's re-keyed frames.
    func replace(inProjectFolder folder: URL, with records: AssetRecords) throws {
        try writeQueue.sync {
            try records.compact(to: AssetRecords.url(inProjectFolder: folder))
        }
        lock.lock()
        recordCache[folder.path] = records
        lock.unlock()
    }

    /// One line per name again, when the file has grown past its names.
    /// Called at idle only.
    func compactIfNeeded(inProjectFolder folder: URL) {
        let url = AssetRecords.url(inProjectFolder: folder)
        guard AssetRecords.needsCompaction(at: url) else { return }
        let records = self.records(inProjectFolder: folder)
        writeQueue.async {
            try? records.compact(to: url)
        }
    }

    // MARK: - Recording (hash + imported metadata)

    /// What a finished job reports back, on the main actor.
    struct Outcome: Sendable {
        var folder: URL
        var recorded: Int
        /// The project-level `imported` layer derived from every source
        /// frame's record — the fields they all agree on, keywords unioned.
        var projectImported: AssetMetadata?
        var projectSource: String?
    }

    /// Hashes every named asset that has no current hash line, and reads
    /// the `imported` metadata layer of every source still among them,
    /// appending one line per file as it goes. `completion` fires on the
    /// main actor when the walk ends, with the project-level record derived
    /// from the frames.
    ///
    /// `extractMetadata` is on for registration and the backfill's first
    /// pass over a project, off for a blend output (a render has no IPTC).
    /// `pausable` is the backfill's flag: a registration-time job runs at
    /// once — the import that started it is what `shouldPause` would see as
    /// "busy", and the panel opens on that project next.
    func recordAssets(
        inProjectFolder folder: URL,
        names: [String],
        extractMetadata: Bool,
        priority: DispatchQoS = .utility,
        pausable: Bool = false,
        completion: (@MainActor (Outcome) -> Void)? = nil
    ) {
        let key = folder.path
        lock.lock()
        guard !busyFolders.contains(key) else {
            lock.unlock()
            return
        }
        busyFolders.insert(key)
        lock.unlock()

        workQueue.async(qos: priority) { [self] in
            defer {
                lock.lock()
                busyFolders.remove(key)
                lock.unlock()
            }
            var records = self.records(inProjectFolder: folder)
            var pending = records.namesNeedingHash(among: names, in: folder)
            if extractMetadata {
                // A frame whose hash landed before its metadata was read (an
                // older build, or a blend-only pass) still needs the read.
                for name in names where !pending.contains(name)
                    && Self.isSourceStill(name) && records[name]?.imported == nil
                    && FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
                    pending.append(name)
                }
            }
            var recorded = 0
            var sinceNotify = 0
            for name in pending {
                // The pause: hot, low power, or a shoot / render / transfer.
                while pausable, shouldPause() {
                    Thread.sleep(forTimeInterval: 5)
                }
                let url = folder.appendingPathComponent(name)
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
                var record = records[name] ?? AssetRecord(name: name)
                if extractMetadata, Self.isSourceStill(name) {
                    let read = MetadataReader.read(fileAt: url)
                    record.imported = read.metadata.isEmpty ? nil : read.metadata
                    record.importedSource = read.source
                    record.importedAt = Date()
                }
                if record.hash == nil || record.bytes != Int64(size) {
                    guard let hash = try? AssetHash.sha256(of: url) else { continue }
                    record.hash = hash
                    record.bytes = Int64(size)
                    record.hashedAt = Date()
                }
                records.put(record)
                let line = record
                writeQueue.sync {
                    try? AssetRecords.append(line, to: AssetRecords.url(inProjectFolder: folder))
                }
                lock.lock()
                recordCache[key] = records
                lock.unlock()
                recorded += 1
                sinceNotify += 1
                if sinceNotify >= 25 {
                    sinceNotify = 0
                    let changed = folder
                    Task { @MainActor in self.onChange?(changed) }
                }
            }

            // The project-level record: what the frames agree on.
            var projectImported: AssetMetadata?
            var projectSource: String?
            if extractMetadata {
                let frames = names.filter(Self.isSourceStill).compactMap { records[$0]?.imported }
                if !frames.isEmpty {
                    let common = AssetMetadata.common(across: frames)
                    projectImported = common.isEmpty ? nil : common
                    projectSource = names.compactMap { records[$0]?.importedSource }
                        .contains(MetadataReader.sourceSidecar) ? MetadataReader.sourceSidecar : MetadataReader.sourceFile
                    if let projectImported {
                        try? self.updateProject(inProjectFolder: folder) { metadata in
                            metadata.imported = projectImported
                            metadata.importedSource = projectSource
                            metadata.importedAt = Date()
                        }
                    }
                }
            }
            if recorded > 0 || projectImported != nil {
                LLog("assets: \(folder.lastPathComponent.prefix(8)) recorded \(recorded) of \(pending.count) pending (\(names.count) assets)")
            }
            let outcome = Outcome(folder: folder, recorded: recorded, projectImported: projectImported, projectSource: projectSource)
            Task { @MainActor in
                self.onChange?(folder)
                completion?(outcome)
            }
        }
    }

    /// A source frame the metadata reader can read: a still under `source/`.
    static func isSourceStill(_ name: String) -> Bool {
        name.hasPrefix("source/") && ImportedStills.isStill(URL(fileURLWithPath: name))
    }
}

import Foundation

/// The library's index — a SQLite database rebuilt from the per-project
/// files, never the other way round (data model Phase 3; Part 2 §5, §8).
///
/// The truth is on disk as `Projects/<id>/project.json`, `assets.ndjson`
/// and `metadata.json`. This database is a CACHE of the searchable subset
/// of those files: what a list renders without opening a folder (id,
/// origin, kind, dates, name, mode, frame count, dimensions, size, tags),
/// the blend entries, one row per asset (bytes, hash, rating, title,
/// caption, keywords, camera, place) and an FTS5 table over the words a
/// person would search for. Deleting `Index/library.sqlite` loses nothing:
/// `rebuild(from:)` walks the files and reproduces it, and that walk IS the
/// reconciliation Part 1 §6.2 asked for. Measured in Part 2 §5: every
/// query here answers in under 5 ms at a million rows, where the JSON
/// manifest in memory ends between 10k and 30k projects on a phone.
///
/// JSON-level like the audit: the app hands it the document bytes it just
/// wrote, and the rebuild reads the same files the audit reads, so the Kit
/// needs none of the app's record types. Dates are stored as seconds since
/// 2001 — the manifest's own convention — parsed from the documents' ISO-8601.
///
/// Thread-safe: every public call takes the instance's lock, so the
/// document writer (on the persister's queue) and the asset-record store
/// (on its own) can both keep it current. WAL mode lets the `lapse` CLI
/// read the file while the app writes it.
public final class LibraryIndex: @unchecked Sendable {

    /// 2 (M2): `category`, `scanner_sidecar`, `edited_at`, the shape counts
    /// and `shapes_indexed_at` on the project row; tag labels in the search
    /// table. A v1 database is dropped and rebuilt from the files.
    public static let schemaVersion = 2
    public static let folderName = "Index"
    public static let fileName = "library.sqlite"

    /// `<root>/Index/library.sqlite` — a top-level sibling of `Projects/`,
    /// where the other caches live.
    public static func url(inRoot root: URL) -> URL {
        root.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(fileName)
    }

    public let url: URL
    private let db: SQLiteDatabase
    private let lock = NSRecursiveLock()

    public init(at url: URL) throws {
        self.url = url
        db = try SQLiteDatabase(at: url)
        try migrate()
    }

    // MARK: - Schema

    private func migrate() throws {
        let version = db.userVersion
        guard version < Self.schemaVersion else { return }
        if version > 0 {
            // A database from an older schema: drop it and start over. It is
            // a cache; the files rebuild it.
            try db.execute("""
                DROP TABLE IF EXISTS search; DROP TABLE IF EXISTS assets;
                DROP TABLE IF EXISTS blends; DROP TABLE IF EXISTS projects; DROP TABLE IF EXISTS meta;
                """)
        }
        try db.execute("""
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS projects (
                id TEXT PRIMARY KEY,
                origin_id TEXT, origin_device_id TEXT, derived_from_origin_id TEXT, imported_from_id TEXT,
                kind TEXT NOT NULL, capture_mode TEXT,
                name TEXT, original_name TEXT NOT NULL, mode TEXT NOT NULL,
                created_at REAL NOT NULL, added_at REAL, modified_at REAL, deleted_at REAL,
                frame_count INTEGER NOT NULL, width INTEGER, height INTEGER, duration_seconds REAL, fps REAL,
                size_bytes INTEGER, size_measured_at REAL,
                preset_kind TEXT, preset_id TEXT,
                scene_tags TEXT, scene_elements TEXT,
                blend_count INTEGER NOT NULL DEFAULT 0,
                revision INTEGER, modified_by TEXT,
                title TEXT, caption TEXT, rating INTEGER, creator TEXT, keywords TEXT,
                city TEXT, country TEXT,
                folder TEXT NOT NULL,
                document_modified_at REAL,
                assets_indexed_at REAL,
                category TEXT NOT NULL DEFAULT 'interval',
                scanner_sidecar INTEGER,
                edited_at REAL,
                shape_ellipses INTEGER NOT NULL DEFAULT 0,
                shape_rectangles INTEGER NOT NULL DEFAULT 0,
                shape_squares INTEGER NOT NULL DEFAULT 0,
                shapes_indexed_at REAL
            );
            CREATE INDEX IF NOT EXISTS projects_created ON projects(deleted_at, created_at);
            CREATE INDEX IF NOT EXISTS projects_added ON projects(deleted_at, added_at);
            CREATE INDEX IF NOT EXISTS projects_modified ON projects(deleted_at, modified_at);
            CREATE INDEX IF NOT EXISTS projects_edited ON projects(deleted_at, edited_at);
            CREATE INDEX IF NOT EXISTS projects_size ON projects(deleted_at, size_bytes);
            CREATE INDEX IF NOT EXISTS projects_category ON projects(deleted_at, category);
            CREATE INDEX IF NOT EXISTS projects_origin ON projects(origin_id);
            CREATE TABLE IF NOT EXISTS blends (
                id TEXT PRIMARY KEY, project_id TEXT NOT NULL,
                kind TEXT NOT NULL, created_at REAL NOT NULL, modified_at REAL, deleted_at REAL,
                output_file_name TEXT NOT NULL, summary TEXT NOT NULL,
                width INTEGER, height INTEGER, output_fps INTEGER, input_frames INTEGER, output_frames INTEGER,
                has_warp INTEGER NOT NULL DEFAULT 0, has_time_slice INTEGER NOT NULL DEFAULT 0,
                has_reframe INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS blends_project ON blends(project_id, deleted_at, created_at);
            CREATE TABLE IF NOT EXISTS assets (
                project_id TEXT NOT NULL, name TEXT NOT NULL,
                bytes INTEGER, hash TEXT, hashed_at REAL,
                title TEXT, caption TEXT, rating INTEGER, creator TEXT, keywords TEXT,
                captured TEXT, camera TEXT, lens TEXT, city TEXT, country TEXT, lat REAL, lon REAL,
                edited INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (project_id, name)
            );
            CREATE INDEX IF NOT EXISTS assets_hash ON assets(hash);
            CREATE INDEX IF NOT EXISTS assets_rating ON assets(rating);
            CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(
                kind UNINDEXED, id UNINDEXED, project_id UNINDEXED,
                title, name, caption, keywords,
                tokenize='unicode61 remove_diacritics 2'
            );
            """)
        try db.setUserVersion(Self.schemaVersion)
    }

    // MARK: - Meta

    public func meta(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return (try? db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { $0.text(0) })?.first ?? nil
    }

    public func setMeta(_ key: String, _ value: String?) throws {
        lock.lock(); defer { lock.unlock() }
        if let value {
            try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [.text(key), .text(value)])
        } else {
            try db.run("DELETE FROM meta WHERE key = ?", [.text(key)])
        }
    }

    // MARK: - Rebuild

    public struct RebuildOutcome: Equatable {
        public var projects = 0
        public var blends = 0
        public var assets = 0
        public var unreadableDocuments: [String] = []
        public var seconds: Double = 0
    }

    /// Empties the database and refills it from every `project.json` under
    /// `Projects/<id>/` and `Projects/.trash/<id>/`, with each project's
    /// `assets.ndjson` and `metadata.json`. One transaction: a reader sees
    /// the old index or the new one.
    @discardableResult
    public func rebuild(fromProjectsFolder projects: URL) throws -> RebuildOutcome {
        lock.lock(); defer { lock.unlock() }
        let started = Date()
        var report = LibraryIndexRebuild.Report(root: projects.path)
        let documents = LibraryIndexRebuild.readDocuments(in: projects, report: &report)
        var outcome = RebuildOutcome()
        outcome.unreadableDocuments = report.unreadableDocuments
        try db.transaction {
            try db.execute("DELETE FROM search; DELETE FROM assets; DELETE FROM blends; DELETE FROM projects;")
            for document in documents {
                let folderPath = document.inTrash ? ".trash/\(document.folder)" : document.folder
                let folderURL = projects.appendingPathComponent(folderPath, isDirectory: true)
                let documentURL = ProjectDocumentFormat.url(inProjectFolder: folderURL)
                let modified = (try? documentURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                try upsertProject(document.capture, blends: document.blends, folder: folderPath, documentModifiedAt: modified, projectFolderURL: folderURL)
                outcome.projects += 1
                outcome.blends += document.blends.count
                outcome.assets += try upsertAssets(projectID: document.captureID, inProjectFolder: folderURL)
                try upsertShapes(projectID: document.captureID, inProjectFolder: folderURL)
            }
            try setMeta("builtAt", FrameTimestamps.string(from: Date()))
            try setMeta("source", projects.path)
        }
        outcome.seconds = Date().timeIntervalSince(started)
        return outcome
    }

    // MARK: - Upserts (the app's incremental path)

    /// Indexes one project from the bytes of its `project.json` — what the
    /// app hands over right after writing the file. `folder` is the
    /// project's folder relative to `Projects/` (`<id>` or `.trash/<id>`);
    /// `projectFolderURL` is where the folder is, for the one classification
    /// the document cannot settle alone (the scanner sidecar, read once).
    public func upsertProject(documentData data: Data, folder: String, documentModifiedAt: Date? = nil, projectFolderURL: URL? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let capture = object["capture"] as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try db.transaction {
            try upsertProject(capture, blends: object["blends"] as? [[String: Any]] ?? [], folder: folder,
                              documentModifiedAt: documentModifiedAt, projectFolderURL: projectFolderURL)
        }
    }

    /// Re-counts one project's shapes from its `shapes.json` (M2) — the
    /// Gallery's SHAPES rows. An empty register counts as no shapes and
    /// stamps `shapesIndexedAt`; a missing one counts as none and clears it.
    public func reindexShapes(projectID: UUID, inProjectFolder folder: URL) throws {
        lock.lock(); defer { lock.unlock() }
        try db.transaction {
            try upsertShapes(projectID: projectID.uuidString.uppercased(), inProjectFolder: folder)
        }
    }

    /// When the project's shape counts were last written — nil when never.
    public func shapesIndexedAt(projectID: UUID) -> Date? {
        lock.lock(); defer { lock.unlock() }
        let rows = try? db.query("SELECT shapes_indexed_at FROM projects WHERE id = ?", [.text(projectID.uuidString.uppercased())]) { $0.real(0) }
        guard let seconds = rows?.first ?? nil else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Re-indexes one project's assets from its `assets.ndjson` and
    /// `metadata.json`; returns the number of asset rows written.
    @discardableResult
    public func reindexAssets(projectID: UUID, inProjectFolder folder: URL) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        return try db.transaction {
            try upsertAssets(projectID: projectID.uuidString.uppercased(), inProjectFolder: folder)
        }
    }

    public func removeProject(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        let key = id.uuidString.uppercased()
        try db.transaction {
            try db.run("DELETE FROM search WHERE project_id = ?", [.text(key)])
            try db.run("DELETE FROM assets WHERE project_id = ?", [.text(key)])
            try db.run("DELETE FROM blends WHERE project_id = ?", [.text(key)])
            try db.run("DELETE FROM projects WHERE id = ?", [.text(key)])
        }
    }

    /// When the project's document was last indexed, by its file's
    /// modification date — nil when the project is not in the index.
    public func documentModifiedAt(projectID: UUID) -> Date? {
        lock.lock(); defer { lock.unlock() }
        let rows = try? db.query("SELECT document_modified_at FROM projects WHERE id = ?", [.text(projectID.uuidString.uppercased())]) { $0.real(0) }
        guard let seconds = rows?.first ?? nil else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// When the project's asset rows were last written — nil when never.
    public func assetsIndexedAt(projectID: UUID) -> Date? {
        lock.lock(); defer { lock.unlock() }
        let rows = try? db.query("SELECT assets_indexed_at FROM projects WHERE id = ?", [.text(projectID.uuidString.uppercased())]) { $0.real(0) }
        guard let seconds = rows?.first ?? nil else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    private func upsertProject(_ capture: [String: Any], blends: [[String: Any]], folder: String, documentModifiedAt: Date?, projectFolderURL: URL?) throws {
        guard let id = (capture["id"] as? String)?.uppercased() else { return }
        func text(_ key: String) -> SQLiteDatabase.Value { .init((capture[key] as? String)?.uppercased()) }
        func plain(_ key: String) -> SQLiteDatabase.Value { .init(capture[key] as? String) }
        func date(_ key: String) -> SQLiteDatabase.Value { .init(Self.seconds(capture[key])) }
        func number(_ key: String) -> SQLiteDatabase.Value {
            if let value = capture[key] as? NSNumber { return .real(value.doubleValue) }
            return .null
        }
        func integer(_ key: String) -> SQLiteDatabase.Value {
            if let value = capture[key] as? NSNumber { return .int(value.int64Value) }
            return .null
        }
        let names = (capture["sourceFileNames"] as? [String] ?? []).filter { !$0.hasSuffix(".json") }
        let preset = capture["presetState"] as? [String: Any]
        let liveBlendRecords = blends.filter { $0["deletedAt"] == nil }
        let liveBlends = liveBlendRecords.count
        let kind = capture["kind"] as? String ?? ""
        let mode = capture["mode"] as? String ?? ""
        let captureMode = capture["captureMode"] as? String
        // The scanner sidecar's verdict is read at most once per project:
        // kept from the row across upserts, and read from the file only for
        // a project whose document cannot settle its category, when the
        // caller said where the folder is.
        var sidecar: Bool? = (try db.query("SELECT scanner_sidecar FROM projects WHERE id = ?", [.text(id)]) { $0.int(0) }.first ?? nil).map { $0 != 0 }
        if sidecar == nil, ProjectCategory.needsSidecar(kind: kind, mode: mode, captureMode: captureMode), let projectFolderURL {
            sidecar = ProjectCategory.sidecarHasRectangle(inProjectFolder: projectFolderURL)
        }
        let category = ProjectCategory.classify(kind: kind, mode: mode, captureMode: captureMode, scannerSidecar: sidecar ?? false)
        // The app's Edit date: a human edit, else the newest live blend,
        // else the capture — the same rule as `AppModel.lastEdited`.
        let editedAt = Self.seconds(capture["modifiedAt"])
            ?? liveBlendRecords.compactMap { Self.seconds($0["createdAt"]) }.max()
            ?? Self.seconds(capture["createdAt"])
        try db.run("""
            INSERT OR REPLACE INTO projects (
                id, origin_id, origin_device_id, derived_from_origin_id, imported_from_id,
                kind, capture_mode, name, original_name, mode,
                created_at, added_at, modified_at, deleted_at,
                frame_count, width, height, duration_seconds, fps, size_bytes, size_measured_at,
                preset_kind, preset_id, scene_tags, scene_elements, blend_count, revision, modified_by,
                title, caption, rating, creator, keywords, city, country,
                folder, document_modified_at, assets_indexed_at,
                category, scanner_sidecar, edited_at,
                shape_ellipses, shape_rectangles, shape_squares, shapes_indexed_at
            ) VALUES (?,?,?,?,?, ?,?,?,?,?, ?,?,?,?, ?,?,?,?,?,?,?, ?,?,?,?,?,?,?,
                (SELECT title FROM projects WHERE id = ?), (SELECT caption FROM projects WHERE id = ?),
                (SELECT rating FROM projects WHERE id = ?), (SELECT creator FROM projects WHERE id = ?),
                (SELECT keywords FROM projects WHERE id = ?), (SELECT city FROM projects WHERE id = ?),
                (SELECT country FROM projects WHERE id = ?),
                ?, ?, (SELECT assets_indexed_at FROM projects WHERE id = ?),
                ?, ?, ?,
                COALESCE((SELECT shape_ellipses FROM projects WHERE id = ?), 0),
                COALESCE((SELECT shape_rectangles FROM projects WHERE id = ?), 0),
                COALESCE((SELECT shape_squares FROM projects WHERE id = ?), 0),
                (SELECT shapes_indexed_at FROM projects WHERE id = ?))
            """, [
                .text(id), text("originID"), text("originDeviceID"), text("derivedFromOriginID"), text("importedFromID"),
                plain("kind"), plain("captureMode"), plain("name"), .init(capture["originalName"] as? String ?? ""), .init(mode),
                date("createdAt"), date("addedAt"), date("modifiedAt"), date("deletedAt"),
                .int(Int64(names.count)), integer("sourceWidth"), integer("sourceHeight"), number("sourceDurationSeconds"), number("sourceFPS"),
                integer("sizeBytes"), date("sizeMeasuredAt"),
                .init(preset?["kind"] as? String), .init((preset?["id"] as? String)?.uppercased()),
                .init(list: capture["sceneTags"] as? [String]), .init(list: capture["sceneElements"] as? [String]),
                .int(Int64(liveBlends)), integer("revision"), text("modifiedBy"),
                .text(id), .text(id), .text(id), .text(id), .text(id), .text(id), .text(id),
                .text(folder), .init(documentModifiedAt?.timeIntervalSinceReferenceDate), .text(id),
                .text(category.rawValue), .init(sidecar), .init(editedAt),
                .text(id), .text(id), .text(id), .text(id),
            ])
        try db.run("DELETE FROM blends WHERE project_id = ?", [.text(id)])
        for blend in blends {
            guard let blendID = (blend["id"] as? String)?.uppercased() else { continue }
            try db.run("""
                INSERT OR REPLACE INTO blends (
                    id, project_id, kind, created_at, modified_at, deleted_at, output_file_name, summary,
                    width, height, output_fps, input_frames, output_frames, has_warp, has_time_slice, has_reframe
                ) VALUES (?,?,?,?,?,?,?,?, ?,?,?,?,?,?,?,?)
                """, [
                    .text(blendID), .text(id), .init(blend["kind"] as? String ?? ""),
                    .init(Self.seconds(blend["createdAt"]) ?? 0), .init(Self.seconds(blend["modifiedAt"])), .init(Self.seconds(blend["deletedAt"])),
                    .init(blend["outputFileName"] as? String ?? ""), .init(blend["summary"] as? String ?? ""),
                    .init((blend["width"] as? NSNumber)?.int64Value), .init((blend["height"] as? NSNumber)?.int64Value),
                    .init((blend["outputFPS"] as? NSNumber)?.int64Value), .init((blend["inputFrames"] as? NSNumber)?.int64Value),
                    .init((blend["outputFrames"] as? NSNumber)?.int64Value),
                    .init(blend["warp"] != nil), .init(blend["timeSlice"] != nil), .init(blend["reframe"] != nil),
                ])
        }
        try refreshProjectSearchRow(id)
    }

    /// The project's own FTS row: its display name, the project-level
    /// metadata's title and caption, and every word a person might search
    /// for — the metadata keywords, the scene tags as their raw values AND
    /// their chip labels (the words a person reads and types: "weather"
    /// must find `skyWeather`), the model's elements, the creator and the
    /// place (Part 2 §4.4's searchable subset).
    private func refreshProjectSearchRow(_ id: String) throws {
        let rows = try db.query("""
            SELECT name, original_name, title, caption, keywords, scene_tags, scene_elements, creator, city, country
            FROM projects WHERE id = ?
            """, [.text(id)]) { cursor -> (String, String?, String?, String) in
            let name = cursor.text(0) ?? cursor.text(1) ?? ""
            var words: [String] = []
            words.append(contentsOf: Self.list(cursor.text(4)))
            for tag in Self.list(cursor.text(5)) {
                words.append(tag)
                words.append(SceneTagLabel.label(for: tag))
            }
            words.append(contentsOf: Self.list(cursor.text(6)))
            for column in 7...9 { if let word = cursor.text(column) { words.append(word) } }
            return (name, cursor.text(2), cursor.text(3), words.joined(separator: " "))
        }
        try db.run("DELETE FROM search WHERE kind = 'project' AND id = ?", [.text(id)])
        guard let row = rows.first else { return }
        try db.run("INSERT INTO search (kind, id, project_id, title, name, caption, keywords) VALUES ('project', ?, ?, ?, ?, ?, ?)",
                   [.text(id), .text(id), .init(row.1), .text(row.0), .init(row.2), .text(row.3)])
    }

    /// Replaces a project's asset rows from its files. The project-level
    /// record's resolved fields land on the project row (title, caption,
    /// rating, creator, keywords, place) and each asset's on its own row,
    /// with the project's values as the fallback (Part 2 §4.3).
    private func upsertAssets(projectID: String, inProjectFolder folder: URL) throws -> Int {
        let records = AssetRecords.load(inProjectFolder: folder)
        let project = ProjectMetadata.load(inProjectFolder: folder)
        let projectResolved = AssetMetadata.resolving(project?.edited, over: project?.imported)
        try db.run("""
            UPDATE projects SET title = ?, caption = ?, rating = ?, creator = ?, keywords = ?, city = ?, country = ?,
                assets_indexed_at = ? WHERE id = ?
            """, [
                .init(projectResolved.title), .init(projectResolved.caption), .init(projectResolved.rating),
                .init(projectResolved.creator?.joined(separator: ", ")), .init(list: projectResolved.keywords),
                .init(projectResolved.location?.city), .init(projectResolved.location?.country),
                .real(Date().timeIntervalSinceReferenceDate), .text(projectID),
            ])
        try db.run("DELETE FROM assets WHERE project_id = ?", [.text(projectID)])
        try db.run("DELETE FROM search WHERE kind = 'asset' AND project_id = ?", [.text(projectID)])
        var count = 0
        for record in records.ordered {
            // Asset edited → project edited → asset imported → project imported.
            let resolved = AssetMetadata.resolving(
                AssetMetadata.resolving(record.edited, over: project?.edited),
                over: AssetMetadata.resolving(record.imported, over: project?.imported))
            try db.run("""
                INSERT OR REPLACE INTO assets (
                    project_id, name, bytes, hash, hashed_at, title, caption, rating, creator, keywords,
                    captured, camera, lens, city, country, lat, lon, edited
                ) VALUES (?,?,?,?,?, ?,?,?,?,?, ?,?,?,?,?,?,?, ?)
                """, [
                    .text(projectID), .text(record.name), .init(record.bytes), .init(record.hash),
                    .init(record.hashedAt?.timeIntervalSinceReferenceDate),
                    .init(resolved.title), .init(resolved.caption), .init(resolved.rating),
                    .init(resolved.creator?.joined(separator: ", ")), .init(list: resolved.keywords),
                    .init(resolved.captured),
                    .init({ let camera = [resolved.camera?.make, resolved.camera?.model].compactMap { $0 }.joined(separator: " "); return camera.isEmpty ? nil : camera }()),
                    .init(resolved.camera?.lens), .init(resolved.location?.city), .init(resolved.location?.country),
                    .init(resolved.gps?.lat), .init(resolved.gps?.lon),
                    .init(!(record.edited?.isEmpty ?? true)),
                ])
            // A search row only for an asset that says something of its OWN
            // — a title, caption, keywords, creator, place or camera on its
            // record. What it inherits from the project is on the project's
            // row already, and a 5,000-frame set with one caption must not
            // put 5,000 copies of it in the table.
            let own = AssetMetadata.resolving(record.edited, over: record.imported)
            let ownWords: [String?] = [own.title, own.caption, own.keywords?.first, own.creator?.first,
                                       own.location?.city, own.location?.country, own.camera?.model]
            if ownWords.contains(where: { $0 != nil }) {
                var words = resolved.keywords ?? []
                words += resolved.creator ?? []
                words += [resolved.location?.city, resolved.location?.country,
                          resolved.camera?.make, resolved.camera?.model, resolved.camera?.lens].compactMap { $0 }
                try db.run("INSERT INTO search (kind, id, project_id, title, name, caption, keywords) VALUES ('asset', ?, ?, ?, ?, ?, ?)",
                           [.text(record.name), .text(projectID), .init(resolved.title),
                            .text((record.name as NSString).lastPathComponent), .init(resolved.caption),
                            .text(words.joined(separator: " "))])
            }
            count += 1
        }
        try refreshProjectSearchRow(projectID)
        return count
    }

    /// One project's shape counts from its register, the way the Gallery's
    /// rows count them: ellipses one row whatever their obliquity, quads
    /// split square / rectangle by family. A project with no register at
    /// all counts zero and keeps `shapes_indexed_at` null — "no file, never
    /// counted" is its steady state, not something to re-check each launch.
    private func upsertShapes(projectID: String, inProjectFolder folder: URL) throws {
        var ellipses = 0, rectangles = 0, squares = 0
        let exists = FileManager.default.fileExists(atPath: ShapeRegister.url(inProjectFolder: folder).path)
        if exists, let register = ShapeRegister.load(inProjectFolder: folder) {
            for shape in register.shapes {
                switch shape.kind {
                case .ellipse: ellipses += 1
                case .quad: if shape.family == .square { squares += 1 } else { rectangles += 1 }
                }
            }
        }
        try db.run("""
            UPDATE projects SET shape_ellipses = ?, shape_rectangles = ?, shape_squares = ?, shapes_indexed_at = ? WHERE id = ?
            """, [.int(Int64(ellipses)), .int(Int64(rectangles)), .int(Int64(squares)),
                   .init(exists ? Date().timeIntervalSinceReferenceDate : nil), .text(projectID)])
    }

    // MARK: - Queries

    public enum Sort: String, CaseIterable, Sendable {
        case created, added, modified, size, name
        /// The app's Edit sort: a human edit, else the newest live blend,
        /// else the capture (`edited_at`).
        case edited
    }

    public struct ProjectQuery: Equatable, Sendable {
        public var sort: Sort = .created
        public var ascending = false
        /// `video` or `photos`; nil for both.
        public var kind: String?
        /// Scanner runs only, never, or either.
        public var scanner: Bool?
        public var includeDeleted = false
        /// Every listed tag must be on the project (the chips' rule).
        public var tags: [String] = []
        /// Words for the FTS table; every word must match somewhere on the
        /// project or one of its assets. Prefix matching, so "brid" finds
        /// "bridge".
        public var text: String = ""
        /// The lists' kind (M2): photo / interval / video / scan by the
        /// app's rules, or nil for every category.
        public var category: ProjectCategory?
        /// The Projects and Gallery base while the Scans tab exists: no
        /// scans, whatever `category` says.
        public var excludeScans = false
        /// The Gallery's SHAPES rows: every lit row must hold (`none`
        /// alone means an empty or missing register).
        public var shapes: Set<ShapeRow> = []
        /// Projects with at least one live blend (the clip picker).
        public var withBlends = false
        public var offset = 0
        public var limit = 60
        public init() {}
    }

    public struct ProjectRow: Equatable, Sendable {
        public var id: UUID
        public var originID: UUID?
        public var kind: String
        public var captureMode: String?
        public var name: String?
        public var originalName: String
        public var mode: String
        public var createdAt: Date
        public var addedAt: Date?
        public var modifiedAt: Date?
        public var deletedAt: Date?
        public var frameCount: Int
        public var width: Int?
        public var height: Int?
        public var durationSeconds: Double?
        public var sizeBytes: Int64?
        public var sceneTags: [String]
        public var blendCount: Int
        public var title: String?
        public var rating: Int?
        public var folder: String
        public var category: ProjectCategory
        public var editedAt: Date?

        public var displayName: String { name ?? originalName }
    }

    public struct Page<Row: Equatable>: Equatable {
        public var rows: [Row]
        public var total: Int
        public var offset: Int
    }

    /// A page of projects, and the total the query matches.
    public func projects(_ query: ProjectQuery) throws -> Page<ProjectRow> {
        lock.lock(); defer { lock.unlock() }
        let (whereSQL, values) = Self.whereClause(query)
        let total = Int(try db.scalar("SELECT COUNT(*) FROM projects p \(whereSQL)", values) ?? 0)
        let rows = try db.query("""
            SELECT \(Self.projectColumns) FROM projects p \(whereSQL)
            ORDER BY \(Self.orderClause(query)) LIMIT ? OFFSET ?
            """, values + [.int(Int64(query.limit)), .int(Int64(query.offset))], Self.projectRow)
        return Page(rows: rows, total: total, offset: query.offset)
    }

    /// Every id the query matches, in the query's order — what a list
    /// renders from, one record at a time, without the row payload. Ignores
    /// `offset` and `limit`: ids are sixteen bytes each.
    public func projectIDs(_ query: ProjectQuery) throws -> [UUID] {
        lock.lock(); defer { lock.unlock() }
        let (whereSQL, values) = Self.whereClause(query)
        return try db.query("SELECT p.id FROM projects p \(whereSQL) ORDER BY \(Self.orderClause(query))", values) {
            UUID(uuidString: $0.text(0) ?? "")
        }.compactMap { $0 }
    }

    /// How many projects each category holds under the query's other terms
    /// (its text, tags, scans rule and shapes; not its own `category`) — the
    /// filter bar's counts, which must agree with what tapping a filter shows.
    public func categoryCounts(_ query: ProjectQuery) throws -> [ProjectCategory: Int] {
        lock.lock(); defer { lock.unlock() }
        var base = query
        base.category = nil
        let (whereSQL, values) = Self.whereClause(base)
        var counts: [ProjectCategory: Int] = [:]
        for (category, count) in try db.query("SELECT p.category, COUNT(*) FROM projects p \(whereSQL) GROUP BY p.category", values, {
            (ProjectCategory(rawValue: $0.text(0) ?? ""), Int($0.int(1) ?? 0))
        }) {
            if let category { counts[category] = count }
        }
        return counts
    }

    /// The live project holding `originID` — as its origin, its own id or
    /// its one-hop import id, the three threads `AppModel.existingImport`
    /// follows — or nil.
    public func projectID(originID: UUID) throws -> UUID? {
        lock.lock(); defer { lock.unlock() }
        let key = originID.uuidString.uppercased()
        return try db.query("""
            SELECT id FROM projects WHERE deleted_at IS NULL AND (origin_id = ? OR id = ? OR imported_from_id = ?)
            ORDER BY CASE WHEN origin_id = ? THEN 0 ELSE 1 END LIMIT 1
            """, [.text(key), .text(key), .text(key), .text(key)]) { UUID(uuidString: $0.text(0) ?? "") }.first ?? nil
    }

    private static func whereClause(_ query: ProjectQuery) -> (String, [SQLiteDatabase.Value]) {
        var clauses: [String] = []
        var values: [SQLiteDatabase.Value] = []
        if !query.includeDeleted { clauses.append("p.deleted_at IS NULL") }
        if let kind = query.kind { clauses.append("p.kind = ?"); values.append(.text(kind)) }
        if let scanner = query.scanner {
            clauses.append(scanner ? "p.capture_mode = 'scanner'" : "(p.capture_mode IS NULL OR p.capture_mode <> 'scanner')")
        }
        if let category = query.category { clauses.append("p.category = ?"); values.append(.text(category.rawValue)) }
        if query.excludeScans { clauses.append("p.category <> 'scan'") }
        if query.withBlends { clauses.append("p.blend_count > 0") }
        for row in query.shapes.sorted(by: { $0.rawValue < $1.rawValue }) {
            switch row {
            case .ellipse: clauses.append("p.shape_ellipses > 0")
            case .rectangle: clauses.append("p.shape_rectangles > 0")
            case .square: clauses.append("p.shape_squares > 0")
            case .none: clauses.append("p.shape_ellipses + p.shape_rectangles + p.shape_squares = 0")
            }
        }
        for tag in query.tags {
            // The tags column is a JSON array; `json_each` makes it a set.
            clauses.append("EXISTS (SELECT 1 FROM json_each(p.scene_tags) WHERE json_each.value = ?)")
            values.append(.text(tag))
        }
        if let match = Self.ftsQuery(query.text) {
            clauses.append("p.id IN (SELECT project_id FROM search WHERE search MATCH ?)")
            values.append(.text(match))
        }
        return (clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND "), values)
    }

    /// The app's own order for each sort, ties included (M2): the key in
    /// the sort's direction, then the capture date and the id — in that
    /// direction too, because the lists sorted ascending and reversed, so
    /// every tie-break turns with the sort. Edit is the one exception: its
    /// ties held the array's capture order (newest first) when ascending
    /// and turned it when descending, so its capture tie-break runs against
    /// the sort. Unmeasured sizes sort as −1, below any measured project.
    private static func orderClause(_ query: ProjectQuery) -> String {
        let direction = query.ascending ? "ASC" : "DESC"
        let opposite = query.ascending ? "DESC" : "ASC"
        switch query.sort {
        case .created: return "p.created_at \(direction), p.id \(direction)"
        case .added: return "COALESCE(p.added_at, p.created_at) \(direction), p.created_at \(direction), p.id \(direction)"
        case .modified: return "COALESCE(p.modified_at, p.created_at) \(direction), p.created_at \(direction), p.id \(direction)"
        case .edited: return "COALESCE(p.edited_at, p.created_at) \(direction), p.created_at \(opposite), p.id \(direction)"
        case .size: return "COALESCE(p.size_bytes, -1) \(direction), p.created_at \(direction), p.id \(direction)"
        case .name: return "LOWER(COALESCE(p.name, p.original_name)) \(direction), p.created_at \(direction), p.id \(direction)"
        }
    }

    /// One project's row, live or deleted, or nil when it is not indexed.
    public func project(id: UUID) throws -> ProjectRow? {
        lock.lock(); defer { lock.unlock() }
        return try db.query("SELECT \(Self.projectColumns) FROM projects p WHERE p.id = ?",
                     [.text(id.uuidString.uppercased())], Self.projectRow).first
    }

    private static let projectColumns = """
        p.id, p.origin_id, p.kind, p.capture_mode, p.name, p.original_name, p.mode,
        p.created_at, p.added_at, p.modified_at, p.deleted_at,
        p.frame_count, p.width, p.height, p.duration_seconds, p.size_bytes,
        p.scene_tags, p.blend_count, p.title, p.rating, p.folder, p.category, p.edited_at
        """

    private static func projectRow(_ cursor: SQLiteDatabase.Cursor) -> ProjectRow {
        ProjectRow(
            id: UUID(uuidString: cursor.text(0) ?? "") ?? UUID(),
            originID: cursor.text(1).flatMap(UUID.init(uuidString:)),
            kind: cursor.text(2) ?? "", captureMode: cursor.text(3),
            name: cursor.text(4), originalName: cursor.text(5) ?? "", mode: cursor.text(6) ?? "",
            createdAt: Date(timeIntervalSinceReferenceDate: cursor.real(7) ?? 0),
            addedAt: cursor.real(8).map { Date(timeIntervalSinceReferenceDate: $0) },
            modifiedAt: cursor.real(9).map { Date(timeIntervalSinceReferenceDate: $0) },
            deletedAt: cursor.real(10).map { Date(timeIntervalSinceReferenceDate: $0) },
            frameCount: Int(cursor.int(11) ?? 0),
            width: cursor.int(12).map(Int.init), height: cursor.int(13).map(Int.init),
            durationSeconds: cursor.real(14), sizeBytes: cursor.int(15),
            sceneTags: list(cursor.text(16)), blendCount: Int(cursor.int(17) ?? 0),
            title: cursor.text(18), rating: cursor.int(19).map(Int.init),
            folder: cursor.text(20) ?? "",
            category: ProjectCategory(rawValue: cursor.text(21) ?? "") ?? .interval,
            editedAt: cursor.real(22).map { Date(timeIntervalSinceReferenceDate: $0) })
    }

    public struct SearchHit: Equatable, Sendable {
        /// `project` or `asset`.
        public var kind: String
        public var projectID: UUID
        /// The asset's name for an asset hit; the project id for a project hit.
        public var id: String
        public var name: String
        public var title: String?
        public var rank: Double
    }

    /// Full-text hits, best first — projects and assets alike.
    public func search(_ text: String, limit: Int = 60) throws -> [SearchHit] {
        lock.lock(); defer { lock.unlock() }
        guard let match = Self.ftsQuery(text) else { return [] }
        return try db.query("""
            SELECT kind, id, project_id, name, title, rank FROM search WHERE search MATCH ? ORDER BY rank LIMIT ?
            """, [.text(match), .int(Int64(limit))]) { cursor in
            SearchHit(kind: cursor.text(0) ?? "", projectID: UUID(uuidString: cursor.text(2) ?? "") ?? UUID(),
                      id: cursor.text(1) ?? "", name: cursor.text(3) ?? "", title: cursor.text(4), rank: cursor.real(5) ?? 0)
        }
    }

    /// The tags present on live projects, with how many carry each —
    /// without the scans' when the lists exclude them, so no chip can only
    /// ever find nothing.
    public func tagCounts(excludingScans: Bool = false) throws -> [(tag: String, count: Int)] {
        lock.lock(); defer { lock.unlock() }
        return try db.query("""
            SELECT json_each.value, COUNT(*) FROM projects p, json_each(p.scene_tags)
            WHERE p.deleted_at IS NULL \(excludingScans ? "AND p.category <> 'scan'" : "")
            GROUP BY json_each.value ORDER BY COUNT(*) DESC, json_each.value
            """) { (tag: $0.text(0) ?? "", count: Int($0.int(1) ?? 0)) }
    }

    public struct Counts: Equatable {
        public var projects: Int
        public var deletedProjects: Int
        public var blends: Int
        public var assets: Int
        public var hashedAssets: Int
        public var searchRows: Int
    }

    public func counts() throws -> Counts {
        lock.lock(); defer { lock.unlock() }
        return Counts(
            projects: Int(try db.scalar("SELECT COUNT(*) FROM projects WHERE deleted_at IS NULL") ?? 0),
            deletedProjects: Int(try db.scalar("SELECT COUNT(*) FROM projects WHERE deleted_at IS NOT NULL") ?? 0),
            blends: Int(try db.scalar("SELECT COUNT(*) FROM blends WHERE deleted_at IS NULL") ?? 0),
            assets: Int(try db.scalar("SELECT COUNT(*) FROM assets") ?? 0),
            hashedAssets: Int(try db.scalar("SELECT COUNT(*) FROM assets WHERE hash IS NOT NULL") ?? 0),
            searchRows: Int(try db.scalar("SELECT COUNT(*) FROM search") ?? 0))
    }

    /// Every project id in the index, live and deleted.
    public func projectIDs() throws -> Set<UUID> {
        lock.lock(); defer { lock.unlock() }
        return Set(try db.query("SELECT id FROM projects") { UUID(uuidString: $0.text(0) ?? "") }.compactMap { $0 })
    }

    public struct Verification: Equatable {
        public var documents: Int
        public var indexed: Int
        /// Projects with a document on disk and no row.
        public var missing: [UUID]
        /// Rows with no document on disk.
        public var stale: [UUID]
        public var consistent: Bool { missing.isEmpty && stale.isEmpty }
    }

    /// The index's project ids against the documents under `Projects/`
    /// (live and `.trash`) — the check that deleting and rebuilding the
    /// database would change nothing.
    public func verify(againstProjectsFolder projects: URL) throws -> Verification {
        lock.lock(); defer { lock.unlock() }
        var report = LibraryIndexRebuild.Report(root: projects.path)
        let documents = LibraryIndexRebuild.readDocuments(in: projects, report: &report)
        let onDisk = Set(documents.compactMap { UUID(uuidString: $0.captureID) })
        let indexed = try projectIDs()
        return Verification(
            documents: onDisk.count, indexed: indexed.count,
            missing: onDisk.subtracting(indexed).sorted { $0.uuidString < $1.uuidString },
            stale: indexed.subtracting(onDisk).sorted { $0.uuidString < $1.uuidString })
    }

    // MARK: - Helpers

    /// A person's words as an FTS5 query: each word quoted and prefix-
    /// matched, all required. A word with no letter or digit in it ("&",
    /// "·", "—") is not a word to the tokeniser and would match nothing, so
    /// it is dropped: "Sky & weather" asks for sky and weather. Nil when
    /// there is nothing to search for.
    static func ftsQuery(_ text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " AND ")
    }

    static func seconds(_ value: Any?) -> Double? {
        if let text = value as? String { return ProjectDocumentFormat.manifestSeconds(fromDocumentDate: text) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    static func list(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return list
    }
}

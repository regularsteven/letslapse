import Foundation

/// `lapse import-lightroom <catalog> --library <root>` — the one-time,
/// read-only-on-the-catalogue migration of Part 2 §6, in the shape the
/// data model now allows (Phase 4 W6: a folder with its own `project.json`
/// joins the library at the next launch, so this tool never touches
/// `library.json`).
///
/// Two kinds of image in a catalogue:
///
/// - **Attach.** An image whose folder is a LetsLapse `Projects/<id>/source/`
///   of THIS library is a frame the library already holds; its record gets
///   the catalogue's statements — rating, caption, copyright, creator,
///   place, keywords, capture time, camera and exposure — as the `imported`
///   layer of its `assets.ndjson` line, over what the file and its sidecar
///   say (the catalogue wins for the fields it owns; title, the rights URLs
///   and the contact block come from the file). A person's `edited` layer
///   is never touched. The project's own record gets what the frames agree
///   on when it has none yet.
/// - **Create.** Any other image becomes a project of its own — one Photo
///   project per still, one video project per movie — as a folder under
///   `Projects/` holding a COPY of the file (and the `.xmp` beside a raw),
///   its `assets.ndjson` (hash, bytes, the imported layer), `metadata.json`
///   and `project.json`; the develop settings of a sidecar become the
///   whole-picture grade through `LightroomImport`. The original stays where
///   Lightroom keeps it, untouched.
///
/// Lightroom's collections become a keyword each on their images (§6.4).
/// Every action is appended to `<root>/Lightroom/migration.ndjson`, which
/// is what makes a second run idempotent: an image already created is
/// skipped, an attach rewrites only a record that differs. The projects
/// whose frames the catalogue references are listed there as PINNED (Part
/// 3 §10.5 — no eviction, no rename until the migration is verified); no
/// eviction exists yet, so the list is the record of the pin.
///
/// Refuses to write while the Mac app holds the library (`Projects/.lock`)
/// unless forced: the app caches every record file it has read.
public struct LightroomMigration {

    public struct Options {
        public var root: URL
        public var dryRun = false
        /// At most this many projects created (a trial run); nil for all.
        public var createLimit: Int?
        public var force = false
        public init(root: URL) { self.root = root }
    }

    public struct Attach: Equatable {
        public var image: LightroomCatalogue.Image
        public var projectID: UUID
        public var name: String
        public var fileExists: Bool
    }

    public struct Plan {
        public var attaches: [Attach] = []
        public var creates: [LightroomCatalogue.Image] = []
        public var alreadyCreated: [(image: LightroomCatalogue.Image, project: UUID)] = []
        public var skipped: [(image: LightroomCatalogue.Image, why: String)] = []
        public var pinnedProjects: Set<UUID> = []
        public var collectionsByImage: [Int64: [String]] = [:]
        public var rootFolders: [LightroomCatalogue.RootFolder] = []
        public var catalogueImages = 0
    }

    public struct Report {
        public var attached = 0
        public var attachedUnchanged = 0
        public var attachMissingFile = 0
        public var created = 0
        public var createFailed: [String] = []
        public var skipped = 0
        public var projectRecordsWritten = 0
        public var dryRun = false
        public var seconds: Double = 0
    }

    public static let logFolderName = "Lightroom"
    public static let logFileName = "migration.ndjson"

    /// One line of the migration log.
    public struct LogEntry: Codable, Equatable {
        public var kind: String
        public var at: Date
        public var image: Int64?
        public var project: UUID?
        public var name: String?
        public var catalogue: String?
        public var note: String?
    }

    public static func logURL(root: URL) -> URL {
        root.appendingPathComponent(logFolderName, isDirectory: true).appendingPathComponent(logFileName)
    }

    // MARK: - Plan

    public static func plan(catalogue: LightroomCatalogue, options: Options) throws -> Plan {
        var plan = Plan()
        let projects = LibraryIndexRebuild.projectsFolder(under: options.root)
        let previous = NDJSONFile.decode(LogEntry.self, from: (try? Data(contentsOf: logURL(root: options.root))) ?? Data())
        let createdBefore: [Int64: UUID] = Dictionary(
            previous.filter { $0.kind == "created" }.compactMap { entry in entry.image.flatMap { image in entry.project.map { (image, $0) } } },
            uniquingKeysWith: { _, last in last })

        for collection in try catalogue.collections() {
            for image in collection.imageIDs { plan.collectionsByImage[image, default: []].append(collection.name) }
        }
        plan.rootFolders = try catalogue.rootFolders()
        let images = try catalogue.images()
        plan.catalogueImages = images.count
        var creates = 0
        for image in images {
            if let projectID = projectID(inSourceFolderPath: image.folderPath) {
                let folder = projects.appendingPathComponent(projectID.uuidString, isDirectory: true)
                guard FileManager.default.fileExists(atPath: folder.path) else {
                    plan.skipped.append((image, "its project \(projectID.uuidString.prefix(8)) is not in this library"))
                    continue
                }
                let name = "source/\(image.fileName)"
                let exists = FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
                plan.attaches.append(Attach(image: image, projectID: projectID, name: name, fileExists: exists))
                plan.pinnedProjects.insert(projectID)
                continue
            }
            if let project = createdBefore[image.id] {
                plan.alreadyCreated.append((image, project))
                continue
            }
            guard FileManager.default.fileExists(atPath: image.path) else {
                plan.skipped.append((image, "file not found at \(image.path)"))
                continue
            }
            let ext = (image.fileName as NSString).pathExtension.lowercased()
            guard ImportedStills.stillExtensions.contains(ext) || ["mov", "mp4", "m4v"].contains(ext) else {
                plan.skipped.append((image, "unsupported file type .\(ext)"))
                continue
            }
            if let limit = options.createLimit, creates >= limit {
                plan.skipped.append((image, "over the trial limit of \(limit)"))
                continue
            }
            creates += 1
            plan.creates.append(image)
        }
        return plan
    }

    /// The LetsLapse project a Lightroom folder IS, when it is one:
    /// `…/Projects/<uuid>/source` (with or without a trailing slash).
    static func projectID(inSourceFolderPath path: String) -> UUID? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[parts.count - 1].lowercased() == "source",
              parts[parts.count - 3].lowercased() == "projects" else { return nil }
        return UUID(uuidString: parts[parts.count - 2])
    }

    // MARK: - Apply

    public static func apply(_ plan: Plan, options: Options, catalogueName: String, progress: ((String) -> Void)? = nil) throws -> Report {
        let started = Date()
        var report = Report()
        report.dryRun = options.dryRun
        report.skipped = plan.skipped.count
        let projects = LibraryIndexRebuild.projectsFolder(under: options.root)
        if !options.dryRun, !options.force, LibraryLockRecord.isHeld(projectsRoot: projects) {
            throw SQLiteDatabase.Failure(message: "the library is open in LetsLapse (Projects/.lock is live) — quit it, or pass --force", code: 0)
        }
        var log: [LogEntry] = []
        let now = Date()
        log.append(LogEntry(kind: "run", at: now, catalogue: catalogueName,
                            note: "\(plan.attaches.count) to attach, \(plan.creates.count) to create, \(plan.skipped.count) skipped\(options.dryRun ? " (dry run)" : "")"))
        for project in plan.pinnedProjects.sorted(by: { $0.uuidString < $1.uuidString }) {
            log.append(LogEntry(kind: "pinned", at: now, project: project, note: "frames referenced by the catalogue; no eviction, no rename until verified"))
        }

        // Attach, one project at a time.
        let byProject = Dictionary(grouping: plan.attaches, by: \.projectID)
        for (projectID, attaches) in byProject.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let folder = projects.appendingPathComponent(projectID.uuidString, isDirectory: true)
            var records = AssetRecords.load(inProjectFolder: folder)
            var written = 0
            for attach in attaches {
                guard attach.fileExists else {
                    report.attachMissingFile += 1
                    log.append(LogEntry(kind: "attach-missing", at: now, image: attach.image.id, project: projectID, name: attach.name))
                    continue
                }
                let fileURL = folder.appendingPathComponent(attach.name)
                let imported = importedMetadata(for: attach.image, collections: plan.collectionsByImage[attach.image.id] ?? [], fileURL: fileURL)
                var record = records[attach.name] ?? AssetRecord(name: attach.name)
                if record.imported == imported, record.importedSource == MetadataReader.sourceCatalogue {
                    report.attachedUnchanged += 1
                    continue
                }
                record.imported = imported
                record.importedSource = MetadataReader.sourceCatalogue
                record.importedAt = now
                records.put(record)
                if !options.dryRun {
                    try AssetRecords.append(record, to: AssetRecords.url(inProjectFolder: folder))
                }
                written += 1
                report.attached += 1
                log.append(LogEntry(kind: "attached", at: now, image: attach.image.id, project: projectID, name: attach.name))
            }
            // The project's own record, when it has none: what the frames agree on.
            if written > 0, !options.dryRun, ProjectMetadata.load(inProjectFolder: folder)?.imported == nil {
                let frames = records.ordered.compactMap { $0.name.hasPrefix("source/") ? $0.imported : nil }
                let common = AssetMetadata.common(across: frames)
                if !common.isEmpty {
                    var metadata = ProjectMetadata.load(inProjectFolder: folder) ?? ProjectMetadata()
                    metadata.imported = common
                    metadata.importedSource = MetadataReader.sourceCatalogue
                    metadata.importedAt = now
                    try metadata.write(inProjectFolder: folder)
                    report.projectRecordsWritten += 1
                }
            }
            if !options.dryRun { progress?("attached \(written) of \(attaches.count) in \(projectID.uuidString.prefix(8))") }
        }

        // Create.
        for image in plan.creates {
            do {
                let id = try createProject(from: image, collections: plan.collectionsByImage[image.id] ?? [], projects: projects, dryRun: options.dryRun, now: now)
                report.created += 1
                log.append(LogEntry(kind: "created", at: now, image: image.id, project: id, name: image.fileName))
                if !options.dryRun { progress?("created \(id.uuidString.prefix(8)) from \(image.fileName)") }
            } catch {
                report.createFailed.append("\(image.path): \(error.localizedDescription)")
                log.append(LogEntry(kind: "create-failed", at: now, image: image.id, name: image.path, note: error.localizedDescription))
            }
        }

        if !options.dryRun {
            let url = logURL(root: options.root)
            for entry in log { try NDJSONFile.append(entry, to: url) }
        }
        report.seconds = Date().timeIntervalSince(started)
        return report
    }

    // MARK: - The record

    /// The `imported` layer for one image: the file's own statement (its
    /// sidecar over its embedded XMP over Exif/IIM) with the catalogue's
    /// values over it for the fields the catalogue owns.
    public static func importedMetadata(for image: LightroomCatalogue.Image, collections: [String], fileURL: URL?) -> AssetMetadata {
        let base = fileURL.map { MetadataReader.read(fileAt: $0).metadata } ?? AssetMetadata()
        var over = AssetMetadata()
        over.rating = image.rating
        over.caption = image.caption
        over.rights = image.copyright
        over.creator = image.creator.map { [$0] }
        if image.city != nil || image.state != nil || image.country != nil || image.countryCode != nil || image.location != nil {
            var location = AssetMetadata.Location()
            location.city = image.city
            location.state = image.state
            location.country = image.country
            location.countryCode = image.countryCode
            location.sublocation = image.location
            over.location = location
        }
        switch image.copyrightState {
        case 1: over.rightsStatus = .copyrighted
        case 2: over.rightsStatus = .publicDomain
        default: break
        }
        let keywords = orderedUnique(image.keywords + collections)
        over.keywords = keywords.isEmpty ? nil : keywords
        if base.captured == nil, let captureTime = image.captureTime { over.captured = isoCaptureTime(captureTime) }
        if base.camera == nil, image.cameraModel != nil || image.lens != nil {
            var camera = AssetMetadata.Camera()
            camera.model = image.cameraModel
            camera.lens = image.lens
            over.camera = camera
        }
        if base.exposure == nil, image.apertureAPEX != nil || image.shutterAPEX != nil || image.iso != nil || image.focalLength != nil {
            var exposure = AssetMetadata.Exposure()
            exposure.seconds = image.shutterSeconds
            exposure.aperture = image.aperture
            exposure.iso = image.iso
            exposure.focalLength = image.focalLength
            over.exposure = exposure
        }
        if base.gps == nil, let lat = image.gpsLatitude, let lon = image.gpsLongitude {
            var gps = AssetMetadata.GPS()
            gps.lat = lat
            gps.lon = lon
            over.gps = gps
        }
        if base.dimensions == nil, let width = image.width, let height = image.height {
            var dimensions = AssetMetadata.Dimensions()
            dimensions.width = width
            dimensions.height = height
            over.dimensions = dimensions
        }
        return AssetMetadata.resolving(over, over: base)
    }

    /// Lightroom's `captureTime` (`2026-08-31T20:29:30`, no zone) as the
    /// record's ISO-8601 text — kept zoneless, as the file itself has it.
    static func isoCaptureTime(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "T")
    }

    static func orderedUnique(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.filter { seen.insert($0.lowercased()).inserted }
    }

    // MARK: - Creating a project

    /// A project folder for one standalone image: a copy of the file (and
    /// its sidecar), the asset record with hash and imported layer, the
    /// project record, and the document the app adopts at launch.
    static func createProject(from image: LightroomCatalogue.Image, collections: [String], projects: URL, dryRun: Bool, now: Date) throws -> UUID {
        let id = UUID()
        let source = URL(fileURLWithPath: image.path)
        let ext = (image.fileName as NSString).pathExtension.lowercased()
        let isVideo = ["mov", "mp4", "m4v"].contains(ext)
        let name = "source/\(image.fileName)"
        let imported = importedMetadata(for: image, collections: collections, fileURL: source)
        guard !dryRun else { return id }

        let folder = projects.appendingPathComponent(id.uuidString, isDirectory: true)
        let sourceFolder = folder.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let copy = sourceFolder.appendingPathComponent(image.fileName)
        try FileManager.default.copyItem(at: source, to: copy)
        if !isVideo, let sidecar = LightroomSidecar.sidecarURL(forRawFile: source),
           FileManager.default.fileExists(atPath: sidecar.path) {
            try? FileManager.default.copyItem(at: sidecar, to: sourceFolder.appendingPathComponent(sidecar.lastPathComponent))
        }

        // The asset record.
        var record = AssetRecord(name: name)
        record.bytes = Int64((try? copy.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        record.hash = try AssetHash.sha256(of: copy)
        record.hashedAt = now
        record.imported = imported.isEmpty ? nil : imported
        record.importedSource = MetadataReader.sourceCatalogue
        record.importedAt = now
        try AssetRecords.append(record, to: AssetRecords.url(inProjectFolder: folder))
        if !imported.isEmpty {
            var metadata = ProjectMetadata()
            metadata.imported = imported
            metadata.importedSource = MetadataReader.sourceCatalogue
            metadata.importedAt = now
            try metadata.write(inProjectFolder: folder)
        }

        // The project document.
        let created = imported.capturedDate ?? image.captureTime.flatMap { AssetMetadata.parseISO8601(isoCaptureTime($0)) }
            ?? (try? source.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
        var capture: [String: Any] = [
            "id": id.uuidString, "originID": id.uuidString,
            "kind": isVideo ? "video" : "photos",
            "createdAt": FrameTimestamps.string(from: created),
            "addedAt": FrameTimestamps.string(from: now),
            "originalName": image.fileName,
            "mode": isVideo ? "Import" : "Photo · Imported",
            "sourceFileNames": [name],
        ]
        if let width = imported.dimensions?.width, let height = imported.dimensions?.height {
            capture["sourceWidth"] = width
            capture["sourceHeight"] = height
        }
        if let keywords = imported.keywords, !keywords.isEmpty { capture["sceneTags"] = keywords }
        if !isVideo, let sidecar = try? LightroomSidecar.read(forRawFile: copy) {
            let grade = LightroomImport.map(sidecar)
            if !grade.adjustments.isEmpty {
                var adjustments: [String: Any] = ["v": 2]
                for (key, value) in grade.adjustments { adjustments[key] = value }
                capture["adjustments"] = adjustments
            }
        }
        let document: [String: Any] = ["formatVersion": ProjectDocumentFormat.current, "capture": capture, "blends": []]
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: ProjectDocumentFormat.url(inProjectFolder: folder), options: .atomic)
        return id
    }

    // MARK: - Rendering

    public static func text(plan: Plan, report: Report?, options: Options) -> String {
        var lines: [String] = []
        lines.append("lapse import-lightroom · \(plan.catalogueImages) images in the catalogue · library \(options.root.path)")
        lines.append("  root folders: \(plan.rootFolders.count)")
        for folder in plan.rootFolders.prefix(20) {
            let project = projectID(inSourceFolderPath: folder.absolutePath)
            lines.append("    \(folder.absolutePath)\(project.map { "  → project \($0.uuidString.prefix(8))" } ?? "")")
        }
        let attachProjects = Set(plan.attaches.map(\.projectID))
        lines.append("  attach: \(plan.attaches.count) frames in \(attachProjects.count) projects (\(plan.attaches.filter { !$0.fileExists }.count) not on disk)")
        lines.append("  create: \(plan.creates.count) projects (\(plan.creates.filter { ["mov", "mp4", "m4v"].contains(($0.fileName as NSString).pathExtension.lowercased()) }.count) videos) · already created \(plan.alreadyCreated.count)")
        lines.append("  skipped: \(plan.skipped.count)")
        var reasons: [String: Int] = [:]
        for (_, why) in plan.skipped { reasons[why.split(separator: " ").prefix(3).joined(separator: " "), default: 0] += 1 }
        for (why, count) in reasons.sorted(by: { $0.value > $1.value }).prefix(6) { lines.append("      \(count) × \(why)…") }
        lines.append("  pinned: \(plan.pinnedProjects.count) projects")
        if let report {
            lines.append("")
            lines.append(report.dryRun ? "dry run — nothing written" : "applied")
            lines.append(String(format: "  attached %d (%d unchanged, %d files missing) · project records %d · created %d · failed %d · in %.1f s",
                                report.attached, report.attachedUnchanged, report.attachMissingFile, report.projectRecordsWritten,
                                report.created, report.createFailed.count, report.seconds))
            for failure in report.createFailed.prefix(8) { lines.append("      \(failure)") }
        }
        return lines.joined(separator: "\n")
    }
}

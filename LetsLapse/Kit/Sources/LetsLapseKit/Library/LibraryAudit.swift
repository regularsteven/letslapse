import Foundation

/// `lapse audit <root>` — the instrument the data-model work is verified
/// with, before and after every step (docs/data-model-phase1-spec-2026-09-12.md
/// W1).
///
/// Reads `Projects/library.json` as plain JSON (`JSONSerialization`) rather
/// than through the app's `Codable` types, so it needs nothing from the app,
/// runs against any root — the Mac volume, a `devicectl` copy of a phone's
/// container, a simulator container — and, crucially, still reads a manifest
/// a strict decoder would refuse. Every inconsistency Part 1 found by hand is
/// a numbered line here; the report is the before/after check.
///
/// Nothing here writes.
public struct LibraryAudit {

    /// What a root is measured to contain. Every list is capped for the JSON
    /// form (`examplesLimit`) but every COUNT is exact.
    public struct Report {
        public var root: String
        public var projectsFolder: String
        public var manifestPath: String
        public var manifestBytes: Int64 = 0
        public var manifestDecoded = false
        public var manifestError: String?
        /// `library.json.unreadable-<stamp>` files set aside by the guard (W7).
        public var unreadableManifests: [String] = []

        public var captureCount = 0
        public var blendCount = 0
        public var collectionCount = 0
        public var gradingSchemaVersion: Int?
        public var projectFolderCount = 0

        public var orphanFolders: [String] = []
        public var stagingLeftovers: [String] = []
        public var recordsWithoutFolder: [String] = []
        /// Records whose folder exists but whose `source/` holds no media.
        public var recordsOverEmptyFolder: [String] = []

        public var missingListedFileCount = 0
        public var missingListedFiles: [ProjectFinding] = []
        public var unlistedMediaCount = 0
        public var unlistedMedia: [ProjectFinding] = []
        public var jsonNameCount = 0
        public var jsonNames: [ProjectFinding] = []
        public var unlistedBlendFileCount = 0
        public var unlistedBlendFiles: [ProjectFinding] = []
        public var blendRecordsMissingFileCount = 0
        public var blendRecordsMissingFile: [ProjectFinding] = []
        public var blendRecordsWithoutCapture = 0

        /// Projects carrying each registered sidecar, by relative path.
        public var sidecarPresence: [String: Int] = [:]

        public var capturesWithOriginID = 0
        public var distinctOriginIDs = 0
        public var capturesWithOriginDeviceID = 0
        public var capturesWithDerivedFromOriginID = 0
        public var capturesWithImportedFromID = 0
        public var importedFromResolvedLocally = 0
        public var capturesWithModifiedBy = 0
        public var blendsWithModifiedBy = 0
        public var collectionsWithModifiedBy = 0

        public var tombstonedCaptures = 0
        public var tombstonedBlends = 0
        public var tombstonedCollections = 0
        public var trashFolders = 0
        public var trashBytes: Int64 = 0

        /// Hash coverage over source frames + blend outputs of live captures.
        public var assetCount = 0
        public var hashedAssetCount = 0
        public var assetBytes: Int64 = 0
        public var hashedAssetBytes: Int64 = 0
        public var projectsWithAssetRecords = 0
        /// Records whose recorded byte count differs from the file on disk.
        public var staleAssetRecords = 0
        public var assetRecordsWithMetadata = 0

        public var totalBytes: Int64 = 0
        public var deviceID: String?

        public var consistent: Bool {
            orphanFolders.isEmpty && recordsWithoutFolder.isEmpty
                && missingListedFileCount == 0 && unlistedMediaCount == 0
                && jsonNameCount == 0 && unlistedBlendFileCount == 0
                && blendRecordsMissingFileCount == 0 && blendRecordsWithoutCapture == 0
                && manifestDecoded
        }
    }

    /// One project's share of a finding.
    public struct ProjectFinding: Equatable {
        public var project: String
        public var count: Int
        public var examples: [String]
    }

    public struct Options {
        public var examplesLimit = 5
        /// A preferences plist to read `letslapse.deviceID` from (W2).
        public var preferencesPlist: URL?
        public init() {}
    }

    // MARK: - Running

    /// `root` may be the storage root (holding `Projects/`) or the `Projects`
    /// folder itself.
    public static func run(root: URL, options: Options = Options()) -> Report {
        let fm = FileManager.default
        let projects = LibraryIndexRebuild.projectsFolder(under: root)
        var report = Report(
            root: root.path, projectsFolder: projects.path,
            manifestPath: projects.appendingPathComponent("library.json").path)

        // 1. The manifest, as JSON.
        var captures: [[String: Any]] = []
        var blends: [[String: Any]] = []
        var collections: [[String: Any]] = []
        let manifestURL = URL(fileURLWithPath: report.manifestPath)
        if let data = try? Data(contentsOf: manifestURL) {
            report.manifestBytes = Int64(data.count)
            do {
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                captures = object["captures"] as? [[String: Any]] ?? []
                blends = object["blends"] as? [[String: Any]] ?? []
                collections = object["collections"] as? [[String: Any]] ?? []
                report.gradingSchemaVersion = object["gradingSchemaVersion"] as? Int
                report.manifestDecoded = true
            } catch {
                report.manifestError = error.localizedDescription
            }
        } else {
            report.manifestError = "no library.json"
        }

        let entries = (try? fm.contentsOfDirectory(atPath: projects.path)) ?? []
        report.unreadableManifests = entries.filter { $0.hasPrefix("library.json.unreadable") }.sorted()
        report.stagingLeftovers = entries.filter { $0.hasPrefix(".dng-archive-") }.sorted()

        // 2. Folders vs records.
        let folderNames = Set(entries.filter { name in
            !name.hasPrefix(".") && name != "library.json"
                && isDirectory(projects.appendingPathComponent(name))
        })
        report.projectFolderCount = folderNames.count

        func isTombstoned(_ record: [String: Any]) -> Bool { record["deletedAt"] != nil }
        let liveCaptures = captures.filter { !isTombstoned($0) }
        let liveBlends = blends.filter { !isTombstoned($0) }
        report.captureCount = liveCaptures.count
        report.blendCount = liveBlends.count
        report.collectionCount = collections.filter { !isTombstoned($0) }.count
        report.tombstonedCaptures = captures.count - liveCaptures.count
        report.tombstonedBlends = blends.count - liveBlends.count
        report.tombstonedCollections = collections.count - report.collectionCount

        let captureIDs = Set(captures.compactMap { ($0["id"] as? String)?.uppercased() })
        let liveCaptureIDs = Set(liveCaptures.compactMap { ($0["id"] as? String)?.uppercased() })
        report.orphanFolders = folderNames.filter { !captureIDs.contains($0.uppercased()) }.sorted()
        report.recordsWithoutFolder = liveCaptureIDs.filter { !folderNames.map { $0.uppercased() }.contains($0) }.sorted()

        // 3. Per project: listed files, unlisted media, .json names, blends, sidecars, hashes.
        var blendsByCapture: [String: [[String: Any]]] = [:]
        for blend in liveBlends {
            guard let captureID = (blend["captureID"] as? String)?.uppercased() else { continue }
            blendsByCapture[captureID, default: []].append(blend)
            if !liveCaptureIDs.contains(captureID) { report.blendRecordsWithoutCapture += 1 }
        }
        for sidecar in ProjectFileRegistry.auditedSidecars {
            report.sidecarPresence[sidecar.relativePath] = 0
        }
        var originIDs = Set<String>()
        for capture in liveCaptures {
            guard let id = (capture["id"] as? String)?.uppercased() else { continue }
            let folder = projects.appendingPathComponent(id, isDirectory: true)
            let names = capture["sourceFileNames"] as? [String] ?? []

            if capture["originID"] != nil { report.capturesWithOriginID += 1 }
            if let origin = capture["originID"] as? String { originIDs.insert(origin.uppercased()) }
            if capture["originDeviceID"] != nil { report.capturesWithOriginDeviceID += 1 }
            if capture["derivedFromOriginID"] != nil { report.capturesWithDerivedFromOriginID += 1 }
            if let imported = (capture["importedFromID"] as? String)?.uppercased() {
                report.capturesWithImportedFromID += 1
                if captureIDs.contains(imported) { report.importedFromResolvedLocally += 1 }
            }
            if capture["modifiedBy"] != nil { report.capturesWithModifiedBy += 1 }

            let jsonNames = names.filter { $0.hasSuffix(".json") }
            if !jsonNames.isEmpty {
                report.jsonNameCount += jsonNames.count
                report.jsonNames.append(ProjectFinding(
                    project: id, count: jsonNames.count,
                    examples: Array(jsonNames.prefix(options.examplesLimit))))
            }

            guard folderNames.contains(where: { $0.uppercased() == id }) else { continue }

            // Listed files present on disk.
            var missing: [String] = []
            for name in names where !fm.fileExists(atPath: folder.appendingPathComponent(name).path) {
                missing.append(name)
            }
            if !missing.isEmpty {
                report.missingListedFileCount += missing.count
                report.missingListedFiles.append(ProjectFinding(
                    project: id, count: missing.count, examples: Array(missing.prefix(options.examplesLimit))))
            }

            // Media on disk not listed.
            let sourceFolder = folder.appendingPathComponent("source", isDirectory: true)
            let listed = Set(names.map { ($0 as NSString).lastPathComponent.lowercased() })
            let encodings = Set(
                ((capture["clipEncodings"] as? [String: [[String: Any]]]) ?? [:]).values
                    .flatMap { $0 }.compactMap { ($0["fileName"] as? String)?.lowercased()
                        .split(separator: "/").last.map(String.init) })
            let sourceItems = (try? fm.contentsOfDirectory(atPath: sourceFolder.path)) ?? []
            var mediaOnDisk = 0
            var unlisted: [String] = []
            for item in sourceItems where !item.hasPrefix(".") {
                let ext = (item as NSString).pathExtension.lowercased()
                guard mediaExtensions.contains(ext) else { continue }
                mediaOnDisk += 1
                let lower = item.lowercased()
                if listed.contains(lower) || encodings.contains(lower) { continue }
                // Scanner siblings and rectified pages sit beside their DNG by
                // design and are found by name, never listed.
                if lower.contains("-corrected.") { continue }
                let stem = (lower as NSString).deletingPathExtension
                if listed.contains(where: { ($0 as NSString).deletingPathExtension == stem && $0 != lower }) { continue }
                unlisted.append(item)
            }
            if !unlisted.isEmpty {
                report.unlistedMediaCount += unlisted.count
                report.unlistedMedia.append(ProjectFinding(
                    project: id, count: unlisted.count, examples: Array(unlisted.prefix(options.examplesLimit))))
            }
            if mediaOnDisk == 0, !names.isEmpty { report.recordsOverEmptyFolder.append(id) }

            // Blends: files vs records.
            let blendFolder = folder.appendingPathComponent("blends", isDirectory: true)
            let blendFiles = Set(((try? fm.contentsOfDirectory(atPath: blendFolder.path)) ?? [])
                .filter { !$0.hasPrefix(".") })
            let records = blendsByCapture[id] ?? []
            let recordedFiles = Set(records.compactMap { ($0["outputFileName"] as? String).map { ($0 as NSString).lastPathComponent } })
            let unlistedBlends = blendFiles.subtracting(recordedFiles).sorted()
            if !unlistedBlends.isEmpty {
                report.unlistedBlendFileCount += unlistedBlends.count
                report.unlistedBlendFiles.append(ProjectFinding(
                    project: id, count: unlistedBlends.count, examples: Array(unlistedBlends.prefix(options.examplesLimit))))
            }
            let missingBlends = recordedFiles.subtracting(blendFiles).sorted()
            if !missingBlends.isEmpty {
                report.blendRecordsMissingFileCount += missingBlends.count
                report.blendRecordsMissingFile.append(ProjectFinding(
                    project: id, count: missingBlends.count, examples: Array(missingBlends.prefix(options.examplesLimit))))
            }

            // Sidecar presence.
            for sidecar in ProjectFileRegistry.auditedSidecars {
                let path = folder.appendingPathComponent(sidecar.relativePath).path
                if fm.fileExists(atPath: path) { report.sidecarPresence[sidecar.relativePath, default: 0] += 1 }
            }

            // Hash coverage: every listed media file and every recorded blend
            // file, against the project's assets.ndjson.
            let recordsURL = folder.appendingPathComponent(ProjectFileRegistry.assetRecordsName)
            let assetRecords = AssetRecords.load(from: recordsURL)
            if !assetRecords.isEmpty { report.projectsWithAssetRecords += 1 }
            var assetNames = names.filter { !$0.hasSuffix(".json") }
            assetNames += records.compactMap { $0["outputFileName"] as? String }
            for name in assetNames {
                let url = folder.appendingPathComponent(name)
                guard let size = fileSize(url) else { continue }
                report.assetCount += 1
                report.assetBytes += size
                if let record = assetRecords[name] {
                    if record.imported != nil || record.edited != nil { report.assetRecordsWithMetadata += 1 }
                    if record.hash != nil {
                        if record.bytes == size {
                            report.hashedAssetCount += 1
                            report.hashedAssetBytes += size
                        } else {
                            report.staleAssetRecords += 1
                        }
                    }
                }
            }
        }
        report.distinctOriginIDs = originIDs.count
        for blend in blends where blend["modifiedBy"] != nil { report.blendsWithModifiedBy += 1 }
        for collection in collections where collection["modifiedBy"] != nil { report.collectionsWithModifiedBy += 1 }

        // 4. Trash and total bytes.
        let trash = projects.appendingPathComponent(".trash", isDirectory: true)
        if isDirectory(trash) {
            let items = ((try? fm.contentsOfDirectory(atPath: trash.path)) ?? []).filter { !$0.hasPrefix(".") }
            report.trashFolders = items.count
            report.trashBytes = folderBytes(trash)
        }
        report.totalBytes = folderBytes(projects)

        // 5. The device id, from a plist copy.
        if let plist = options.preferencesPlist,
           let data = try? Data(contentsOf: plist),
           let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            report.deviceID = dictionary["letslapse.deviceID"] as? String
        }
        return report
    }

    // MARK: - Rendering

    public static func text(_ r: Report) -> String {
        var lines: [String] = []
        lines.append("lapse audit · \(r.root)")
        lines.append("  manifest: \(r.manifestDecoded ? "decoded" : "UNREADABLE (\(r.manifestError ?? "?"))") · \(r.manifestBytes) bytes · schema \(r.gradingSchemaVersion.map(String.init) ?? "—")")
        if !r.unreadableManifests.isEmpty { lines.append("  set-aside manifests: \(r.unreadableManifests.joined(separator: ", "))") }
        lines.append("  captures \(r.captureCount) · blends \(r.blendCount) · collections \(r.collectionCount) · project folders \(r.projectFolderCount) · \(bytes(r.totalBytes))")
        if let deviceID = r.deviceID { lines.append("  deviceID: \(deviceID)") }
        lines.append("")
        lines.append("consistency")
        lines.append("  orphan folders (no record): \(r.orphanFolders.count)" + examples(r.orphanFolders))
        lines.append("  records with no folder: \(r.recordsWithoutFolder.count)" + examples(r.recordsWithoutFolder))
        lines.append("  records over an empty folder: \(r.recordsOverEmptyFolder.count)" + examples(r.recordsOverEmptyFolder))
        lines.append("  listed source files missing on disk: \(r.missingListedFileCount) in \(r.missingListedFiles.count) projects" + findings(r.missingListedFiles))
        lines.append("  media in source/ not listed: \(r.unlistedMediaCount) in \(r.unlistedMedia.count) projects" + findings(r.unlistedMedia))
        lines.append("  .json names in sourceFileNames: \(r.jsonNameCount) in \(r.jsonNames.count) projects" + findings(r.jsonNames))
        lines.append("  blend files unlisted: \(r.unlistedBlendFileCount) in \(r.unlistedBlendFiles.count) projects" + findings(r.unlistedBlendFiles))
        lines.append("  blend records whose file is missing: \(r.blendRecordsMissingFileCount)" + findings(r.blendRecordsMissingFile))
        lines.append("  blend records whose capture is missing: \(r.blendRecordsWithoutCapture)")
        if !r.stagingLeftovers.isEmpty { lines.append("  DNG-archive staging leftovers: \(r.stagingLeftovers.count)") }
        lines.append("")
        lines.append("sidecars (projects carrying each)")
        for (name, count) in r.sidecarPresence.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(name.padding(toLength: 26, withPad: " ", startingAt: 0)) \(count)")
        }
        lines.append("")
        lines.append("identity")
        lines.append("  originID: \(r.capturesWithOriginID) of \(r.captureCount) captures · \(r.distinctOriginIDs) distinct · originDeviceID \(r.capturesWithOriginDeviceID) · derivedFromOriginID \(r.capturesWithDerivedFromOriginID)")
        lines.append("  importedFromID: \(r.capturesWithImportedFromID) · resolvable locally \(r.importedFromResolvedLocally)")
        lines.append("  modifiedBy: captures \(r.capturesWithModifiedBy) · blends \(r.blendsWithModifiedBy) · collections \(r.collectionsWithModifiedBy)")
        lines.append("")
        lines.append("tombstones")
        lines.append("  captures \(r.tombstonedCaptures) · blends \(r.tombstonedBlends) · collections \(r.tombstonedCollections) · .trash \(r.trashFolders) folders, \(bytes(r.trashBytes))")
        lines.append("")
        lines.append("hashes")
        let percent = r.assetCount == 0 ? 0 : Double(r.hashedAssetCount) * 100 / Double(r.assetCount)
        lines.append(String(format: "  hashed %d of %d assets (%.1f%%) · %@ of %@ · %d projects with assets.ndjson · %d stale records · %d records with metadata",
                            r.hashedAssetCount, r.assetCount, percent, bytes(r.hashedAssetBytes), bytes(r.assetBytes),
                            r.projectsWithAssetRecords, r.staleAssetRecords, r.assetRecordsWithMetadata))
        lines.append("")
        lines.append(r.consistent ? "AUDIT CONSISTENT" : "AUDIT INCONSISTENT")
        return lines.joined(separator: "\n")
    }

    public static func json(_ r: Report) throws -> Data {
        func findings(_ list: [ProjectFinding]) -> [[String: Any]] {
            list.map { ["project": $0.project, "count": $0.count, "examples": $0.examples] }
        }
        var payload: [String: Any] = [
            "root": r.root,
            "projectsFolder": r.projectsFolder,
            "manifest": [
                "path": r.manifestPath, "bytes": r.manifestBytes, "decoded": r.manifestDecoded,
                "error": r.manifestError ?? "", "setAside": r.unreadableManifests,
                "gradingSchemaVersion": r.gradingSchemaVersion ?? 0,
            ] as [String: Any],
            "counts": [
                "captures": r.captureCount, "blends": r.blendCount, "collections": r.collectionCount,
                "projectFolders": r.projectFolderCount, "bytes": r.totalBytes,
            ] as [String: Any],
            "consistency": [
                "orphanFolders": r.orphanFolders,
                "recordsWithoutFolder": r.recordsWithoutFolder,
                "recordsOverEmptyFolder": r.recordsOverEmptyFolder,
                "missingListedFiles": ["count": r.missingListedFileCount, "projects": findings(r.missingListedFiles)] as [String: Any],
                "unlistedMedia": ["count": r.unlistedMediaCount, "projects": findings(r.unlistedMedia)] as [String: Any],
                "jsonNames": ["count": r.jsonNameCount, "projects": findings(r.jsonNames)] as [String: Any],
                "unlistedBlendFiles": ["count": r.unlistedBlendFileCount, "projects": findings(r.unlistedBlendFiles)] as [String: Any],
                "blendRecordsMissingFile": ["count": r.blendRecordsMissingFileCount, "projects": findings(r.blendRecordsMissingFile)] as [String: Any],
                "blendRecordsWithoutCapture": r.blendRecordsWithoutCapture,
                "stagingLeftovers": r.stagingLeftovers,
                "consistent": r.consistent,
            ] as [String: Any],
            "sidecars": r.sidecarPresence,
            "identity": [
                "originID": r.capturesWithOriginID, "distinctOriginIDs": r.distinctOriginIDs,
                "originDeviceID": r.capturesWithOriginDeviceID, "derivedFromOriginID": r.capturesWithDerivedFromOriginID,
                "importedFromID": r.capturesWithImportedFromID, "importedFromResolvedLocally": r.importedFromResolvedLocally,
                "modifiedBy": ["captures": r.capturesWithModifiedBy, "blends": r.blendsWithModifiedBy, "collections": r.collectionsWithModifiedBy],
            ] as [String: Any],
            "tombstones": [
                "captures": r.tombstonedCaptures, "blends": r.tombstonedBlends, "collections": r.tombstonedCollections,
                "trashFolders": r.trashFolders, "trashBytes": r.trashBytes,
            ] as [String: Any],
            "hashes": [
                "assets": r.assetCount, "hashed": r.hashedAssetCount,
                "bytes": r.assetBytes, "hashedBytes": r.hashedAssetBytes,
                "projectsWithRecords": r.projectsWithAssetRecords, "stale": r.staleAssetRecords,
                "withMetadata": r.assetRecordsWithMetadata,
            ] as [String: Any],
        ]
        if let deviceID = r.deviceID { payload["deviceID"] = deviceID }
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Helpers

    /// Media the app treats as frames or clips.
    static let mediaExtensions: Set<String> = ImportedStills.stillExtensions.union(["mov", "mp4", "m4v"])

    static func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }

    static func fileSize(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize else { return nil }
        return Int64(size)
    }

    static func folderBytes(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            if let size = fileSize(item) { total += size }
        }
        return total
    }

    static func bytes(_ count: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(count)
        var unit = 0
        while value >= 1024, unit < units.count - 1 { value /= 1024; unit += 1 }
        return unit == 0 ? "\(count) B" : String(format: "%.1f %@", value, units[unit])
    }

    private static func examples(_ list: [String]) -> String {
        list.isEmpty ? "" : "  [" + list.prefix(5).joined(separator: ", ") + (list.count > 5 ? ", …" : "") + "]"
    }

    private static func findings(_ list: [ProjectFinding]) -> String {
        guard !list.isEmpty else { return "" }
        return "\n" + list.prefix(8).map { "      \($0.project.prefix(8)) ×\($0.count): \($0.examples.joined(separator: ", "))" }.joined(separator: "\n")
            + (list.count > 8 ? "\n      …" : "")
    }
}

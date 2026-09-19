import Foundation

/// A project folder written by a tool rather than by the app — one
/// standalone file made a project of its own, as `lapse import-lightroom`
/// creates one per still and `lapse shapemation stage --project` makes one
/// per synthetic scene. The app's record types live in the app, so the
/// document is built as JSON here, key for key what `AppModel.registerProject`
/// writes for a Photo capture: `{formatVersion, capture, blends}` with the
/// capture's identity, kind, dates, mode and source list. A folder holding
/// such a document under `Projects/<id>/` joins the library at the next
/// launch (data model Phase 4 W6, `LibraryReconciler`), and a `.lapse` of
/// the folder installs through the archive door, which reads the document
/// as its manifest and re-keys it.
public enum StandaloneProject {

    /// The capture record, as much of it as a standalone file has. Dates go
    /// out as ISO-8601 with fractional seconds (`FrameTimestamps.string`),
    /// the persistent document's form.
    public struct Capture {
        public var id: UUID
        /// The shoot's identity on every device (Phase 1 W3); the local id
        /// at first registration.
        public var originID: UUID
        /// `photos` or `video` — the app's `CaptureKind` raw values.
        public var kind: String
        /// The mode line (`ProjectModes`).
        public var mode: String
        public var originalName: String
        /// The shoot's own date — what the lists sort by under Capture order.
        public var createdAt: Date
        /// When the project landed in this library.
        public var addedAt: Date
        /// Relative to the project folder (`source/<file>`).
        public var sourceFileNames: [String]
        /// The oriented pixel size, when known.
        public var sourceWidth: Int?
        public var sourceHeight: Int?
        public var sceneTags: [String]?
        /// The whole-picture grade, already in the document's own form
        /// (`{"v": 2, …}`), when a sidecar gave one.
        public var adjustments: [String: Any]?

        public init(id: UUID, originID: UUID? = nil, kind: String, mode: String, originalName: String,
                    createdAt: Date, addedAt: Date, sourceFileNames: [String],
                    sourceWidth: Int? = nil, sourceHeight: Int? = nil, sceneTags: [String]? = nil,
                    adjustments: [String: Any]? = nil) {
            self.id = id; self.originID = originID ?? id; self.kind = kind; self.mode = mode
            self.originalName = originalName; self.createdAt = createdAt; self.addedAt = addedAt
            self.sourceFileNames = sourceFileNames; self.sourceWidth = sourceWidth; self.sourceHeight = sourceHeight
            self.sceneTags = sceneTags; self.adjustments = adjustments
        }

        /// The `capture` object of the document.
        public var json: [String: Any] {
            var capture: [String: Any] = [
                "id": id.uuidString, "originID": originID.uuidString,
                "kind": kind,
                "createdAt": FrameTimestamps.string(from: createdAt),
                "addedAt": FrameTimestamps.string(from: addedAt),
                "originalName": originalName,
                "mode": mode,
                "sourceFileNames": sourceFileNames,
            ]
            if let sourceWidth, let sourceHeight {
                capture["sourceWidth"] = sourceWidth
                capture["sourceHeight"] = sourceHeight
            }
            if let sceneTags, !sceneTags.isEmpty { capture["sceneTags"] = sceneTags }
            if let adjustments, !adjustments.isEmpty { capture["adjustments"] = adjustments }
            return capture
        }
    }

    /// The document as bytes: `ProjectDocumentFormat.current`, the capture,
    /// no blends — sorted keys, pretty printed, slashes unescaped, the way
    /// the app writes it.
    public static func documentData(for capture: Capture) throws -> Data {
        let document: [String: Any] = ["formatVersion": ProjectDocumentFormat.current, "capture": capture.json, "blends": []]
        return try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Writes `project.json` into `folder` (created if need be).
    public static func writeDocument(for capture: Capture, inProjectFolder folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try documentData(for: capture).write(to: ProjectDocumentFormat.url(inProjectFolder: folder), options: .atomic)
    }

    /// The per-asset record for one source file — bytes, whole-file hash,
    /// and the imported metadata layer when there is one — appended to the
    /// folder's `assets.ndjson`. `name` is the record's name, relative to
    /// the project folder (`source/<file>`); `file` is where the bytes are.
    @discardableResult
    public static func recordAsset(name: String, file: URL, imported: AssetMetadata? = nil, importedSource: String? = nil,
                                   now: Date, inProjectFolder folder: URL) throws -> AssetRecord {
        var record = AssetRecord(name: name)
        record.bytes = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        record.hash = try AssetHash.sha256(of: file)
        record.hashedAt = now
        if let imported, !imported.isEmpty { record.imported = imported }
        if let importedSource {
            record.importedSource = importedSource
            record.importedAt = now
        }
        try AssetRecords.append(record, to: AssetRecords.url(inProjectFolder: folder))
        return record
    }
}

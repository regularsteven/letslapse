import Foundation

/// What one on-device vision pass said about a project — Auto rename & tag's
/// **Stage A**, cached (2026-09-16). `Projects/<id>/scene-analysis.json`.
///
/// The expensive half of the feature, written once per frame looked at and
/// read by every later request: a title today and a tag set next month are
/// two cheap *generations* (Stage B, in the app) over one stored analysis,
/// never two passes of the model. The record is therefore the engine's raw
/// reading of the picture — labels with confidences, the language model's
/// own description, what text it could see, how many faces — and nothing the
/// app can read off the project for free: no place name, no time of day, no
/// capture date. Those are read live each time, because caching them would
/// only let them drift.
///
/// The cache key is `assetID + sourceFrameID + schemaVersion`: a changed
/// thumbnail frame or a bumped schema invalidates the record, and nothing
/// else does — an engine change in particular does not (a Vision record is
/// not upgraded to a Gemma one until the person re-runs).
public struct SceneAnalysisRecord: Codable, Equatable, Sendable {

    public static let fileName = ProjectFileRegistry.sceneAnalysisName
    /// Bump to invalidate every record at once.
    public static let currentSchema = 1

    /// Which model read the frame. Recorded rather than inferred so a
    /// record says what produced it after the active model has changed.
    public enum Engine: String, Codable, Sendable {
        case vision
        case gemma
    }

    /// One thing the engine saw. Vision's are its own classifier identifiers
    /// (`waterfall`, `city_street`); Gemma's are the taxonomy tags and the
    /// free nouns it named, at the confidence it reported for the answer.
    public struct Label: Codable, Equatable, Sendable {
        public var identifier: String
        public var confidence: Double

        public init(identifier: String, confidence: Double) {
            self.identifier = identifier
            self.confidence = confidence
        }
    }

    /// The project.
    public var assetID: UUID
    /// The frame analysed, as the project knows it: a path relative to the
    /// project folder (`source/frame-00012.dng`, `blends/stack.jpg`), with
    /// `@<seconds>` appended for a frame pulled out of a movie. A relative
    /// path rather than a minted UUID because that is how the project
    /// identifies its frames everywhere else (`assets.ndjson` is keyed by
    /// name), and it survives a transfer, where a UUID would need a table.
    public var sourceFrameID: String
    public var schemaVersion: Int
    public var engine: Engine
    public var producedAt: Date
    public var labels: [Label]
    /// The language model's free-form description of the scene — Gemma
    /// only. Vision classifies without describing and leaves this nil.
    public var sceneText: String?
    /// Legible text in the frame — signage, OCR. Present in the schema for
    /// the record's sake; the shipping Vision stage stores none of it (see
    /// `VisionSceneAnalyzer`: what a sign *says* is not scene information,
    /// and a record that travels with the project is not the place for a
    /// stranger's shopfront). `hasText` carries the one fact used.
    public var recognisedText: [String]
    /// Whether the frame carried legible text at all — what the "signage"
    /// element is drawn from.
    public var hasText: Bool
    public var faceCount: Int

    public init(
        assetID: UUID, sourceFrameID: String, schemaVersion: Int = SceneAnalysisRecord.currentSchema,
        engine: Engine, producedAt: Date = Date(), labels: [Label], sceneText: String? = nil,
        recognisedText: [String] = [], hasText: Bool = false, faceCount: Int = 0
    ) {
        self.assetID = assetID
        self.sourceFrameID = sourceFrameID
        self.schemaVersion = schemaVersion
        self.engine = engine
        self.producedAt = producedAt
        self.labels = labels
        self.sceneText = sceneText
        self.recognisedText = recognisedText
        self.hasText = hasText
        self.faceCount = faceCount
    }

    /// Whether this record answers for `assetID`'s frame `sourceFrameID`
    /// under the current schema — the cache hit test.
    public func isCurrent(assetID: UUID, sourceFrameID: String) -> Bool {
        self.assetID == assetID && self.sourceFrameID == sourceFrameID && schemaVersion == Self.currentSchema
    }

    // MARK: - On disk

    public static func url(inProjectFolder folder: URL) -> URL {
        folder.appendingPathComponent(fileName)
    }

    /// The record in `folder`, or nil when there is none or it cannot be
    /// read — an unreadable cache is a miss, not an error.
    public static func load(inProjectFolder folder: URL) -> SceneAnalysisRecord? {
        guard let data = try? Data(contentsOf: url(inProjectFolder: folder)) else { return nil }
        return try? NDJSONFile.makeDecoder().decode(SceneAnalysisRecord.self, from: data)
    }

    /// The record for `assetID`'s frame in `folder`, only if it is current.
    public static func current(inProjectFolder folder: URL, assetID: UUID, sourceFrameID: String) -> SceneAnalysisRecord? {
        guard let record = load(inProjectFolder: folder),
              record.isCurrent(assetID: assetID, sourceFrameID: sourceFrameID) else { return nil }
        return record
    }

    public func write(inProjectFolder folder: URL) throws {
        let encoder = NDJSONFile.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: Self.url(inProjectFolder: folder), options: .atomic)
    }

    public static func remove(inProjectFolder folder: URL) {
        try? FileManager.default.removeItem(at: url(inProjectFolder: folder))
    }
}

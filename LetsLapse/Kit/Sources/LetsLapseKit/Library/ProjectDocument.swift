import Foundation

/// The on-disk `Projects/<id>/project.json` (data model Phase 2): one
/// project's whole record — its capture entry and every blend entry that
/// belongs to it — as one JSON document a server could store verbatim.
///
/// The document is `{formatVersion, capture, blends}`, the same shape the
/// `.lapse` archive and the network transfer have carried since they existed
/// (Part 1 §3.14); what changes in Phase 2 is that it is PERSISTENT: written
/// by the app on every persist that touches the project, and read from disk
/// by export and transfer instead of synthesised. `library.json` stays
/// authoritative until Phase 3 rewrites it as an index; `lapse audit
/// --rebuild-index` is the check that the two agree.
///
/// The Swift record types live in the app, so this file holds only what the
/// Kit needs to know about the document without them: its name, its format
/// number, its coding, and which keys are dates — the one thing a JSON-level
/// reader has to know to compare a document against the manifest, because
/// the manifest writes dates as seconds since 2001 and the document writes
/// them as ISO-8601.
public enum ProjectDocumentFormat {

    public static let fileName = ProjectFileRegistry.projectDocumentName

    /// 1 = the transient archive manifest (plain `.iso8601` dates, whole
    /// seconds); 2 = the persistent document (fractional seconds, slashes
    /// unescaped). A reader accepts both; a writer writes `current`.
    public static let current = 2

    /// The keys, on a capture or a blend record, whose values are dates. In
    /// `library.json` they are `Double` seconds since 2001-01-01; in
    /// `project.json` ISO-8601 with millisecond fractions. Every other
    /// number is a number on both sides.
    public static let dateKeys: Set<String> = ["createdAt", "addedAt", "modifiedAt", "deletedAt", "sizeMeasuredAt"]

    public static func url(inProjectFolder folder: URL) -> URL {
        folder.appendingPathComponent(fileName)
    }

    /// Sorted keys and pretty printing (a document is read by people and
    /// diffed by tools), slashes unescaped (`source/frame-00042.dng`), dates
    /// as ISO-8601 with fractional seconds — the same date form as every
    /// NDJSON record in the library, so one formatter serves both.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = NDJSONFile.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Reads a format-2 document and a format-1 archive manifest alike: the
    /// date strategy accepts fractional and whole-second ISO-8601.
    public static func makeDecoder() -> JSONDecoder {
        NDJSONFile.makeDecoder()
    }

    // MARK: - The two date encodings

    /// A manifest date (`Double` seconds since 2001) as the document's string.
    public static func documentDate(fromManifestSeconds seconds: Double) -> String {
        FrameTimestamps.string(from: Date(timeIntervalSinceReferenceDate: seconds))
    }

    /// A document date string as manifest seconds, or nil when it is not a
    /// date the reader accepts.
    public static func manifestSeconds(fromDocumentDate text: String) -> Double? {
        (FrameTimestamps.iso8601.date(from: text) ?? FrameTimestamps.iso8601Plain.date(from: text))?
            .timeIntervalSinceReferenceDate
    }
}

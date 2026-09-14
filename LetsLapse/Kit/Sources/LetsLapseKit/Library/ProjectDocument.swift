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

    /// The collections' own document — `<root>/Collections/collections.json`,
    /// `{formatVersion, collections}` with every collection, tombstoned ones
    /// included. Collections span projects, so they have no per-project
    /// document; this file is what lets a manifest be rebuilt from the
    /// folders alone (Phase 4).
    public static let collectionsFileName = "collections.json"
    public static let collectionsFolderName = "Collections"
    public static let collectionsFormat = 1

    public static func collectionsURL(inRoot root: URL) -> URL {
        root.appendingPathComponent(collectionsFolderName, isDirectory: true).appendingPathComponent(collectionsFileName)
    }

    /// Date keys that occur inside a collection record at any depth
    /// (`lastExport.exportedAt` is nested).
    public static let collectionDateKeys: Set<String> = ["createdAt", "modifiedAt", "deletedAt", "exportedAt"]

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

/// `Projects/library.json` after the switch (data model M1, 2026-09-14): no
/// longer what the app loads, but a **generated compatibility export** — the
/// same manifest as before, regenerated from the documents at the end of
/// every persist so an older build, the transfer server's catalogue and
/// `lapse audit` keep reading what they always read. The export is marked at
/// its root with `"generated": true`; a manifest without the marker is one a
/// pre-switch build wrote and still holds the truth of that build's session,
/// so the app keeps a copy of it (`preSwitchPrefix`) before the first export
/// overwrites it. It is retired one release later (M4).
public enum LibraryExportFormat {
    public static let fileName = "library.json"
    /// The root key whose `true` marks a generated export.
    public static let generatedKey = "generated"
    /// `library.json.pre-switch-<stamp>`: the last manifest a pre-switch
    /// build wrote, kept beside the export by the first launch that flipped.
    public static let preSwitchPrefix = "library.json.pre-switch-"
    /// `library.json.unreadable-<stamp>`: a manifest set aside because it
    /// could not be decoded (Phase 1 W7).
    public static let unreadablePrefix = "library.json.unreadable-"

    /// The root keys a generated export carries beside the marker (M3):
    /// how many capture and blend records it lists, so a launch can tell
    /// whether it still describes the library without parsing it.
    public static let generatedCapturesKey = "generatedCaptures"
    public static let generatedBlendsKey = "generatedBlends"

    /// True when the manifest object carries the marker.
    public static func isGenerated(_ manifest: [String: Any]) -> Bool {
        (manifest[generatedKey] as? Bool) == true
    }

    /// What an export's tail says (M3). Both writers of `library.json` —
    /// the app's `JSONEncoder` and the Kit's `JSONSerialization`, sorted
    /// keys and pretty-printed — put the root's `g…` keys last, so the
    /// marker and the counts sit in the file's final bytes: a 73 MB export
    /// (10,000 projects) answers from its last kilobyte rather than from a
    /// parse that costs hundreds of megabytes.
    public struct Trailer: Equatable, Sendable {
        public var generated: Bool
        /// Nil on an export written before the counts existed (M1, M2).
        public var captures: Int?
        public var blends: Int?
    }

    /// Reads the trailer from the last `bytes` of the file at `url`; nil
    /// when the file cannot be read.
    public static func readTrailer(at url: URL, bytes: Int = 1024) -> Trailer? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        func number(_ key: String) -> Int? {
            guard let range = text.range(of: "\"\(key)\" : ") else { return nil }
            let digits = text[range.upperBound...].prefix { $0.isNumber }
            return Int(digits)
        }
        return Trailer(generated: text.contains("\"\(generatedKey)\" : true"),
                       captures: number(generatedCapturesKey), blends: number(generatedBlendsKey))
    }
}

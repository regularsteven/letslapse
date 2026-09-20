import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import LetsLapseKit

// The Shape-mation library: finished videos and their posters under
// `<storage root>/Shapemations/`, indexed by `shapemations.json` beside them.
// Its own folder rather than a collection: collections hold blended clips, and
// a Shape-mation is built from photo assets — the collection model has no
// place for those yet. `StorageRoot.libraryItemNames` carries the folder on a
// library move.

@MainActor
final class ShapemationStore: ObservableObject {
    /// Replaced between models by a library switch (libraries plan L22).
    static private(set) var shared = ShapemationStore()
    static func reroot() { shared = ShapemationStore() }
    static let folderName = "Shapemations"
    private static let indexName = "shapemations.json"

    struct Record: Codable, Identifiable, Equatable {
        var id: UUID
        var title: String
        var createdAt: Date
        var family: DetectedShape.Family
        var mode: ShapemationMode
        var itemCount: Int
        var width: Int
        var height: Int
        var seconds: Double
        var fileName: String
        var posterFileName: String?
        /// The Match, Sort and Timing the slideshow was built with (2026-09-11
        /// designs); nil on records from before they existed.
        var match: ShapeMatch?
        var sort: ShapemationSort?
        var timing: ShapemationTiming?
        /// The output frame a `.frame` render was made with
        /// (docs/shapemation/output-frame.md §6); nil under the stack modes
        /// and on records from before it existed. The framing's own decoder
        /// is tolerant, and a missing key reads as nil.
        var framing: ShapemationFraming?
        /// The Apply filters step's answer the slideshow was built from
        /// (2026-09-20): the lit tags and the search words; nil when nothing
        /// was lit, and on records from before the step existed.
        var filterTags: [String]?
        var filterText: String?

        var subtitle: String {
            var line = "\(match?.summary ?? family.title) · \(modeWord) · \(itemCount) photo\(itemCount == 1 ? "" : "s") · \(width)×\(height)"
            if let timing { line += " · \(timing.summary)" }
            if !filterWords.isEmpty { line = filterWords.joined(separator: " · ") + " · " + line }
            return line
        }

        /// The filter as the subtitle's prefix: the tags' labels, then the
        /// words quoted.
        private var filterWords: [String] {
            var parts = (filterTags ?? []).map { SceneMetadata.label(for: $0) }
            if let filterText, !filterText.isEmpty { parts.append("\u{201C}\(filterText)\u{201D}") }
            return parts
        }

        private var modeWord: String {
            switch mode {
            case .stack: return "fit"
            case .crop: return "crop"
            case .frame: return "frame"
            }
        }
    }

    @Published private(set) var records: [Record] = []
    /// Index entries this build could not read as a `Record` — a newer
    /// build's shape of record — kept as they were read and written back by
    /// `persist`, so the video and poster they name are never orphaned by
    /// an older build's save. The same rule as `ShapeRegister.foreignShapes`.
    private var foreignRecords: [JSONValue] = []
    /// Set when an index file is there but is not a JSON list at all: the
    /// store then reads as empty and `persist` refuses, so a save can never
    /// write that emptiness over whatever the file holds.
    private var indexUnreadable = false

    var folderURL: URL {
        StorageRoot.current.appendingPathComponent(Self.folderName, isDirectory: true)
    }
    private var indexURL: URL { folderURL.appendingPathComponent(Self.indexName) }

    init() { load() }

    func url(for record: Record) -> URL { folderURL.appendingPathComponent(record.fileName) }
    func posterURL(for record: Record) -> URL? { record.posterFileName.map { folderURL.appendingPathComponent($0) } }

    /// Where a new render should write, before it has a record.
    func outputURL(for id: UUID) -> URL { folderURL.appendingPathComponent("\(id.uuidString).mp4") }
    func posterURL(for id: UUID) -> URL { folderURL.appendingPathComponent("\(id.uuidString).jpg") }

    /// Reads the index one entry at a time: an entry that is not a `Record`
    /// to this build is kept aside as JSON rather than failing the whole
    /// index (which would have emptied the list — and the next `persist`
    /// would have written that emptiness over every record).
    func load() {
        indexUnreadable = false
        guard FileManager.default.fileExists(atPath: indexURL.path) else { records = []; foreignRecords = []; return }
        let data: Data
        do { data = try Data(contentsOf: indexURL) } catch {
            // There, but its bytes will not load (permissions, a volume
            // hiccup): not absent — the same lock as bytes that are no list.
            records = []; foreignRecords = []; indexUnreadable = true
            LLog("shapemation: the index could not be read (\(error)); nothing will be written over it")
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var known: [Record] = []
        var foreign: [JSONValue] = []
        if let entries = try? decoder.decode([JSONValue].self, from: data) {
            let encoder = JSONEncoder()
            for entry in entries {
                // Back to bytes and through the record's own decoder, so the
                // dates read the way they were written.
                if let bytes = try? encoder.encode(entry), let record = try? decoder.decode(Record.self, from: bytes) {
                    known.append(record)
                } else {
                    foreign.append(entry)
                }
            }
        } else {
            indexUnreadable = true
            LLog("shapemation: the index could not be read; nothing will be written over it")
        }
        records = known.sorted { $0.createdAt > $1.createdAt }
        foreignRecords = foreign
        if !foreign.isEmpty {
            LLog("shapemation: \(foreign.count) record\(foreign.count == 1 ? "" : "s") in the index this build cannot read — kept as \(foreign.count == 1 ? "it is" : "they are")")
        }
    }

    func add(_ record: Record) {
        records.insert(record, at: 0)
        persist()
    }

    func delete(_ record: Record) {
        try? FileManager.default.removeItem(at: url(for: record))
        if let poster = posterURL(for: record) { try? FileManager.default.removeItem(at: poster) }
        records.removeAll { $0.id == record.id }
        persist()
    }

    private func persist() {
        guard !indexUnreadable else {
            LLog("shapemation: not writing the index — the one on disk could not be read")
            return
        }
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            // The known records, then the foreign ones, as `ShapeRegister`
            // does. Each record goes through its own encoder first (the
            // dates as ISO 8601 strings) and comes back as a plain value, so
            // one list can hold both kinds.
            let decoder = JSONDecoder()
            var entries = try records.map { try decoder.decode(JSONValue.self, from: encoder.encode($0)) }
            entries += foreignRecords
            try encoder.encode(entries).write(to: indexURL, options: .atomic)
        } catch {
            LLog("shapemation: could not write the index: \(error)")
        }
    }

    /// Writes the poster JPEG for a finished render.
    nonisolated static func writePoster(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}

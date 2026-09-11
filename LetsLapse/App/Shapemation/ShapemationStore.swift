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
    static let shared = ShapemationStore()
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

        var subtitle: String {
            var line = "\(match?.summary ?? family.title) · \(mode == .stack ? "fit" : "crop") · \(itemCount) photo\(itemCount == 1 ? "" : "s") · \(width)×\(height)"
            if let timing { line += " · \(timing.summary)" }
            return line
        }
    }

    @Published private(set) var records: [Record] = []

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

    func load() {
        guard let data = try? Data(contentsOf: indexURL) else { records = []; return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = ((try? decoder.decode([Record].self, from: data)) ?? []).sorted { $0.createdAt > $1.createdAt }
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
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(records).write(to: indexURL, options: .atomic)
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

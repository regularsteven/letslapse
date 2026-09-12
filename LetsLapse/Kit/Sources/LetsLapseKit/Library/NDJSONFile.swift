import Foundation

/// One JSON object per line, appended and flushed per line, read with
/// torn-line tolerance — the shape every hot-path and per-asset record in the
/// library takes (`frames.timestamps`, `frames.exposure`, `assets.ndjson`,
/// the experiment log from W11 on).
///
/// The reader's contract: blank lines and a line that does not parse are
/// skipped, never fatal. A run killed mid-write leaves a torn final line and
/// one bad line must not cost the file its every other line.
public enum NDJSONFile {

    /// The shared encoding for line records: sorted keys (greppable, and a
    /// stable byte form for tests), ISO-8601 dates with fractional seconds.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // `source/frame-00042.dng`, not `source\/frame-00042.dng`: the name is
        // the record's key and is grepped for by humans and by `tools/`.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(FrameTimestamps.string(from: date))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = FrameTimestamps.iso8601.date(from: raw)
                ?? FrameTimestamps.iso8601Plain.date(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "not an ISO-8601 date: \(raw)")
            }
            return date
        }
        return decoder
    }

    /// Every decodable line of `data`, in file order.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> [T] {
        let decoder = makeDecoder()
        var records: [T] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let record = try? decoder.decode(type, from: Data(line)) else { continue }
            records.append(record)
        }
        return records
    }

    /// Encodes `record` as one line (trailing newline included).
    public static func line<T: Encodable>(_ record: T) throws -> Data {
        var data = try makeEncoder().encode(record)
        data.append(0x0A)
        return data
    }

    /// Appends one line to the file at `url`, creating the file when absent.
    /// The write is one `write(2)` of a whole line, which is what keeps a
    /// concurrent reader from ever seeing half of one on APFS.
    public static func append<T: Encodable>(_ record: T, to url: URL) throws {
        let data = try line(record)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return
        }
        // Updating, not writing: the last byte has to be READ to know
        // whether the previous line was closed.
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        // A file whose last write was torn ends mid-line. Closing that line
        // off first keeps the torn fragment as the one unreadable line it
        // already is, instead of gluing this record onto it and losing both.
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([0x0A]))
            }
        }
        try handle.write(contentsOf: data)
    }

    /// Rewrites the whole file from `records` through a temporary file and
    /// `replaceItemAt`, so a reader sees the old file or the new one and never
    /// a truncated middle.
    public static func rewrite<T: Encodable>(_ records: [T], at url: URL) throws {
        let encoder = makeEncoder()
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).rewrite-\(UUID().uuidString)")
        try data.write(to: staging, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: url)
        }
    }
}

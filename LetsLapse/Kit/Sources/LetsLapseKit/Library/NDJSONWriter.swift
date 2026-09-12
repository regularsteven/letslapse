import Foundation

/// A line-at-a-time appender for an NDJSON file — one open handle, one
/// `write(2)` per record, flushed by the kernel as it goes — the shape every
/// hot-path record in the library takes (Part 1 §6.1).
///
/// Phase 1 W11 introduces it for the live-blend experiment log, whose whole-
/// document rewrite after every output was the one O(n²) writer left; the
/// three hand-rolled appenders (`FrameTimestampWriter`,
/// `CaptureExposureWriter`, the capture session logger's) are to move onto
/// it over time. Not thread-safe: confine it to one queue, as the capture
/// code does with every sidecar writer.
public final class NDJSONWriter {
    public let url: URL
    private var handle: FileHandle?
    private let encoder: JSONEncoder

    /// Opens `url` for appending, creating it when absent. Returns nil when
    /// the file cannot be opened — a run must never fail for its log.
    public init?(url: URL, encoder: JSONEncoder = NDJSONFile.makeEncoder()) {
        self.url = url
        self.encoder = encoder
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: url.path, contents: nil) else { return nil }
        }
        guard let handle = try? FileHandle(forUpdating: url) else { return nil }
        self.handle = handle
        // A file whose last write was torn ends mid-line: close it off, so
        // the next record lands on its own line (see `NDJSONFile.append`).
        if let end = try? handle.seekToEnd(), end > 0 {
            try? handle.seek(toOffset: end - 1)
            if (try? handle.read(upToCount: 1)) != Data([0x0A]) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: Data([0x0A]))
            }
        }
        try? handle.seekToEnd()
    }

    /// Appends `record` as one line. False when the write failed.
    @discardableResult
    public func append<T: Encodable>(_ record: T) -> Bool {
        guard let handle, var data = try? encoder.encode(record) else { return false }
        data.append(0x0A)
        do {
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    /// Appends already-encoded line bytes (a newline is added).
    @discardableResult
    public func appendLine(_ data: Data) -> Bool {
        guard let handle else { return false }
        var line = data
        line.append(0x0A)
        do {
            try handle.write(contentsOf: line)
            return true
        } catch {
            return false
        }
    }

    /// Pushes the kernel's pages to disk — at a milestone, never per line.
    public func synchronize() {
        try? handle?.synchronize()
    }

    public func close() {
        try? handle?.close()
        handle = nil
    }

    deinit { close() }
}

/// The experiment log's two shapes (Phase 1 W11): the crash-safe line form
/// written during a run — `{"kind":"header",…}`, one `{"kind":"output",…}`
/// per window, `{"kind":"summary",…}` at the end — and the
/// `{header, outputs, summary}` document `tools/blend_compare.py` and
/// `shoot.py` read, written once at finish and reconstructable from the
/// lines for a run that never finished.
///
/// Typed by the app (`LiveBlendSessionLog`), untyped here: the lines are
/// JSON objects with a `kind`, and this converts between the two shapes
/// without knowing the fields — which is what keeps it in the Kit beside
/// the other NDJSON readers and testable without the app.
public enum ExperimentLog {

    public static let kindKey = "kind"
    public static let headerKind = "header"
    public static let outputKind = "output"
    public static let summaryKind = "summary"

    /// One line's bytes: `payload` (an encoded JSON object) with `kind`
    /// added, sorted keys.
    public static func line(kind: String, payload: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        object[kindKey] = kind
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// The document — `{"header":…,"outputs":[…],"summary":…}` — rebuilt
    /// from the line form, torn-line tolerant. Nil when there is no header
    /// line at all (nothing to reconstruct). `summary` is absent for a run
    /// that never finished.
    public static func document(fromLines data: Data) -> Data? {
        var header: [String: Any]?
        var outputs: [[String: Any]] = []
        var summary: [String: Any]?
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard var object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let kind = object[kindKey] as? String else { continue }
            object[kindKey] = nil
            switch kind {
            case headerKind: header = object
            case outputKind: outputs.append(object)
            case summaryKind: summary = object
            default: break
            }
        }
        guard let header else { return nil }
        var document: [String: Any] = ["header": header, "outputs": outputs]
        if let summary { document["summary"] = summary }
        return try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// The line form of a document — for a test's round trip, and for a
    /// tool that wants to re-line a legacy log.
    public static func lines(fromDocument data: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = object["header"] as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        var out = Data()
        func emit(_ kind: String, _ payload: [String: Any]) throws {
            var line = payload
            line[kindKey] = kind
            out.append(try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes]))
            out.append(0x0A)
        }
        try emit(headerKind, header)
        for output in object["outputs"] as? [[String: Any]] ?? [] { try emit(outputKind, output) }
        if let summary = object["summary"] as? [String: Any] { try emit(summaryKind, summary) }
        return out
    }

    /// Keeps the newest `keep` files matching `prefix` in `directory` and
    /// removes the rest — the console log's rule, applied to
    /// `liveblend-*` and `ladder-*` at launch (W11). Names sort by their
    /// timestamp stem, so "newest" is lexical.
    public static func prune(directory: URL, prefix: String, keep: Int) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let matching = names.filter { $0.hasPrefix(prefix) }.sorted(by: >)
        for name in matching.dropFirst(keep) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

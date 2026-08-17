import Foundation

/// The per-frame capture record a holy-grail (or any variable-interval) still
/// shoot writes beside its frames: one JSON object per line, appended as each
/// frame lands, so a crash mid-shoot leaves every finished line intact.
///
/// Why it exists: `ImageStacker.stackSequence` lays output frames out at a
/// constant `1 / outputFPS`, which assumes every still is the same distance in
/// scene time from the last. A holy-grail shoot breaks that assumption — the
/// exposure ramps toward a 1-second shutter, and a run may change its spacing
/// outright — so the finished clip would speed up and slow down for reasons
/// nothing in the scene explains. With this sidecar the assembly reads the
/// real wall clock instead.
public struct FrameTimestamps: Equatable, Sendable {

    /// One captured frame. `frame` is the capture index (0-based) and the
    /// entries are written in capture order, so position in the file is the
    /// authoritative ordering — the field is for humans and for spotting gaps.
    public struct Entry: Codable, Equatable, Sendable {
        public var frame: Int
        public var captureTime: Date
        /// Exposure time in seconds.
        public var shutter: Double
        public var iso: Double
        /// The scene EV the ramp was chasing when this frame was taken, at
        /// ISO 100. Nil for a frame captured outside a ramp.
        public var ev: Double?
        /// The flat object the Scanner had in view at the moment this frame was
        /// requested — four normalised corners and the detector's confidence.
        ///
        /// Absent, not null, for a frame taken with no rectangle in view: the
        /// key's presence *is* the answer to "can this frame be rectified?",
        /// and a sequence shot half against a page and half against a table
        /// says so line by line. Nothing here modifies the frame itself — the
        /// correction is a separate file written later (see
        /// `PerspectiveCorrector`), so the sidecar stays a record rather than
        /// an instruction.
        public var rectangle: NormalizedQuad?

        public init(
            frame: Int,
            captureTime: Date,
            shutter: Double,
            iso: Double,
            ev: Double? = nil,
            rectangle: NormalizedQuad? = nil
        ) {
            self.frame = frame
            self.captureTime = captureTime
            self.shutter = shutter
            self.iso = iso
            self.ev = ev
            self.rectangle = rectangle
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// The sidecar's name inside a capture's staging directory (and, after
    /// registration, inside the project's `source/` folder).
    public static let fileName = "frames.timestamps"

    // MARK: - Reading

    public static func load(from url: URL) throws -> FrameTimestamps {
        let text = try String(contentsOf: url, encoding: .utf8)
        return decode(text)
    }

    /// Parses NDJSON, skipping blank and unparseable lines — a run killed
    /// mid-write can leave a torn final line, and one bad line must not cost
    /// the whole shoot its timing.
    public static func decode(_ text: String) -> FrameTimestamps {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = iso8601.date(from: raw) ?? iso8601Plain.date(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "not an ISO-8601 date: \(raw)")
            }
            return date
        }
        var entries: [Entry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                  let entry = try? decoder.decode(Entry.self, from: data)
            else { continue }
            entries.append(entry)
        }
        return FrameTimestamps(entries: entries)
    }

    /// Drops one frame's line from the sidecar beside `directory`, leaving
    /// every other line byte-for-byte as it was.
    ///
    /// **The remaining frames keep their numbers.** A scan's files, its sidecar
    /// and anything that has already read either all refer to a pose by its
    /// index, so renumbering after a deletion would silently re-point every one
    /// of those references at a different photograph. A gap is the honest
    /// record of a page that was thrown away.
    ///
    /// Written through a temporary file and swapped in, because the alternative
    /// — truncating the real one and re-appending — loses the whole shoot's
    /// timing if anything interrupts it between the two.
    public static func deleteEntry(frame: Int, in directory: URL) throws {
        let url = directory.appendingPathComponent(fileName)
        guard let existing = try? load(from: url) else { return }
        let kept = existing.entries.filter { $0.frame != frame }
        guard kept.count != existing.entries.count else { return }

        let staging = directory.appendingPathComponent("\(fileName).rewrite", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        guard let writer = FrameTimestampWriter(directory: staging) else {
            throw SidecarError.unwritable(staging)
        }
        for entry in kept { writer.append(entry) }
        writer.close()
        _ = try FileManager.default.replaceItemAt(url, withItemAt: writer.url)
    }

    /// Finds the sidecar beside a set of frames — the same directory the
    /// stills live in. Returns nil when there isn't one, which is the normal
    /// case for every shoot that isn't a ramp.
    public static func load(besideFrames urls: [URL]) -> FrameTimestamps? {
        guard let first = urls.first else { return nil }
        let url = first.deletingLastPathComponent().appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? load(from: url)
    }

    // MARK: - Derived timing

    /// Seconds elapsed from the first frame's capture time, in capture order.
    /// Monotonic by construction: a clock that steps backwards (it shouldn't,
    /// but `Date` is wall-clock) is held at the previous value rather than
    /// producing a non-monotonic presentation timeline.
    public var elapsedSeconds: [Double] {
        guard let first = entries.first?.captureTime else { return [] }
        var last = 0.0
        return entries.map { entry in
            let elapsed = max(entry.captureTime.timeIntervalSince(first), last)
            last = elapsed
            return elapsed
        }
    }

    /// Elapsed seconds for a subset of the shoot, picked by capture order —
    /// what the app needs when tail-frame review has dropped some frames from
    /// the blend but the sidecar still describes the whole run.
    public func elapsedSeconds(forOrders orders: [Int]) -> [Double]? {
        let all = elapsedSeconds
        guard !all.isEmpty else { return nil }
        var picked: [Double] = []
        picked.reserveCapacity(orders.count)
        for order in orders {
            guard all.indices.contains(order) else { return nil }
            picked.append(all[order])
        }
        return picked
    }

    // MARK: - Date format

    /// Fractional seconds are part of the contract: a fast interval shoot puts
    /// several frames inside one second, and a whole-second stamp would
    /// quantise them onto each other.
    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Tolerant fallback for a stamp written without fractional seconds.
    static let iso8601Plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func string(from date: Date) -> String {
        iso8601.string(from: date)
    }
}

/// What can go wrong rewriting a sidecar. Its own type rather than the
/// corrector's, so this file stays free of the CoreImage-gated half of the Kit.
public enum SidecarError: Error {
    case unwritable(URL)
}

/// Appends `FrameTimestamps.Entry` lines to a sidecar as a shoot runs.
///
/// Line-at-a-time and flushed on every append: the file is the only record of
/// a long shoot's pacing, and a shoot that ends in a crash (or a battery) is
/// exactly when it matters most. Not thread-safe — the capture code confines
/// it to its session queue.
public final class FrameTimestampWriter {
    public let url: URL
    private var handle: FileHandle?
    private let encoder: JSONEncoder

    /// Creates (or truncates) the sidecar at `directory/frames.timestamps`.
    /// Returns nil if the file can't be opened — a shoot must never fail
    /// because its sidecar couldn't be written; assembly just falls back to
    /// index-based timing.
    public init?(directory: URL) {
        let url = directory.appendingPathComponent(FrameTimestamps.fileName)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.url = url
        self.handle = handle
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(FrameTimestamps.string(from: date))
        }
        self.encoder = encoder
    }

    @discardableResult
    public func append(_ entry: FrameTimestamps.Entry) -> Bool {
        guard let handle, var data = try? encoder.encode(entry) else { return false }
        data.append(0x0A)  // newline
        do {
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    public func close() {
        try? handle?.close()
        handle = nil
    }

    deinit { close() }
}

// MARK: - Presentation timing

public enum FrameTimeMapping {

    /// Turns per-frame capture times into presentation times for the finished
    /// clip.
    ///
    /// The spacing between frames is preserved *proportionally*, not
    /// literally: a shoot whose frames are 20 seconds apart plays as a
    /// timelapse, not as six hours of video. The whole run is scaled so the
    /// clip is exactly as long as `frameTimes.count / outputFPS` — the length
    /// the estimate card promised — while a frame that took twice as long to
    /// arrive still occupies twice as much of the clip. That is what stops an
    /// exposure ramp (or an interval change mid-shoot) from reading as the
    /// scene speeding up.
    ///
    /// Returns nil when the input can't describe a timeline (fewer than two
    /// frames, or every frame stamped at the same instant), which is the
    /// caller's signal to keep the constant-fps layout.
    public static func presentationSeconds(frameTimes: [Double], outputFPS: Double) -> [Double]? {
        guard frameTimes.count >= 2, outputFPS > 0 else { return nil }
        guard let first = frameTimes.first, let last = frameTimes.last else { return nil }
        let span = last - first
        guard span > 0 else { return nil }
        let nominalSpan = Double(frameTimes.count - 1) / outputFPS
        let scale = nominalSpan / span
        return frameTimes.map { ($0 - first) * scale }
    }
}

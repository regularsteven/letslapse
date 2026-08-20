import Foundation

/// What each frame of a still shoot was exposed at, written beside the frames.
///
/// Two files, deliberately:
///
/// - `frames.exposure` — one line per **captured** frame, appended as it lands,
///   so a run killed mid-shoot still has every finished line. At a blend depth
///   above 1 this is denser than the frame count on disk: it records what the
///   camera did, not what was written out.
/// - `capture_log.json` — one document per **session**, written when the run
///   ends. Its `frames` are the output frames — the files actually in the
///   project — each carrying the exposure of the capture it was built around
///   and the blend count that produced it.
///
/// The exposure numbers themselves are the camera's own (`AVCapturePhoto`'s
/// EXIF dictionary), not settings the app asked for: on an auto-exposed shoot
/// those two are not the same thing, and only the first is a measurement.
public struct CaptureExposureLog {

    /// One capture. `ev` is the exposure value at ISO 100 the frame was taken
    /// at, derived from aperture, shutter and ISO together — absent unless all
    /// three are known.
    public struct Entry: Codable, Equatable, Sendable {
        public var frameIndex: Int
        public var capturedAt: Date
        public var iso: Double?
        public var exposureDuration: Double?
        public var aperture: Double?
        public var ev: Double?
        /// How many captures were blended into the output frame this entry
        /// describes. Only the session document sets it; the per-capture
        /// sidecar leaves it absent, because a capture doesn't have one.
        public var blendCount: Int?

        public init(
            frameIndex: Int,
            capturedAt: Date,
            iso: Double? = nil,
            exposureDuration: Double? = nil,
            aperture: Double? = nil,
            ev: Double? = nil,
            blendCount: Int? = nil
        ) {
            self.frameIndex = frameIndex
            self.capturedAt = capturedAt
            self.iso = iso
            self.exposureDuration = exposureDuration
            self.aperture = aperture
            self.ev = ev
            self.blendCount = blendCount
        }

        /// Builds an entry from a capture's own reported exposure.
        public init(
            frameIndex: Int,
            exposure: DNGAuthor.DNGExposure,
            capturedAt: Date? = nil,
            blendCount: Int? = nil
        ) {
            self.init(
                frameIndex: frameIndex,
                capturedAt: capturedAt ?? exposure.capturedAt ?? Date(),
                iso: exposure.iso,
                exposureDuration: exposure.exposureDuration,
                aperture: exposure.aperture,
                ev: exposure.exposureValue,
                blendCount: blendCount)
        }
    }

    /// The whole session, as `capture_log.json` holds it.
    public struct Session: Codable, Equatable, Sendable {
        public var sessionID: String
        public var deviceModel: String
        public var captureMode: String
        public var blendMode: String
        public var startedAt: Date?
        public var endedAt: Date?
        public var frames: [Entry]

        public init(
            sessionID: String,
            deviceModel: String,
            captureMode: String,
            blendMode: String,
            startedAt: Date? = nil,
            endedAt: Date? = nil,
            frames: [Entry] = []
        ) {
            self.sessionID = sessionID
            self.deviceModel = deviceModel
            self.captureMode = captureMode
            self.blendMode = blendMode
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.frames = frames
        }
    }

    /// Per-capture NDJSON sidecar, alongside `FrameTimestamps.fileName`.
    public static let sidecarFileName = "frames.exposure"
    /// Per-session document in the capture's source directory.
    public static let sessionFileName = "capture_log.json"

    /// ISO-8601 with fractional seconds, matching the other sidecars so one
    /// parser reads a whole project folder.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = withFraction.date(from: raw) ?? plain.date(from: raw) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath, debugDescription: "bad date: \(raw)"))
            }
            return date
        }
        return decoder
    }

    /// Writes the session document into a capture's directory. Atomic, so a
    /// reader never sees half a file.
    @discardableResult
    public static func write(_ session: Session, toDirectory directory: URL) -> URL? {
        let url = directory.appendingPathComponent(sessionFileName)
        do {
            let encoder = makeEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(session).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    public static func loadSession(from url: URL) throws -> Session {
        try makeDecoder().decode(Session.self, from: Data(contentsOf: url))
    }

    /// Reads the per-capture sidecar, skipping blank or torn lines — one bad
    /// line must not cost a shoot its whole exposure record.
    public static func loadSidecar(from url: URL) throws -> [Entry] {
        let decoder = makeDecoder()
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
                return try? decoder.decode(Entry.self, from: data)
            }
    }
}

/// Appends per-capture exposure lines as they land. One line per capture,
/// flushed immediately: the point of NDJSON here is that a crash costs at most
/// the line being written.
///
/// Not thread-safe by itself — callers own the serialization (both blend
/// controllers already confine their state to a single queue).
public final class CaptureExposureWriter {
    private let handle: FileHandle
    private let encoder: JSONEncoder
    public let url: URL

    /// Creates (or truncates) the sidecar at `directory/frames.exposure`.
    public init?(directory: URL) {
        let url = directory.appendingPathComponent(CaptureExposureLog.sidecarFileName)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.url = url
        self.handle = handle
        self.encoder = CaptureExposureLog.makeEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
    }

    @discardableResult
    public func append(_ entry: CaptureExposureLog.Entry) -> Bool {
        guard var data = try? encoder.encode(entry) else { return false }
        data.append(0x0A)
        do {
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    public func close() {
        try? handle.close()
    }
}

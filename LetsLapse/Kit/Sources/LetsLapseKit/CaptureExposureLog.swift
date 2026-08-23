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

    /// How the window behind an output frame actually performed — the
    /// delivery record beside the exposure record. `blendCount` on the entry
    /// says what landed; this says what was *asked* and what got in the way,
    /// so a log alone can show where a device fell short (a budget phone
    /// missing captures, a thermal ramp, processing falling behind) without
    /// the separate experiment log, which does not travel with the project.
    ///
    /// Every field is optional and flags are stamped only when true, so the
    /// document stays small and the schema stays decodable in both
    /// directions.
    public struct WindowPerformance: Codable, Equatable, Sendable {
        /// The window's resolved frame target; nil = unthrottled (no target).
        public var requestedFrames: Int?
        /// Capture opportunities skipped by pacing/backpressure.
        public var missed: Int?
        /// Frames refused because blend processing was still behind on
        /// earlier windows (video path) — the falling-behind signal.
        public var droppedProcessingBehind: Int?
        /// Frames the camera dropped on its own (video path).
        public var droppedByCamera: Int?
        /// Captures that fired and failed.
        public var failures: Int?
        /// Window was cut short (finish/keep-partial), stopped at the
        /// memory budget, or fell back to an unblended single frame.
        public var partial: Bool?
        public var memoryCapped: Bool?
        public var fallbackSingleFrame: Bool?
        public var thermalStateAtStart: String?
        public var thermalStateAtClose: String?
        /// Spacing of the window's captures — bunching shows a device
        /// struggling to keep its cadence.
        public var frameSpacingAvgSeconds: Double?
        public var frameSpacingMaxSeconds: Double?
        /// Wall-clock cost of producing this output. On the DNG path this
        /// is blend + author + write alone; on the video path it also
        /// includes any wait behind earlier windows in the processing
        /// queue — there, sustained growth IS the falling-behind signal.
        public var processingMillis: Double?
        /// Completion-to-completion spacing against `intervalSeconds` —
        /// sustained drift means the device cannot hold the interval.
        public var actualIntervalSeconds: Double?
        /// The interval the run was pacing at when this window ran (moves
        /// mid-run under EVERY=Auto).
        public var intervalSeconds: Double?
        public var fileBytes: Int?
        /// Ramped runs only: the worst divergence (stops) between what the
        /// ramp commanded and what the sensor's frames actually reported —
        /// the guard the 2026-08-20 field test lacked, when command and
        /// delivery drifted ~6 stops apart in silence.
        public var exposureDivergenceStops: Double?

        /// Stops between a delivered exposure and the commanded one:
        /// |log2((actualISO·actualDuration) / (targetISO·targetDuration))|.
        /// nil when any input is missing or non-positive.
        public static func exposureDivergenceStops(
            actualISO: Double, actualDuration: Double,
            targetISO: Double, targetDuration: Double
        ) -> Double? {
            guard actualISO > 0, actualDuration > 0,
                  targetISO > 0, targetDuration > 0 else { return nil }
            return abs(log2((actualISO * actualDuration) / (targetISO * targetDuration)))
        }

        public init(
            requestedFrames: Int? = nil,
            missed: Int? = nil,
            droppedProcessingBehind: Int? = nil,
            droppedByCamera: Int? = nil,
            failures: Int? = nil,
            partial: Bool? = nil,
            memoryCapped: Bool? = nil,
            fallbackSingleFrame: Bool? = nil,
            thermalStateAtStart: String? = nil,
            thermalStateAtClose: String? = nil,
            frameSpacingAvgSeconds: Double? = nil,
            frameSpacingMaxSeconds: Double? = nil,
            processingMillis: Double? = nil,
            actualIntervalSeconds: Double? = nil,
            intervalSeconds: Double? = nil,
            fileBytes: Int? = nil,
            exposureDivergenceStops: Double? = nil
        ) {
            self.requestedFrames = requestedFrames
            self.missed = missed
            self.droppedProcessingBehind = droppedProcessingBehind
            self.droppedByCamera = droppedByCamera
            self.failures = failures
            self.partial = partial
            self.memoryCapped = memoryCapped
            self.fallbackSingleFrame = fallbackSingleFrame
            self.thermalStateAtStart = thermalStateAtStart
            self.thermalStateAtClose = thermalStateAtClose
            self.frameSpacingAvgSeconds = frameSpacingAvgSeconds
            self.frameSpacingMaxSeconds = frameSpacingMaxSeconds
            self.processingMillis = processingMillis
            self.actualIntervalSeconds = actualIntervalSeconds
            self.intervalSeconds = intervalSeconds
            self.fileBytes = fileBytes
            self.exposureDivergenceStops = exposureDivergenceStops
        }
    }

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
        /// The full strategy decision behind an Auto window — every
        /// strategy's proposal, the ceiling, and the pixel stats it read.
        /// Absent outside Auto field-test runs.
        public var strategy: BlendStrategyDecision?
        /// How the window actually delivered — present on every blend-path
        /// output frame, whatever the depth, so fixed-depth runs can show
        /// their shortfalls too.
        public var window: WindowPerformance?

        public init(
            frameIndex: Int,
            capturedAt: Date,
            iso: Double? = nil,
            exposureDuration: Double? = nil,
            aperture: Double? = nil,
            ev: Double? = nil,
            blendCount: Int? = nil,
            strategy: BlendStrategyDecision? = nil,
            window: WindowPerformance? = nil
        ) {
            self.frameIndex = frameIndex
            self.capturedAt = capturedAt
            self.iso = iso
            self.exposureDuration = exposureDuration
            self.aperture = aperture
            self.ev = ev
            self.blendCount = blendCount
            self.strategy = strategy
            self.window = window
        }

        /// Builds an entry from a capture's own reported exposure.
        public init(
            frameIndex: Int,
            exposure: DNGAuthor.DNGExposure,
            capturedAt: Date? = nil,
            blendCount: Int? = nil,
            strategy: BlendStrategyDecision? = nil,
            window: WindowPerformance? = nil
        ) {
            self.init(
                frameIndex: frameIndex,
                capturedAt: capturedAt ?? exposure.capturedAt ?? Date(),
                iso: exposure.iso,
                exposureDuration: exposure.exposureDuration,
                aperture: exposure.aperture,
                ev: exposure.exposureValue,
                blendCount: blendCount,
                strategy: strategy,
                window: window)
        }
    }

    /// The whole session, as `capture_log.json` holds it.
    public struct Session: Codable, Equatable, Sendable {
        public var sessionID: String
        public var deviceModel: String
        public var captureMode: String
        public var blendMode: String
        /// Which Auto strategy actuated this run (`zone` / `latitude` /
        /// `lumen`) and the decision-logic version that produced the log.
        /// `blendMode` alone can't tell field-test runs apart — it reads
        /// `auto` for all of them.
        public var algorithm: String?
        public var algorithmVersion: String?
        /// Whether Capture Flat was on for this run. nil where the setting
        /// does not apply (the DNG path never offers it); the 2026-08-23
        /// flat/non-flat A/B pair was indistinguishable from their logs
        /// because nothing recorded this.
        public var captureFlat: Bool?
        /// Run context a cross-device comparison needs beside the numbers:
        /// which camera and capture format produced them (a 12MP frame and
        /// a 48MP frame have very different per-frame costs), and the
        /// interval the run was asked to hold at start.
        public var cameraName: String?
        public var captureWidth: Int?
        public var captureHeight: Int?
        public var intervalSeconds: Double?
        /// How the run ended — "user", "consecutiveFailures", … — and what
        /// the travelling log can't show per-frame because failed and
        /// starved windows write no frame entries: their counts. The
        /// 2026-08-22 sunrise stops were undiagnosable from this file
        /// because none of this was recorded.
        public var endReason: String?
        public var failedWindows: Int?
        public var starvedWindows: Int?
        public var startedAt: Date?
        public var endedAt: Date?
        public var frames: [Entry]

        public init(
            sessionID: String,
            deviceModel: String,
            captureMode: String,
            blendMode: String,
            algorithm: String? = nil,
            algorithmVersion: String? = nil,
            captureFlat: Bool? = nil,
            cameraName: String? = nil,
            captureWidth: Int? = nil,
            captureHeight: Int? = nil,
            intervalSeconds: Double? = nil,
            endReason: String? = nil,
            failedWindows: Int? = nil,
            starvedWindows: Int? = nil,
            startedAt: Date? = nil,
            endedAt: Date? = nil,
            frames: [Entry] = []
        ) {
            self.sessionID = sessionID
            self.deviceModel = deviceModel
            self.captureMode = captureMode
            self.blendMode = blendMode
            self.algorithm = algorithm
            self.algorithmVersion = algorithmVersion
            self.captureFlat = captureFlat
            self.cameraName = cameraName
            self.captureWidth = captureWidth
            self.captureHeight = captureHeight
            self.intervalSeconds = intervalSeconds
            self.endReason = endReason
            self.failedWindows = failedWindows
            self.starvedWindows = starvedWindows
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

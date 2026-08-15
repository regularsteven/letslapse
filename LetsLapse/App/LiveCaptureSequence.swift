import Foundation

struct LiveCaptureSequence: Codable, Equatable {
    enum Mode: String, Codable, Equatable, Identifiable, CaseIterable {
        case ramp
        case marker

        var id: String { rawValue }

        var label: String {
            switch self {
            case .ramp: return "Ramp"
            case .marker: return "Marker"
            }
        }
    }

    struct Resolution: Codable, Equatable, Hashable {
        var width: Int32
        var height: Int32
    }

    struct Segment: Codable, Equatable {
        var index: Int
        var fileName: String
        var frameRate: Int
        var relativeStart: TimeInterval
        var relativeEnd: TimeInterval
        /// When the file's first frame actually landed, on the run's clock —
        /// stamped from the writer's did-start callback, where `relativeStart`
        /// is stamped before the writer has spun up (~0.27s early). nil in
        /// sidecars written before honest stamps existed.
        var recordedStart: TimeInterval? = nil
        /// The finished file's own media length, probed at capture time. With
        /// `recordedStart` it places the segment's real frames exactly, so an
        /// inter-file gap is measured rather than bracketed by wall-clock
        /// stamps that err in opposite directions.
        var recordedDuration: TimeInterval? = nil
        /// Frames ÷ duration for the finished file — the average QuickTime
        /// reports and `Capture.sourceSegmentFPS` probes, recorded here at
        /// capture time instead of re-derived from the file much later.
        /// `frameRate` above stays the rate that was ASKED for.
        var measuredFrameRate: Double? = nil
        /// The cadence the file settles at, past any head transient. A
        /// burst's real rate, undragged by a switch that hadn't finished
        /// landing when the file opened.
        var steadyFrameRate: Double? = nil
        /// How long the file's head ran off that cadence. The regression
        /// detector for the early frame-duration write: ~0 once the sensor
        /// has re-timed before the file opens, 0.20 on the 2026-08-13 shoot
        /// that motivated it (four frames still at the base 25 fps cadence
        /// inside a 100 fps burst, dragging its average to 98.14).
        var settleSeconds: Double? = nil
        /// What this file actually recorded at, when it differs from the
        /// sequence's `lockedResolution` — a burst may shoot 4K off a 1080p
        /// base so a punch-in has pixels to crop into.
        ///
        /// **nil means "the sequence's resolution"**, which is what every
        /// sidecar written before 2026-08-15 means: those runs were one
        /// resolution throughout, by construction. `Segment` has no hand-written
        /// `CodingKeys`, so the synthesized decoder already treats a missing key
        /// as nil and needs no back-compat code.
        var resolution: Resolution? = nil
    }

    struct Marker: Codable, Equatable {
        var index: Int
        var relativeTime: TimeInterval
    }

    struct RampInterval: Codable, Equatable {
        var index: Int
        var relativeStart: TimeInterval
        var relativeEnd: TimeInterval?
    }

    var mode: Mode
    var createdAt: Date
    var lockedResolution: Resolution
    var baseFrameRate: Int
    var rampFrameRate: Int?
    var segments: [Segment]
    var markers: [Marker]
    var rampIntervals: [RampInterval]
    /// Moments annotated during the run: an in point, an out point, and
    /// nothing else. **A mark changes no footage.** No file is opened, no
    /// frame rate is touched — it says "this stretch is worth coming back to",
    /// at whatever rate the run was already shooting.
    ///
    /// A separate list from `rampIntervals` on purpose. A burst IS a rate
    /// change and already owns that list; keeping marks apart means the two
    /// can overlap freely (mark IN, burst, mark OUT) and that neither one's
    /// meaning shifts under the other. Absent in every sidecar written before
    /// marks existed, which decodes to empty and behaves exactly as before.
    var markIntervals: [RampInterval]
    /// Whether Capture Flat was requested for this run, and whether Apple Log
    /// actually engaged — the device's colour space at the first segment's
    /// first frame, not the request. Distinct fields because the 2026-08-14
    /// investigation had exactly one question the sidecar couldn't answer:
    /// "was the toggle even on?". Optional so older sidecars still decode.
    var captureFlat: Bool?
    var appleLog: Bool?

    enum CodingKeys: String, CodingKey {
        case mode
        case createdAt
        case lockedResolution
        case baseFrameRate
        case rampFrameRate
        case segments
        case markers
        case rampIntervals
        case markIntervals
        case captureFlat
        case appleLog
    }

    init(
        mode: Mode,
        createdAt: Date,
        lockedResolution: Resolution,
        baseFrameRate: Int,
        rampFrameRate: Int?,
        segments: [Segment],
        markers: [Marker],
        rampIntervals: [RampInterval],
        markIntervals: [RampInterval] = [],
        captureFlat: Bool? = nil,
        appleLog: Bool? = nil
    ) {
        self.mode = mode
        self.createdAt = createdAt
        self.lockedResolution = lockedResolution
        self.baseFrameRate = baseFrameRate
        self.rampFrameRate = rampFrameRate
        self.segments = segments
        self.markers = markers
        self.rampIntervals = rampIntervals
        self.markIntervals = markIntervals
        self.captureFlat = captureFlat
        self.appleLog = appleLog
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(Mode.self, forKey: .mode)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lockedResolution = try container.decode(Resolution.self, forKey: .lockedResolution)
        baseFrameRate = try container.decode(Int.self, forKey: .baseFrameRate)
        rampFrameRate = try container.decodeIfPresent(Int.self, forKey: .rampFrameRate)
        segments = try container.decode([Segment].self, forKey: .segments)
        markers = try container.decodeIfPresent([Marker].self, forKey: .markers) ?? []
        rampIntervals = try container.decodeIfPresent([RampInterval].self, forKey: .rampIntervals) ?? []
        markIntervals = try container.decodeIfPresent([RampInterval].self, forKey: .markIntervals) ?? []
        captureFlat = try container.decodeIfPresent(Bool.self, forKey: .captureFlat)
        appleLog = try container.decodeIfPresent(Bool.self, forKey: .appleLog)
    }

    /// What each segment really recorded at, with `lockedResolution` standing
    /// in wherever the segment doesn't say — which is every segment of every
    /// sidecar written before per-segment resolution existed.
    func resolution(of segment: Segment) -> Resolution {
        segment.resolution ?? lockedResolution
    }

    /// Whether this shoot's segments disagree about resolution, i.e. whether a
    /// burst recorded at a different resolution from the base.
    ///
    /// The render path branches on this: a mixed shoot must crop and scale each
    /// segment to one common size *before* the stitch, because a composition
    /// track has one size and the burst's extra pixels have to be spent on the
    /// punch-in crop rather than thrown away by a downscale. A uniform shoot —
    /// which is every shoot recorded before 2026-08-15 — takes the original
    /// path untouched.
    var hasMixedSegmentResolutions: Bool {
        guard let first = segments.first else { return false }
        let firstResolution = resolution(of: first)
        return segments.contains { resolution(of: $0) != firstResolution }
    }

    /// The distinct resolutions this shoot recorded, largest first.
    var segmentResolutions: [Resolution] {
        var seen: [Resolution] = []
        for segment in segments {
            let value = resolution(of: segment)
            if !seen.contains(value) { seen.append(value) }
        }
        return seen.sorted {
            Int64($0.width) * Int64($0.height) > Int64($1.width) * Int64($1.height)
        }
    }

    private var markSummary: String {
        markIntervals.isEmpty ? "" : "\(markIntervals.count) marks · "
    }

    var summary: String {
        switch mode {
        case .ramp:
            let highRate = rampFrameRate.map { " -> \($0) fps" } ?? ""
            return "Ramp capture · \(rampIntervals.count) ramp intervals · \(markSummary)\(segments.count) segments · \(baseFrameRate) fps\(highRate)"
        case .marker:
            return "Marker capture · \(rampIntervals.count) ramp intervals · \(markSummary)\(baseFrameRate) fps"
        }
    }
}

struct LiveCaptureResult {
    var sequence: LiveCaptureSequence
    var segmentURLs: [URL]
    var metadataURL: URL

    var primaryVideoURL: URL? {
        segmentURLs.first
    }
}

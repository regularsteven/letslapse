import Foundation

/// The record a framing review leaves beside an interval shoot's stills:
/// where every photo's content sits against one locked reference framing,
/// the knocks that moved it, and the plan that would hold it still — human
/// copy for the screen and the numbers the blend applies, in one file, so
/// the review a person read and the correction the engine performs can never
/// be two different things.
///
/// Non-destructive by construction: nothing here touches a pixel on disk.
/// `stabilisation` is the plan *committed* ("Stabilise photos"); consumers
/// apply it through `FramingLock` at render time, or ignore it.
///
/// Written as `framing.json` in the project's `source/` folder, beside
/// `frames.timestamps` and `frames.exposure`. Offsets are keyed by the bare
/// file name, the same identity nominations use, so a hidden or deleted
/// photo never re-points another photo's correction.
public struct FramingReview: Codable, Equatable, Sendable {

    public static let fileName = "framing.json"
    public static let currentVersion = 1

    public enum Verdict: String, Codable, Sendable {
        /// Knocks found: locking is recommended.
        case recommended
        /// The framing held; nothing to fix (a slow drift may still be noted).
        case steady
        /// Too little confident measurement to say either way.
        case inconclusive
    }

    public enum LockMode: String, Codable, Sendable {
        /// One reference framing for the whole shoot — knocks and the slow
        /// drift both removed. Steven's call (2026-09-03): this is what
        /// "100% locked" means.
        case lockEverything
    }

    /// One photo's content offset from the reference, full-resolution source
    /// pixels, y-down: +dx = the scene sits further right in this photo than
    /// in the reference, +dy = further down.
    public struct Offset: Codable, Equatable, Sendable {
        public var name: String
        public var dx: Double
        public var dy: Double
        /// Correlation response behind the estimate, 0…1.
        public var confidence: Double

        public init(name: String, dx: Double, dy: Double, confidence: Double) {
            self.name = name
            self.dx = dx
            self.dy = dy
            self.confidence = confidence
        }
    }

    /// A run of photos displaced from the local baseline — a knock.
    public struct Event: Codable, Equatable, Sendable {
        public var firstIndex: Int
        public var lastIndex: Int
        public var firstName: String
        public var lastName: String
        public var peakPixels: Double
        /// "Photos 802–820 · 19 photos · 6.6 px"
        public var summary: String

        public var count: Int { lastIndex - firstIndex + 1 }
    }

    public struct Plan: Codable, Equatable, Sendable {
        public var mode: LockMode
        /// The reference framing: the centre of the shoot's excursion, so the
        /// crop is the smallest that holds every photo.
        public var referenceX: Double
        public var referenceY: Double
        /// Half the excursion on each axis — the margin the crop must keep.
        public var insetX: Double
        public var insetY: Double
        /// The same-aspect inset as a fraction of each edge.
        public var cropFraction: Double
        public var summary: String
    }

    /// The plan, committed. Carries its own copy of the numbers and the
    /// review stamp it was made from, so a later re-review is visibly stale
    /// rather than silently re-pointing the correction.
    public struct Stabilisation: Codable, Equatable, Sendable {
        public var appliedAt: Date
        public var reviewedAt: Date
        public var mode: LockMode
        public var referenceX: Double
        public var referenceY: Double
        public var insetX: Double
        public var insetY: Double
        public var cropFraction: Double
    }

    public var version: Int
    public var reviewedAt: Date
    /// Full-resolution source size the offsets are expressed in.
    public var width: Int
    public var height: Int
    /// The decode scale the measurement ran at (0.5 = half size).
    public var measurementScale: Double
    /// Capture span from the timestamps sidecar, for the copy. Nil when
    /// unknown.
    public var captureSpanSeconds: Double?
    public var frames: [Offset]
    public var events: [Event]
    /// Span of the slow (121-photo running median) component of the path.
    public var driftX: Double
    public var driftY: Double
    public var verdict: Verdict
    /// The report's headline, ready for a screen.
    public var summary: String
    public var plan: Plan
    public var stabilisation: Stabilisation?

    // MARK: - Analysis thresholds

    /// A photo displaced further than this from the local baseline is part
    /// of a knock.
    public static let eventThresholdPixels = 2.0
    /// Knocks closer than this many photos merge into one event.
    public static let eventMergeGap = 10
    /// The running-median window that separates slow drift from knocks.
    public static let driftWindow = 121
    /// Below this median confidence the review calls itself inconclusive.
    /// `PhaseCorrelator` scores a static scene one second apart at ~0.85
    /// (E33ED216, sunset to night: p5 0.83) and unrelated frames far lower.
    public static let confidenceFloor = 0.3

    // MARK: - Derived

    public var isStabilised: Bool { stabilisation != nil }

    /// True when the committed stabilisation was made from THIS review.
    public var isStabilisationCurrent: Bool {
        guard let stabilisation else { return false }
        return abs(stabilisation.reviewedAt.timeIntervalSince(reviewedAt)) < 0.001
    }

    public func offset(named name: String) -> Offset? {
        frames.first { $0.name == name }
    }

    /// The review with its plan committed at `date`.
    public func applyingPlan(at date: Date = Date()) -> FramingReview {
        var copy = self
        copy.stabilisation = Stabilisation(
            appliedAt: date, reviewedAt: reviewedAt, mode: plan.mode,
            referenceX: plan.referenceX, referenceY: plan.referenceY,
            insetX: plan.insetX, insetY: plan.insetY, cropFraction: plan.cropFraction)
        return copy
    }

    /// The review with any committed stabilisation withdrawn.
    public func withdrawingStabilisation() -> FramingReview {
        var copy = self
        copy.stabilisation = nil
        return copy
    }

    // MARK: - Building

    /// Analyses a measured path into a review. `offsets` are in capture
    /// order against one reference (any reference — the plan re-centres).
    public static func make(
        width: Int,
        height: Int,
        measurementScale: Double,
        offsets: [Offset],
        captureSpanSeconds: Double? = nil,
        reviewedAt: Date = Date()
    ) -> FramingReview {
        let n = offsets.count
        let xs = offsets.map(\.dx)
        let ys = offsets.map(\.dy)
        let slowX = runningMedian(xs, window: driftWindow)
        let slowY = runningMedian(ys, window: driftWindow)
        let residualX = zip(xs, slowX).map { $0 - $1 }
        let residualY = zip(ys, slowY).map { $0 - $1 }
        let magnitude = zip(residualX, residualY).map { ($0 * $0 + $1 * $1).squareRoot() }

        // Events: runs over the threshold, merged across small gaps.
        var events: [Event] = []
        var runStart: Int?
        func close(_ start: Int, _ end: Int) {
            let peak = magnitude[start...end].max() ?? 0
            if let last = events.last, start - last.lastIndex <= eventMergeGap {
                events[events.count - 1].lastIndex = end
                events[events.count - 1].lastName = offsets[end].name
                events[events.count - 1].peakPixels = max(last.peakPixels, peak)
            } else {
                events.append(Event(
                    firstIndex: start, lastIndex: end,
                    firstName: offsets[start].name, lastName: offsets[end].name,
                    peakPixels: peak, summary: ""))
            }
        }
        for index in 0..<n {
            if magnitude[index] > eventThresholdPixels {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                close(start, index - 1)
                runStart = nil
            }
        }
        if let start = runStart { close(start, n - 1) }
        for index in events.indices {
            let event = events[index]
            let first = displayNumber(name: event.firstName, index: event.firstIndex)
            let last = displayNumber(name: event.lastName, index: event.lastIndex)
            let range = first == last ? "Photo \(first)" : "Photos \(first)–\(last)"
            events[index].summary = "\(range) · \(event.count) photo\(event.count == 1 ? "" : "s") · \(format(event.peakPixels)) px"
        }

        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        let referenceX = (minX + maxX) / 2
        let referenceY = (minY + maxY) / 2
        let insetX = (maxX - minX) / 2
        let insetY = (maxY - minY) / 2
        let cropFraction = width > 0 && height > 0
            ? max(2 * insetX / Double(width), 2 * insetY / Double(height)) : 0
        let driftX = (slowX.max() ?? 0) - (slowX.min() ?? 0)
        let driftY = (slowY.max() ?? 0) - (slowY.min() ?? 0)

        let confidences = offsets.map(\.confidence).sorted()
        let medianConfidence = confidences.isEmpty ? 0 : confidences[confidences.count / 2]
        let verdict: Verdict
        if n < 2 || medianConfidence < confidenceFloor {
            verdict = .inconclusive
        } else if events.isEmpty {
            verdict = .steady
        } else {
            verdict = .recommended
        }

        let keptWidth = Int((Double(width) * (1 - cropFraction)).rounded(.down))
        let keptHeight = Int((Double(height) * (1 - cropFraction)).rounded(.down))
        let cropCopy = "crops \(percent(cropFraction)) from each edge (\(keptWidth)×\(keptHeight) of \(width)×\(height))"
        let span = captureSpanSeconds.map { " over \(duration($0))" } ?? ""
        let summary: String
        switch verdict {
        case .inconclusive:
            summary = n < 2
                ? "Not enough photos to review."
                : "The photos could not be matched confidently enough to judge the framing (median confidence \(format(medianConfidence)))."
        case .steady:
            let held = max(maxX - minX, maxY - minY)
            var text = "The framing held within \(format(held)) px across all \(n) photos\(span). Nothing to fix."
            if max(driftX, driftY) >= 4 {
                text += " It drifted \(format(max(driftX, driftY))) px over the shoot, which locking would also remove."
            }
            summary = text
        case .recommended:
            let largest = events.max { $0.peakPixels < $1.peakPixels }!
            let first = displayNumber(name: largest.firstName, index: largest.firstIndex)
            let last = displayNumber(name: largest.lastName, index: largest.lastIndex)
            let at = first == last ? "photo \(first)" : "photos \(first)–\(last)"
            summary = "\(events.count) knock\(events.count == 1 ? "" : "s") across \(n) photos\(span), the largest \(format(largest.peakPixels)) px at \(at). Locking the framing \(cropCopy)."
        }

        let planSummary = "Lock every photo to one framing: shift each by up to ±\(format(insetX)) px across and ±\(format(insetY)) px down, and crop \(percent(cropFraction)) from each edge. The originals stay untouched — the correction is applied when a clip is blended or a photo is viewed."
        let plan = Plan(
            mode: .lockEverything, referenceX: referenceX, referenceY: referenceY,
            insetX: insetX, insetY: insetY, cropFraction: cropFraction, summary: planSummary)

        return FramingReview(
            version: currentVersion, reviewedAt: reviewedAt, width: width, height: height,
            measurementScale: measurementScale, captureSpanSeconds: captureSpanSeconds,
            frames: offsets, events: events, driftX: driftX, driftY: driftY,
            verdict: verdict, summary: summary, plan: plan, stabilisation: nil)
    }

    // MARK: - Maths

    /// Running median, edge-clamped, window forced odd and no wider than
    /// the series.
    static func runningMedian(_ values: [Double], window: Int) -> [Double] {
        let n = values.count
        guard n > 2 else { return values }
        var k = min(window, n)
        if k % 2 == 0 { k -= 1 }
        guard k >= 3 else { return values }
        let half = k / 2
        var out = [Double](repeating: 0, count: n)
        for index in 0..<n {
            var sample: [Double] = []
            sample.reserveCapacity(k)
            for offset in -half...half {
                sample.append(values[min(max(index + offset, 0), n - 1)])
            }
            sample.sort()
            out[index] = sample[half]
        }
        return out
    }

    // MARK: - Copy helpers

    /// The number a person sees for a photo: the capture number in its file
    /// name when it has one (`frame-00802.dng` → 802), else its 1-based
    /// position.
    public static func displayNumber(name: String, index: Int) -> Int {
        let stem = name.split(separator: ".").first.map(String.init) ?? name
        if let dash = stem.lastIndex(of: "-"), let number = Int(stem[stem.index(after: dash)...]) {
            return number
        }
        return index + 1
    }

    public static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    public static func percent(_ fraction: Double) -> String {
        fraction < 0.001 ? String(format: "%.2f%%", fraction * 100) : String(format: "%.1f%%", fraction * 100)
    }

    public static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 90 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 120 { return "\(minutes) minutes" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    // MARK: - Files

    public static func url(inSourceFolder folder: URL) -> URL {
        folder.appendingPathComponent(fileName)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func data() throws -> Data {
        try Self.encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> FramingReview {
        try decoder.decode(FramingReview.self, from: data)
    }

    public static func load(from url: URL) throws -> FramingReview {
        try decode(Data(contentsOf: url))
    }

    /// Nil when no review has been written beside these frames, or the file
    /// is unreadable — an absent review is a state, not an error.
    public static func load(inSourceFolder folder: URL) -> FramingReview? {
        try? load(from: url(inSourceFolder: folder))
    }

    /// Atomic write: the file is either the old review or the new one.
    public func write(to url: URL) throws {
        try data().write(to: url, options: .atomic)
    }

    public func write(inSourceFolder folder: URL) throws {
        try write(to: Self.url(inSourceFolder: folder))
    }
}

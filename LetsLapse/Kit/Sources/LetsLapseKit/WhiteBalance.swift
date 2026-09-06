import Foundation

/// What a shoot's white balance is anchored to.
///
/// The grade's temperature and tint are *offsets* — a mired nudge measured
/// from somewhere — and for a single photograph "somewhere" is obviously the
/// file's own as-shot reading. Over a sequence that reading is a moving
/// target: a camera left on auto white balance re-decides between frames, in
/// coarse plateaus and occasionally in one large step. An offset measured from
/// a moving anchor moves with it, so the same slider value renders a different
/// white on either side of the camera's decision and no amount of keyframing
/// can close the gap — both keyframes ride the same jump.
///
/// Pinning the anchor is the fix. With one declared here, the offsets become
/// absolute: the same value means the same white on every frame, keyframes
/// between two declared whites read as a white-balance ramp, and the camera's
/// own decisions stop reaching the picture.
public enum WhiteBalanceSource: Codable, Equatable, Sendable {
    /// Every frame anchored on its own as-shot reading. The historic
    /// behaviour, and right for a single still or a run shot on a manual
    /// white balance.
    case asShot
    /// One illuminant for the whole shoot. `kelvin` and `tint` are in the raw
    /// converter's units — the ±150 tint axis Adobe's Tint slider also uses.
    case fixed(kelvin: Float, tint: Float)
    /// The measured as-shot series with its camera-side artefacts taken out:
    /// steps and jitter no scene can produce are removed, a genuine
    /// daylight-to-dusk drift survives. `anchorPosition` (0…1 of the source)
    /// chooses which frame's own white the corrected curve is levelled to.
    case smoothed(anchorPosition: Double)

    public var isAsShot: Bool { if case .asShot = self { return true }; return false }
}

/// One frame's as-shot white balance, as the raw converter reports it.
public struct WhiteBalanceSample: Codable, Equatable, Sendable {
    /// The capture index this reading belongs to, 0-based.
    public var frame: Int
    /// The source file's name, for humans and for spotting a re-import.
    public var file: String
    /// As-shot correlated colour temperature, Kelvin.
    public var kelvin: Float
    /// As-shot tint on the converter's ±150 green–magenta axis.
    public var tint: Float
    /// Seconds from the first frame, on the shoot's own clock. Zero when no
    /// timing sidecar was available, in which case the smoother falls back to
    /// frame spacing.
    public var seconds: Double

    public init(frame: Int, file: String, kelvin: Float, tint: Float, seconds: Double = 0) {
        self.frame = frame
        self.file = file
        self.kelvin = kelvin
        self.tint = tint
        self.seconds = seconds
    }

    /// Reciprocal megakelvin. Every piece of white-balance arithmetic here
    /// happens in mired, because that is the axis on which equal steps look
    /// equal — 500 K at the tungsten end is a colour change, 500 K at the
    /// overcast end is barely visible.
    public var mired: Double { 1e6 / Double(min(max(kelvin, 1667), 25000)) }
}

/// The measured as-shot series for one shoot, plus the corrected curve derived
/// from it. Written beside the frames as `frames.whitebalance`, NDJSON, one
/// sample per line — the same shape and the same crash-tolerance as
/// `FrameTimestamps`.
public struct WhiteBalanceSeries: Equatable, Sendable {
    public var samples: [WhiteBalanceSample]

    public init(samples: [WhiteBalanceSample]) {
        self.samples = samples
    }

    public static let fileName = "frames.whitebalance"

    public var isEmpty: Bool { samples.isEmpty }

    // MARK: - Reading and writing

    public static func load(from url: URL) throws -> WhiteBalanceSeries {
        decode(try String(contentsOf: url, encoding: .utf8))
    }

    /// Parses NDJSON, skipping blank and unparseable lines. A measuring pass
    /// killed part-way leaves a torn final line and every good line before it;
    /// one bad line must not cost the shoot its whole series.
    public static func decode(_ text: String) -> WhiteBalanceSeries {
        let decoder = JSONDecoder()
        var samples: [WhiteBalanceSample] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                  let sample = try? decoder.decode(WhiteBalanceSample.self, from: data)
            else { continue }
            samples.append(sample)
        }
        return WhiteBalanceSeries(samples: samples.sorted { $0.frame < $1.frame })
    }

    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var lines: [String] = []
        for sample in samples {
            let data = try encoder.encode(sample)
            lines.append(String(decoding: data, as: UTF8.self))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func write(to directory: URL) throws {
        try encoded().write(
            to: directory.appendingPathComponent(Self.fileName),
            atomically: true, encoding: .utf8)
    }
}

// MARK: - Correction

extension WhiteBalanceSeries {

    /// A single-frame change bigger than this is not light. Twilight's fastest
    /// colour change is a fraction of a mired a second; nothing physical moves
    /// a scene 30 mired between two frames.
    public static let grossStepMired: Double = 30

    /// …and neither is a single step carrying this much of everything the run's
    /// white balance did. A camera walking real light down in plateaus takes it
    /// in many small lumps; one lump worth a third of the whole journey is the
    /// camera re-deciding, not the sun setting.
    public static let grossStepFraction: Double = 0.35

    /// How far, in the shoot's own seconds, the smoothing window reaches. Wide
    /// enough to turn a staircase into a ramp — which is what auto white
    /// balance actually produces, and what actually shows in playback — and
    /// short enough to leave a real dusk curve its shape.
    public static let smoothingWindowSeconds: Double = 60

    /// A frame-to-frame change at or under this is invisible in playback. Used
    /// for reporting a verdict, not for correcting.
    public static let visibleStepMired: Double = 3

    /// The corrected declaration for every frame, in capture order.
    ///
    /// Auto white balance does two distinguishable things to a sequence, and
    /// they need opposite treatments:
    ///
    /// 1. It delivers real light change **late and in lumps** — a body holds
    ///    one white for eighty frames, then moves to the next plateau. That
    ///    change is genuine; only its timing is wrong. Rejecting those steps
    ///    would flatten a real dusk into nothing, so they are *spread*
    ///    instead: a wide window turns the staircase back into the ramp the
    ///    light actually walked.
    /// 2. Occasionally it **re-decides outright** — one step carrying a large
    ///    fraction of everything the run did, inside a single frame interval.
    ///    Nothing in the scene did that, and no amount of smoothing hides it,
    ///    so it is removed as a level shift: every frame after it is brought
    ///    back onto the curve the run was already on.
    ///
    /// `anchorPosition` (0…1) picks the frame whose own as-shot white the
    /// corrected curve is levelled to, so the result passes through a real
    /// reading rather than an average of the run.
    public func correctedDeclarations(anchorPosition: Double = 0) -> [WhiteBalanceSample] {
        guard samples.count > 1 else { return samples }

        let mireds = samples.map(\.mired)
        let tints = samples.map { Double($0.tint) }
        let limit = Self.grossStepLimit(mireds: mireds)

        // Re-integrate, dropping the gross steps outright rather than clamping
        // them: a re-decision carries no information about where the light
        // went, and a clamped one would leave a fraction of the step in and let
        // a run of them accumulate. The tint half moves with its Kelvin half —
        // they are one decision by the camera, so treating them separately
        // would correct a step's temperature and leave its green–magenta
        // standing.
        var levelledMired = [mireds[0]]
        var levelledTint = [tints[0]]
        for index in 1..<samples.count {
            let step = mireds[index] - mireds[index - 1]
            let gross = abs(step) > limit
            levelledMired.append(levelledMired[index - 1] + (gross ? 0 : step))
            levelledTint.append(
                levelledTint[index - 1] + (gross ? 0 : tints[index] - tints[index - 1]))
        }

        // Then spread the plateaus. A short median first, so one rogue frame
        // cannot drag the window, and a mean over the wide span after — which
        // is the part that actually turns a staircase into a ramp.
        let radius = smoothingRadius()
        var correctedMired = Self.movingMean(Self.movingMedian(levelledMired, radius: 2), radius: radius)
        var correctedTint = Self.movingMean(Self.movingMedian(levelledTint, radius: 2), radius: radius)

        // Level the curve so it passes through the anchor frame's own reading.
        let anchor = min(max(Int((Double(samples.count - 1) * anchorPosition).rounded()), 0),
                         samples.count - 1)
        let miredShift = mireds[anchor] - correctedMired[anchor]
        let tintShift = tints[anchor] - correctedTint[anchor]
        correctedMired = correctedMired.map { $0 + miredShift }
        correctedTint = correctedTint.map { $0 + tintShift }

        return samples.indices.map { index in
            var out = samples[index]
            out.kelvin = Float(1e6 / min(max(correctedMired[index], 40), 600))
            out.tint = Float(min(max(correctedTint[index], -150), 150))
            return out
        }
    }

    /// The smoothing window in frames, from the run's own cadence. Falls back
    /// to a fraction of the frame count when the series carries no clock (an
    /// import with no timing sidecar).
    func smoothingRadius() -> Int {
        let span = (samples.last?.seconds ?? 0) - (samples.first?.seconds ?? 0)
        guard span > 0, samples.count > 1 else { return max(samples.count / 20, 1) }
        let perFrame = span / Double(samples.count - 1)
        return max(Int((Self.smoothingWindowSeconds / 2 / perFrame).rounded()), 1)
    }

    /// The single-frame change above which a step is the camera re-deciding
    /// rather than the light moving: a fixed floor, or a third of everything
    /// the run's white balance did, whichever is larger. The travel is measured
    /// between the 5th and 95th percentiles so the outlier being hunted cannot
    /// inflate the threshold that would catch it.
    public static func grossStepLimit(mireds: [Double]) -> Double {
        guard mireds.count > 2 else { return grossStepMired }
        let sorted = mireds.sorted()
        let low = sorted[max(Int(Double(sorted.count) * 0.05), 0)]
        let high = sorted[min(Int(Double(sorted.count) * 0.95), sorted.count - 1)]
        return max(grossStepMired, grossStepFraction * (high - low))
    }

    public static func movingMean(_ values: [Double], radius: Int) -> [Double] {
        guard radius > 0, values.count > 1 else { return values }
        // Prefix sums: the window is wide — a minute of a shoot is easily a
        // hundred frames — and re-summing it per frame is quadratic.
        var prefix: [Double] = [0]
        prefix.reserveCapacity(values.count + 1)
        for value in values { prefix.append(prefix[prefix.count - 1] + value) }
        return values.indices.map { index in
            let lower = max(index - radius, 0)
            let upper = min(index + radius, values.count - 1)
            return (prefix[upper + 1] - prefix[lower]) / Double(upper - lower + 1)
        }
    }

    public static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1
            ? sorted[middle]
            : (sorted[middle - 1] + sorted[middle]) / 2
    }

    public static func movingMedian(_ values: [Double], radius: Int) -> [Double] {
        guard radius > 0, values.count > 2 * radius else { return values }
        return values.indices.map { index in
            let lower = max(index - radius, 0)
            let upper = min(index + radius, values.count - 1)
            return median(Array(values[lower...upper]))
        }
    }
}

// MARK: - Resolving a declaration for one frame

/// A shoot's white-balance choice resolved against its measured series, ready
/// for the renderer to ask "what white is this frame declared at?".
///
/// Carrying the resolved series rather than the raw one keeps the arithmetic
/// out of the render loop: the correction runs once, when the track is built.
public struct WhiteBalanceTrack: Equatable, Sendable {
    public var source: WhiteBalanceSource
    /// One declaration per source frame, in source order. Empty for
    /// `.asShot` and `.fixed`, which need no series to answer.
    public var perFrame: [WhiteBalanceSample]

    /// `perFrame` keyed by file name. Built once, here, rather than on demand:
    /// the blend path asks once per source frame of a shoot that can be
    /// thousands long, and it asks from several threads at once, so a lazily
    /// filled cache would be a race as well as a cost.
    public private(set) var fileIndex: [String: WhiteBalanceSample]

    public static let asShot = WhiteBalanceTrack(source: .asShot, perFrame: [])

    public init(source: WhiteBalanceSource, perFrame: [WhiteBalanceSample] = []) {
        self.source = source
        self.perFrame = perFrame
        self.fileIndex = Dictionary(
            perFrame.map { ($0.file, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Builds the track a shoot renders through. `series` is only read for
    /// `.smoothed`; the other two answer from the source alone, so a project
    /// that has never been measured can still pin a white.
    public static func resolve(
        source: WhiteBalanceSource, series: WhiteBalanceSeries?
    ) -> WhiteBalanceTrack {
        switch source {
        case .asShot, .fixed:
            return WhiteBalanceTrack(source: source)
        case .smoothed(let anchorPosition):
            guard let series, !series.isEmpty else {
                // Nothing measured yet: declare nothing rather than guessing,
                // so the picture stays as-shot until the pass has run.
                return WhiteBalanceTrack(source: source)
            }
            return WhiteBalanceTrack(
                source: source,
                perFrame: series.correctedDeclarations(anchorPosition: anchorPosition))
        }
    }

    /// True when the declared white is a function of position, so a surface
    /// that can only hold one has to say *when*. A fixed white is not: it is
    /// the same everywhere, which is what makes it the answer to a camera that
    /// would not stay still.
    public var variesOverTime: Bool {
        if case .smoothed = source { return !perFrame.isEmpty }
        return false
    }

    /// A short, stable string for render cache keys. Empty for `.asShot`, so
    /// no existing project's keys move.
    public var cacheToken: String {
        switch source {
        case .asShot:
            return ""
        case .fixed(let kelvin, let tint):
            return String(format: "|wbf%.1f,%.2f", kelvin, tint)
        case .smoothed(let anchorPosition):
            // The resolved curve is what actually renders, so the key has to
            // move when the measurement does — its two ends and its length
            // identify it without stringifying five hundred samples.
            let first = perFrame.first.map { String(format: "%.1f,%.2f", $0.kelvin, $0.tint) } ?? "-"
            let last = perFrame.last.map { String(format: "%.1f,%.2f", $0.kelvin, $0.tint) } ?? "-"
            return String(format: "|wbs%.3f,%d,%@,%@", anchorPosition, perFrame.count, first, last)
        }
    }

    /// The white one *file* is declared at.
    ///
    /// The by-position lookup needs a clock; the blend path has only a URL —
    /// its decode closure is handed one frame at a time with no idea where in
    /// the shoot it sits. A smoothed track already records which file each of
    /// its samples came from, so the name is enough, and matching on it means
    /// a re-ordered or partly-hidden frame list cannot slide the correction
    /// off by a frame.
    public func declared(forFile name: String) -> (kelvin: Float, tint: Float)? {
        switch source {
        case .asShot:
            return nil
        case .fixed(let kelvin, let tint):
            return (kelvin, tint)
        case .smoothed:
            guard let sample = fileIndex[name] else { return nil }
            return (sample.kelvin, sample.tint)
        }
    }

    /// This track reduced to the one white a named file is declared at — a
    /// constant, safe to carry across a concurrency boundary and to key a
    /// render cache on. Unchanged for `.asShot` and `.fixed`, which are already
    /// constants.
    public func pinned(forFile name: String) -> WhiteBalanceTrack {
        guard variesOverTime, let declared = declared(forFile: name) else { return self }
        return WhiteBalanceTrack(source: .fixed(kelvin: declared.kelvin, tint: declared.tint))
    }

    /// The white this position is declared at, or nil for "use the frame's own
    /// as-shot" — which is what every existing project says.
    public func declared(atPosition position: Double) -> (kelvin: Float, tint: Float)? {
        switch source {
        case .asShot:
            return nil
        case .fixed(let kelvin, let tint):
            return (kelvin, tint)
        case .smoothed:
            guard !perFrame.isEmpty else { return nil }
            let index = min(max(Int((Double(perFrame.count - 1) * position).rounded()), 0),
                            perFrame.count - 1)
            return (perFrame[index].kelvin, perFrame[index].tint)
        }
    }
}

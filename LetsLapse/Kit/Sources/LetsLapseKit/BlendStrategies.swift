import Foundation

/// The field-test blend strategies behind BLEND=Auto on the DNG path.
///
/// Three ways to answer the same per-window question — "how many RAW captures
/// should this window blend?" — kept side by side so a comparison shoot can
/// run one per device and still log what the other two *would* have chosen:
///
/// - **Zone** — the shipping table: discrete EV bands, 3-cycle rolling
///   average. Reactive and deterministic; the control arm.
/// - **Latitude** — a continuous sigmoid over the same EV signal, with
///   time-based smoothing, a quantisation deadband and a ±1-per-cycle slew.
///   Tests whether continuity beats steps. EV velocity is measured and
///   logged but deliberately does not actuate: during ramped shoots the EV
///   channel is the ramp's own commanded exposure (slew-limited to 1/3 stop
///   per cycle), so a velocity term would measure the ramp, not the sunset —
///   and the engine's own trend compensation ships disabled after a
///   documented field runaway of exactly that signal class.
/// - **Lumen** — Zone's answer plus a bounded correction from what the last
///   window's *pixels* said: when the fraction of the image sitting below an
///   ISO-indexed noise floor says the shadows are starving, add frames (up
///   to +2 over the prior); when they recover, decay back. Strictly
///   feed-forward — it reads the ramp's world and never writes back to it.
///
/// All three return the *uncapped* count they want. The device's capability
/// ceiling is applied once, at actuation, so the log can show what each
/// strategy asked for separately from what the hardware allowed.
public enum BlendStrategyID: String, CaseIterable, Codable, Sendable {
    case zone
    case latitude
    case lumen

    public var displayName: String {
        switch self {
        case .zone: return "Zone"
        case .latitude: return "Latitude"
        case .lumen: return "Lumen"
        }
    }

    /// Stamped into `capture_log.json` beside the algorithm id, so a log can
    /// be tied to the exact decision logic that produced it.
    public static let version = "fieldtest-1"
}

// MARK: - Zone

/// The shipping Auto table, as a pure strategy. This is the single source of
/// the EV bands — the app's `DynamicBlendPolicy` forwards to it.
public struct ZoneBlendStrategy: Sendable {
    public struct Band: Equatable, Sendable {
        public let lowerBound: Double
        public let frames: Int
        public let name: String

        public init(lowerBound: Double, frames: Int, name: String) {
            self.lowerBound = lowerBound
            self.frames = frames
            self.name = name
        }
    }

    /// Bright daylight needs the least help; the deepest stacks are for the
    /// light that is nearly gone. Read top-down: the first band whose
    /// `lowerBound` (inclusive) the EV clears wins.
    public static let bands: [Band] = [
        Band(lowerBound: 13, frames: 8, name: "daylight"),
        Band(lowerBound: 10, frames: 5, name: "overcast"),
        Band(lowerBound: 7, frames: 3, name: "dim"),
        Band(lowerBound: 4, frames: 2, name: "dusk"),
        Band(lowerBound: -.infinity, frames: 1, name: "night"),
    ]

    /// How many cycles of EV the rolling average spans.
    public static let smoothingWindow = 3

    public static func band(forEV ev: Double) -> Band {
        bands.first { ev >= $0.lowerBound } ?? bands[bands.count - 1]
    }

    private var readings: [Double] = []
    private(set) public var lastCount: Int?
    private(set) public var lastSmoothedEV: Double?

    public init() {}

    /// One cycle's resolution. A nil EV (the meter reported nothing usable)
    /// holds the last count rather than guessing, falling back to the middle
    /// of the table on a first cycle with no reading — the same behaviour the
    /// shipping `DynamicBlendState` has always had.
    public mutating func resolve(ev: Double?) -> Int {
        guard let ev else {
            if let held = lastCount { return held }
            let fallback = Self.band(forEV: 10).frames
            lastCount = fallback
            return fallback
        }
        readings.append(ev)
        if readings.count > Self.smoothingWindow {
            readings.removeFirst(readings.count - Self.smoothingWindow)
        }
        let smoothed = readings.reduce(0, +) / Double(readings.count)
        let count = Self.band(forEV: smoothed).frames
        lastSmoothedEV = smoothed
        lastCount = count
        return count
    }
}

// MARK: - Latitude

/// Continuous EV → count mapping. The hypothesis under test: Zone's visible
/// artefact is the 2–3-frame step at a band edge, and a sigmoid quantised
/// with a deadband and a ±1 slew removes it without changing what the count
/// is *for* (more frames in more light, same as Zone).
public struct LatitudeBlendStrategy: Sendable {
    public struct Tuning: Sendable {
        /// EV at which the continuous count crosses its midpoint (4.5).
        public var center: Double = 9.0
        /// Stops per unit of sigmoid steepness. Calibrated to track Zone's
        /// table through the dusk range the field test lives in: ~7.3 at
        /// EV 13 (Zone 8), ~5.4 at EV 10 (Zone 5), ~2.7 at EV 7 (Zone 3),
        /// ~1.4 at EV 4 (Zone 2). The residual differences are the
        /// continuity under test — a curve that diverged by whole frames
        /// through dusk would instead be testing "Latitude stacks less".
        public var width: Double = 1.8
        /// Time constant (seconds) of the EMA on the continuous count —
        /// time-based, so EVERY=Auto re-pacing doesn't change the smoothing.
        public var smoothingTau: Double = 20.0
        /// How far past the ±0.5 rounding edge the smoothed value must move
        /// before the integer count follows. 0.3 means a change needs the
        /// continuous value 0.8 away from the current count — AE hunting by
        /// a third of a stop can't flap it.
        public var deadband: Double = 0.3
        /// Seconds of EV history the velocity diagnostic is fitted over.
        public var velocityWindow: Double = 180.0
        public init() {}
    }

    public var tuning = Tuning()
    private var smoothedContinuous: Double?
    private var lastResolveTime: Double?
    private var history: [(t: Double, ev: Double)] = []
    private(set) public var lastCount: Int?
    private(set) public var lastContinuous: Double?
    /// Signed EV velocity in stops per minute, least-squares over the recent
    /// history. Logged for analysis; never actuates (see the header note).
    private(set) public var lastVelocityStopsPerMinute: Double?

    public init() {}

    /// The raw sigmoid, exposed for tests: EV → continuous count in 1...8.
    public func continuousCount(forEV ev: Double) -> Double {
        1 + 7 / (1 + exp(-(ev - tuning.center) / tuning.width))
    }

    /// `t` is a monotonic clock in seconds (uptime); wall time would smooth
    /// across clock adjustments.
    public mutating func resolve(ev: Double?, at t: Double) -> Int {
        guard let ev else {
            if let held = lastCount { return held }
            // Cold start with no meter: return the mid-table fallback but do
            // NOT anchor the hysteresis on it — anchoring would make the
            // first real reading walk toward the true depth one frame per
            // window (a night shoot started before AE settles would
            // over-stack for four windows), where an unanchored first
            // reading snaps straight to the curve, like Zone does.
            return ZoneBlendStrategy.band(forEV: 10).frames
        }
        let raw = continuousCount(forEV: ev)
        let smoothed: Double
        if let previous = smoothedContinuous, let lastT = lastResolveTime, t > lastT {
            let alpha = 1 - exp(-(t - lastT) / tuning.smoothingTau)
            smoothed = previous + alpha * (raw - previous)
        } else {
            smoothed = raw
        }
        smoothedContinuous = smoothed
        lastResolveTime = t
        lastContinuous = smoothed

        history.append((t: t, ev: ev))
        history.removeAll { t - $0.t > tuning.velocityWindow }
        lastVelocityStopsPerMinute = Self.slopePerMinute(of: history)

        let count: Int
        if let current = lastCount {
            // Hysteresis plus slew: move one frame at a time, and only when
            // the smoothed value has cleared the rounding edge by the
            // deadband.
            if smoothed > Double(current) + 0.5 + tuning.deadband {
                count = min(8, current + 1)
            } else if smoothed < Double(current) - 0.5 - tuning.deadband {
                count = max(1, current - 1)
            } else {
                count = current
            }
        } else {
            count = max(1, min(8, Int(smoothed.rounded())))
        }
        lastCount = count
        return count
    }

    /// Least-squares slope of EV over time, in stops per minute. Needs at
    /// least three points spanning 30 seconds to say anything.
    static func slopePerMinute(of points: [(t: Double, ev: Double)]) -> Double? {
        guard points.count >= 3,
              let first = points.first, let last = points.last,
              last.t - first.t >= 30 else { return nil }
        let n = Double(points.count)
        let meanT = points.reduce(0) { $0 + $1.t } / n
        let meanEV = points.reduce(0) { $0 + $1.ev } / n
        var covariance = 0.0
        var variance = 0.0
        for p in points {
            covariance += (p.t - meanT) * (p.ev - meanEV)
            variance += (p.t - meanT) * (p.t - meanT)
        }
        guard variance > 0 else { return nil }
        return covariance / variance * 60
    }
}

// MARK: - Frame luminance statistics

/// What one blended window's pixels actually said, in the scene-linear
/// working space the blend already operates in (1.0 = sensor saturation).
///
/// Computed by strided point-sampling — never by downscaling, which averages
/// shadow pixels into their neighbours and understates clipping. The
/// fractions are kept at fixed absolute thresholds (rather than one
/// ISO-dependent number) so post-shoot analysis can re-derive a score under
/// any calibration without re-shooting.
public struct FrameLuminanceStats: Codable, Equatable, Sendable {
    /// Fixed scene-linear thresholds the `fractionBelow` array is measured
    /// against: roughly 2^-10 … 2^-3 of saturation. The ladder reaches
    /// 3 stops below saturation because Lumen's ISO-indexed starving
    /// threshold climbs with gain — a ladder topping out at 2^-5 saturates
    /// around ISO 1550 and stops discriminating exactly where night shoots
    /// live.
    public static let thresholds: [Double] = [
        0.001, 0.002, 0.004, 0.008, 0.016, 0.031, 0.062, 0.125,
    ]

    public var sampleCount: Int
    public var meanLuma: Double
    /// Luma percentiles of the sampled distribution.
    public var p01: Double
    public var p05: Double
    public var p10: Double
    public var p50: Double
    /// Fraction of samples at or below each of `Self.thresholds`.
    public var fractionBelow: [Double]
    /// Fraction of samples at or above 0.98 of saturation — highlight clip.
    /// Logged for analysis only: same-exposure stacking cannot recover it.
    public var fractionAbove98: Double
    /// The exposure the window's frames were taken at, for ISO-indexed
    /// interpretation of the fractions — and the provenance that lets an
    /// analyzer match these stats back to the entry they were measured on
    /// (they ride the log one or two windows later).
    public var iso: Double?
    public var exposureDuration: Double?
    public var ev: Double?
    /// The decode scale the sampled buffer came from: 1.0 = full-resolution
    /// point samples (the blend path); below 1.0 the RAW decode itself was
    /// downscaled first (the single-capture path), which averages shadow
    /// pixels toward their neighbours — offline refits must not mix the two
    /// populations blindly, which is why the scale is in the record.
    public var sourceScale: Double?

    public init(
        sampleCount: Int, meanLuma: Double,
        p01: Double, p05: Double, p10: Double, p50: Double,
        fractionBelow: [Double], fractionAbove98: Double,
        iso: Double? = nil, exposureDuration: Double? = nil, ev: Double? = nil,
        sourceScale: Double? = nil
    ) {
        self.sampleCount = sampleCount
        self.meanLuma = meanLuma
        self.p01 = p01
        self.p05 = p05
        self.p10 = p10
        self.p50 = p50
        self.fractionBelow = fractionBelow
        self.fractionAbove98 = fractionAbove98
        self.iso = iso
        self.exposureDuration = exposureDuration
        self.ev = ev
        self.sourceScale = sourceScale
    }

    /// Fraction of samples below an arbitrary threshold, interpolated
    /// piecewise-linearly in log2(threshold) between the fixed measurement
    /// points, clamped at the ends.
    public func fraction(below threshold: Double) -> Double {
        let points = Self.thresholds
        guard fractionBelow.count == points.count, !points.isEmpty else { return 0 }
        guard threshold > points[0] else { return fractionBelow[0] }
        guard threshold < points[points.count - 1] else { return fractionBelow[fractionBelow.count - 1] }
        for i in 1..<points.count where threshold <= points[i] {
            let x0 = log2(points[i - 1]), x1 = log2(points[i])
            let span = x1 - x0
            guard span > 0 else { return fractionBelow[i] }
            let f = (log2(threshold) - x0) / span
            return fractionBelow[i - 1] + f * (fractionBelow[i] - fractionBelow[i - 1])
        }
        return fractionBelow[fractionBelow.count - 1]
    }

    /// Computes stats from an interleaved RGBA 16-bit buffer in the blend's
    /// working space, where stored 1.0 (= 65535) is `2^headroomStops` in
    /// scene units. Strided point sampling, ~`targetSamples` pixels.
    public static func compute(
        rgba16 buffer: [UInt16], width: Int, height: Int,
        headroomStops: Int,
        iso: Double? = nil, exposureDuration: Double? = nil, ev: Double? = nil,
        sourceScale: Double? = nil,
        targetSamples: Int = 8192
    ) -> FrameLuminanceStats? {
        guard width > 0, height > 0, buffer.count >= width * height * 4 else { return nil }
        let step = max(1, Int((Double(width * height) / Double(targetSamples)).squareRoot()))
        let headroom = Double(1 << max(0, headroomStops))
        var lumas: [Double] = []
        lumas.reserveCapacity(targetSamples + width / step + 2)
        var y = 0
        while y < height {
            let row = y * width * 4
            var x = 0
            while x < width {
                let p = row + x * 4
                let r = Double(buffer[p]) / 65535
                let g = Double(buffer[p + 1]) / 65535
                let b = Double(buffer[p + 2]) / 65535
                lumas.append((0.2126 * r + 0.7152 * g + 0.0722 * b) * headroom)
                x += step
            }
            y += step
        }
        guard !lumas.isEmpty else { return nil }
        lumas.sort()
        let n = Double(lumas.count)
        func percentile(_ q: Double) -> Double {
            lumas[min(lumas.count - 1, max(0, Int((q * n).rounded(.down))))]
        }
        let fractions = thresholds.map { threshold in
            Double(lumas.prefix { $0 <= threshold }.count) / n
        }
        let above = Double(lumas.reversed().prefix { $0 >= 0.98 }.count) / n
        return FrameLuminanceStats(
            sampleCount: lumas.count,
            meanLuma: lumas.reduce(0, +) / n,
            p01: percentile(0.01), p05: percentile(0.05),
            p10: percentile(0.10), p50: percentile(0.50),
            fractionBelow: fractions, fractionAbove98: above,
            iso: iso, exposureDuration: exposureDuration, ev: ev,
            sourceScale: sourceScale)
    }
}

// MARK: - Lumen

/// Zone's answer, corrected by what the pixels said. The correction is
/// deliberately narrow: it only ever *adds* frames (stacking's one real
/// power is shadow SNR), it is bounded at `maxBoost` over the prior, it
/// moves one frame per cycle, and with no pixel data yet it is exactly Zone.
public struct LumenBlendStrategy: Sendable {
    public struct Tuning: Sendable {
        /// Scene-linear noise floor at ISO 100, as a fraction of saturation
        /// (~2^-11). A first-guess model, refined from field logs — the
        /// stats carry fixed-threshold fractions precisely so this constant
        /// can be re-fitted offline.
        public var floorAtISO100: Double = 0.0005
        /// The floor scales linearly with ISO/100 (read-noise dominated).
        /// The product is clamped to the top measured threshold.
        public var snrMargin: Double = 4.0
        /// Fraction of starving pixels at which a frame is added…
        public var raiseThreshold: Double = 0.12
        /// …and below which the boost decays back toward the prior.
        public var clearThreshold: Double = 0.04
        /// Ceiling of the correction over the Zone prior.
        public var maxBoost: Int = 2
        public init() {}
    }

    public var tuning = Tuning()
    private(set) public var boost: Int = 0
    /// The starving-pixel fraction the last resolution scored, nil while
    /// cold (no window analysed yet).
    private(set) public var lastScore: Double?
    /// The measurement the boost last moved on. The boost only ever adjusts
    /// on a *new* measurement: capture stalls close several windows in one
    /// tick and analysis lands a window or two late, so the same stats can
    /// be handed in repeatedly — re-scoring them would ratchet the boost to
    /// its cap off a single measurement and defeat the one-per-cycle bound.
    private var lastScoredStats: FrameLuminanceStats?

    public init() {}

    /// The scene-linear threshold below which a pixel counts as starving,
    /// for the exposure the stats were measured at. Clamped to the top of
    /// the measurement ladder (2^-3 of saturation), which the ISO-linear
    /// floor model reaches around ISO 6400.
    public func starvingThreshold(iso: Double) -> Double {
        let floor = tuning.floorAtISO100 * max(1, iso / 100) * tuning.snrMargin
        return min(FrameLuminanceStats.thresholds[FrameLuminanceStats.thresholds.count - 1], floor)
    }

    public mutating func resolve(prior: Int, stats: FrameLuminanceStats?) -> Int {
        guard let stats, let iso = stats.iso, stats != lastScoredStats else {
            // Cold, no usable analysis, or the same measurement again: hold
            // the boost — the scene didn't change because a measurement went
            // missing or a stalled run re-asked before a new one landed.
            return max(1, min(8, prior + boost))
        }
        lastScoredStats = stats
        let score = stats.fraction(below: starvingThreshold(iso: iso))
        lastScore = score
        if score > tuning.raiseThreshold, boost < tuning.maxBoost {
            boost += 1
        } else if score < tuning.clearThreshold, boost > 0 {
            boost -= 1
        }
        return max(1, min(8, prior + boost))
    }
}

// MARK: - Processing ceiling

/// AIMD governor for the frames-per-window ceiling, driven by what whole
/// windows actually cost to process — never by a derived per-frame rate.
///
/// The first attempt at this modelled per-frame cost from window totals and
/// spiralled: window totals include fixed per-window overhead (queue hops,
/// author/write setup), so shrinking the window inflated the estimated
/// per-frame cost, which shrank the window further, down to 1–2 frames on
/// hardware that was comfortably sustaining 5. Bench-caught 2026-08-22.
/// AIMD on the measured total has no model to be wrong about: over budget →
/// step down one frame; comfortably under for two windows running → step
/// back up one.
public struct ProcessingCeiling: Sendable {
    /// Growth requires this many comfortable windows in a row, so one lucky
    /// fast window doesn't oscillate the ceiling.
    static let growthStreak = 2
    /// "Comfortable" = the window's processing finished inside this fraction
    /// of the interval.
    static let comfortableFraction = 0.7

    private(set) public var ceiling = ZoneBlendStrategy.bands[0].frames
    private var comfortableStreak = 0
    /// When even a ONE-frame window costs more than the interval, frame
    /// count has no more room to give — pacing must stretch. This is the
    /// interval the pipeline demonstrably needs (measured cost plus
    /// margin), for EVERY=Auto to repace against; nil while frame-count
    /// reduction is still the remedy or once windows fit comfortably
    /// again. Without it a slow device SURVIVES by churning empty starved
    /// windows (the 12 Pro's resurrection ran 204 of them in 15 minutes);
    /// with it, the same time becomes fewer, full windows at honest
    /// spacing.
    private(set) public var sustainableIntervalSeconds: Double?

    public init() {}

    /// Feed one produced window's measured processing cost.
    public mutating func record(windowSeconds: Double, frames: Int, intervalSeconds: Double) {
        guard frames > 0, windowSeconds > 0, intervalSeconds > 0 else { return }
        if windowSeconds > intervalSeconds {
            // Over budget: the pipeline owes time it doesn't have. Step to
            // one below what this window actually carried (stepping below
            // the current ceiling matters when the window was already
            // smaller than the ceiling allowed).
            comfortableStreak = 0
            if frames <= 1 {
                // Bottomed out: ask pacing for the time instead. Capped at
                // 4x so one pathological window can't demand a crawl.
                let wanted = min(windowSeconds * 1.15, intervalSeconds * 4)
                sustainableIntervalSeconds = max(sustainableIntervalSeconds ?? 0, wanted)
            }
            ceiling = max(1, min(ceiling, frames) - 1)
        } else if windowSeconds < intervalSeconds * Self.comfortableFraction {
            // Fitting comfortably again: pacing may narrow back; if the
            // pressure returns, the floor re-engages from measurement.
            sustainableIntervalSeconds = nil
            comfortableStreak += 1
            if comfortableStreak >= Self.growthStreak,
               ceiling < ZoneBlendStrategy.bands[0].frames {
                ceiling += 1
                comfortableStreak = 0
            }
        } else {
            // In the band between comfortable and over: hold.
            comfortableStreak = 0
        }
    }
}

// MARK: - Bank

/// All three strategies resolved together each cycle, so every shoot logs
/// the full comparison whichever one is actuating.
public struct BlendStrategyBank: Sendable {
    public var zone = ZoneBlendStrategy()
    public var latitude = LatitudeBlendStrategy()
    public var lumen = LumenBlendStrategy()

    public struct Proposals: Sendable {
        public var zone: Int
        public var latitude: Int
        public var lumen: Int
        /// The 3-cycle mean Zone actually decided on — without it, a log
        /// row whose instantaneous EV straddles a band edge from the mean
        /// looks like a Zone bug in the analysis.
        public var zoneSmoothedEV: Double?
        public var latitudeContinuous: Double?
        public var evVelocityStopsPerMinute: Double?
        public var lumenScore: Double?
        public var lumenBoost: Int
    }

    public init() {}

    /// `t` is a monotonic clock in seconds; `stats` is the last closed
    /// window's luminance analysis (nil until one exists).
    public mutating func resolveAll(
        ev: Double?, at t: Double, stats: FrameLuminanceStats?
    ) -> Proposals {
        let zoneCount = zone.resolve(ev: ev)
        let latitudeCount = latitude.resolve(ev: ev, at: t)
        let lumenCount = lumen.resolve(prior: zoneCount, stats: stats)
        return Proposals(
            zone: zoneCount,
            latitude: latitudeCount,
            lumen: lumenCount,
            zoneSmoothedEV: zone.lastSmoothedEV,
            latitudeContinuous: latitude.lastContinuous,
            evVelocityStopsPerMinute: latitude.lastVelocityStopsPerMinute,
            lumenScore: lumen.lastScore,
            lumenBoost: lumen.boost)
    }
}

/// One cycle's full decision record, written per output frame into
/// `capture_log.json` — the raw material of the field-test comparison.
public struct BlendStrategyDecision: Codable, Equatable, Sendable {
    /// The strategy that actuated this window.
    public var algorithm: String
    /// The live AE EV the decision saw (distinct from the captured frame's
    /// own EV, which the entry already carries).
    public var sceneEV: Double?
    public var proposedZone: Int
    public var proposedLatitude: Int
    public var proposedLumen: Int
    /// The 3-cycle mean behind Zone's proposal (see `Proposals`).
    public var zoneSmoothedEV: Double?
    public var latitudeContinuous: Double?
    public var evVelocityStopsPerMinute: Double?
    public var lumenScore: Double?
    public var lumenBoost: Int?
    /// The device ceiling in force for this window, computed against the
    /// interval the run was actually pacing at when the window opened.
    public var deviceCeiling: Int?
    public var intervalSeconds: Double?
    /// What the window actually asked the camera for: the active strategy's
    /// proposal, capped by `deviceCeiling`.
    public var actuatedCount: Int
    /// The last closed window's luminance analysis — what Lumen's proposal
    /// was computed from.
    public var stats: FrameLuminanceStats?

    public init(
        algorithm: String, sceneEV: Double?,
        proposedZone: Int, proposedLatitude: Int, proposedLumen: Int,
        zoneSmoothedEV: Double? = nil,
        latitudeContinuous: Double? = nil,
        evVelocityStopsPerMinute: Double? = nil,
        lumenScore: Double? = nil, lumenBoost: Int? = nil,
        deviceCeiling: Int? = nil, intervalSeconds: Double? = nil,
        actuatedCount: Int, stats: FrameLuminanceStats? = nil
    ) {
        self.algorithm = algorithm
        self.sceneEV = sceneEV
        self.proposedZone = proposedZone
        self.proposedLatitude = proposedLatitude
        self.proposedLumen = proposedLumen
        self.zoneSmoothedEV = zoneSmoothedEV
        self.latitudeContinuous = latitudeContinuous
        self.evVelocityStopsPerMinute = evVelocityStopsPerMinute
        self.lumenScore = lumenScore
        self.lumenBoost = lumenBoost
        self.deviceCeiling = deviceCeiling
        self.intervalSeconds = intervalSeconds
        self.actuatedCount = actuatedCount
        self.stats = stats
    }
}

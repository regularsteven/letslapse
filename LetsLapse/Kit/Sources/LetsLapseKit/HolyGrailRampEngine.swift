import Foundation
import CoreMedia

/// The exposure state machine behind a **holy-grail** interval shoot: a
/// timelapse that runs straight through a major lighting transition (day →
/// dusk → night, or the reverse) without the operator touching a dial and
/// without the frame-to-frame flicker that manual bracketing leaves behind.
///
/// It is a pure value type — no AVFoundation session, no I/O — so the policy
/// can be reasoned about and tested without a device. The caller measures the
/// scene, hands the measurement in, and applies the returned pair with
/// `setExposureModeCustom(duration:iso:)`.
///
/// **The policy is shutter-first.** ISO sits at the sensor's floor while the
/// shutter opens toward its ceiling; only once the shutter is at the ceiling
/// does ISO climb. Brightening reverses it for free: ISO comes back down first,
/// and the shutter only leaves the ceiling once ISO is back on its floor. That
/// ordering buys the cleanest frame available at every light level, because a
/// longer shutter costs nothing but motion blur (which a timelapse wants
/// anyway) while ISO costs noise.
///
/// **Flicker control is the whole game.** Two mechanisms:
///
/// 1. The measurement is smoothed with an exponential moving average
///    (`smoothing`, ~0.15) so a passing cloud, a car's headlights or a moment
///    of AE indecision moves the ramp by a fraction of what it moves the meter.
/// 2. The applied exposure moves at most `stopsPerStep` (1/3 stop) per
///    interval, and that limit is applied to the *total* light gathered
///    (shutter × ISO), not to each control separately — so a step can never
///    exceed 1/3 stop even at the hand-over point where shutter stops moving
///    and ISO starts.
///
/// A ramp therefore lags real light by design. Over a sunset that is exactly
/// right: the sky loses roughly a stop every few minutes, and 1/3 stop per
/// frame is far more headroom than that needs.
public struct HolyGrailRampEngine: Equatable {

    // MARK: - Types

    /// What the active camera format can actually do. Read from
    /// `AVCaptureDevice.Format` at the start of a run (and re-read if the
    /// format changes underneath): on an iPhone 16 Pro every format caps the
    /// shutter at 1.0 s, and the ISO envelope differs per lens (wide
    /// 54–12096, ultra-wide 15–3600, tele 34–4352).
    public struct HardwareLimits: Equatable, Sendable {
        public var minShutter: CMTime
        /// The hardware ceiling — 1.0 s on current iPhones. There is no
        /// multi-second native exposure; deep dark is bought with ISO (and,
        /// later, stacking).
        public var maxShutter: CMTime
        public var minISO: Float
        public var maxISO: Float
        /// The lens's f-number. Fixed on every iPhone camera, so it only
        /// enters the maths as a constant that anchors EV to seconds.
        public var aperture: Float

        public init(
            minShutter: CMTime,
            maxShutter: CMTime,
            minISO: Float,
            maxISO: Float,
            aperture: Float = 1.78
        ) {
            self.minShutter = minShutter
            self.maxShutter = maxShutter
            self.minISO = minISO
            self.maxISO = maxISO
            self.aperture = aperture
        }
    }

    /// One exposure the camera should be set to.
    public struct ExposureTarget: Equatable, Sendable {
        public var shutter: CMTime
        public var iso: Float

        public init(shutter: CMTime, iso: Float) {
            self.shutter = shutter
            self.iso = iso
        }

        public init(shutterSeconds: Double, iso: Float) {
            self.init(shutter: HolyGrailRampEngine.time(shutterSeconds), iso: iso)
        }

        public var shutterSeconds: Double { shutter.seconds }

        /// Seconds of exposure normalised to ISO 100 — the single number the
        /// ramp actually moves. Two targets with the same light gain expose
        /// the same scene identically.
        public var lightGain: Double {
            HolyGrailRampEngine.lightGain(shutterSeconds: shutterSeconds, iso: iso)
        }
    }

    // MARK: - Tuning

    /// The per-interval movement limit, in stops of total exposure. 1/3 stop
    /// is below the threshold where a step reads as a flicker in a finished
    /// clip, and comfortably ahead of how fast civil twilight actually moves.
    public static let defaultStopsPerStep = 1.0 / 3.0
    /// EMA weight on the newest measurement.
    public static let defaultSmoothing = 0.15
    /// EMA weight on the *rate of change* of the smoothed measurement.
    ///
    /// **Zero by default, on field evidence.** Lag compensation multiplies the
    /// smoothed measurement's own movement by `(1 − α)/α` ≈ 5.67, which is
    /// exactly the right thing to do when the measurement describes the scene
    /// and exactly the wrong thing when it doesn't: on an iPad Air (2026-08-15,
    /// 54-frame dawn run) a residual of ~0.02 EV per step was amplified past
    /// unity loop gain and the ramp walked 9.7 stops down — −1/3 stop on every
    /// frame — until the shutter hit its floor. The lag it corrects is real
    /// (~1 stop through a fast sunset, see the tests) but it is only safe once
    /// the measurement is known to be independent of the exposure the ramp
    /// chose. Turn it on deliberately, never by default.
    public static let defaultTrendSmoothing = 0.0
    /// How many measurements are kept for inspection/diagnostics. The EMA
    /// itself is recursive and needs no history; the window is what the
    /// capture log and the HUD read.
    public static let measurementWindow = 8

    // MARK: - State

    public private(set) var currentTarget: ExposureTarget
    /// The smoothed scene EV (EV at ISO 100). `nil` until the first
    /// measurement lands.
    public private(set) var smoothedEV: Double?
    /// The smoothed EV change per interval — how fast the light is moving.
    /// Negative through a sunset.
    public private(set) var evTrend: Double = 0
    /// The last `measurementWindow` raw measurements, oldest first.
    public private(set) var recentEV: [Double] = []
    public private(set) var frameCount = 0

    /// Deliberate under/over-exposure, in stops. Positive brightens. A
    /// holy-grail sequence often wants night to *look* like night — a value
    /// of −0.5 or so keeps the ramp from flattening the whole shoot to the
    /// same grey — but the default is a faithful ramp.
    public var bias: Double
    public var stopsPerStep: Double
    public var smoothing: Double
    /// Weight on the trend estimate. Zero turns lag compensation off and
    /// leaves a plain EMA.
    public var trendSmoothing: Double

    /// Whether the first measurement is taken as *the* correct exposure for
    /// the seed, rather than as an absolute EV to be believed.
    ///
    /// This is on by default, and it is the difference between a ramp that
    /// starts where the camera already was and one that jumps the moment
    /// recording begins. An absolute EV → exposure mapping asks the metadata
    /// to agree with the camera's own meter about what "correctly exposed"
    /// means, and it doesn't: measured on an iPad Air at dawn (2026-08-15),
    /// the EXIF-brightness route asked for 1/61s at ISO 18 where AE had
    /// settled well short of that, and the shoot opened on a visible
    /// over-exposure.
    ///
    /// Anchoring removes the question. The offset between the first
    /// measurement and the exposure the camera was already delivering is
    /// recorded once and held for the run, so the ramp tracks how the light
    /// *changes* — which is all a holy-grail ramp needs — and starts on the
    /// exposure the operator was looking at while they framed the shot.
    public var anchorsToSeedExposure: Bool

    /// The offset folded out of every measurement, learned from the first
    /// one. Nil until then (or when anchoring is off).
    public private(set) var calibration: Double?

    /// Seeds the ramp from an exposure the camera is already delivering —
    /// in practice the live AE values read off the device the instant before
    /// the run starts. Because the seed is already close to correct, the
    /// per-step limit costs nothing at the head of a shoot.
    public init(
        seed: ExposureTarget,
        limits: HardwareLimits,
        bias: Double = 0,
        stopsPerStep: Double = HolyGrailRampEngine.defaultStopsPerStep,
        smoothing: Double = HolyGrailRampEngine.defaultSmoothing,
        trendSmoothing: Double = HolyGrailRampEngine.defaultTrendSmoothing,
        anchorsToSeedExposure: Bool = true
    ) {
        self.bias = bias
        self.stopsPerStep = max(0.01, stopsPerStep)
        self.smoothing = min(max(smoothing, 0.01), 1)
        self.trendSmoothing = min(max(trendSmoothing, 0), 1)
        self.anchorsToSeedExposure = anchorsToSeedExposure
        // Clamp the seed into the envelope so the first step starts from a
        // reachable exposure rather than from whatever a stale format said.
        self.currentTarget = Self.split(
            gain: Self.lightGain(
                shutterSeconds: max(seed.shutterSeconds, 1e-6),
                iso: max(seed.iso, 1)),
            limits: limits)
    }

    // MARK: - The step

    /// Folds one scene measurement into the ramp and returns the exposure the
    /// next frame should be captured at.
    ///
    /// `measuredEV` is the scene's exposure value **at ISO 100** — the EV that
    /// would correctly expose it at ISO 100, so bright daylight is ~15 and a
    /// moonless landscape is negative. `CameraController` derives it from the
    /// EXIF APEX brightness of the frame just captured, falling back to the
    /// device's own metering offset.
    @discardableResult
    public mutating func advance(measuredEV: Double, limits: HardwareLimits) -> ExposureTarget {
        guard measuredEV.isFinite else { return currentTarget }

        recentEV.append(measuredEV)
        if recentEV.count > Self.measurementWindow { recentEV.removeFirst() }
        let smoothed: Double
        if let previous = smoothedEV {
            smoothed = previous + smoothing * (measuredEV - previous)
            evTrend += trendSmoothing * ((smoothed - previous) - evTrend)
        } else {
            // First measurement seeds the average outright: ramping in from a
            // fictional zero would spend the first frames chasing a number
            // nothing measured.
            smoothed = measuredEV
            evTrend = 0
            // …and, anchoring, it also defines "correct": whatever this
            // measurement says, it describes the exposure the camera was
            // already delivering. Everything after is read as a change from
            // here.
            if anchorsToSeedExposure {
                calibration = measuredEV
                    - Self.sceneEV100(forGain: currentTarget.lightGain, aperture: limits.aperture)
            }
        }
        smoothedEV = smoothed

        let wantedGain = Self.requiredGain(
            sceneEV100: aimEV(from: smoothed) - bias, aperture: limits.aperture)
        let currentGain = max(currentTarget.lightGain, 1e-9)
        // Rate-limit in stops of total exposure — the one place flicker is
        // won or lost.
        let wantedStops = log2(max(wantedGain, 1e-9)) - log2(currentGain)
        let allowedStops = min(max(wantedStops, -stopsPerStep), stopsPerStep)
        let steppedGain = currentGain * exp2(allowedStops)

        currentTarget = Self.split(gain: steppedGain, limits: limits)
        frameCount += 1
        return currentTarget
    }

    /// The EV the ramp actually aims at: the smoothed measurement plus the
    /// lag the smoothing itself introduces.
    ///
    /// An EMA chasing light that moves at a steady `r` EV per interval settles
    /// exactly `r · (1 − α) / α` behind it — at α = 0.15 and a stop a minute
    /// on a 10 s interval that is a whole stop of drift, and it shows up in a
    /// finished clip as the picture darkening through the fastest part of the
    /// sunset and brightening again afterwards. Smoothing the *rate* as well
    /// and projecting forward by that same factor cancels the lag while
    /// leaving the noise rejection intact: a one-frame outlier moves the trend
    /// by a fraction of a fraction, and the 1/3-stop limit still bounds every
    /// step. The projection is capped so a burst of nonsense can't aim the
    /// ramp somewhere absurd.
    public func aimEV(from smoothed: Double) -> Double {
        var aim = smoothed - (calibration ?? 0)
        guard trendSmoothing > 0 else { return aim }
        let lagIntervals = (1 - smoothing) / smoothing
        let correction = min(max(evTrend * lagIntervals, -Self.maximumLagCorrection),
                             Self.maximumLagCorrection)
        aim += correction
        return aim
    }

    /// Ceiling on the lag projection, in stops.
    public static let maximumLagCorrection = 2.0

    /// Re-clamps the held target into a (possibly new) envelope without
    /// consuming a measurement — for a format switch mid-run.
    public mutating func reclamp(to limits: HardwareLimits) {
        currentTarget = Self.split(gain: currentTarget.lightGain, limits: limits)
    }

    /// True once the shutter is pinned at its ceiling and ISO is carrying the
    /// ramp — the point where a holy-grail shoot starts paying in noise. The
    /// HUD says so; the operator's cue to stop the shoot or accept grain.
    public func isISORamping(limits: HardwareLimits) -> Bool {
        currentTarget.iso > limits.minISO * 1.05
            && currentTarget.shutterSeconds >= limits.maxShutter.seconds * 0.99
    }

    /// True when the scene has run past what the hardware can hold — the ramp
    /// is asking for more light than max shutter × max ISO can give (or less
    /// than min × min). Frames keep coming; they just stop tracking.
    public func isClipped(limits: HardwareLimits) -> Bool {
        guard let smoothedEV else { return false }
        let wanted = Self.requiredGain(
            sceneEV100: aimEV(from: smoothedEV) - bias, aperture: limits.aperture)
        let ceiling = Self.lightGain(shutterSeconds: limits.maxShutter.seconds, iso: limits.maxISO)
        let floor = Self.lightGain(shutterSeconds: limits.minShutter.seconds, iso: limits.minISO)
        return wanted > ceiling * 1.01 || wanted < floor * 0.99
    }

    // MARK: - Pure maths (the testable core)

    /// Exposure normalised to ISO 100: seconds × (ISO / 100).
    public static func lightGain(shutterSeconds: Double, iso: Float) -> Double {
        shutterSeconds * Double(iso) / 100
    }

    /// The light gain that correctly exposes a scene of `sceneEV100`.
    ///
    /// APEX: at ISO 100, EV = log2(N² / t). Solving for the ISO-100 shutter
    /// gives t = N² / 2^EV, which *is* the light gain by definition.
    public static func requiredGain(sceneEV100: Double, aperture: Float) -> Double {
        let n = Double(max(aperture, 0.1))
        return (n * n) / exp2(sceneEV100)
    }

    /// The inverse: the scene EV that a given light gain correctly exposes.
    public static func sceneEV100(forGain gain: Double, aperture: Float) -> Double {
        let n = Double(max(aperture, 0.1))
        return log2((n * n) / max(gain, 1e-12))
    }

    /// Splits a light gain into a shutter/ISO pair — the shutter-first policy
    /// itself. Spend everything on the shutter until it reaches the ceiling,
    /// then hold it there and spend the rest on ISO. Both are clamped to the
    /// envelope, so an unreachable gain lands on the nearest reachable pair
    /// rather than throwing.
    public static func split(gain: Double, limits: HardwareLimits) -> ExposureTarget {
        let minShutter = max(limits.minShutter.seconds, 1e-6)
        let maxShutter = max(limits.maxShutter.seconds, minShutter)
        let minISO = max(limits.minISO, 1)
        let maxISO = max(limits.maxISO, minISO)

        // What the shutter alone would need at base ISO.
        let shutterAtBaseISO = max(gain, 0) * 100 / Double(minISO)
        if shutterAtBaseISO <= maxShutter {
            // Room in the shutter: ISO stays on the floor.
            let shutter = max(shutterAtBaseISO, minShutter)
            // Below the shortest exposure the format allows, the only way to
            // lose more light is ISO — and it is already at its floor, so the
            // frame is simply as dark as this camera goes.
            let iso = shutter > minShutter
                ? minISO
                : Float(min(max(gain * 100 / shutter, Double(minISO)), Double(maxISO)))
            return ExposureTarget(shutterSeconds: shutter, iso: iso)
        }
        // Shutter is at the ceiling; ISO carries the rest.
        let iso = Float(min(max(gain * 100 / maxShutter, Double(minISO)), Double(maxISO)))
        return ExposureTarget(shutterSeconds: maxShutter, iso: iso)
    }

    /// A shutter time at a timescale fine enough for sub-millisecond
    /// exposures — the same 1/1,000,000 the capture code uses.
    public static func time(_ seconds: Double) -> CMTime {
        CMTimeMakeWithSeconds(max(seconds, 0), preferredTimescale: 1_000_000)
    }
}

// MARK: - Scene measurement

/// How a captured frame is turned into the scene EV the ramp consumes.
/// Separated from the engine so both the derivation and the policy can be
/// tested on their own.
public enum HolyGrailMetering {

    /// Scene EV at ISO 100 from the EXIF APEX brightness value.
    ///
    /// APEX ties the four terms as `Av + Tv = Bv + Sv`. `Av + Tv` is EV, and
    /// at ISO 100 `Sv = log2(100 / 3.125) = 5`, so `EV100 = Bv + 5`. This is
    /// the preferred measurement because it reports what the *scene* is doing
    /// independently of the exposure we forced on the frame.
    public static func sceneEV100(apexBrightness: Double) -> Double {
        apexBrightness + 5
    }

    /// Scene EV at ISO 100 inferred from the exposure a frame was taken at
    /// plus the device's metering offset.
    ///
    /// The exposure alone says nothing about the scene when exposure is being
    /// driven manually — a frame we deliberately underexposed reports as a
    /// dark scene, which would latch the ramp. `exposureTargetOffset` is what
    /// breaks that loop: it is AE's own opinion of how far the current
    /// exposure sits from where it wants to be, in stops, positive when the
    /// frame is brighter than the target.
    public static func sceneEV100(
        shutterSeconds: Double,
        iso: Float,
        aperture: Float,
        exposureTargetOffset: Double
    ) -> Double {
        let gain = HolyGrailRampEngine.lightGain(shutterSeconds: shutterSeconds, iso: iso)
        return HolyGrailRampEngine.sceneEV100(forGain: gain, aperture: aperture)
            + exposureTargetOffset
    }
}

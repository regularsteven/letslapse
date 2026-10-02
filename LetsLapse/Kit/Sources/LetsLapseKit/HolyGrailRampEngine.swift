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

    // MARK: Anti-oscillation (the 2026-08-25 limit-cycle fix)

    /// Wanted moves smaller than this are held rather than commanded. At the
    /// short-shutter end the ISP only latches coarse discrete exposure states
    /// (0.18–0.37 stops apart on the iPad Air M1), the correct exposure sits
    /// between two of them, and a servo with no deadband flip-flops every
    /// window — 13 oscillation events in one dawn. The deadband absorbs the
    /// residual error of sitting on a latched state; a *moving* scene
    /// accumulates past it and still ramps.
    public var deadbandStops: Double = 0
    /// A move must want the same direction this many consecutive steps before
    /// the first command is issued — Steven's "confidence before committing".
    /// Zero commits immediately (legacy).
    public var dwellSteps: Int = 0
    /// After a committed move, the opposite direction is refused for this
    /// many steps (a passing car's headlights can't ring the exposure), so
    /// the fastest possible oscillation is slower than the eye integrates.
    /// Bypassed, like the dwell, when the error is `dwellBypassStops` big.
    public var reversalRefractorySteps: Int = 0
    /// Errors at least this large step immediately — a light switch still
    /// ramps promptly no matter how much confidence the small moves need.
    public var dwellBypassStops: Double = 1.0

    private var pendingDirection: Int = 0
    private var pendingCount: Int = 0
    private var committedDirection: Int = 0
    /// Saturating (a 3 s cadence would need 95 years to reach the cap).
    private var stepsSinceCommit: Int = 1_000_000_000

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

    // MARK: Anchor drift (the 2026-08-25 dark-dawn fix)

    /// How fast the anchor may drift toward the device AE's own opinion, in
    /// stops per step. Zero freezes the anchor (the pre-2026-08-25 behavior).
    ///
    /// The frozen anchor is what turned a 2 h 17 m sunrise 6.1 stops dark:
    /// device AE renders pre-dawn ~3.5 stops darker (against mid-grey) than
    /// it renders daylight, the anchor forbade that rendering change, and the
    /// luma meter's crush multiplied the error ×1.75. Dynamic mode's contract
    /// is that a shoot *ends* where AE would meter the ending scene — so the
    /// anchor drifts there, slowly enough to be invisible frame-to-frame
    /// and referenced to an absolute opinion, which also cancels the meter's
    /// non-invariance. The shipping 1/20 stop per window is a stop a MINUTE
    /// at 3 s (a stop and a half at 2 s) — this comment once said an hour.
    ///
    /// Stability against the 2026-08-15 runaway class was argued by
    /// construction: a rate-capped outer loop slower than the servo it trims,
    /// its per-step authority `anchorDriftPerStep` no matter how wrong the
    /// anchor is, acting only on a smoothed, deadbanded disagreement. Its
    /// TOTAL authority is unbounded, though, and that argument assumed AE's
    /// opinion describes the scene: on 2026-09-28 (iPhone 18 Pro telephoto,
    /// ISO carrying the ramp) it moved stop for stop with the ramp's own
    /// ISO, the gap never closed, and the drift added five stops in a
    /// hundred windows. The highlight guard is what bounds it now: while the
    /// frames show more at white than the shoot opened with, or the guard is
    /// holding the ramp back, the drift may not add light.
    public var anchorDriftPerStep: Double = 0
    /// Disagreements smaller than this never move the anchor — AE breathing
    /// and metering noise stay out of the exposure record.
    public var anchorDriftDeadband: Double = 0.25
    /// EMA weight on the newest AE-vs-aim disagreement.
    public var anchorDriftSmoothing: Double = 0.1
    /// The smoothed disagreement between where the ramp aims and where the
    /// device AE thinks the scene is (aim − AE, stops). Diagnostic:
    /// `measuredEV − appliedEV` told the 2026-08-25 story; this is the same
    /// number available live.
    public private(set) var aeGapEV: Double?

    // MARK: Highlight guard (the 2026-09-28 18 Pro runaway)

    /// What a window's frames said about their brightest areas, read off the
    /// pixels themselves.
    ///
    /// It exists because every other input the ramp has is somebody's
    /// opinion of the scene, and on 2026-09-28 both opinions were wrong the
    /// same way: on an iPhone 18 Pro telephoto at dusk, once the shutter sat
    /// at 1 s and ISO carried the ramp, the frames' APEX brightness fell ~⅔
    /// of a stop for every stop of ISO the ramp added, and the AE's
    /// "scene EV" fell a full stop. Brighter frames read as a darker scene,
    /// the ramp answered with more ISO, and in 2.6 minutes it went from
    /// ISO 19 to the lens's 7,680 while the light fell perhaps a stop — the
    /// last four minutes of the shoot blown out. Pixels at the sensor's
    /// white are not an opinion: no meter can talk the ramp past them.
    public struct HighlightReading: Equatable, Sendable {
        /// Share of the frame whose brightest colour channel sits at the
        /// sensor's white (`clippedLevel`) — detail that is already gone.
        /// The brightest channel, not luma: a golden sky clips red while
        /// its luma still reads well short of white.
        public var clippedFraction: Double
        /// Share within `marginStops` of white (`hotLevel`) — what one more
        /// full step would clip. Logged, not acted on: the camera's own
        /// exposure leaves 12–19 % of a dusk frame here (2026-10-02).
        public var hotFraction: Double
        /// The window the frames were shot in.
        public var window: Int
        /// The light gain those frames were shot at, when the caller knows
        /// it — the ramp chose it, so the camera layer does. Nil is read as
        /// the gain the ramp holds now. It is what makes a late reading
        /// safe: the DNG path measures a window or two behind, and a reading
        /// taken before the ramp last moved must not be answered as if it
        /// described the frames being shot now.
        public var gain: Double?
        /// The brightest sample, on the reading's own scale — logged, so a
        /// device run can confirm where white really sits. On the 18 Pro's
        /// baseline-free DNG decode clipped pixels read 1.05–1.21, not 1.0
        /// (white balance lifts a clipped channel; 2026-09-28/10-02), so
        /// `clippedLevel` counts a little early — which is one more reason
        /// the guard compares a reading with the shoot's own opening rather
        /// than with an absolute share.
        public var peak: Double?

        public init(
            clippedFraction: Double, hotFraction: Double, window: Int,
            gain: Double? = nil, peak: Double? = nil
        ) {
            self.clippedFraction = clippedFraction
            self.hotFraction = hotFraction
            self.window = window
            self.gain = gain
            self.peak = peak
        }

        /// White, as a fraction of saturation.
        public static let clippedLevel = 0.98
        /// How far under white "hot" starts — one full ramp step.
        public static let marginStops = 1.0 / 3.0
        /// A third of a stop under white: 2^(−⅓) of saturation.
        public static let hotLevel = exp2(-marginStops)
    }

    /// What the guard did on the last step, for the log and the readout.
    public enum HighlightGuardState: String, Equatable, Sendable {
        /// Not enabled for this run.
        case off
        /// Nothing bright enough to matter, or no reading yet.
        case clear
        /// The ramp wanted more light and the highlights refused it.
        case holding
        /// The frames were clipping: stepping down.
        case darkening
    }

    /// Off by default so the pure policy tests stay what they were; the
    /// camera layer switches it on for every ramped run (Dynamic and Ladder).
    public var highlightGuardEnabled = false

    /// **A runaway net, not a metering policy (Steven, 2026-10-02).** The
    /// guard judges the frames against the shoot's OPENING — the share of the
    /// frame at white when it began, which is the clipping the operator
    /// framed and accepted — and only acts when the ramp has put clearly
    /// more of the frame at white than that.
    ///
    /// Why relative: the camera's own exposure leaves a lot of a dusk frame
    /// at white. Measured on the 18 Pro: 17 % at the 2026-10-02 opening
    /// (a sunset sky), 8 % at white and 15 % within ⅓ stop of it at the
    /// restart 19 minutes later (city lights, a glowing horizon), 9.4 % at
    /// the 2026-09-28 opening. The first guard held at an absolute 10 %
    /// within ⅓ stop of white, so it fought that normal rendering from the
    /// second window of a healthy shoot — and, with the freeze described at
    /// `foldHighlights`, ended that dusk ~3.8 stops under the camera's own
    /// exposure. Protecting a bright sky below what the camera would choose
    /// is a rendering choice; it belongs to the "Sky first" option
    /// (docs/TODO.md), not to the default.
    ///
    /// More at white than the opening by this share of the frame: no more
    /// light. On the 2026-09-28 runaway (opening 9.4 %) that is ~19 % —
    /// long before its final frames' 59 %.
    public static let highlightHoldExcess = 0.10
    /// …by this much: step back down, a third of a stop a window.
    public static let highlightDarkenExcess = 0.20
    /// …within this much: room — the limit sits at least a lift above the
    /// exposure those frames were shot at.
    public static let highlightRoomExcess = 0.05
    /// How far one lift raises the ceiling over the exposure that showed
    /// room: half a ramp step, and never less than the shipping gate's
    /// 0.12-stop deadband, which would not step into a smaller one.
    public static let highlightLiftStops = 1.0 / 6.0
    /// The opening is the least of this many readings, so one passing
    /// headlight cannot raise it.
    public static let highlightOpeningReadings = 3

    /// The most light the frames may be given, from what their highlights
    /// have shown — seconds at ISO 100, like `lightGain`. Nil = no limit:
    /// on a shoot whose frames never put more at white than they opened
    /// with, there never is one. Set at an exposure that went past the
    /// hold excess, one step under one that went past the darken excess,
    /// and raised to at least a lift above any exposure that showed room.
    /// It only ever limits brightening and forces darkening; everything
    /// else the ramp does is untouched.
    public private(set) var highlightCeilingGain: Double?
    public private(set) var highlightState: HighlightGuardState = .off
    /// The newest reading the guard has seen.
    public private(set) var lastHighlightReading: HighlightReading?
    /// The share of the frame at white the shoot opened with (the least of
    /// its first `highlightOpeningReadings` readings). Nil before the first.
    public private(set) var highlightOpening: Double?
    private var openingReadingsTaken = 0
    private var lastOpeningWindow: Int?

    /// How much more of the frame the newest reading has at white than the
    /// shoot opened with. Zero before any reading.
    public var highlightExcess: Double {
        guard let reading = lastHighlightReading else { return 0 }
        return reading.clippedFraction - (highlightOpening ?? reading.clippedFraction)
    }

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
    /// `aeSceneEV` is the device AE's own absolute opinion of the scene (EV at
    /// ISO 100, from `HolyGrailMetering.sceneEV100(shutterSeconds:iso:aperture:
    /// exposureTargetOffset:)`). Optional: without it the anchor holds exactly
    /// as before; with it (and `anchorDriftPerStep > 0`) the anchor drifts
    /// toward AE's rendering, which is what makes a two-hour dawn end at the
    /// exposure a fresh shoot would open on. On a device path where the ±EV
    /// control drives `setExposureTargetBias`, AE's opinion is bias-inclusive
    /// — the drift converges on the rendering the operator dialed.
    /// `highlights` is the newest reading of the frames' brightest areas
    /// (`highlightGuardEnabled` runs only): it sets the ceiling no step may
    /// cross, whatever the two meters above believe.
    @discardableResult
    public mutating func advance(
        measuredEV: Double, limits: HardwareLimits, aeSceneEV: Double? = nil,
        highlights: HighlightReading? = nil
    ) -> ExposureTarget {
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
        let currentGain = max(currentTarget.lightGain, 1e-9)
        foldHighlights(highlights, currentGain: currentGain)
        // While the frames show more at white than the shoot opened with, or
        // the guard held the ramp back last step, the anchor may not drift
        // toward more light: that drift is what walked the 2026-09-28 shoot
        // five stops over, and behind a held ceiling it would only wind up.
        // Only then — paused whenever a ceiling merely existed, it held the
        // 2026-10-02 dusk 0.6–1 stop under the camera's own exposure all night.
        let holdingHighlights = highlightGuardEnabled
            && (highlightExcess >= Self.highlightHoldExcess
                || highlightState == .holding || highlightState == .darkening)
        driftAnchor(toward: aeSceneEV, smoothed: smoothed, mayBrighten: !holdingHighlights)

        let wantedGain = Self.requiredGain(
            sceneEV100: aimEV(from: smoothed) - bias, aperture: limits.aperture)
        // Rate-limit in stops of total exposure — the one place flicker is
        // won or lost.
        var wantedStops = log2(max(wantedGain, 1e-9)) - log2(currentGain)
        // Never more light than the highlights allow.
        let headroom = highlightCeilingGain.map { log2(max($0, 1e-12)) - log2(currentGain) }
        var held = false
        if let headroom, wantedStops > headroom {
            wantedStops = headroom
            held = true
        }
        frameCount += 1
        var allowedStops = gatedStep(wantedStops: wantedStops)
        let darkening = headroom.map { $0 < -0.01 } ?? false
        if darkening, let headroom {
            // Above the ceiling, the frames are clipping: down now, at most a
            // step a window, whatever the dwell and the refractory say — they
            // exist to stop a quantizer ringing, and this is not that. The
            // step counts as a committed move, so the refractory then keeps
            // the ramp from climbing straight back into the clip.
            allowedStops = min(allowedStops ?? 0, max(headroom, -stopsPerStep))
            noteStep(in: -1)
        }
        if highlightGuardEnabled {
            highlightState = darkening ? .darkening : (held ? .holding : .clear)
        }
        guard let allowedStops else { return currentTarget }
        currentTarget = Self.split(gain: currentGain * exp2(allowedStops), limits: limits)
        return currentTarget
    }

    /// Folds one highlight reading into the opening and the ceiling
    /// (`highlightOpening`, `highlightCeilingGain`).
    private mutating func foldHighlights(_ reading: HighlightReading?, currentGain: Double) {
        guard highlightGuardEnabled, let reading,
              reading.clippedFraction.isFinite, reading.hotFraction.isFinite else { return }
        lastHighlightReading = reading
        // The opening: the least of the first few distinct readings.
        if openingReadingsTaken < Self.highlightOpeningReadings, reading.window != lastOpeningWindow {
            highlightOpening = min(highlightOpening ?? reading.clippedFraction, reading.clippedFraction)
            openingReadingsTaken += 1
            lastOpeningWindow = reading.window
        }
        let excess = highlightExcess
        // The light the frames were shot at. Unknown is read as now: a
        // ceiling set from the current gain can only hold or lower the
        // exposure, never raise it.
        let shotAt = max(reading.gain ?? currentGain, 1e-12)
        if excess >= Self.highlightDarkenExcess {
            // Far more at white than the shoot opened with: that exposure is
            // off limits, and so is the step under it until a reading taken
            // there says otherwise.
            lowerHighlightCeiling(to: shotAt * exp2(-HighlightReading.marginStops))
        } else if excess >= Self.highlightHoldExcess {
            // Clearly more at white than the opening: no more light than this.
            lowerHighlightCeiling(to: shotAt)
        } else if excess <= Self.highlightRoomExcess, let ceiling = highlightCeilingGain {
            // Room at the exposure THESE frames were shot at, so the limit
            // sits at least a lift above it — wherever the ramp has settled
            // under the limit. It used to rise only from a reading shot within
            // 0.05 stop of the limit; on 2026-10-02 the gate's 0.12-stop
            // deadband parked the ramp 0.07 stop under it, neither could
            // move, and a dusk froze at 1/49 s for twelve minutes while the
            // light fell three stops.
            highlightCeilingGain = max(ceiling, shotAt * exp2(Self.highlightLiftStops))
        }
    }

    private mutating func lowerHighlightCeiling(to gain: Double) {
        highlightCeilingGain = min(highlightCeilingGain ?? .infinity, gain)
    }

    /// The slow outer loop: close the standing disagreement between where the
    /// ramp aims and where the device AE believes the scene is, a twentieth
    /// of a stop at a time. See `anchorDriftPerStep` for why and for the
    /// stability argument.
    private mutating func driftAnchor(
        toward aeSceneEV: Double?, smoothed: Double, mayBrighten: Bool = true
    ) {
        guard anchorDriftPerStep > 0, anchorsToSeedExposure,
              calibration != nil, let aeSceneEV, aeSceneEV.isFinite else { return }
        // aim = smoothed − calibration. A positive gap means the ramp is
        // exposing for a brighter scene than AE believes — rendering the
        // frame darker than AE would — so closing it means RAISING the
        // calibration (which lowers the aim and adds gain).
        let gap = (smoothed - (calibration ?? 0)) - aeSceneEV
        let smoothedGap: Double
        if let previous = aeGapEV {
            smoothedGap = previous + anchorDriftSmoothing * (gap - previous)
        } else {
            smoothedGap = gap
        }
        aeGapEV = smoothedGap
        guard abs(smoothedGap) > anchorDriftDeadband else { return }
        // A positive gap raises the calibration, which adds light.
        guard mayBrighten || smoothedGap < 0 else { return }
        calibration = (calibration ?? 0)
            + min(max(smoothedGap, -anchorDriftPerStep), anchorDriftPerStep)
    }

    /// The anti-oscillation gate: the rate-limited stops to apply, or nil to
    /// hold this step. With every gate parameter at zero this is exactly the
    /// legacy behavior.
    private mutating func gatedStep(wantedStops: Double) -> Double? {
        let allowed = min(max(wantedStops, -stopsPerStep), stopsPerStep)
        let gated = deadbandStops > 0 || dwellSteps > 0 || reversalRefractorySteps > 0
        guard gated else { return allowed }
        stepsSinceCommit = min(stepsSinceCommit + 1, 1_000_000_000)
        let magnitude = abs(wantedStops)
        let direction = wantedStops > 0 ? 1 : (wantedStops < 0 ? -1 : 0)
        // A big error steps immediately — confidence is for the small moves.
        if magnitude >= dwellBypassStops {
            noteStep(in: direction)
            return allowed
        }
        // Inside the deadband the servo is *settled*: sitting on a latched
        // ISP state whose residual error can never be commanded away. Any
        // future move starts from scratch.
        if magnitude < deadbandStops || direction == 0 {
            pendingDirection = 0
            pendingCount = 0
            committedDirection = 0
            return nil
        }
        // An established ramp keeps stepping at full rate — dwell gates
        // entry into movement, never a ramp already agreed on.
        if direction == committedDirection {
            noteStep(in: direction)
            return allowed
        }
        // Reversing shortly after a step is the limit cycle's signature —
        // the step itself perturbed the quantizer. Refuse it for a while.
        if committedDirection != 0, stepsSinceCommit <= reversalRefractorySteps {
            return nil
        }
        if direction == pendingDirection {
            pendingCount += 1
        } else {
            pendingDirection = direction
            pendingCount = 1
        }
        guard pendingCount >= max(dwellSteps, 1) else { return nil }
        noteStep(in: direction)
        return allowed
    }

    private mutating func noteStep(in direction: Int) {
        committedDirection = direction
        pendingDirection = 0
        pendingCount = 0
        stepsSinceCommit = 0
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
    ///
    /// Not while the highlights hold the ramp under the hardware's ceiling:
    /// then it is not asking the sensor for more than it has, it is declining
    /// to take it, and a red "past the sensor's limit" over frames that are
    /// correctly held is the false alarm that got a shoot stopped on
    /// 2026-09-04.
    public func isClipped(limits: HardwareLimits) -> Bool {
        guard let smoothedEV else { return false }
        let wanted = Self.requiredGain(
            sceneEV100: aimEV(from: smoothedEV) - bias, aperture: limits.aperture)
        let ceiling = Self.lightGain(shutterSeconds: limits.maxShutter.seconds, iso: limits.maxISO)
        let floor = Self.lightGain(shutterSeconds: limits.minShutter.seconds, iso: limits.minISO)
        let holding = highlightState == .holding || highlightState == .darkening
        let heldUnderHardware = holding && (highlightCeilingGain.map { $0 < ceiling * 0.99 } ?? false)
        return (wanted > ceiling * 1.01 && !heldUnderHardware) || wanted < floor * 0.99
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

    /// Mid-grey in linear light — the reference a delivered frame's mean luma
    /// is read against. Its absolute value never matters (the ramp's anchor
    /// folds any constant out on the first frame); it only has to stay fixed.
    public static let referenceLuma = 0.18

    /// Scene EV at ISO 100 from a delivered frame's mean linear luma and the
    /// exposure that frame was **actually taken at** — the video-tap path's
    /// meter, where the frames carry no APEX brightness of their own.
    ///
    /// The exposure says what EV the frame assumed; how far its luma sits
    /// from mid-grey says how wrong that assumption was. Both terms are read
    /// off the same frame, so a stop of exposure moves them a stop in
    /// opposite directions and the sum is a property of the scene alone.
    ///
    /// **The pair must be the delivered one, never the commanded one.** Fed
    /// the ramp's own target instead, the derivation is scene-referred only
    /// while the camera obeys: on 2026-09-04 an iPhone 12 Pro refused every
    /// custom-exposure write, shot a whole dusk on AE, and the luma never
    /// answered a step — so each step the engine took was read back as the
    /// scene moving the same way, and the target walked from 1/305 s to the
    /// format's 14 µs floor while the frames stayed correctly exposed
    /// (`docs/fieldtests/2026-09-04-ladder-readout-runaway.md`). With the
    /// delivered pair the same run reads a 2.2-stop darkening, which is what
    /// the frames show. The ISP's exposure quantization stops leaking into
    /// the measurement for the same reason: the luma was made at the
    /// latched exposure, and so is the EV term.
    public static func sceneEV100(
        meanLinearLuma luma: Double,
        deliveredShutterSeconds shutterSeconds: Double,
        iso: Float,
        aperture: Float,
        referenceLuma: Double = HolyGrailMetering.referenceLuma
    ) -> Double {
        let gain = HolyGrailRampEngine.lightGain(
            shutterSeconds: max(shutterSeconds, 1e-6), iso: max(iso, 1))
        return HolyGrailRampEngine.sceneEV100(forGain: gain, aperture: aperture)
            + log2(max(luma, 1e-6) / max(referenceLuma, 1e-6))
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

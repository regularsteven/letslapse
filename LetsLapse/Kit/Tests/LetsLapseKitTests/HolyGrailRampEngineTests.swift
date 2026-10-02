import XCTest
import CoreMedia
@testable import LetsLapseKit

/// The holy-grail exposure policy, pinned. Everything here is pure value-type
/// maths — no camera, no session — which is the whole point of the engine
/// being a struct.
final class HolyGrailRampEngineTests: XCTestCase {

    /// An iPhone 16 Pro wide, as probed 2026-08-13: 1.0 s shutter ceiling on
    /// every format, ISO 54–12096.
    private let wide = HolyGrailRampEngine.HardwareLimits(
        minShutter: CMTime(value: 1, timescale: 8000),  // 1/8000 s
        maxShutter: CMTime(value: 1, timescale: 1),     // 1.0 s
        minISO: 54,
        maxISO: 12096,
        aperture: 1.78)

    /// Absolute-EV engine (anchoring off) — the mode the policy tests below
    /// reason about, where a measured EV maps straight to an exposure.
    private func engine(shutter: Double, iso: Float, bias: Double = 0) -> HolyGrailRampEngine {
        HolyGrailRampEngine(
            seed: .init(shutterSeconds: shutter, iso: iso), limits: wide, bias: bias,
            anchorsToSeedExposure: false)
    }

    /// Lag compensation, explicitly on. It is off by default since the
    /// 2026-08-15 field runaway — see `defaultTrendSmoothing`.
    private func compensatedEngine(shutter: Double, iso: Float) -> HolyGrailRampEngine {
        HolyGrailRampEngine(
            seed: .init(shutterSeconds: shutter, iso: iso), limits: wide,
            trendSmoothing: 0.1, anchorsToSeedExposure: false)
    }

    /// The shipping configuration: the first measurement defines "correct"
    /// for the exposure the camera was already delivering.
    private func anchoredEngine(shutter: Double, iso: Float, bias: Double = 0) -> HolyGrailRampEngine {
        HolyGrailRampEngine(
            seed: .init(shutterSeconds: shutter, iso: iso), limits: wide, bias: bias)
    }

    // MARK: - The split (shutter-first policy)

    func testSplitSpendsShutterFirstAndHoldsISOAtBase() {
        // A gain reachable well inside the shutter's travel.
        let target = HolyGrailRampEngine.split(
            gain: HolyGrailRampEngine.lightGain(shutterSeconds: 0.25, iso: 54), limits: wide)
        XCTAssertEqual(target.iso, 54, accuracy: 0.01)
        XCTAssertEqual(target.shutterSeconds, 0.25, accuracy: 1e-6)
    }

    func testSplitRaisesISOOnlyOnceShutterIsAtItsCeiling() {
        // Four stops more light than base ISO at a 1 s shutter can gather.
        let ceiling = HolyGrailRampEngine.lightGain(shutterSeconds: 1.0, iso: 54)
        let target = HolyGrailRampEngine.split(gain: ceiling * 16, limits: wide)
        XCTAssertEqual(target.shutterSeconds, 1.0, accuracy: 1e-6)
        XCTAssertEqual(target.iso, 54 * 16, accuracy: 1)
    }

    func testSplitClampsAtTheHardwareCeiling() {
        let beyond = HolyGrailRampEngine.lightGain(shutterSeconds: 1.0, iso: 12096) * 8
        let target = HolyGrailRampEngine.split(gain: beyond, limits: wide)
        XCTAssertEqual(target.shutterSeconds, 1.0, accuracy: 1e-6)
        XCTAssertEqual(target.iso, 12096, accuracy: 0.01)
    }

    func testSplitClampsAtTheHardwareFloor() {
        let below = HolyGrailRampEngine.lightGain(shutterSeconds: 1.0 / 8000, iso: 54) / 100
        let target = HolyGrailRampEngine.split(gain: below, limits: wide)
        XCTAssertEqual(target.shutterSeconds, 1.0 / 8000, accuracy: 1e-9)
        XCTAssertEqual(target.iso, 54, accuracy: 0.01)
    }

    // MARK: - EV ↔ exposure

    func testRequiredGainRoundTripsThroughSceneEV() {
        for ev in stride(from: -6.0, through: 16.0, by: 0.5) {
            let gain = HolyGrailRampEngine.requiredGain(sceneEV100: ev, aperture: 1.78)
            XCTAssertEqual(
                HolyGrailRampEngine.sceneEV100(forGain: gain, aperture: 1.78), ev, accuracy: 1e-9)
        }
    }

    func testOneStopDarkerSceneDoublesTheRequiredGain() {
        let bright = HolyGrailRampEngine.requiredGain(sceneEV100: 10, aperture: 1.78)
        let darker = HolyGrailRampEngine.requiredGain(sceneEV100: 9, aperture: 1.78)
        XCTAssertEqual(darker / bright, 2, accuracy: 1e-9)
    }

    // MARK: - Rate limiting (the flicker guarantee)

    /// The tolerance is the shutter's own storage: `CMTime` at 1/1,000,000
    /// quantises a 1/500 s exposure to the nearest microsecond, which is
    /// ~0.0005 stop here. It doesn't accumulate — the quantised value is what
    /// the next step measures from.
    func testASingleStepNeverMovesMoreThanAThirdOfAStop() {
        var engine = self.engine(shutter: 1.0 / 500, iso: 54)
        // Slam the meter from bright daylight to full dark: the step must
        // still be 1/3 stop.
        let before = engine.currentTarget.lightGain
        let after = engine.advance(measuredEV: -4, limits: wide).lightGain
        XCTAssertEqual(log2(after / before), 1.0 / 3.0, accuracy: 1e-3)
    }

    func testABrighteningSceneIsRateLimitedToo() {
        var engine = self.engine(shutter: 1.0, iso: 3000)
        let before = engine.currentTarget.lightGain
        let after = engine.advance(measuredEV: 15, limits: wide).lightGain
        XCTAssertEqual(log2(after / before), -1.0 / 3.0, accuracy: 1e-3)
    }

    func testNeitherControlEverJumpsMoreThanAThirdOfAStopAcrossTheHandover() {
        // Start just below the hand-over and ramp into darkness, so the run
        // crosses the point where shutter stops moving and ISO takes over.
        var engine = self.engine(shutter: 0.5, iso: 54)
        var previous = engine.currentTarget
        for _ in 0..<200 {
            let target = engine.advance(measuredEV: -2, limits: wide)
            let shutterStops = abs(log2(target.shutterSeconds / previous.shutterSeconds))
            let isoStops = abs(log2(Double(target.iso) / Double(previous.iso)))
            XCTAssertLessThanOrEqual(shutterStops, 1.0 / 3.0 + 1e-6)
            XCTAssertLessThanOrEqual(isoStops, 1.0 / 3.0 + 1e-6)
            previous = target
        }
    }

    // MARK: - Convergence

    func testTheRampConvergesOnTheMeteredExposure() {
        var engine = self.engine(shutter: 1.0 / 500, iso: 54)
        for _ in 0..<400 { engine.advance(measuredEV: 5, limits: wide) }
        let wanted = HolyGrailRampEngine.requiredGain(sceneEV100: 5, aperture: 1.78)
        XCTAssertEqual(engine.currentTarget.lightGain, wanted, accuracy: wanted * 0.02)
    }

    func testBiasUnderexposesByTheStopsAskedFor() {
        var engine = self.engine(shutter: 1.0 / 500, iso: 54, bias: -1)
        for _ in 0..<400 { engine.advance(measuredEV: 5, limits: wide) }
        let faithful = HolyGrailRampEngine.requiredGain(sceneEV100: 5, aperture: 1.78)
        XCTAssertEqual(engine.currentTarget.lightGain, faithful / 2, accuracy: faithful * 0.02)
    }

    /// A day→night ramp: EV falls a stop a minute at a 10 s interval (6 frames
    /// per stop, well inside the 1/3-stop budget). With lag compensation on,
    /// the ramp tracks it rather than falling behind.
    func testLagCompensationTracksARealisticSunsetWhenTurnedOn() {
        var engine = compensatedEngine(shutter: 1.0 / 250, iso: 54)
        var ev = 12.0
        for _ in 0..<60 {
            engine.advance(measuredEV: ev, limits: wide)
            ev -= 1.0 / 6.0
        }
        let wanted = HolyGrailRampEngine.requiredGain(sceneEV100: ev, aperture: 1.78)
        // Within a third of a stop of the truth after a whole hour of ramp.
        XCTAssertEqual(log2(engine.currentTarget.lightGain / wanted), 0, accuracy: 1.0 / 3.0)
    }

    /// **The shipping default's cost, stated.** A plain EMA settles ~0.94 stop
    /// behind a stop-a-minute sunset, which reads as the picture dimming
    /// through the fastest part of the transition and recovering afterwards.
    /// That is the price of not amplifying a measurement error by 5.67× — a
    /// trade made after lag compensation walked a real shoot 9.7 stops into
    /// its shutter floor.
    func testTheDefaultRampLagsAFastSunsetRatherThanRiskingRunaway() {
        var engine = HolyGrailRampEngine(
            seed: .init(shutterSeconds: 1.0 / 250, iso: 54), limits: wide,
            anchorsToSeedExposure: false)
        var ev = 12.0
        for _ in 0..<60 {
            engine.advance(measuredEV: ev, limits: wide)
            ev -= 1.0 / 6.0
        }
        let wanted = HolyGrailRampEngine.requiredGain(sceneEV100: ev, aperture: 1.78)
        // 0.94 stop of EMA lag — r(1−α)/α — plus the one step of ramp the
        // last measurement hadn't seen yet.
        XCTAssertEqual(log2(engine.currentTarget.lightGain / wanted), -1.11, accuracy: 0.05)
    }

    /// Lag compensation must not turn into an outlier amplifier: one bright
    /// frame in a settled scene still moves the aim by well under a stop.
    func testLagCompensationDoesNotAmplifyAOneFrameOutlier() {
        var engine = compensatedEngine(shutter: 1.0 / 250, iso: 54)
        for _ in 0..<40 { engine.advance(measuredEV: 10, limits: wide) }
        let settled = engine.aimEV(from: engine.smoothedEV ?? 0)
        engine.advance(measuredEV: 14, limits: wide)
        let after = engine.aimEV(from: engine.smoothedEV ?? 0)
        XCTAssertLessThan(after - settled, 1.0)
    }

    func testTheLagProjectionIsCapped() {
        var engine = compensatedEngine(shutter: 1.0 / 250, iso: 54)
        // A cliff-edge light change every frame: the trend estimate saturates,
        // the projection must not.
        var ev = 15.0
        for _ in 0..<40 {
            engine.advance(measuredEV: ev, limits: wide)
            ev -= 3
        }
        let aim = engine.aimEV(from: engine.smoothedEV ?? 0)
        XCTAssertGreaterThanOrEqual(
            aim - (engine.smoothedEV ?? 0), -HolyGrailRampEngine.maximumLagCorrection - 1e-9)
    }

    func testTheOrderIsShutterFirstThenISOAndReversesOnBrightening() {
        var engine = self.engine(shutter: 1.0 / 250, iso: 54)
        // Into the dark: the shutter must reach its ceiling before ISO leaves
        // the floor.
        var sawISOMoveEarly = false
        for _ in 0..<200 {
            let target = engine.advance(measuredEV: -3, limits: wide)
            if target.iso > 55, target.shutterSeconds < 0.99 { sawISOMoveEarly = true }
        }
        XCTAssertFalse(sawISOMoveEarly, "ISO climbed before the shutter was at its ceiling")
        XCTAssertEqual(engine.currentTarget.shutterSeconds, 1.0, accuracy: 1e-6)
        XCTAssertGreaterThan(engine.currentTarget.iso, 1000)

        // Back into daylight: ISO must come down before the shutter shortens.
        var sawShutterMoveEarly = false
        for _ in 0..<200 {
            let target = engine.advance(measuredEV: 12, limits: wide)
            if target.shutterSeconds < 0.99, target.iso > 55 { sawShutterMoveEarly = true }
        }
        XCTAssertFalse(sawShutterMoveEarly, "the shutter shortened before ISO was back at base")
        XCTAssertEqual(engine.currentTarget.iso, 54, accuracy: 0.01)
        XCTAssertLessThan(engine.currentTarget.shutterSeconds, 0.01)
    }

    // MARK: - Anchoring to the seed exposure

    /// The regression that matters: a shoot must open on the exposure the
    /// camera was already delivering, whatever the meter's absolute numbers
    /// say. Measured on an iPad Air at dawn, the absolute route asked for
    /// 1/61s at ISO 18 the instant recording began — a visible over-exposure
    /// in the first frame.
    func testAnAnchoredRampDoesNotMoveOnTheFirstMeasurement() {
        var engine = anchoredEngine(shutter: 1.0 / 200, iso: 18)
        let seed = engine.currentTarget
        // Whatever this measurement claims — and it claims a scene 1.4 stops
        // brighter than the seed exposure implies — the ramp holds.
        engine.advance(measuredEV: 10.1, limits: wide)
        XCTAssertEqual(engine.currentTarget.lightGain, seed.lightGain, accuracy: seed.lightGain * 0.01)
    }

    func testTheSameMeasurementRepeatedNeverMovesAnAnchoredRamp() {
        var engine = anchoredEngine(shutter: 1.0 / 200, iso: 18)
        let seed = engine.currentTarget
        for _ in 0..<50 { engine.advance(measuredEV: 10.1, limits: wide) }
        XCTAssertEqual(engine.currentTarget.lightGain, seed.lightGain, accuracy: seed.lightGain * 0.01)
    }

    /// Anchoring must not cost the ramp its job: a real change in the light
    /// still moves the exposure by exactly that much.
    func testAnAnchoredRampStillFollowsAChangeInTheLight() {
        var engine = anchoredEngine(shutter: 1.0 / 200, iso: 18)
        let seed = engine.currentTarget
        engine.advance(measuredEV: 10.1, limits: wide)
        // Three stops darker than where it started.
        for _ in 0..<200 { engine.advance(measuredEV: 7.1, limits: wide) }
        XCTAssertEqual(log2(engine.currentTarget.lightGain / seed.lightGain), 3, accuracy: 0.05)
    }

    func testTheCalibrationIsLearnedOnceAndReported() {
        var engine = anchoredEngine(shutter: 1.0 / 200, iso: 18)
        XCTAssertNil(engine.calibration)
        engine.advance(measuredEV: 10.1, limits: wide)
        let learned = try? XCTUnwrap(engine.calibration)
        engine.advance(measuredEV: 4.0, limits: wide)
        XCTAssertEqual(engine.calibration, learned)
    }

    /// Over/under exposure rides on top of the anchor: "start where the
    /// camera was, minus a stop".
    func testBiasShiftsAnAnchoredRampOffItsAnchor() {
        var engine = anchoredEngine(shutter: 1.0 / 200, iso: 18, bias: -1)
        let seed = engine.currentTarget
        for _ in 0..<50 { engine.advance(measuredEV: 10.1, limits: wide) }
        XCTAssertEqual(log2(engine.currentTarget.lightGain / seed.lightGain), -1, accuracy: 0.05)
    }

    /// Bias set mid-run (the operator turning the dial while shooting) moves
    /// the ramp at the same rate-limited pace as any other change.
    func testBiasChangedMidRunIsRateLimitedLikeEverythingElse() {
        var engine = anchoredEngine(shutter: 1.0 / 200, iso: 18)
        for _ in 0..<20 { engine.advance(measuredEV: 10.1, limits: wide) }
        let before = engine.currentTarget.lightGain
        engine.bias = 2
        let after = engine.advance(measuredEV: 10.1, limits: wide).lightGain
        XCTAssertEqual(log2(after / before), 1.0 / 3.0, accuracy: 1e-3)
        for _ in 0..<50 { engine.advance(measuredEV: 10.1, limits: wide) }
        XCTAssertEqual(log2(engine.currentTarget.lightGain / before), 2, accuracy: 0.05)
    }

    // MARK: - The closed loop (the 2026-08-15 field runaway)

    /// Simulates the whole loop the app runs: expose → deliver a frame →
    /// measure the frame → step. The measurement is the app's own
    /// (`sceneEV(gain) + log2(luma / reference)`), and the delivered luma is
    /// the physical truth: proportional to the scene's luminance times the
    /// light the exposure gathers.
    private func closedLoopMeasurement(
        gain: Double, sceneLuminance: Double, aperture: Float = 1.78
    ) -> Double {
        // What the sensor actually delivers, linear, up to a fixed constant
        // the ramp's anchor folds out on frame 1.
        let luma = sceneLuminance * gain * 12
        return HolyGrailRampEngine.sceneEV100(forGain: gain, aperture: aperture)
            + log2(luma / 0.18)
    }

    /// **The regression.** A scene that isn't changing must leave the exposure
    /// exactly where it started, however many frames go by. The shipped
    /// measurement failed this: it read the scene *through* the exposure, so
    /// darkening a frame looked like the world getting brighter, and a 54-frame
    /// dawn run on an iPad walked 9.7 stops down — −1/3 stop on every single
    /// frame — until the shutter hit its floor.
    func testAConstantSceneNeverMovesTheRamp() {
        var engine = anchoredEngine(shutter: 1.0 / 200, iso: 18)
        let seed = engine.currentTarget.lightGain
        for _ in 0..<200 {
            let measured = closedLoopMeasurement(
                gain: engine.currentTarget.lightGain, sceneLuminance: 0.42)
            engine.advance(measuredEV: measured, limits: wide)
        }
        XCTAssertEqual(log2(engine.currentTarget.lightGain / seed), 0, accuracy: 0.01)
    }

    /// …and the light changing is what does move it: three stops of dusk, and
    /// the ramp gathers exactly three stops more light.
    func testTheSceneChangingIsWhatMovesTheRamp() {
        var engine = anchoredEngine(shutter: 1.0 / 200, iso: 18)
        let seed = engine.currentTarget.lightGain
        var luminance = 0.42
        // Settle on the anchor first, then dim the world by three stops.
        for _ in 0..<10 {
            engine.advance(
                measuredEV: closedLoopMeasurement(gain: engine.currentTarget.lightGain, sceneLuminance: luminance),
                limits: wide)
        }
        luminance /= 8
        for _ in 0..<300 {
            engine.advance(
                measuredEV: closedLoopMeasurement(gain: engine.currentTarget.lightGain, sceneLuminance: luminance),
                limits: wide)
        }
        XCTAssertEqual(log2(engine.currentTarget.lightGain / seed), 3, accuracy: 0.05)
    }

    // MARK: - The 2026-09-04 open-loop runaway (a camera that ignores the ramp)

    /// An iPhone 12 Pro wide as the 2026-09-04 run had it: a 14 µs floor
    /// (`format.minExposureDuration`), the 1.0 s ceiling, ISO 33 on the floor.
    private let twelvePro = HolyGrailRampEngine.HardwareLimits(
        minShutter: CMTime(value: 14, timescale: 1_000_000),
        maxShutter: CMTime(value: 1, timescale: 1),
        minISO: 33, maxISO: 3072, aperture: 1.6)

    /// The engine exactly as `CameraController.seedHolyGrailRamp` ships it:
    /// anchored, drifting at 1/20 stop, deadband 0.12, three-window dwell,
    /// ten-window refractory.
    private func shippingEngine(
        shutter: Double, iso: Float, limits: HolyGrailRampEngine.HardwareLimits
    ) -> HolyGrailRampEngine {
        var engine = HolyGrailRampEngine(
            seed: .init(shutterSeconds: shutter, iso: iso), limits: limits)
        engine.anchorDriftPerStep = 0.05
        engine.deadbandStops = 0.12
        engine.dwellSteps = 3
        engine.reversalRefractorySteps = 10
        return engine
    }

    /// A camera on AE that never takes the ramp's command: it exposes at its
    /// own pair and renders the scene at whatever luma its metering lands
    /// on, whatever the engine asked for.
    private struct RefusingCamera {
        var shutter: Double
        var iso: Float
        var luma: Double
    }

    /// **The 2026-09-04 regression.** Metered through the pair the frames
    /// were actually taken at, a ramp the camera is refusing reads a still
    /// scene as still — for 500 windows, the length of the field run — and
    /// its target never leaves the seed. The real run's target walked 7.9
    /// stops in that time.
    func testARefusedRampMeteredThroughTheDeliveredPairNeverWalks() {
        var engine = shippingEngine(shutter: 1.0 / 305, iso: 33, limits: twelvePro)
        let seed = engine.currentTarget.lightGain
        let camera = RefusingCamera(shutter: 1.0 / 296, iso: 33, luma: 0.24)
        for _ in 0..<500 {
            let measured = HolyGrailMetering.sceneEV100(
                meanLinearLuma: camera.luma, deliveredShutterSeconds: camera.shutter,
                iso: camera.iso, aperture: 1.6)
            let ae = HolyGrailMetering.sceneEV100(
                shutterSeconds: camera.shutter, iso: camera.iso, aperture: 1.6,
                exposureTargetOffset: 0)
            engine.advance(measuredEV: measured, limits: twelvePro, aeSceneEV: ae)
        }
        XCTAssertEqual(log2(engine.currentTarget.lightGain / seed), 0, accuracy: 0.01)
    }

    /// …and the small luma drift that started the real walk (AE's rendering
    /// crept 0.14 stops brighter over the first hundred windows) moves it by
    /// that drift at most, because the drift is all there is: nothing the
    /// engine commands feeds back into what it measures.
    func testARefusedRampFollowsOnlyTheLumaDriftItIsShown() {
        var engine = shippingEngine(shutter: 1.0 / 305, iso: 33, limits: twelvePro)
        let seed = engine.currentTarget.lightGain
        var camera = RefusingCamera(shutter: 1.0 / 296, iso: 33, luma: 0.24)
        for window in 0..<600 {
            if window < 100 { camera.luma *= pow(2, 0.14 / 100) }
            let measured = HolyGrailMetering.sceneEV100(
                meanLinearLuma: camera.luma, deliveredShutterSeconds: camera.shutter,
                iso: camera.iso, aperture: 1.6)
            engine.advance(measuredEV: measured, limits: twelvePro)
        }
        XCTAssertLessThanOrEqual(abs(log2(engine.currentTarget.lightGain / seed)), 0.2)
    }

    /// Pinned so it cannot come back: read the luma against the ENGINE's
    /// pair and the same camera is a runaway. Each step the engine takes
    /// raises the commanded-pair term by the step, the luma never answers,
    /// and the error re-crosses the deadband every ~1/α windows — the
    /// 0.12-stop staircase in the field sidecar, 1/305 s to 1/71429 s.
    func testMeteringThroughTheCommandedPairIsTheRunaway() {
        var engine = shippingEngine(shutter: 1.0 / 305, iso: 33, limits: twelvePro)
        let seed = engine.currentTarget.lightGain
        var camera = RefusingCamera(shutter: 1.0 / 296, iso: 33, luma: 0.24)
        for window in 0..<600 {
            if window < 100 { camera.luma *= pow(2, 0.14 / 100) }
            let measured = HolyGrailMetering.sceneEV100(
                meanLinearLuma: camera.luma,
                deliveredShutterSeconds: engine.currentTarget.shutterSeconds,  // the bug
                iso: engine.currentTarget.iso, aperture: 1.6)
            engine.advance(measuredEV: measured, limits: twelvePro)
        }
        XCTAssertLessThan(log2(engine.currentTarget.lightGain / seed), -1.5)
    }

    /// The same meter on a DRIVING camera is scene-referred across the ISP's
    /// quantization: the sensor latches a pair a sixth of a stop off the
    /// command, the luma is made at the latched pair, and the measurement
    /// is the scene's EV to the last digit — the quantization never leaks in.
    func testTheDeliveredPairMeterIsExactAcrossAnISPLatch() {
        let sceneEV = 11.0
        // A frame at the correctly exposing gain sits on mid-grey.
        func luma(atGain gain: Double) -> Double {
            HolyGrailMetering.referenceLuma * gain
                / HolyGrailRampEngine.requiredGain(sceneEV100: sceneEV, aperture: 1.6)
        }
        for latched in [1.0 / 305, 1.0 / 280, 1.0 / 340, 1.0 / 121] {
            let gain = HolyGrailRampEngine.lightGain(shutterSeconds: latched, iso: 33)
            let measured = HolyGrailMetering.sceneEV100(
                meanLinearLuma: luma(atGain: gain), deliveredShutterSeconds: latched,
                iso: 33, aperture: 1.6)
            XCTAssertEqual(measured, sceneEV, accuracy: 1e-9)
        }
    }

    /// A refused ramp still tracks the light — which is what its readout
    /// must print. AE walks its pair down 2.2 stops through a dusk; the
    /// engine's smoothed EV falls by the same.
    func testARefusedRampReadsAFadingSceneAsFading() {
        var engine = shippingEngine(shutter: 1.0 / 305, iso: 33, limits: twelvePro)
        var camera = RefusingCamera(shutter: 1.0 / 296, iso: 33, luma: 0.24)
        var first: Double?
        for window in 0..<500 {
            // AE keeps its rendering and pays for the dusk in exposure.
            camera.shutter = (1.0 / 296) * pow(2, 2.2 * Double(window) / 499)
            let measured = HolyGrailMetering.sceneEV100(
                meanLinearLuma: camera.luma, deliveredShutterSeconds: camera.shutter,
                iso: camera.iso, aperture: 1.6)
            engine.advance(measuredEV: measured, limits: twelvePro)
            if first == nil { first = engine.smoothedEV }
        }
        XCTAssertEqual((first ?? 0) - (engine.smoothedEV ?? 0), 2.2, accuracy: 0.15)
    }

    /// The loop must also survive the operator: a bias dialled mid-run settles
    /// at exactly that offset and then stops, rather than drifting on.
    func testTheClosedLoopSettlesAfterABiasChange() {
        var engine = anchoredEngine(shutter: 1.0 / 200, iso: 18)
        for _ in 0..<10 {
            engine.advance(
                measuredEV: closedLoopMeasurement(gain: engine.currentTarget.lightGain, sceneLuminance: 0.42),
                limits: wide)
        }
        let settled = engine.currentTarget.lightGain
        engine.bias = -1
        for _ in 0..<100 {
            engine.advance(
                measuredEV: closedLoopMeasurement(gain: engine.currentTarget.lightGain, sceneLuminance: 0.42),
                limits: wide)
        }
        XCTAssertEqual(log2(engine.currentTarget.lightGain / settled), -1, accuracy: 0.02)
    }

    // MARK: - Smoothing

    func testASingleOutlierMeasurementBarelyMovesTheRamp() {
        var engine = self.engine(shutter: 1.0 / 250, iso: 54)
        for _ in 0..<40 { engine.advance(measuredEV: 10, limits: wide) }
        let settled = engine.smoothedEV ?? 0
        XCTAssertEqual(settled, 10, accuracy: 0.01)
        // One frame of a headlight sweep: 4 stops brighter, for one frame.
        engine.advance(measuredEV: 14, limits: wide)
        // alpha 0.15 → the average moves 0.6 EV, not 4.
        XCTAssertEqual(engine.smoothedEV ?? 0, 10.6, accuracy: 0.05)
    }

    func testTheFirstMeasurementSeedsTheAverageOutright() {
        var engine = self.engine(shutter: 1.0 / 250, iso: 54)
        engine.advance(measuredEV: 3, limits: wide)
        XCTAssertEqual(engine.smoothedEV ?? 0, 3, accuracy: 1e-9)
    }

    func testTheMeasurementWindowIsBounded() {
        var engine = self.engine(shutter: 1.0 / 250, iso: 54)
        for index in 0..<50 { engine.advance(measuredEV: Double(index), limits: wide) }
        XCTAssertEqual(engine.recentEV.count, HolyGrailRampEngine.measurementWindow)
        XCTAssertEqual(engine.recentEV.last, 49)
        XCTAssertEqual(engine.frameCount, 50)
    }

    func testANonFiniteMeasurementIsIgnored() {
        var engine = self.engine(shutter: 1.0 / 250, iso: 54)
        let before = engine.currentTarget
        engine.advance(measuredEV: .nan, limits: wide)
        XCTAssertEqual(engine.currentTarget, before)
        XCTAssertEqual(engine.frameCount, 0)
    }

    // MARK: - State reporting

    func testISORampingAndClippingReportHonestly() {
        var engine = self.engine(shutter: 1.0 / 250, iso: 54)
        XCTAssertFalse(engine.isISORamping(limits: wide))
        for _ in 0..<200 { engine.advance(measuredEV: -3, limits: wide) }
        XCTAssertTrue(engine.isISORamping(limits: wide))
        XCTAssertFalse(engine.isClipped(limits: wide))

        // Darker than 1 s at ISO 12096 can hold.
        for _ in 0..<200 { engine.advance(measuredEV: -12, limits: wide) }
        XCTAssertTrue(engine.isClipped(limits: wide))
    }

    func testReclampFitsTheTargetToANewEnvelope() {
        var engine = self.engine(shutter: 1.0, iso: 54)
        let tighter = HolyGrailRampEngine.HardwareLimits(
            minShutter: CMTime(value: 1, timescale: 8000),
            maxShutter: CMTime(value: 1, timescale: 4),  // 1/4 s
            minISO: 54, maxISO: 4352, aperture: 1.78)
        engine.reclamp(to: tighter)
        // Same light, redistributed: the shutter fits the new ceiling and the
        // lost two stops come back as ISO.
        XCTAssertEqual(engine.currentTarget.shutterSeconds, 0.25, accuracy: 1e-6)
        XCTAssertEqual(engine.currentTarget.iso, 216, accuracy: 1)
    }

    // MARK: - Metering

    func testAPEXBrightnessBecomesSceneEV() {
        // Sunny 16 is EV100 15, which is Bv 10.
        XCTAssertEqual(HolyGrailMetering.sceneEV100(apexBrightness: 10), 15, accuracy: 1e-9)
    }

    func testMeteringOffsetCorrectsAManuallyDrivenExposure() {
        // A frame taken at 1/60 ISO 400 that AE says is one stop too bright.
        let ev = HolyGrailMetering.sceneEV100(
            shutterSeconds: 1.0 / 60, iso: 400, aperture: 1.78, exposureTargetOffset: 1)
        let unbiased = HolyGrailMetering.sceneEV100(
            shutterSeconds: 1.0 / 60, iso: 400, aperture: 1.78, exposureTargetOffset: 0)
        XCTAssertEqual(ev - unbiased, 1, accuracy: 1e-9)
        // And feeding that EV back gives an exposure a stop darker.
        let wanted = HolyGrailRampEngine.requiredGain(sceneEV100: ev, aperture: 1.78)
        let was = HolyGrailRampEngine.lightGain(shutterSeconds: 1.0 / 60, iso: 400)
        XCTAssertEqual(was / wanted, 2, accuracy: 1e-6)
    }

    // MARK: - Anchor drift (the 2026-08-25 dark-dawn fix)

    /// The shipping drift configuration on top of an anchored engine.
    private func driftingEngine(shutter: Double, iso: Float) -> HolyGrailRampEngine {
        var engine = anchoredEngine(shutter: shutter, iso: iso)
        engine.anchorDriftPerStep = 0.05
        return engine
    }

    /// A perfectly exposure-invariant luma meter for the loop simulations:
    /// whatever gain the engine runs, the measurement reports the true scene.
    private func invariantMeasurement(trueEV: Double) -> Double { trueEV }

    /// The 2026-08-25 failure, reproduced and fixed: an anchor seeded 3 stops
    /// under AE's rendering walks onto AE's opinion at the capped rate, and
    /// the exposure ends where a fresh shoot would open.
    func testTheAnchorDriftsOntoAEsOpinionAtTheCappedRate() {
        let trueEV = 11.0
        // Seed the camera 3 stops darker than AE would choose for this scene.
        let aeGain = HolyGrailRampEngine.requiredGain(sceneEV100: trueEV, aperture: 1.78)
        let seedGain = aeGain / 8
        var engine = driftingEngine(shutter: seedGain / (54.0 / 100), iso: 54)
        var previousCalibration: Double?
        for _ in 0..<400 {
            engine.advance(
                measuredEV: invariantMeasurement(trueEV: trueEV),
                limits: wide, aeSceneEV: trueEV)
            if let previous = previousCalibration, let now = engine.calibration {
                XCTAssertLessThanOrEqual(
                    abs(now - previous), engine.anchorDriftPerStep + 1e-9,
                    "the drift must never exceed its per-step cap")
            }
            previousCalibration = engine.calibration
        }
        // Converged: the exposure sits within the drift deadband (plus one
        // rate-limited step of slack) of what AE would choose.
        let gap = abs(log2(engine.currentTarget.lightGain / aeGain))
        XCTAssertLessThanOrEqual(gap, engine.anchorDriftDeadband + 0.34,
                                 "a drifted ramp ends where AE would meter")
        XCTAssertNotNil(engine.aeGapEV)
    }

    func testSmallAEDisagreementsNeverMoveTheAnchor() {
        let trueEV = 11.0
        let aeGain = HolyGrailRampEngine.requiredGain(sceneEV100: trueEV, aperture: 1.78)
        // Seeded only 0.2 stops off AE — inside the drift deadband.
        var engine = driftingEngine(shutter: (aeGain / exp2(0.2)) / (54.0 / 100), iso: 54)
        engine.advance(measuredEV: trueEV, limits: wide, aeSceneEV: trueEV)
        let learned = engine.calibration
        for _ in 0..<100 {
            engine.advance(measuredEV: trueEV, limits: wide, aeSceneEV: trueEV)
        }
        XCTAssertEqual(engine.calibration, learned,
                       "AE breathing inside the deadband must not walk the anchor")
    }

    func testWithoutAnAEOpinionTheAnchorStaysFrozen() {
        var engine = driftingEngine(shutter: 1.0 / 200, iso: 54)
        engine.advance(measuredEV: 10.1, limits: wide)
        let learned = engine.calibration
        for _ in 0..<100 { engine.advance(measuredEV: 10.1, limits: wide) }
        XCTAssertEqual(engine.calibration, learned)
    }

    // MARK: - Anti-oscillation gate (the 2026-08-25 limit-cycle fix)

    /// The shipping gate on an absolute-EV engine with no smoothing lag, so a
    /// fed measurement maps directly to a wanted move.
    private func gatedEngine(shutter: Double, iso: Float) -> HolyGrailRampEngine {
        var engine = HolyGrailRampEngine(
            seed: .init(shutterSeconds: shutter, iso: iso), limits: wide,
            smoothing: 1.0, anchorsToSeedExposure: false)
        engine.deadbandStops = 0.12
        engine.dwellSteps = 3
        engine.reversalRefractorySteps = 10
        return engine
    }

    /// The measured signature of the 2026-08-25 iPad run: the wanted move
    /// flips sign every window at sub-quarter-stop amplitude. The gate must
    /// hold the target perfectly still.
    func testAlternatingSmallErrorsNeverMoveTheTarget() {
        var engine = gatedEngine(shutter: 1.0 / 1000, iso: 54)
        let anchor = HolyGrailRampEngine.sceneEV100(
            forGain: engine.currentTarget.lightGain, aperture: 1.78)
        let seed = engine.currentTarget.lightGain
        for step in 0..<200 {
            let error = step.isMultiple(of: 2) ? 0.11 : -0.11
            engine.advance(measuredEV: anchor + error, limits: wide)
            XCTAssertEqual(engine.currentTarget.lightGain, seed,
                           accuracy: seed * 1e-9,
                           "a sub-deadband alternation is the limit cycle — hold")
        }
    }

    /// A genuine change larger than the deadband still ramps — after the
    /// dwell has seen it persist.
    func testAPersistentChangeRampsAfterTheDwell() {
        var engine = gatedEngine(shutter: 1.0 / 1000, iso: 54)
        let anchor = HolyGrailRampEngine.sceneEV100(
            forGain: engine.currentTarget.lightGain, aperture: 1.78)
        let seed = engine.currentTarget.lightGain
        // 0.6 stops darker, persistently (below the 1-stop bypass).
        for step in 1...20 {
            engine.advance(measuredEV: anchor - 0.6, limits: wide)
            if step < 3 {
                XCTAssertEqual(engine.currentTarget.lightGain, seed,
                               accuracy: seed * 1e-9,
                               "dwell: no commitment on step \(step)")
            }
        }
        XCTAssertEqual(log2(engine.currentTarget.lightGain / seed), 0.6,
                       accuracy: 0.05, "after the dwell the ramp tracks fully")
    }

    func testAReversalWaitsOutTheRefractoryPeriod() {
        var engine = gatedEngine(shutter: 1.0 / 1000, iso: 54)
        let anchor = HolyGrailRampEngine.sceneEV100(
            forGain: engine.currentTarget.lightGain, aperture: 1.78)
        // Establish a gain-raising ramp and flip MID-COMMITMENT — the limit
        // cycle's own move: the step just taken is what perturbed the
        // quantizer, and the flip arrives on the very next window.
        for _ in 0..<4 { engine.advance(measuredEV: anchor - 0.9, limits: wide) }
        let committed = engine.currentTarget.lightGain
        XCTAssertGreaterThan(committed, engine.currentTarget.lightGain * 0.99)
        // The measured light now claims 0.3 brighter than the anchor — a
        // sub-emergency reversal. Refused for the whole refractory period.
        for _ in 0..<10 {
            engine.advance(measuredEV: anchor + 0.3, limits: wide)
            XCTAssertGreaterThanOrEqual(engine.currentTarget.lightGain, committed * 0.999,
                                        "no reversal inside the refractory period")
        }
        // …and then followed, once patience and dwell are both served.
        for _ in 0..<20 { engine.advance(measuredEV: anchor + 0.3, limits: wide) }
        XCTAssertLessThan(engine.currentTarget.lightGain, committed * 0.9,
                          "a persistent reversal is eventually followed")
    }

    func testAnEmergencyErrorBypassesTheDwell() {
        var engine = gatedEngine(shutter: 1.0 / 1000, iso: 54)
        let anchor = HolyGrailRampEngine.sceneEV100(
            forGain: engine.currentTarget.lightGain, aperture: 1.78)
        let seed = engine.currentTarget.lightGain
        engine.advance(measuredEV: anchor - 2.0, limits: wide)
        XCTAssertEqual(log2(engine.currentTarget.lightGain / seed), 1.0 / 3.0,
                       accuracy: 0.01,
                       "a big error steps immediately, at the rate limit")
    }

    // MARK: - Highlight guard (the 2026-09-28 18 Pro runaway)

    private typealias Reading = HolyGrailRampEngine.HighlightReading

    /// The iPhone 18 Pro telephoto (4×) as the 2026-09-28 shoot met it:
    /// 1.0 s shutter ceiling, ISO 15–7,680, f/2.8.
    private let tele18 = HolyGrailRampEngine.HardwareLimits(
        minShutter: CMTime(value: 1, timescale: 50_000),
        maxShutter: CMTime(value: 1, timescale: 1),
        minISO: 15,
        maxISO: 7680,
        aperture: 2.8)

    private func wideEV(_ gain: Double) -> Double {
        HolyGrailRampEngine.sceneEV100(forGain: gain, aperture: 1.78)
    }

    /// A plain servo with the guard on — no smoothing lag, no gate, no
    /// anchor — so a fed measurement maps straight to a wanted move.
    private func guardedServo(shutter: Double, iso: Float) -> HolyGrailRampEngine {
        var engine = HolyGrailRampEngine(
            seed: .init(shutterSeconds: shutter, iso: iso), limits: wide,
            smoothing: 1.0, anchorsToSeedExposure: false)
        engine.highlightGuardEnabled = true
        return engine
    }

    /// Every Dynamic run's configuration, as `seedHolyGrailRamp` sets it.
    private func shippingDynamicEngine(
        seed: HolyGrailRampEngine.ExposureTarget, limits: HolyGrailRampEngine.HardwareLimits
    ) -> HolyGrailRampEngine {
        var engine = HolyGrailRampEngine(seed: seed, limits: limits)
        engine.anchorDriftPerStep = 0.05
        engine.deadbandStops = 0.12
        engine.dwellSteps = 3
        engine.reversalRefractorySteps = 10
        engine.highlightGuardEnabled = true
        return engine
    }

    func testTheHighlightGuardIsInertUntilEnabled() {
        var plain = anchoredEngine(shutter: 1.0 / 100, iso: 54)
        var fed = plain
        let start = wideEV(plain.currentTarget.lightGain)
        for step in 0..<40 {
            let ev = start - 0.05 * Double(step)
            plain.advance(measuredEV: ev, limits: wide)
            fed.advance(measuredEV: ev, limits: wide,
                        highlights: Reading(clippedFraction: 0.5, hotFraction: 0.9, window: step))
        }
        XCTAssertEqual(plain, fed, "off, the guard reads nothing and changes nothing")
        XCTAssertEqual(fed.highlightState, .off)
        XCTAssertNil(fed.highlightCeilingGain)
    }

    /// Three readings at `clipped` — the shoot's opening, the least of
    /// which every later reading is measured against.
    private func open(_ engine: inout HolyGrailRampEngine, clipped: Double, measuredEV: Double,
                      limits: HolyGrailRampEngine.HardwareLimits) {
        for window in 0..<HolyGrailRampEngine.highlightOpeningReadings {
            engine.advance(measuredEV: measuredEV, limits: limits,
                           highlights: Reading(clippedFraction: clipped, hotFraction: clipped, window: window,
                                               gain: engine.currentTarget.lightGain))
        }
    }

    /// A shoot whose highlights never come near white runs exactly as it
    /// did before the guard — the property the 16 Pro's shoots rely on.
    func testAHealthyShootNeverFeelsTheGuard() {
        var plain = anchoredEngine(shutter: 1.0 / 100, iso: 54)
        var guarded = plain
        guarded.highlightGuardEnabled = true
        let start = wideEV(plain.currentTarget.lightGain)
        for step in 0..<120 {
            let ev = start - 0.04 * Double(step)
            plain.advance(measuredEV: ev, limits: wide)
            guarded.advance(
                measuredEV: ev, limits: wide,
                highlights: Reading(clippedFraction: 0.0, hotFraction: 0.03, window: step,
                                    gain: guarded.currentTarget.lightGain))
            XCTAssertEqual(guarded.currentTarget, plain.currentTarget)
        }
        XCTAssertEqual(guarded.highlightState, .clear)
        XCTAssertNil(guarded.highlightCeilingGain)
    }

    /// 2026-10-02: the camera's own exposure opened a dusk with 17 % of the
    /// frame at white (a sunset sky) and 19 % within ⅓ stop of it. That is
    /// the operator's framing, not a runaway — the net must leave it alone,
    /// however long it stays and however the meter moves.
    func testAShootThatOpensWithItsSkyAtWhiteIsNeverHeld() {
        var plain = anchoredEngine(shutter: 1.0 / 100, iso: 54)
        var guarded = plain
        guarded.highlightGuardEnabled = true
        let start = wideEV(plain.currentTarget.lightGain)
        for step in 0..<300 {
            let ev = start - 0.01 * Double(step)
            plain.advance(measuredEV: ev, limits: wide)
            guarded.advance(
                measuredEV: ev, limits: wide,
                highlights: Reading(clippedFraction: 0.17, hotFraction: 0.19, window: step,
                                    gain: guarded.currentTarget.lightGain))
            XCTAssertEqual(guarded.currentTarget, plain.currentTarget)
        }
        XCTAssertEqual(guarded.highlightOpening ?? -1, 0.17, accuracy: 1e-9)
        XCTAssertNil(guarded.highlightCeilingGain)
    }

    func testTheOpeningIsTheLeastOfItsFirstReadings() {
        var engine = guardedServo(shutter: 1.0 / 100, iso: 54)
        let ev = wideEV(engine.currentTarget.lightGain)
        for (window, clipped) in [0.09, 0.30, 0.08, 0.02].enumerated() {
            engine.advance(measuredEV: ev, limits: wide,
                           highlights: Reading(clippedFraction: clipped, hotFraction: clipped, window: window))
        }
        XCTAssertEqual(engine.highlightOpening ?? -1, 0.08, accuracy: 1e-9,
                       "a headlight in the second reading cannot raise it; a fourth cannot lower it")
    }

    func testMoreAtWhiteThanTheOpeningHoldsTheRamp() {
        var engine = guardedServo(shutter: 1.0 / 100, iso: 54)
        let start = engine.currentTarget.lightGain
        open(&engine, clipped: 0.05, measuredEV: wideEV(start), limits: wide)
        let darker = wideEV(start) - 1   // the meter asks for a stop more light
        // Hot alone is the camera's normal dusk: no hold.
        engine.advance(measuredEV: wideEV(start), limits: wide,
                       highlights: Reading(clippedFraction: 0.05, hotFraction: 0.5, window: 3, gain: start))
        XCTAssertNil(engine.highlightCeilingGain)
        // 11 points more of the frame at white than it opened with: hold.
        let more = Reading(clippedFraction: 0.16, hotFraction: 0.3, window: 4, gain: start)
        for _ in 0..<10 { engine.advance(measuredEV: darker, limits: wide, highlights: more) }
        XCTAssertEqual(engine.currentTarget.lightGain, start, accuracy: start * 1e-9)
        XCTAssertEqual(engine.highlightState, .holding)
        XCTAssertEqual(engine.highlightCeilingGain ?? 0, start, accuracy: start * 1e-9)

        var free = guardedServo(shutter: 1.0 / 100, iso: 54)
        free.advance(measuredEV: darker, limits: wide)
        XCTAssertEqual(log2(free.currentTarget.lightGain / start), 1.0 / 3.0, accuracy: 0.01,
                       "without the reading the same servo climbs")
    }

    func testFarMoreAtWhiteStepsDownAThirdOfAStopPerReading() {
        var engine = guardedServo(shutter: 1.0 / 100, iso: 54)
        let start = engine.currentTarget.lightGain
        open(&engine, clipped: 0.02, measuredEV: wideEV(start), limits: wide)
        let darker = wideEV(start) - 1   // the meter still asks for MORE light
        let clipped = Reading(clippedFraction: 0.25, hotFraction: 0.3, window: 3, gain: start)
        engine.advance(measuredEV: darker, limits: wide, highlights: clipped)
        XCTAssertEqual(log2(engine.currentTarget.lightGain / start), -1.0 / 3.0, accuracy: 0.01)
        XCTAssertEqual(engine.highlightState, .darkening)
        // The same reading again — window 3's blend is still the newest to
        // land — is not answered twice.
        engine.advance(measuredEV: darker, limits: wide, highlights: clipped)
        XCTAssertEqual(log2(engine.currentTarget.lightGain / start), -1.0 / 3.0, accuracy: 0.01)
        XCTAssertEqual(engine.highlightState, .holding)
        // The frames shot at the new exposure, still far over: another step.
        let lower = engine.currentTarget.lightGain
        engine.advance(measuredEV: darker, limits: wide,
                       highlights: Reading(clippedFraction: 0.23, hotFraction: 0.3, window: 4, gain: lower))
        XCTAssertEqual(log2(engine.currentTarget.lightGain / start), -2.0 / 3.0, accuracy: 0.01)
    }

    /// Clipping outranks the gate: the dwell and the refractory exist to stop
    /// a quantizer ringing, and a blown sky is not that.
    func testAClipStepsDownThroughTheGate() {
        var engine = gatedEngine(shutter: 1.0 / 1000, iso: 54)
        engine.highlightGuardEnabled = true
        let start = engine.currentTarget.lightGain
        let anchor = wideEV(start)
        // Establish an upward ramp (the reversal refractory is now armed),
        // its frames opening with nothing at white.
        for window in 0..<4 {
            engine.advance(measuredEV: anchor - 0.9, limits: wide,
                           highlights: Reading(clippedFraction: 0, hotFraction: 0, window: window,
                                               gain: engine.currentTarget.lightGain))
        }
        let committed = engine.currentTarget.lightGain
        XCTAssertGreaterThan(committed, start)
        engine.advance(measuredEV: anchor - 0.9, limits: wide,
                       highlights: Reading(clippedFraction: 0.25, hotFraction: 0.4, window: 5, gain: committed))
        XCTAssertEqual(log2(engine.currentTarget.lightGain / committed), -1.0 / 3.0, accuracy: 0.01)
    }

    /// Room lifts the limit relative to the exposure the frames were SHOT
    /// at — wherever the ramp has settled under the limit.
    func testRoomRaisesTheCeilingAboveTheExposureThatShowedIt() {
        var engine = guardedServo(shutter: 1.0 / 100, iso: 54)
        let start = engine.currentTarget.lightGain
        open(&engine, clipped: 0.0, measuredEV: wideEV(start), limits: wide)
        let darker = wideEV(start) - 1
        engine.advance(measuredEV: darker, limits: wide,
                       highlights: Reading(clippedFraction: 0.12, hotFraction: 0.2, window: 3, gain: start))
        XCTAssertEqual(engine.currentTarget.lightGain, start, accuracy: start * 1e-9, "held")
        // Room, measured on frames shot 0.07 stop under the limit — the
        // 2026-10-02 freeze's exact geometry. The limit goes to a lift above
        // THEM, so the ramp can move again.
        engine.advance(measuredEV: darker, limits: wide,
                       highlights: Reading(clippedFraction: 0.0, hotFraction: 0.0, window: 4,
                                           gain: start * exp2(-0.07)))
        XCTAssertEqual(log2((engine.highlightCeilingGain ?? 0) / start), -0.07 + 1.0 / 6.0, accuracy: 1e-9)
        XCTAssertGreaterThan(engine.currentTarget.lightGain, start)
        // Room further down never lowers a limit.
        let ceiling = engine.highlightCeilingGain ?? 0
        engine.advance(measuredEV: darker, limits: wide,
                       highlights: Reading(clippedFraction: 0, hotFraction: 0, window: 5, gain: start / 4))
        XCTAssertEqual(engine.highlightCeilingGain ?? 0, ceiling, accuracy: ceiling * 1e-9)
    }

    /// 2026-10-02, reproduced and fixed: the shipping gate parks the ramp
    /// 0.07 stop under a limit it may not step into (its deadband is 0.12),
    /// the light falls three stops over 700 windows, and the frames hold
    /// nothing at white. Before the fix it moved 0.000 stops for the rest of
    /// the shoot; it must now follow the light.
    func testTheFreezeOf20261002Releases() {
        let main = HolyGrailRampEngine.HardwareLimits(
            minShutter: CMTime(value: 1, timescale: 100_000), maxShutter: CMTime(value: 1, timescale: 1),
            minISO: 55, maxISO: 7000, aperture: 1.8)
        var engine = shippingDynamicEngine(seed: .init(shutterSeconds: 0.0206, iso: 55), limits: main)
        let g0 = engine.currentTarget.lightGain
        let ev0 = HolyGrailRampEngine.sceneEV100(forGain: g0, aperture: 1.8)
        open(&engine, clipped: 0.02, measuredEV: ev0, limits: main)
        // A limit 0.07 stop above the ramp, set by frames shot a little higher.
        engine.advance(measuredEV: ev0, limits: main,
                       highlights: Reading(clippedFraction: 0.13, hotFraction: 0.2, window: 3, gain: g0 * exp2(0.07)))
        XCTAssertEqual(log2((engine.highlightCeilingGain ?? 0) / g0), 0.07, accuracy: 1e-9)
        for w in 4..<704 {
            let ev = ev0 - 3.0 * Double(w - 3) / 700
            engine.advance(measuredEV: ev, limits: main,
                           highlights: Reading(clippedFraction: 0.0, hotFraction: 0.0, window: w,
                                               gain: engine.currentTarget.lightGain))
        }
        XCTAssertGreaterThan(log2(engine.currentTarget.lightGain / g0), 2.7, "the ramp follows the light")
        XCTAssertEqual(engine.highlightState, .clear)
    }

    /// The red "past the sensor's limit" is for a ramp the SENSOR has run out
    /// on. One its highlights are holding is declining the light, and saying
    /// otherwise over correctly held frames is how a shoot gets stopped.
    func testTheRedReadoutStaysAmberWhileHighlightsHoldTheRamp() {
        let night = wideEV(HolyGrailRampEngine.lightGain(shutterSeconds: 1, iso: 12096)) - 3
        var unguarded = guardedServo(shutter: 1.0 / 100, iso: 54)
        unguarded.highlightGuardEnabled = false
        unguarded.advance(measuredEV: night, limits: wide)
        XCTAssertTrue(unguarded.isClipped(limits: wide))

        var engine = guardedServo(shutter: 1.0 / 100, iso: 54)
        open(&engine, clipped: 0.0, measuredEV: wideEV(engine.currentTarget.lightGain), limits: wide)
        engine.advance(measuredEV: night, limits: wide,
                       highlights: Reading(clippedFraction: 0.15, hotFraction: 0.2, window: 3,
                                           gain: engine.currentTarget.lightGain))
        XCTAssertEqual(engine.highlightState, .holding)
        XCTAssertFalse(engine.isClipped(limits: wide))
    }

    /// The 2026-09-28 pattern in miniature: an AE opinion that reads the
    /// scene 0.6 stops darker than wherever the ramp is, however far it goes.
    /// While the frames show more at white than they opened with, the drift
    /// may not add light.
    func testTheAnchorCannotDriftTowardMoreLightWhileTheFramesShowExcess() {
        var held = anchoredEngine(shutter: 1.0 / 100, iso: 54)
        held.anchorDriftPerStep = 0.05
        held.highlightGuardEnabled = true
        var free = held
        free.highlightGuardEnabled = false
        let measured = wideEV(held.currentTarget.lightGain)
        for window in 0..<60 {
            held.advance(
                measuredEV: measured, limits: wide,
                aeSceneEV: wideEV(held.currentTarget.lightGain) - 0.6,
                highlights: Reading(clippedFraction: window < 3 ? 0 : 0.15, hotFraction: 0.2, window: window,
                                    gain: held.currentTarget.lightGain))
            free.advance(
                measuredEV: measured, limits: wide,
                aeSceneEV: wideEV(free.currentTarget.lightGain) - 0.6)
        }
        XCTAssertLessThanOrEqual(held.calibration ?? 99, 0.2,
                                 "only the opening windows, before the excess showed, could drift")
        XCTAssertGreaterThan(free.calibration ?? 0, 1, "unguarded, the same opinion walks the anchor")
        XCTAssertGreaterThan(free.currentTarget.lightGain, held.currentTarget.lightGain * 2)
    }

    /// 2026-10-02: paused whenever a limit merely existed, the drift held a
    /// dusk 0.6–1 stop under the camera's exposure all night. Frames at their
    /// opening share are no reason to stop it.
    func testTheDriftRunsWhileTheFramesSitAtTheirOpening() {
        var engine = anchoredEngine(shutter: 1.0 / 100, iso: 54)
        engine.anchorDriftPerStep = 0.05
        engine.highlightGuardEnabled = true
        let measured = wideEV(engine.currentTarget.lightGain)
        for window in 0..<60 {
            engine.advance(
                measuredEV: measured, limits: wide,
                aeSceneEV: wideEV(engine.currentTarget.lightGain) - 0.6,
                highlights: Reading(clippedFraction: 0.08, hotFraction: 0.15, window: window,
                                    gain: engine.currentTarget.lightGain))
        }
        XCTAssertGreaterThan(engine.calibration ?? 0, 1)
    }

    // MARK: The 2026-09-28 dusk, simulated

    /// The frames' own brightness meter as the shoot met it: honest near a
    /// correct exposure, compressing past it, and never able to report more
    /// than ~3 stops over however far over the frames are — the run's APEX
    /// brightness sat at exactly that for its last 90 windows.
    private func compressedMeter(exposureEV: Double, overStops x: Double) -> Double {
        exposureEV + (x <= 0 ? x : 3.05 * (1 - exp(-x / 3.05)))
    }

    /// A dusk telephoto frame: 30 % sky, spread evenly in stops from 0.30 to
    /// 0.65 of saturation at a correct exposure; the rest mid-grey and
    /// darker. The share of the frame at white and within ⅓ stop of it when
    /// the frame is `x` stops over.
    private func duskHighlights(overStops x: Double) -> (clipped: Double, hot: Double) {
        let sky = 0.30
        let low = log2(0.30), high = log2(0.65)
        func share(atOrAbove level: Double) -> Double {
            let threshold = log2(level) - x
            var total = sky * min(max((high - threshold) / (high - low), 0), 1)
            if log2(0.18) >= threshold { total += 1 - sky }
            return total
        }
        return (share(atOrAbove: Reading.clippedLevel), share(atOrAbove: Reading.hotLevel))
    }

    private struct DuskRun {
        var finalISO: Float = 0
        var finalOverStops = 0.0
        /// Windows whose frames had 10 % or more of the frame at white.
        var windowsClipped = 0
        var worstClipped = 0.0
    }

    /// Seeded correctly exposed, the light falling ~0.12 stop a minute at
    /// 2 s windows, both meters behaving as they did that night, the
    /// shipping drift and gate, and the highlights landing two windows late
    /// (the DNG path's blend) stamped with the gain their frames had.
    private func simulateTelephotoDusk(guarded: Bool, windows: Int = 500) -> DuskRun {
        let startEV = 7.2
        let seed = HolyGrailRampEngine.split(
            gain: HolyGrailRampEngine.requiredGain(sceneEV100: startEV, aperture: 2.8), limits: tele18)
        var engine = shippingDynamicEngine(seed: seed, limits: tele18)
        engine.highlightGuardEnabled = guarded
        var readings: [Int: Reading] = [:]
        var run = DuskRun()
        for window in 0..<windows {
            let sceneEV = startEV - 0.004 * Double(window)
            let gain = engine.currentTarget.lightGain
            let exposureEV = HolyGrailRampEngine.sceneEV100(forGain: gain, aperture: 2.8)
            let over = sceneEV - exposureEV
            let lights = duskHighlights(overStops: over)
            if lights.clipped >= 0.10 { run.windowsClipped += 1 }
            run.worstClipped = max(run.worstClipped, lights.clipped)
            readings[window] = Reading(
                clippedFraction: lights.clipped, hotFraction: lights.hot, window: window, gain: gain)
            engine.advance(
                measuredEV: compressedMeter(exposureEV: exposureEV, overStops: over),
                limits: tele18,
                aeSceneEV: exposureEV - 0.6,
                highlights: readings[window - 2])
            run.finalOverStops = over
        }
        run.finalISO = engine.currentTarget.iso
        return run
    }

    /// The failure itself, reproduced from the mechanism alone: the drift
    /// pushes, the compressed meter reads the brighter frames as a darker
    /// scene, and the ramp runs to the lens's maximum ISO.
    func testTheTelephotoDuskRunsAwayWithoutTheGuard() {
        let run = simulateTelephotoDusk(guarded: false)
        XCTAssertEqual(run.finalISO, 7680, accuracy: 1)
        XCTAssertGreaterThan(run.finalOverStops, 5)
        XCTAssertGreaterThan(run.windowsClipped, 200)
    }

    /// The runaway net on the same night: it lets the fooled ramp go until a
    /// tenth more of the frame is at white than the shoot opened with
    /// (nothing, here), then holds, pauses the drift, and lets ISO follow
    /// only as the light falls.
    func testTheHighlightGuardHoldsTheTelephotoDusk() {
        let run = simulateTelephotoDusk(guarded: true)
        XCTAssertLessThan(run.finalOverStops, 1.0, "the sky's brightest third stays under white")
        XCTAssertLessThan(run.finalISO, 100)
        XCTAssertLessThanOrEqual(run.windowsClipped, 10, "a late reading may overshoot briefly — no more")
        XCTAssertLessThan(run.worstClipped, 0.3)
    }

    // MARK: A sunrise, simulated (the logic in reverse)

    /// Pre-dawn to day over 600 windows (30 minutes at 3 s): the light rises
    /// six stops. The frame: city lights holding 3 % of it at white from the
    /// start, plus the dusk frame's sky. `meterStuck` stands the ramp's meter
    /// still at its opening reading — a meter that stops seeing the light
    /// rise, which is the sunrise form of the 2026-09-28 failure.
    private func simulateSunrise(guarded: Bool, meterStuck: Bool, windows: Int = 600) -> DuskRun {
        let startEV = 2.0
        let seed = HolyGrailRampEngine.split(
            gain: HolyGrailRampEngine.requiredGain(sceneEV100: startEV, aperture: 2.8), limits: tele18)
        var engine = shippingDynamicEngine(seed: seed, limits: tele18)
        engine.highlightGuardEnabled = guarded
        var readings: [Int: Reading] = [:]
        var run = DuskRun()
        for window in 0..<windows {
            let sceneEV = startEV + 6.0 * Double(window) / Double(windows)
            let gain = engine.currentTarget.lightGain
            let exposureEV = HolyGrailRampEngine.sceneEV100(forGain: gain, aperture: 2.8)
            let over = sceneEV - exposureEV
            let sky = duskHighlights(overStops: over)
            let clipped = min(1, 0.03 + sky.clipped), hot = min(1, 0.03 + sky.hot)
            if clipped >= 0.10 { run.windowsClipped += 1 }
            run.worstClipped = max(run.worstClipped, clipped)
            readings[window] = Reading(clippedFraction: clipped, hotFraction: hot, window: window, gain: gain)
            engine.advance(
                measuredEV: meterStuck ? startEV : sceneEV,
                limits: tele18,
                aeSceneEV: meterStuck ? startEV - 0.6 : sceneEV,
                highlights: readings[window - 2])
            run.finalOverStops = over
        }
        run.finalISO = engine.currentTarget.iso
        return run
    }

    /// An honest sunrise: the ramp follows the light down from ISO to shutter
    /// and the net — the lights at their opening 3 % throughout — never acts.
    func testAnHonestSunriseNeverFeelsTheGuard() {
        let guarded = simulateSunrise(guarded: true, meterStuck: false)
        let plain = simulateSunrise(guarded: false, meterStuck: false)
        XCTAssertEqual(guarded.finalOverStops, plain.finalOverStops, accuracy: 1e-9)
        XCTAssertEqual(guarded.worstClipped, plain.worstClipped, accuracy: 1e-9)
        XCTAssertLessThan(abs(guarded.finalOverStops), 0.3, "it tracks the sunrise")
    }

    /// A sunrise the meter cannot see: unguarded, the frames end six stops
    /// over and wholly white; the net steps the exposure down after the
    /// light, keeping the frame within a fifth of white beyond its opening.
    func testASunriseTheMeterCannotSeeIsSteppedDownAfterTheLight() {
        let plain = simulateSunrise(guarded: false, meterStuck: true)
        XCTAssertGreaterThan(plain.finalOverStops, 5.5)
        XCTAssertGreaterThan(plain.worstClipped, 0.9)
        let guarded = simulateSunrise(guarded: true, meterStuck: true)
        XCTAssertLessThan(guarded.finalOverStops, 1.6)
        XCTAssertLessThan(guarded.worstClipped, 0.03 + 0.25, "no more than a quarter past the opening")
    }
}

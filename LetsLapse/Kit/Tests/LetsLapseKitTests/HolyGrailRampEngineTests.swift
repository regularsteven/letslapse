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
}

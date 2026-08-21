import XCTest
@testable import LetsLapseKit

final class BlendStrategiesTests: XCTestCase {

    // MARK: Zone

    /// The shipping table, pinned: these are the numbers the app has been
    /// shipping as Auto, so a change here is a behaviour change by definition.
    func testZoneTableMatchesShippingBands() {
        XCTAssertEqual(ZoneBlendStrategy.band(forEV: 14).frames, 8)
        XCTAssertEqual(ZoneBlendStrategy.band(forEV: 13).frames, 8)
        XCTAssertEqual(ZoneBlendStrategy.band(forEV: 12.9).frames, 5)
        XCTAssertEqual(ZoneBlendStrategy.band(forEV: 10).frames, 5)
        XCTAssertEqual(ZoneBlendStrategy.band(forEV: 9.9).frames, 3)
        XCTAssertEqual(ZoneBlendStrategy.band(forEV: 7).frames, 3)
        XCTAssertEqual(ZoneBlendStrategy.band(forEV: 6.9).frames, 2)
        XCTAssertEqual(ZoneBlendStrategy.band(forEV: 4).frames, 2)
        XCTAssertEqual(ZoneBlendStrategy.band(forEV: 3.9).frames, 1)
        XCTAssertEqual(ZoneBlendStrategy.band(forEV: -5).frames, 1)
    }

    func testZoneSmoothsOverThreeCyclesAndResolvesFirstCycleDirectly() {
        var zone = ZoneBlendStrategy()
        // First cycle resolves from its single reading, no warm-up.
        XCTAssertEqual(zone.resolve(ev: 14), 8)
        // 14, 9 → mean 11.5 → overcast.
        XCTAssertEqual(zone.resolve(ev: 9), 5)
        // 14, 9, 4 → mean 9 → dim.
        XCTAssertEqual(zone.resolve(ev: 4), 3)
        // Window slides: 9, 4, 4 → mean 5.67 → dusk.
        XCTAssertEqual(zone.resolve(ev: 4), 2)
    }

    func testZoneHoldsOnMissingReadingAndFallsBackMidTable() {
        var zone = ZoneBlendStrategy()
        // First cycle with no reading: the middle of the table.
        XCTAssertEqual(zone.resolve(ev: nil), 5)
        var warm = ZoneBlendStrategy()
        _ = warm.resolve(ev: 14)
        XCTAssertEqual(warm.resolve(ev: nil), 8, "a missing reading holds the last count")
    }

    // MARK: Latitude

    func testLatitudeSigmoidLandsNearZoneTable() {
        let latitude = LatitudeBlendStrategy()
        // Calibrated against Zone's table so the field test compares
        // continuity, not depth: EV 10 → ~5.4 (Zone 5), EV 13 → ~7.3
        // (Zone 8), EV 7 → ~2.7 (Zone 3), EV 4 → ~1.4 (Zone 2).
        XCTAssertEqual(latitude.continuousCount(forEV: 9), 4.5, accuracy: 0.01)
        XCTAssertEqual(latitude.continuousCount(forEV: 10), 5.45, accuracy: 0.05)
        XCTAssertEqual(latitude.continuousCount(forEV: 13), 7.32, accuracy: 0.05)
        XCTAssertEqual(latitude.continuousCount(forEV: 7), 2.73, accuracy: 0.05)
        XCTAssertEqual(latitude.continuousCount(forEV: 4), 1.41, accuracy: 0.05)
        XCTAssertGreaterThan(latitude.continuousCount(forEV: 16), 7.5)
        XCTAssertLessThan(latitude.continuousCount(forEV: 0), 1.1)
        // Monotone in EV.
        var previous = -Double.infinity
        for ev in stride(from: 0.0, through: 16.0, by: 0.5) {
            let value = latitude.continuousCount(forEV: ev)
            XCTAssertGreaterThan(value, previous)
            previous = value
        }
    }

    func testLatitudeDoesNotFlapOnAEHunting() {
        var latitude = LatitudeBlendStrategy()
        // Settle at an EV that quantises right near a rounding edge.
        var t = 0.0
        let base = 10.0  // continuous 4.5, the worst case for flapping
        var counts = Set<Int>()
        for i in 0..<40 {
            t += 5
            // AE hunting: a third of a stop either way.
            let ev = base + (i % 2 == 0 ? 0.33 : -0.33)
            counts.insert(latitude.resolve(ev: ev, at: t))
        }
        // After the first settle the count must not alternate.
        XCTAssertEqual(counts.count, 1, "AE hunting flapped the count: \(counts)")
    }

    func testLatitudeSlewsOneFramePerCycle() {
        var latitude = LatitudeBlendStrategy()
        var t = 0.0
        // The sigmoid sits below Zone's dusk band down here: EV 4 → ~1.1 → 1.
        XCTAssertEqual(latitude.resolve(ev: 4, at: t), 1)
        // A sudden jump to full daylight walks up one frame per cycle, never
        // leaps — and the EMA means the early cycles hold while the smoothed
        // value catches up.
        var last = 1
        for _ in 0..<60 {
            t += 30
            let count = latitude.resolve(ev: 15, at: t)
            XCTAssertLessThanOrEqual(count - last, 1, "count leapt by more than 1")
            XCTAssertGreaterThanOrEqual(count, last, "count moved against the light")
            last = count
        }
        XCTAssertGreaterThanOrEqual(last, 7, "never converged to daylight depth")
    }

    func testLatitudeHoldsOnMissingReading() {
        var latitude = LatitudeBlendStrategy()
        XCTAssertEqual(latitude.resolve(ev: nil, at: 0), 5)
        var warm = LatitudeBlendStrategy()
        _ = warm.resolve(ev: 15, at: 0)
        let held = warm.resolve(ev: nil, at: 30)
        XCTAssertEqual(held, warm.lastCount)
    }

    func testLatitudeColdStartWithoutMeterDoesNotAnchorTheSlew() {
        var latitude = LatitudeBlendStrategy()
        // A shoot started before AE settles: the fallback answers 5 but
        // must not anchor the hysteresis — the first real reading snaps to
        // the curve instead of walking one frame per window from 5.
        XCTAssertEqual(latitude.resolve(ev: nil, at: 0), 5)
        XCTAssertNil(latitude.lastCount)
        XCTAssertEqual(latitude.resolve(ev: 15, at: 5), 8)
        var night = LatitudeBlendStrategy()
        _ = night.resolve(ev: nil, at: 0)
        XCTAssertEqual(night.resolve(ev: 2, at: 5), 1,
                       "a night start must not spend four windows walking down from 5")
    }

    func testLatitudeVelocityMeasuresASunset() throws {
        var latitude = LatitudeBlendStrategy()
        // One stop per minute, falling, sampled every 10 s.
        var t = 0.0
        for i in 0..<12 {
            t = Double(i) * 10
            _ = latitude.resolve(ev: 12 - t / 60, at: t)
        }
        let velocity = try XCTUnwrap(latitude.lastVelocityStopsPerMinute)
        XCTAssertEqual(velocity, -1.0, accuracy: 0.05)
    }

    func testVelocityNeedsSpanAndPoints() {
        XCTAssertNil(LatitudeBlendStrategy.slopePerMinute(of: []))
        XCTAssertNil(LatitudeBlendStrategy.slopePerMinute(of: [(0, 10), (10, 10)]))
        XCTAssertNil(LatitudeBlendStrategy.slopePerMinute(of: [(0, 10), (10, 10), (20, 10)]),
                     "under 30 s of span says nothing about a sunset")
    }

    // MARK: Frame luminance stats

    /// A synthetic half-dark buffer: 50% of pixels at scene 0.0004 (below the
    /// 0.001 threshold), 50% at scene 0.5. Headroom 2 stops means stored
    /// values are scene/4.
    private func halfDarkStats(darkScene: Double = 0.0004, brightScene: Double = 0.5,
                               iso: Double? = 3200) -> FrameLuminanceStats {
        let width = 64, height = 64
        var buffer = [UInt16](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let scene = (i % 2 == 0) ? darkScene : brightScene
            let stored = UInt16((scene / 4 * 65535).rounded())
            buffer[i * 4] = stored
            buffer[i * 4 + 1] = stored
            buffer[i * 4 + 2] = stored
            buffer[i * 4 + 3] = 65535
        }
        return FrameLuminanceStats.compute(
            rgba16: buffer, width: width, height: height,
            headroomStops: 2, iso: iso, targetSamples: 4096)!
    }

    func testStatsComputeFindsTheDarkHalf() {
        let stats = halfDarkStats()
        XCTAssertEqual(stats.fractionBelow[0], 0.5, accuracy: 0.05)
        XCTAssertEqual(stats.p01, 0.0004, accuracy: 0.0002)
        XCTAssertEqual(stats.p10, 0.0004, accuracy: 0.0002)
        // Exactly half dark: the median sits on the first bright sample.
        XCTAssertEqual(stats.p50, 0.5, accuracy: 0.01)
        XCTAssertEqual(stats.meanLuma, 0.25, accuracy: 0.02)
        XCTAssertEqual(stats.fractionAbove98, 0, accuracy: 0.001)
    }

    func testStatsFractionInterpolatesBetweenThresholds() {
        let stats = FrameLuminanceStats(
            sampleCount: 100, meanLuma: 0.1,
            p01: 0, p05: 0, p10: 0, p50: 0.1,
            fractionBelow: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8],
            fractionAbove98: 0)
        // Clamped at the ends.
        XCTAssertEqual(stats.fraction(below: 0.0001), 0.1)
        XCTAssertEqual(stats.fraction(below: 0.5), 0.8)
        // Halfway in log2 between 0.001 and 0.002.
        XCTAssertEqual(stats.fraction(below: 0.001 * pow(2, 0.5)), 0.15, accuracy: 0.001)
    }

    func testThresholdLadderReachesTheHighISORange() {
        // The ladder must keep discriminating where night shoots live: the
        // ISO-indexed starving threshold at ISO 3200 has to land strictly
        // inside the ladder, not on its clamp.
        let lumen = LumenBlendStrategy()
        let at3200 = lumen.starvingThreshold(iso: 3200)
        XCTAssertLessThan(at3200, FrameLuminanceStats.thresholds.last!)
        XCTAssertGreaterThan(at3200, FrameLuminanceStats.thresholds.first!)
    }

    // MARK: Lumen

    func testLumenColdStartIsExactlyThePrior() {
        var lumen = LumenBlendStrategy()
        XCTAssertEqual(lumen.resolve(prior: 3, stats: nil), 3)
        XCTAssertEqual(lumen.boost, 0)
        XCTAssertNil(lumen.lastScore)
    }

    func testLumenBoostsStarvingShadowsAndDecays() {
        var lumen = LumenBlendStrategy()
        // At ISO 3200 the starving threshold is well above the dark half.
        XCTAssertGreaterThan(lumen.starvingThreshold(iso: 3200), 0.0004)
        // Distinct starving measurements walk the boost to its cap, one per
        // cycle. (Each window's stats differ slightly, as real ones do —
        // here by the reported ISO, which is part of the record.)
        XCTAssertEqual(lumen.resolve(prior: 2, stats: halfDarkStats(darkScene: 0.0004, iso: 3200)), 3)
        XCTAssertEqual(lumen.resolve(prior: 2, stats: halfDarkStats(darkScene: 0.0004, iso: 3210)), 4)
        XCTAssertEqual(lumen.resolve(prior: 2, stats: halfDarkStats(darkScene: 0.0004, iso: 3220)), 4,
                       "boost is bounded at +2")
        // Shadows recover: the boost decays a frame at a time.
        XCTAssertEqual(lumen.resolve(prior: 2, stats: halfDarkStats(darkScene: 0.10, iso: 100)), 3)
        XCTAssertEqual(lumen.resolve(prior: 2, stats: halfDarkStats(darkScene: 0.11, iso: 110)), 2)
    }

    func testLumenDoesNotRatchetOnTheSameMeasurement() {
        var lumen = LumenBlendStrategy()
        let starving = halfDarkStats(darkScene: 0.0004, iso: 3200)
        XCTAssertEqual(lumen.resolve(prior: 2, stats: starving), 3)
        // Catch-up closes and late-landing analysis hand the same stats in
        // again: the boost must hold, not walk to its cap off one
        // measurement.
        XCTAssertEqual(lumen.resolve(prior: 2, stats: starving), 3)
        XCTAssertEqual(lumen.resolve(prior: 2, stats: starving), 3)
        XCTAssertEqual(lumen.boost, 1)
    }

    func testLumenLowISOIgnoresDeepShadowsBelowItsFloor() {
        var lumen = LumenBlendStrategy()
        // The same dark half, but at base ISO the floor sits below it —
        // those shadows are dark scene content, not noise-starved pixels.
        // 0.0004 scene at ISO 100: threshold = 0.0005*1*4 = 0.002 > 0.0004,
        // so it WOULD starve; use a brighter dark half instead.
        let dusk = halfDarkStats(darkScene: 0.004, iso: 100)
        XCTAssertEqual(lumen.resolve(prior: 3, stats: dusk), 3)
        XCTAssertEqual(lumen.boost, 0)
    }

    func testLumenHoldsBoostAcrossAMissingWindow() {
        var lumen = LumenBlendStrategy()
        let starving = halfDarkStats(darkScene: 0.0004, iso: 3200)
        _ = lumen.resolve(prior: 2, stats: starving)
        XCTAssertEqual(lumen.boost, 1)
        XCTAssertEqual(lumen.resolve(prior: 2, stats: nil), 3, "missing stats hold the boost")
        XCTAssertEqual(lumen.boost, 1)
    }

    // MARK: Processing ceiling (AIMD)

    func testProcessingCeilingDoesNotSpiralOnFixedOverhead() {
        // The regression the bench caught: 0.4s fixed overhead + 0.5s/frame
        // at a 3s interval. A per-frame model derived from shrinking windows
        // walks to 1; AIMD must settle where the TOTAL fits.
        var governor = ProcessingCeiling()
        var frames = 5
        for _ in 0..<20 {
            let total = 0.4 + 0.5 * Double(frames)
            governor.record(windowSeconds: total, frames: frames, intervalSeconds: 3)
            frames = governor.ceiling
        }
        // 5 frames = 2.9s fits (hold); the governor must never leave it.
        XCTAssertEqual(governor.ceiling, 5)
    }

    func testProcessingCeilingConvergesWhenGenuinelyOverBudget() {
        // The 12 Pro's sunrise shape: ~1.04s/frame + 0.5s overhead, 3s
        // interval. 5 frames = 5.7s drowns; 2 frames = 2.58s fits.
        var governor = ProcessingCeiling()
        var frames = 5
        for _ in 0..<10 {
            let total = 0.5 + 1.04 * Double(frames)
            governor.record(windowSeconds: total, frames: frames, intervalSeconds: 3)
            frames = min(governor.ceiling, 5)
        }
        XCTAssertEqual(governor.ceiling, 2, "must settle at the sustainable count, not 1")
    }

    func testProcessingCeilingRegrowsAfterConditionsImprove() {
        var governor = ProcessingCeiling()
        governor.record(windowSeconds: 6.0, frames: 5, intervalSeconds: 3)
        XCTAssertEqual(governor.ceiling, 4)
        governor.record(windowSeconds: 5.0, frames: 4, intervalSeconds: 3)
        XCTAssertEqual(governor.ceiling, 3)
        // Light moves on, windows get cheap: two comfortable windows per
        // step back up — one lucky window must not oscillate it.
        governor.record(windowSeconds: 1.0, frames: 3, intervalSeconds: 3)
        XCTAssertEqual(governor.ceiling, 3)
        governor.record(windowSeconds: 1.0, frames: 3, intervalSeconds: 3)
        XCTAssertEqual(governor.ceiling, 4)
        governor.record(windowSeconds: 1.2, frames: 4, intervalSeconds: 3)
        governor.record(windowSeconds: 1.2, frames: 4, intervalSeconds: 3)
        XCTAssertEqual(governor.ceiling, 5)
    }

    func testPaceFloorEngagesWhenBlendingBecomesUnaffordable() throws {
        var governor = ProcessingCeiling()
        // Plenty of frame-count room: overruns shrink the count, never
        // demand pacing.
        governor.record(windowSeconds: 6.0, frames: 5, intervalSeconds: 3)
        XCTAssertNil(governor.sustainableIntervalSeconds)
        governor.record(windowSeconds: 5.0, frames: 4, intervalSeconds: 3)
        governor.record(windowSeconds: 4.5, frames: 3, intervalSeconds: 3)
        XCTAssertEqual(governor.ceiling, 2)
        XCTAssertNil(governor.sustainableIntervalSeconds)
        // A TWO-frame window over the interval would step below a real
        // blend — the mission is blended frames, so pacing pays instead:
        // the floor is the blend's measured cost plus margin. (Retreating
        // to singles is a trap: pass-through singles are cheap and never
        // overrun, leaving a 1↔2 limit cycle — bench-observed.)
        governor.record(windowSeconds: 4.0, frames: 2, intervalSeconds: 3)
        XCTAssertEqual(governor.ceiling, 1)
        XCTAssertEqual(try XCTUnwrap(governor.sustainableIntervalSeconds), 4.6, accuracy: 0.01)
        // And it is capped at 4x the interval.
        governor.record(windowSeconds: 60, frames: 1, intervalSeconds: 3)
        XCTAssertEqual(try XCTUnwrap(governor.sustainableIntervalSeconds), 12, accuracy: 0.01)
    }

    func testPaceFloorClearsOnAComfortableStreakOnly() throws {
        var governor = ProcessingCeiling()
        governor.record(windowSeconds: 4.0, frames: 1, intervalSeconds: 3)
        XCTAssertNotNil(governor.sustainableIntervalSeconds)
        // One comfortable window must NOT release the floor — clearing on a
        // single cheap window oscillated the pace 12s↔23s on the bench.
        governor.record(windowSeconds: 4.0, frames: 1, intervalSeconds: 6)
        XCTAssertNotNil(governor.sustainableIntervalSeconds)
        // A streak does: the thermals (or the light) genuinely improved.
        governor.record(windowSeconds: 4.0, frames: 1, intervalSeconds: 6)
        XCTAssertNil(governor.sustainableIntervalSeconds)
    }

    func testProcessingCeilingShrinksBelowCeilingWhenSmallWindowOverruns() {
        // A window that carried fewer frames than the ceiling and STILL
        // overran must pull the ceiling below that count, not just below
        // the old ceiling.
        var governor = ProcessingCeiling()
        governor.record(windowSeconds: 4.0, frames: 3, intervalSeconds: 3)
        XCTAssertEqual(governor.ceiling, 2)
    }

    // MARK: Exposure divergence guard

    func testExposureDivergenceMath() {
        typealias W = CaptureExposureLog.WindowPerformance
        // Matching exposure: zero stops.
        XCTAssertEqual(try XCTUnwrap(W.exposureDivergenceStops(
            actualISO: 80, actualDuration: 1 / 60,
            targetISO: 80, targetDuration: 1 / 60)), 0, accuracy: 1e-9)
        // The field-test failure: commanded 1.0s ISO 59, delivered 1/60 ISO 80
        // — log2((80/60)/(59·1)) ≈ 5.47 stops under.
        XCTAssertEqual(try XCTUnwrap(W.exposureDivergenceStops(
            actualISO: 80, actualDuration: 1 / 60,
            targetISO: 59, targetDuration: 1.0)), 5.47, accuracy: 0.01)
        // Direction-agnostic: over-delivery diverges the same way.
        XCTAssertEqual(try XCTUnwrap(W.exposureDivergenceStops(
            actualISO: 59, actualDuration: 1.0,
            targetISO: 80, targetDuration: 1 / 60)), 5.47, accuracy: 0.01)
        // The ramp's own per-window step (1/3 stop) stays under the 0.5 guard.
        XCTAssertLessThan(try XCTUnwrap(W.exposureDivergenceStops(
            actualISO: 100, actualDuration: 0.01,
            targetISO: 126, targetDuration: 0.01)), 0.5)
        // Garbage in, nil out.
        XCTAssertNil(W.exposureDivergenceStops(
            actualISO: 0, actualDuration: 1, targetISO: 100, targetDuration: 1))
        XCTAssertNil(W.exposureDivergenceStops(
            actualISO: 100, actualDuration: 1, targetISO: 100, targetDuration: 0))
    }

    // MARK: Bank + decision log round-trip

    func testBankResolvesAllThreeEveryCycle() {
        var bank = BlendStrategyBank()
        let proposals = bank.resolveAll(ev: 11, at: 0, stats: nil)
        XCTAssertEqual(proposals.zone, 5)
        XCTAssertEqual(proposals.lumen, proposals.zone, "cold Lumen is exactly Zone")
        XCTAssertGreaterThanOrEqual(proposals.latitude, 1)
        XCTAssertLessThanOrEqual(proposals.latitude, 8)
    }

    func testStrategyDecisionSurvivesTheSessionCodec() throws {
        let decision = BlendStrategyDecision(
            algorithm: "lumen", sceneEV: 6.4,
            proposedZone: 2, proposedLatitude: 3, proposedLumen: 4,
            latitudeContinuous: 2.7, evVelocityStopsPerMinute: -0.8,
            lumenScore: 0.21, lumenBoost: 2,
            deviceCeiling: 4, intervalSeconds: 5,
            actuatedCount: 4,
            stats: FrameLuminanceStats(
                sampleCount: 4096, meanLuma: 0.02,
                p01: 0.0001, p05: 0.0004, p10: 0.001, p50: 0.01,
                fractionBelow: [0.1, 0.15, 0.2, 0.3, 0.45, 0.6],
                fractionAbove98: 0.001, iso: 2500, exposureDuration: 1.0, ev: 1.2))
        let window = CaptureExposureLog.WindowPerformance(
            requestedFrames: 4, missed: 2, droppedProcessingBehind: 3,
            failures: 1, partial: true,
            thermalStateAtStart: "fair", thermalStateAtClose: "serious",
            frameSpacingAvgSeconds: 1.1, frameSpacingMaxSeconds: 2.4,
            processingMillis: 840, actualIntervalSeconds: 6.2,
            intervalSeconds: 5, fileBytes: 24_000_000,
            exposureDivergenceStops: 5.5)
        let session = CaptureExposureLog.Session(
            sessionID: "test", deviceModel: "iPhone17,1",
            captureMode: "interval", blendMode: "auto",
            algorithm: "lumen", algorithmVersion: BlendStrategyID.version,
            cameraName: "Back Camera", captureWidth: 4032, captureHeight: 3024,
            intervalSeconds: 5,
            startedAt: Date(), endedAt: Date(),
            frames: [CaptureExposureLog.Entry(
                frameIndex: 1, capturedAt: Date(), iso: 2500,
                exposureDuration: 1.0, aperture: 1.78, ev: 1.2,
                blendCount: 4, strategy: decision, window: window)])
        let data = try CaptureExposureLog.makeEncoder().encode(session)
        let decoded = try CaptureExposureLog.makeDecoder()
            .decode(CaptureExposureLog.Session.self, from: data)
        XCTAssertEqual(decoded.algorithm, "lumen")
        XCTAssertEqual(decoded.cameraName, "Back Camera")
        XCTAssertEqual(decoded.intervalSeconds, 5)
        XCTAssertEqual(decoded.frames.first?.strategy, decision)
        XCTAssertEqual(decoded.frames.first?.window, window)
    }

    func testOldSessionJSONStillDecodes() throws {
        let legacy = """
        {"sessionID":"old","deviceModel":"iPhone13,3","captureMode":"interval",
         "blendMode":"auto","frames":[{"frameIndex":1,
         "capturedAt":"2026-08-01T10:00:00.000Z","iso":100,"blendCount":3}]}
        """.data(using: .utf8)!
        let decoded = try CaptureExposureLog.makeDecoder()
            .decode(CaptureExposureLog.Session.self, from: legacy)
        XCTAssertNil(decoded.algorithm)
        XCTAssertNil(decoded.frames.first?.strategy)
        XCTAssertEqual(decoded.frames.first?.blendCount, 3)
    }
}

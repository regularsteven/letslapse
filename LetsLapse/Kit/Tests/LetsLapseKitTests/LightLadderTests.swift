import XCTest
import CoreMedia
@testable import LetsLapseKit

/// The Light Ladder model — `docs/light-ladder.md` §3 and §8. Every number
/// here is computed from the wide lens the design quotes (f/1.78, ISO
/// 54–3072, 1 s ceiling), so a change to the built-in or to the servo's
/// maths shows up as a changed number, not a changed sentence.
final class LightLadderTests: XCTestCase {

    private let wide = HolyGrailRampEngine.HardwareLimits(
        minShutter: HolyGrailRampEngine.time(1.0 / 8000),
        maxShutter: HolyGrailRampEngine.time(1.0),
        minISO: 54, maxISO: 3072, aperture: 1.78)

    private let tele = HolyGrailRampEngine.HardwareLimits(
        minShutter: HolyGrailRampEngine.time(1.0 / 8000),
        maxShutter: HolyGrailRampEngine.time(1.0),
        minISO: 34, maxISO: 1600, aperture: 2.8)

    // MARK: The built-in

    func testBuiltInMatchesThePlan() {
        let ladder = LightLadder.builtIn
        XCTAssertTrue(ladder.isBuiltIn)
        XCTAssertTrue(ladder.isNormalized)
        XCTAssertEqual(ladder.rungs.map(\.name), ["Daylight", "Fading", "Dusk", "Night"])
        XCTAssertEqual(ladder.rungs.map(\.lowerBoundEV), [13, 8, 4, nil])
        XCTAssertEqual(ladder.rungs.map(\.intervalSeconds), [3, 2, 2, 2])
        XCTAssertEqual(ladder.rungs.map(\.blendFrames), [10, 5, 3, 1])
        // Decision D1: Night's shutter is capped, never pinned.
        XCTAssertEqual(ladder.rungs[3].shutter, .autoCapped(1))
        XCTAssertEqual(ladder.rungs.map(\.whiteBalance), [.auto, .auto, .auto, .auto])

        XCTAssertEqual(ladder.thresholdSummary, "4 rungs · EV 13 · 8 · 4 · darker")
        XCTAssertEqual(ladder.rungs[1].leverSummary, "ISO min · shutter auto ≤ 1 s · every 2 s · blend 5")
        XCTAssertEqual(ladder.rungs[3].shortLeverSummary, "ISO auto · auto ≤ 1 s · 2 s · blend off")
        XCTAssertEqual(ladder.rangeDescription(at: 0), "EV 13 and brighter")
        XCTAssertEqual(ladder.rangeDescription(at: 2), "EV 4 to 8")
        XCTAssertEqual(ladder.rangeDescription(at: 3), "below EV 4 · and darker")
        // The rail and ribbon draw spans of 3 · 5 · 4 · 6 inside 16 … −2.
        XCTAssertEqual(ladder.drawingSpans(), [3, 5, 4, 6])
    }

    /// The thesis, checked: every built-in boundary leaves the servo's settled
    /// exposure where it was. Releasing ISO at 8 → 4 changes nothing *at* the
    /// boundary — it matters deeper in — and dropping blend at 4 → night is
    /// pacing, not exposure.
    func testBuiltInBoundariesCarryTheExposureStraightThrough() {
        let ladder = LightLadder.builtIn
        XCTAssertNil(LightLadderAdvice.boundaryEffect(above: 0, in: ladder, format: wide))
        for index in 1..<ladder.rungs.count {
            XCTAssertEqual(
                LightLadderAdvice.boundaryEffect(above: index, in: ladder, format: wide),
                .pacingOnly, "boundary above \(ladder.rungs[index].name)")
        }
        XCTAssertEqual(
            LightLadderAdvice.boundaryStatement(above: 1, in: ladder, format: wide),
            "This boundary changes pacing only — the exposure carries straight through it.")
    }

    func testCloneGetsNewIdentityAndRemembersItsSource() {
        let copy = LightLadder.builtIn.cloned()
        XCTAssertFalse(copy.isBuiltIn)
        XCTAssertEqual(copy.name, "Bright & Fast, Dark & Slow (copy)")
        XCTAssertEqual(copy.clonedFromID, LightLadder.builtInID)
        XCTAssertEqual(copy.rungs.map(\.name), LightLadder.builtIn.rungs.map(\.name))
        XCTAssertTrue(Set(copy.rungs.map(\.id)).isDisjoint(with: LightLadder.builtIn.rungs.map(\.id)))
    }

    // MARK: Codable

    func testCodableRoundTripWithCompactChoices() throws {
        var ladder = LightLadder.builtIn.cloned(named: "Test")
        ladder.rungs[0].iso = .value(200)
        ladder.rungs[0].shutter = .value(0.5)
        ladder.rungs[1].whiteBalance = .locked
        let data = try JSONEncoder().encode(ladder)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"iso\":\"min\""), text)
        XCTAssertTrue(text.contains("\"iso\":200"), text)
        XCTAssertTrue(text.contains("\"shutter\":{\"cap\":1}"), text)
        XCTAssertTrue(text.contains("\"shutter\":0.5"), text)
        XCTAssertTrue(text.contains("\"whiteBalance\":\"locked\""), text)
        let back = try JSONDecoder().decode(LightLadder.self, from: data)
        XCTAssertEqual(back, ladder)
    }

    /// An older or hand-edited file: missing levers take their defaults,
    /// unknown keys are ignored, and normalisation repairs the order.
    func testDecodeToleratesOlderAndHandEditedFiles() throws {
        let json = """
        {"id":"11111111-2222-3333-4444-555555555555","name":"Hand made","colour":"amber",
         "rungs":[
           {"name":"Dark","lowerBoundEV":null,"intervalSeconds":4},
           {"name":"Bright","lowerBoundEV":12,"iso":"min","shutter":"auto","intervalSeconds":2,"blendFrames":6},
           {"name":"Also dark","lowerBoundEV":null,"intervalSeconds":9},
           {"name":"Mid","lowerBoundEV":6,"shutter":{"cap":0.5},"intervalSeconds":3,"blendFrames":2}
         ]}
        """
        let decoded = try JSONDecoder().decode(LightLadder.self, from: Data(json.utf8)).normalized()
        XCTAssertEqual(decoded.name, "Hand made")
        XCTAssertEqual(decoded.rungs.map(\.name), ["Bright", "Mid", "Dark"])
        XCTAssertEqual(decoded.rungs.map(\.lowerBoundEV), [12, 6, nil])
        XCTAssertEqual(decoded.rungs[2].whiteBalance, .auto)
        XCTAssertEqual(decoded.rungs[2].blendFrames, 1)
        XCTAssertEqual(decoded.rungs[1].shutter, .autoCapped(0.5))
    }

    func testNormalizedRestoresOrderAndTheUnboundedLast() {
        let messy = LightLadder(name: "Messy", rungs: [
            Rung(name: "A", lowerBoundEV: 4, intervalSeconds: 2, blendFrames: 1),
            Rung(name: "C", lowerBoundEV: 13, intervalSeconds: 2, blendFrames: 1),
            Rung(name: "D", lowerBoundEV: 8, intervalSeconds: 2, blendFrames: 1),
            Rung(name: "E", lowerBoundEV: 8, intervalSeconds: 2, blendFrames: 1),
        ])
        XCTAssertFalse(messy.isNormalized)
        let fixed = messy.normalized()
        XCTAssertEqual(fixed.rungs.map(\.name), ["C", "D", "A"])
        // A bounded last rung becomes "and darker".
        XCTAssertEqual(fixed.rungs.map(\.lowerBoundEV), [13, 8, nil])
        XCTAssertTrue(fixed.isNormalized)
    }

    // MARK: The exposure box

    func testPinsBecomeMinEqualsMaxClampedToTheFormat() {
        let rung = Rung(name: "Locked", lowerBoundEV: nil, iso: .value(20), shutter: .value(2),
                        intervalSeconds: 5, blendFrames: 1)
        XCTAssertTrue(rung.isManualLock)
        let box = rung.exposureBox(within: wide)
        // 2 s asked; the hardware's 1 s wins.
        XCTAssertEqual(box.minShutter.seconds, 1, accuracy: 1e-6)
        XCTAssertEqual(box.maxShutter.seconds, 1, accuracy: 1e-6)
        // ISO 20 asked; the lens floor of 54 wins.
        XCTAssertEqual(box.minISO, 54)
        XCTAssertEqual(box.maxISO, 54)
        XCTAssertEqual(box.aperture, wide.aperture)
    }

    func testShutterCeilingSharesTheWindowAcrossBlendFrames() {
        let ladder = LightLadder.builtIn
        // Daylight: (3 − 0.3) ÷ 10 frames.
        XCTAssertEqual(ladder.rungs[0].effectiveShutterCeiling(within: wide), 0.27, accuracy: 1e-6)
        // Fading: (2 − 0.3) ÷ 5, under its 1 s cap.
        XCTAssertEqual(ladder.rungs[1].effectiveShutterCeiling(within: wide), 0.34, accuracy: 1e-6)
        // Dusk: (2 − 0.3) ÷ 3.
        XCTAssertEqual(ladder.rungs[2].effectiveShutterCeiling(within: wide), 1.7 / 3, accuracy: 1e-6)
        // Night: one frame gets the window; the 1 s cap is what's left.
        XCTAssertEqual(ladder.rungs[3].effectiveShutterCeiling(within: wide), 1, accuracy: 1e-6)
        // A cap tighter than the share wins.
        let tight = Rung(name: "Tight", lowerBoundEV: nil, shutter: .autoCapped(0.1), intervalSeconds: 2, blendFrames: 1)
        XCTAssertEqual(tight.effectiveShutterCeiling(within: wide), 0.1, accuracy: 1e-6)
    }

    func testSymbolicISOResolvesPerLens() {
        let minRung = Rung(name: "Min", lowerBoundEV: nil, iso: .min, intervalSeconds: 2, blendFrames: 1)
        XCTAssertEqual(minRung.exposureBox(within: wide).maxISO, 54)
        XCTAssertEqual(minRung.exposureBox(within: tele).maxISO, 34)
        let maxRung = Rung(name: "Max", lowerBoundEV: nil, iso: .max, intervalSeconds: 2, blendFrames: 1)
        XCTAssertEqual(maxRung.exposureBox(within: wide).minISO, 3072)
        let autoRung = Rung(name: "Auto", lowerBoundEV: nil, iso: .auto, intervalSeconds: 2, blendFrames: 1)
        let box = autoRung.exposureBox(within: tele)
        XCTAssertEqual(box.minISO, 34)
        XCTAssertEqual(box.maxISO, 1600)
    }

    // MARK: Selection

    func testSelectorDescendsAndClimbsTheBuiltIn() {
        var selector = LightLadderSelector(ladder: .builtIn)
        func feed(_ ev: Double, times: Int = 3) -> Int {
            var index = 0
            for _ in 0..<times { index = selector.resolve(ev: ev) }
            return index
        }
        XCTAssertEqual(feed(14), 0)          // Daylight
        XCTAssertEqual(feed(12), 1)          // Fading, once the average is under 12.5
        XCTAssertEqual(feed(7), 2)           // Dusk
        XCTAssertEqual(feed(3), 3)           // Night
        XCTAssertEqual(feed(4.6), 2)         // climbing: 4.6 clears 4 + 0.5
        XCTAssertEqual(feed(8.4), 2)         // 8.4 is inside Fading but not past 8.5 — hold
        XCTAssertEqual(feed(8.6), 1)         // Fading
        XCTAssertEqual(feed(13.6), 0)        // Daylight
        XCTAssertEqual(selector.currentRung?.name, "Daylight")
    }

    func testSelectorHoldsInsideTheBandAndSwitchesPastIt() {
        var selector = LightLadderSelector(ladder: .builtIn)
        for _ in 0..<3 { selector.resolve(ev: 10) }
        XCTAssertEqual(selector.currentIndex, 1)
        // Just inside the band below Fading's 8: hold.
        for _ in 0..<3 {
            XCTAssertEqual(selector.resolve(ev: 7.6), 1)
            XCTAssertFalse(selector.changedOnLastResolve)
        }
        // Past it: switch, and say so exactly once.
        var changes = 0
        for _ in 0..<3 {
            _ = selector.resolve(ev: 7.4)
            if selector.changedOnLastResolve { changes += 1 }
        }
        XCTAssertEqual(selector.currentIndex, 2)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(selector.lastSmoothedEV ?? 0, 7.4, accuracy: 1e-9)
    }

    func testSelectorWalksMultipleRungsAsTheAverageFollowsALightCrash() {
        var selector = LightLadderSelector(ladder: .builtIn)
        for _ in 0..<3 { selector.resolve(ev: 14) }
        // 14, 14, 3 → 10.3; 14, 3, 3 → 6.7; 3, 3, 3 → 3.
        XCTAssertEqual(selector.resolve(ev: 3), 1)
        XCTAssertEqual(selector.resolve(ev: 3), 2)
        XCTAssertEqual(selector.resolve(ev: 3), 3)
    }

    func testSelectorHoldsOnNoReadingAndSeedsMidTableWithNoHistory() {
        var cold = LightLadderSelector(ladder: .builtIn)
        XCTAssertEqual(cold.resolve(ev: nil), 2)
        XCTAssertEqual(cold.resolve(ev: nil), 2)
        var warm = LightLadderSelector(ladder: .builtIn)
        XCTAssertEqual(warm.resolve(ev: 14), 0)
        XCTAssertEqual(warm.resolve(ev: nil), 0)
        XCTAssertFalse(warm.changedOnLastResolve)
        XCTAssertEqual(warm.resolve(ev: .nan), 0)
    }

    func testSingleRungLadderAlwaysSelectsIt() {
        let one = LightLadder(name: "One", rungs: [Rung(name: "All", lowerBoundEV: 9, intervalSeconds: 2, blendFrames: 2)])
        var selector = LightLadderSelector(ladder: one)
        XCTAssertNil(selector.ladder.rungs[0].lowerBoundEV)
        XCTAssertEqual(selector.resolve(ev: 15), 0)
        XCTAssertEqual(selector.resolve(ev: -3), 0)
        XCTAssertEqual(one.rangeDescription(at: 0), "EV 9 and brighter")
        XCTAssertEqual(one.normalized().rangeDescription(at: 0), "all light")
    }

    // MARK: Pacing and the governor

    func testPacingYieldsDepthFirstThenStretchesAndNeverShortens() {
        let dusk = LightLadder.builtIn.rungs[2]
        var ceiling = ProcessingCeiling(maximum: 10)
        XCTAssertNil(LightLadderPacing.apply(rung: dusk, ceiling: ceiling).yield)

        // One over-budget window: depth steps to one below what it carried.
        ceiling.record(windowSeconds: 2.5, frames: 3, intervalSeconds: 2)
        var pacing = LightLadderPacing.apply(rung: dusk, ceiling: ceiling)
        XCTAssertEqual(pacing.blendFrames, 2)
        XCTAssertEqual(pacing.intervalSeconds, 2)
        XCTAssertEqual(pacing.yield, .depth(asked: 3, applied: 2))
        XCTAssertEqual(pacing.readoutLine(rungName: "Dusk", reason: "thermal"),
                       "Dusk · every 2 s · blend 3 → 2, thermal")

        // Another: the step would land below a real blend, so pacing stretches.
        ceiling.record(windowSeconds: 2.5, frames: 2, intervalSeconds: 2)
        pacing = LightLadderPacing.apply(rung: dusk, ceiling: ceiling)
        XCTAssertEqual(pacing.intervalSeconds, 2.875, accuracy: 1e-9)
        XCTAssertEqual(pacing.yield, .pace(asked: 2, applied: 2.875))
        XCTAssertEqual(pacing.readoutLine(rungName: "Dusk"),
                       "Dusk · every 2 s → 2.9 s, processing · blend off")

        // A sustainable pace shorter than the rung's own never shortens it.
        var relaxed = ProcessingCeiling(maximum: 10)
        relaxed.record(windowSeconds: 1.2, frames: 1, intervalSeconds: 1)
        XCTAssertNotNil(relaxed.sustainableIntervalSeconds)
        XCTAssertLessThan(relaxed.sustainableIntervalSeconds ?? 0, dusk.intervalSeconds)
        XCTAssertEqual(LightLadderPacing.apply(rung: dusk, ceiling: relaxed).intervalSeconds, 2)
    }

    func testProcessingCeilingHonoursItsMaximum() {
        XCTAssertEqual(ProcessingCeiling().maximum, ZoneBlendStrategy.bands[0].frames)
        XCTAssertEqual(ProcessingCeiling().ceiling, 8)
        var tall = ProcessingCeiling(maximum: 10)
        XCTAssertEqual(tall.ceiling, 10)
        tall.record(windowSeconds: 3.5, frames: 10, intervalSeconds: 3)
        XCTAssertEqual(tall.ceiling, 9)
        for _ in 0..<6 { tall.record(windowSeconds: 1, frames: 9, intervalSeconds: 3) }
        XCTAssertEqual(tall.ceiling, 10, "grows back to the rung's ask and no further")

        // A rung change mid-run: lowering the ask clamps, raising it trusts.
        tall.maximum = 3
        XCTAssertEqual(tall.ceiling, 3)
        tall.record(windowSeconds: 3.5, frames: 3, intervalSeconds: 3)
        XCTAssertEqual(tall.ceiling, 2)
        tall.maximum = 5
        XCTAssertEqual(tall.ceiling, 5, "a raised ask is trusted until a window overruns")
        tall.maximum = 0
        XCTAssertEqual(tall.maximum, 1)
        XCTAssertEqual(tall.ceiling, 1)
    }

    // MARK: Advice

    func testDuskFitsAndSaysWhatTheWindowShareIs() {
        let messages = LightLadderAdvice.messages(for: 2, in: .builtIn, format: wide)
        XCTAssertEqual(messages.map(\.kind), [.fits, .note])
        XCTAssertEqual(messages[0].text,
            "Shutter 0.57 s and blend 3 both fit a 2 s interval — 0.3 s settle margin kept, ceiling 7 frames.")
        XCTAssertEqual(messages[1].text,
            "3 frames share a 2 s window, so each gets 0.57 s at most — the 1 s shutter only applies once blend is off.")
        // Night: one frame, the cap applies, nothing to note.
        let night = LightLadderAdvice.messages(for: 3, in: .builtIn, format: wide)
        XCTAssertEqual(night.map(\.kind), [.fits])
        XCTAssertEqual(night[0].text,
            "Shutter 1 s and no stacking both fit a 2 s interval — 0.3 s settle margin kept, ceiling 7 frames.")
    }

    /// Decision D1's evidence: the handoff's Night rung pinned 1 s from EV 4.
    func testPinnedNightShutterIsFlaggedBelowTheFloorAndAsAJump() {
        var ladder = LightLadder.builtIn.cloned()
        ladder.rungs[3].shutter = .value(1)
        let messages = LightLadderAdvice.messages(for: 3, in: ladder, format: wide)
        XCTAssertEqual(messages.map(\.kind), [.fits, .warning, .warning])
        XCTAssertEqual(messages[1].text,
            "At EV 4 this box cannot close down far enough — frames run 1.4 stops over until EV 2.6. A 1 s shutter here needs ISO 20, below this lens's 54.")
        XCTAssertEqual(messages[2].text,
            "Night leaves the shutter 1.4 stops from where Dusk settles. The servo will walk that over about 5 windows — the frames in between are neither look. Consider bringing the two rungs' shutter closer.")
        guard case .jump(let stops, let windows, let lever)? = LightLadderAdvice.boundaryEffect(above: 3, in: ladder, format: wide) else {
            return XCTFail("expected a jump")
        }
        // ISO 54 at 1 s against the 0.198 s·ISO100 the scene wants: log2(0.54 / 0.198).
        XCTAssertEqual(stops, log2(0.54 / (1.78 * 1.78 / 16)), accuracy: 0.01)
        XCTAssertEqual(windows, 5)
        XCTAssertEqual(lever, "shutter")
    }

    func testISOMinRungUnderexposesAtItsDimEdge() {
        let ladder = LightLadder(name: "Floor", rungs: [
            Rung(name: "Bright", lowerBoundEV: 0, iso: .min, intervalSeconds: 2, blendFrames: 1),
            Rung(name: "Dark", lowerBoundEV: nil, intervalSeconds: 2, blendFrames: 1),
        ])
        let messages = LightLadderAdvice.messages(for: 0, in: ladder, format: wide)
        XCTAssertEqual(messages.map(\.kind), [.fits, .warning])
        XCTAssertEqual(messages[1].text,
            "At EV 0 this box cannot open up far enough — frames run 2.6 stops under from EV 2.6 down. ISO min holds the sensor at 54; let ISO go auto here.")
        // The boundary below it releases ISO by 2.6 stops at once — a jump.
        guard case .jump(_, let windows, let lever)? = LightLadderAdvice.boundaryEffect(above: 1, in: ladder, format: wide) else {
            return XCTFail("expected a jump")
        }
        XCTAssertEqual(lever, "ISO")
        XCTAssertEqual(windows, 8)
    }

    func testBlendBeyondTheWindowIsAWarningAndAShutterBeyondItToo() {
        let greedy = LightLadder(name: "Greedy", rungs: [
            Rung(name: "Fast", lowerBoundEV: nil, shutter: .autoCapped(1), intervalSeconds: 1, blendFrames: 8),
        ])
        let messages = LightLadderAdvice.messages(for: 0, in: greedy, format: wide)
        XCTAssertEqual(messages.map(\.kind), [.warning, .warning])
        XCTAssertTrue(messages[0].text.hasPrefix("Shutter 1 s does not fit a 1 s interval"), messages[0].text)
        XCTAssertTrue(messages[1].text.contains("the device will take 3 at most"), messages[1].text)
        XCTAssertEqual(LightLadderAdvice.blendCeiling(intervalSeconds: 2), 7)
        XCTAssertEqual(LightLadderAdvice.blendCeiling(intervalSeconds: 3), 11)
    }

    // MARK: Formatting

    func testFormatting() {
        XCTAssertEqual(LightLadderFormat.ev(13), "13")
        XCTAssertEqual(LightLadderFormat.ev(4.5), "4.5")
        XCTAssertEqual(LightLadderFormat.ev(-2), "−2")
        XCTAssertEqual(LightLadderFormat.ev(2.5527), "2.6")
        XCTAssertEqual(LightLadderFormat.seconds(3), "3 s")
        XCTAssertEqual(LightLadderFormat.seconds(2.875), "2.9 s")
        XCTAssertEqual(LightLadderFormat.seconds(0.5), "1/2 s")
        XCTAssertEqual(LightLadderFormat.seconds(0.125), "1/8 s")
        XCTAssertEqual(LightLadderFormat.seconds(1.0 / 2000), "1/2000 s")
        XCTAssertEqual(LightLadderFormat.seconds(0.37), "0.37 s")
        XCTAssertEqual(LightLadderFormat.seconds(0), "0 s")
    }
}

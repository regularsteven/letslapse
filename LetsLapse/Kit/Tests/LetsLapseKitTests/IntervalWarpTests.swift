import XCTest
@testable import LetsLapseKit

/// The interval warp compiler — the stills timeline's window schedule.
final class IntervalWarpTests: XCTestCase {

    private func uniformSeconds(_ count: Int, spacing: Double = 1) -> [Double] {
        (0..<count).map { Double($0) * spacing }
    }

    // MARK: - Parity with the slider it absorbs

    /// An untouched timeline must render what the whole-shoot BLEND slider
    /// always rendered: the same windows `WindowSchedule.make` builds.
    func testATrivialTimelineMatchesTheConstantSchedule() throws {
        for (count, depth) in [(100, 1), (100, 5), (101, 5), (7, 3), (12, 60)] {
            let compiled = try XCTUnwrap(IntervalWarp.compile(
                frameSeconds: uniformSeconds(count), hasClock: false,
                bounds: [0, Double(count)], depths: [Double(depth)], outputFPS: 30))
            XCTAssertEqual(
                compiled.windows,
                WindowSchedule.make(totalInputFrames: count, ramp: .constant(depth)),
                "count \(count) depth \(depth)")
            XCTAssertEqual(compiled.windows.reduce(0, +), count, "never a trim")
            XCTAssertNil(compiled.presentationSeconds, "no clock, no retiming")
        }
    }

    /// And an untouched timeline over a CLOCK keeps phase 1's honest layout:
    /// the exact presentation times `FrameTimeMapping` produces.
    func testATrivialClockTimelineKeepsTheCaptureClockLayout() throws {
        // Depth 1, uneven spacing — every frame is a window.
        let seconds: [Double] = [0, 10, 20, 40, 45, 90]
        let compiled = try XCTUnwrap(IntervalWarp.compile(
            frameSeconds: seconds, hasClock: true,
            bounds: [0, 90], depths: [1], outputFPS: 30))
        let expected = try XCTUnwrap(
            FrameTimeMapping.presentationSeconds(frameTimes: seconds, outputFPS: 30))
        let got = try XCTUnwrap(compiled.presentationSeconds)
        XCTAssertEqual(got.count, expected.count)
        for (a, b) in zip(got, expected) {
            XCTAssertEqual(a, b, accuracy: 1e-9)
        }
    }

    // MARK: - Depth changes across the shoot

    /// A window's depth is its FIRST frame's stretch — the boundary switches
    /// the schedule where the frames really cross it.
    func testDepthSwitchesAtTheStretchBoundary() throws {
        // 10 frames at 1s spacing; first 5 seconds at depth 1, rest depth 5.
        let compiled = try XCTUnwrap(IntervalWarp.compile(
            frameSeconds: uniformSeconds(10), hasClock: false,
            bounds: [0, 5, 10], depths: [1, 5], outputFPS: 30))
        XCTAssertEqual(compiled.windows, [1, 1, 1, 1, 1, 5])
        XCTAssertEqual(compiled.stretchWindows, [5, 1])
    }

    /// A stretch shorter than its depth folds its frames into one window and
    /// the walk carries on — depth is a ceiling, not a demand.
    func testAShortTailClampsItsLastWindow() throws {
        let compiled = try XCTUnwrap(IntervalWarp.compile(
            frameSeconds: uniformSeconds(8), hasClock: false,
            bounds: [0, 8], depths: [3], outputFPS: 30))
        XCTAssertEqual(compiled.windows, [3, 3, 2])
    }

    /// Fractional and sub-1 depths are cleaned up rather than obeyed.
    func testDepthsAreRoundedAndFloored() throws {
        let compiled = try XCTUnwrap(IntervalWarp.compile(
            frameSeconds: uniformSeconds(6), hasClock: false,
            bounds: [0, 6], depths: [0.25], outputFPS: 30))
        XCTAssertEqual(compiled.windows, [Int](repeating: 1, count: 6))
    }

    // MARK: - Authored pacing on the capture clock

    /// The point of the per-stretch layout: a depth change re-paces the clip
    /// (fewer windows = less clip time), while INSIDE a stretch the windows
    /// keep their real capture spacing proportionally.
    func testEachStretchKeepsItsOwnProportionalClock() throws {
        // 8 frames: first 4 evenly at 0,1,2,3 (depth 1); last 4 at
        // 10,11,12,33 (depth 2 → 2 windows starting at 10 and 12).
        let seconds: [Double] = [0, 1, 2, 3, 10, 11, 12, 33]
        let fps = 10.0
        let compiled = try XCTUnwrap(IntervalWarp.compile(
            frameSeconds: seconds, hasClock: true,
            bounds: [0, 5, 33], depths: [1, 2], outputFPS: fps))
        XCTAssertEqual(compiled.windows, [1, 1, 1, 1, 2, 2])
        let pres = try XCTUnwrap(compiled.presentationSeconds)
        // First run: 4 windows over (4-1)/fps, even spacing preserved.
        XCTAssertEqual(pres[0], 0, accuracy: 1e-9)
        XCTAssertEqual(pres[1], 1 / fps, accuracy: 1e-9)
        XCTAssertEqual(pres[3], 3 / fps, accuracy: 1e-9)
        // Second run anchors at its cumulative start (4 windows before it).
        XCTAssertEqual(pres[4], 4 / fps, accuracy: 1e-9)
        XCTAssertEqual(pres[5], 5 / fps, accuracy: 1e-9)
        // Monotonic throughout.
        for pair in zip(pres.dropFirst(), pres) {
            XCTAssertGreaterThan(pair.0, pair.1)
        }
    }

    /// A burst whose stamps collapse into one instant can't be laid out
    /// proportionally — it ticks at the constant rate instead of dividing by
    /// zero.
    func testAZeroSpanRunTicksConstantly() throws {
        let seconds: [Double] = [0, 0, 0, 5, 6]
        let compiled = try XCTUnwrap(IntervalWarp.compile(
            frameSeconds: seconds, hasClock: true,
            bounds: [0, 3, 6], depths: [1, 1], outputFPS: 10))
        let pres = try XCTUnwrap(compiled.presentationSeconds)
        XCTAssertEqual(pres[0], 0, accuracy: 1e-9)
        XCTAssertEqual(pres[1], 0.1, accuracy: 1e-9)
        XCTAssertEqual(pres[2], 0.2, accuracy: 1e-9)
        for pair in zip(pres.dropFirst(), pres) {
            XCTAssertGreaterThan(pair.0, pair.1)
        }
    }

    // MARK: - Refusals

    func testWhatCannotBeASequenceReturnsNil() {
        XCTAssertNil(IntervalWarp.compile(
            frameSeconds: [0], hasClock: false, bounds: [0, 1], depths: [1], outputFPS: 30))
        XCTAssertNil(IntervalWarp.compile(
            frameSeconds: uniformSeconds(5), hasClock: false,
            bounds: [0, 5], depths: [1, 2], outputFPS: 30),
            "bounds/depths mismatch")
        XCTAssertNil(IntervalWarp.compile(
            frameSeconds: uniformSeconds(5), hasClock: false,
            bounds: [0, 5], depths: [1], outputFPS: 0))
    }
}

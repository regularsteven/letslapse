import XCTest
@testable import LetsLapseKit

/// The stills time axis every frame scrubber shares.
final class FrameAxisTests: XCTestCase {

    // MARK: - Which axis the inputs earn

    func testACoveringClockBecomesTheAxis() {
        let axis = FrameAxis(frameCount: 3, elapsedSeconds: [0, 10, 40], uniformDuration: 99)
        XCTAssertTrue(axis.hasClock)
        XCTAssertEqual(axis.span, 40)
    }

    /// A sidecar that doesn't describe exactly these frames is ignored rather
    /// than guessed at — same contract as every other sidecar reader.
    func testAMismatchedClockFallsThroughToUniform() {
        let axis = FrameAxis(frameCount: 5, elapsedSeconds: [0, 10, 40], uniformDuration: 100)
        XCTAssertFalse(axis.hasClock)
        XCTAssertEqual(axis.span, 100)
    }

    /// A clock whose last stamp is 0 (every frame in the same instant) says
    /// nothing about spacing — it can't be an axis.
    func testAZeroSpanClockFallsThrough() {
        let axis = FrameAxis(frameCount: 2, elapsedSeconds: [0, 0])
        XCTAssertFalse(axis.hasClock)
        XCTAssertEqual(axis.span, 0)
    }

    func testNoInputsMeansAFrameNumberAxis() {
        let axis = FrameAxis(frameCount: 4)
        XCTAssertFalse(axis.hasClock)
        XCTAssertEqual(axis.span, 0)
    }

    // MARK: - Position → frame (the scrubber mapping)

    /// The exact mapping the photo editor's strip has always used: linear in
    /// index space, nearest frame, clamped.
    func testPositionsMapLinearlyAcrossTheIndices() {
        let axis = FrameAxis(frameCount: 5, uniformDuration: 100)
        XCTAssertEqual(axis.index(atPosition: 0), 0)
        XCTAssertEqual(axis.index(atPosition: 0.25), 1)
        XCTAssertEqual(axis.index(atPosition: 0.5), 2)
        XCTAssertEqual(axis.index(atPosition: 1), 4)
        XCTAssertEqual(axis.index(atPosition: -0.5), 0)
        XCTAssertEqual(axis.index(atPosition: 1.5), 4)
    }

    /// Index-linear even on a clock axis: a scrubber's travel visits every
    /// frame equally however unevenly they were captured.
    func testAClockDoesNotBendThePositionMapping() {
        let axis = FrameAxis(frameCount: 3, elapsedSeconds: [0, 1, 100])
        XCTAssertEqual(axis.index(atPosition: 0.5), 1)
    }

    /// The contract the photo editor's one-frame step buttons stand on: a frame
    /// index turned back into a 0…1 position — `Double(index) / (count - 1)` —
    /// lands on exactly that frame again, on a clock axis as much as a uniform
    /// one. Without this a step of one would sometimes land two frames on, or
    /// on the frame it started from, on a long shoot.
    func testAnIndexRoundTripsThroughItsPosition() {
        for count in [2, 3, 60, 250, 999] {
            let axis = FrameAxis(frameCount: count, uniformDuration: 3600)
            for index in 0..<count {
                let position = Double(index) / Double(count - 1)
                XCTAssertEqual(axis.index(atPosition: position), index,
                               "frame \(index) of \(count)")
            }
        }
        // The uneven capture clock must not bend it either.
        let clocked = FrameAxis(frameCount: 4, elapsedSeconds: [0, 1, 2, 900])
        for index in 0..<4 {
            XCTAssertEqual(clocked.index(atPosition: Double(index) / 3), index)
        }
    }

    func testASingleFrameAlwaysAnswersZero() {
        let axis = FrameAxis(frameCount: 1, elapsedSeconds: [0], uniformDuration: 10)
        XCTAssertEqual(axis.index(atPosition: 0.9), 0)
        XCTAssertEqual(axis.second(atIndex: 0), 0)
        XCTAssertEqual(axis.index(atSecond: 5), 0)
    }

    // MARK: - Frame → moment

    func testAClockAnswersItsOwnStamps() {
        let axis = FrameAxis(frameCount: 3, elapsedSeconds: [0, 10, 40])
        XCTAssertEqual(axis.second(atIndex: 0), 0)
        XCTAssertEqual(axis.second(atIndex: 1), 10)
        XCTAssertEqual(axis.second(atIndex: 2), 40)
        XCTAssertEqual(axis.second(atIndex: 99), 40, "clamped, not crashed")
    }

    func testAUniformAxisInterpolatesTheSpan() {
        let axis = FrameAxis(frameCount: 5, uniformDuration: 100)
        XCTAssertEqual(axis.second(atIndex: 0), 0)
        XCTAssertEqual(axis.second(atIndex: 2), 50)
        XCTAssertEqual(axis.second(atIndex: 4), 100)
    }

    // MARK: - Moment → frame (the timeline mapping)

    /// A still holds until the next one lands, so the frame at a moment is
    /// the last one captured at or before it.
    func testTheFrameAtAMomentIsTheLastOneCapturedBeforeIt() {
        let axis = FrameAxis(frameCount: 4, elapsedSeconds: [0, 10, 20, 60])
        XCTAssertEqual(axis.index(atSecond: 0), 0)
        XCTAssertEqual(axis.index(atSecond: 9.9), 0)
        XCTAssertEqual(axis.index(atSecond: 10), 1)
        XCTAssertEqual(axis.index(atSecond: 59), 2)
        XCTAssertEqual(axis.index(atSecond: 60), 3)
        XCTAssertEqual(axis.index(atSecond: 1000), 3)
        XCTAssertEqual(axis.index(atSecond: -5), 0)
    }

    func testAUniformAxisAnswersTheSameContract() {
        let axis = FrameAxis(frameCount: 5, uniformDuration: 100)
        XCTAssertEqual(axis.index(atSecond: 0), 0)
        XCTAssertEqual(axis.index(atSecond: 24.9), 0)
        XCTAssertEqual(axis.index(atSecond: 25), 1)
        XCTAssertEqual(axis.index(atSecond: 99), 3)
        XCTAssertEqual(axis.index(atSecond: 100), 4)
    }

    func testASpanlessAxisMapsEveryMomentToTheFirstFrame() {
        let axis = FrameAxis(frameCount: 4)
        XCTAssertEqual(axis.index(atSecond: 3), 0)
    }

    // MARK: - The coverage gate

    func testTheSidecarCoverageGateHasOneDefinition() {
        let stamps = FrameTimestamps(entries: (0..<3).map {
            FrameTimestamps.Entry(
                frame: $0,
                captureTime: Date(timeIntervalSince1970: 1_700_000_000 + Double($0) * 5),
                shutter: 0.01, iso: 100)
        })
        XCTAssertEqual(stamps.elapsedSeconds(coveringExactly: 3), [0, 5, 10])
        XCTAssertNil(stamps.elapsedSeconds(coveringExactly: 2))
        XCTAssertNil(stamps.elapsedSeconds(coveringExactly: 4))
    }
}

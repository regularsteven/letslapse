import XCTest
@testable import LetsLapseKit

final class BlendProgressPlanTests: XCTestCase {
    func testClipBandsPartitionBlendRange() {
        let plan = BlendProgressPlan.make(clipFrames: [100, 300, 100], hasStitch: true, hasGrade: false)
        XCTAssertEqual(plan.clipBands.count, 3)
        XCTAssertEqual(plan.clipBands.first?.lowerBound, 0)
        XCTAssertEqual(plan.clipBands.last?.upperBound ?? 0, 0.90, accuracy: 1e-9)
        for (a, b) in zip(plan.clipBands, plan.clipBands.dropFirst()) {
            XCTAssertEqual(a.upperBound, b.lowerBound, accuracy: 1e-9)
        }
        // 300-frame clip owns 3/5 of the blend band.
        let middle = plan.clipBands[1]
        XCTAssertEqual(middle.upperBound - middle.lowerBound, 0.90 * 0.6, accuracy: 1e-9)
    }

    func testMonotonicAcrossClipBoundaries() {
        let plan = BlendProgressPlan.make(clipFrames: [50, 200, 10, 400], hasStitch: true, hasGrade: true)
        for index in 0..<3 {
            let endOfClip = plan.globalFraction(clip: index, localFraction: 1)
            let startOfNext = plan.globalFraction(clip: index + 1, localFraction: 0)
            XCTAssertEqual(endOfClip, startOfNext, accuracy: 1e-9)
        }
        // Local fractions never map beyond the blend band.
        XCTAssertEqual(plan.globalFraction(clip: 3, localFraction: 1), 0.88, accuracy: 1e-9)
        XCTAssertEqual(plan.globalFraction(clip: 3, localFraction: 2), 0.88, accuracy: 1e-9)
        XCTAssertEqual(plan.globalFraction(clip: 0, localFraction: -1), 0)
    }

    func testTailBandsChain() {
        let both = BlendProgressPlan.make(clipFrames: [10], hasStitch: true, hasGrade: true)
        XCTAssertEqual(both.stitchBand, 0.88...0.96)
        XCTAssertEqual(both.gradeBand, 0.96...0.99)
        XCTAssertEqual(both.saveBand, 0.99...1.0)
        XCTAssertEqual(both.tailStageCount, 3)

        let stitchOnly = BlendProgressPlan.make(clipFrames: [10], hasStitch: true, hasGrade: false)
        XCTAssertEqual(stitchOnly.stitchBand, 0.90...0.98)
        XCTAssertNil(stitchOnly.gradeBand)
        XCTAssertEqual(stitchOnly.saveBand, 0.98...1.0)
        XCTAssertEqual(stitchOnly.tailStageCount, 2)

        let gradeOnly = BlendProgressPlan.make(clipFrames: [10], hasStitch: false, hasGrade: true)
        XCTAssertNil(gradeOnly.stitchBand)
        XCTAssertEqual(gradeOnly.gradeBand, 0.95...0.99)

        let neither = BlendProgressPlan.make(clipFrames: [10], hasStitch: false, hasGrade: false)
        XCTAssertNil(neither.stitchBand)
        XCTAssertNil(neither.gradeBand)
        XCTAssertEqual(neither.saveBand, 0.98...1.0)
        XCTAssertEqual(neither.tailStageCount, 1)
    }

    func testZeroAndNegativeWeightsGetMeanWeight() {
        let plan = BlendProgressPlan.make(clipFrames: [0, 100, -5, 300], hasStitch: true, hasGrade: false)
        XCTAssertEqual(plan.clipFrames, [200, 100, 200, 300])
        XCTAssertEqual(plan.totalFrames, 800)
    }

    func testAllBadOrEmptyWeightsFallBack() {
        let allBad = BlendProgressPlan.make(clipFrames: [0, 0], hasStitch: true, hasGrade: false)
        XCTAssertEqual(allBad.clipFrames, [1, 1])

        let empty = BlendProgressPlan.make(clipFrames: [], hasStitch: false, hasGrade: false)
        XCTAssertEqual(empty.clipFrames, [1])
        XCTAssertEqual(empty.clipBands, [0...0.98])
    }

    func testSingleClipDegenerateCase() {
        let plan = BlendProgressPlan.make(clipFrames: [500], hasStitch: false, hasGrade: false)
        XCTAssertEqual(plan.clipBands, [0...0.98])
        XCTAssertEqual(plan.globalFraction(clip: 0, localFraction: 0.5), 0.49, accuracy: 1e-9)
        XCTAssertEqual(plan.framesDone(clip: 0, localFraction: 0.5), 250)
    }

    func testFramesDoneAccumulatesAndClamps() {
        let plan = BlendProgressPlan.make(clipFrames: [100, 200, 300], hasStitch: true, hasGrade: false)
        XCTAssertEqual(plan.framesDone(clip: 0, localFraction: 0), 0)
        XCTAssertEqual(plan.framesDone(clip: 1, localFraction: 0.5), 200)
        XCTAssertEqual(plan.framesDone(clip: 2, localFraction: 1), 600)
        XCTAssertEqual(plan.framesDone(clip: 2, localFraction: 5), 600)
        XCTAssertEqual(plan.framesDone(clip: 9, localFraction: 1), 0)
    }

    /// Real weights from the Tram Tester project's sequence.json: three long
    /// 30 fps base segments and two ~1.3 s 120 fps bursts. Frame weighting
    /// gives the bursts ~1.3% of the bar each, not an equal fifth.
    func testTramTesterFixture() {
        let plan = BlendProgressPlan.make(
            clipFrames: [6562, 156, 2417, 155, 2272], hasStitch: true, hasGrade: true)
        XCTAssertEqual(plan.totalFrames, 11562)
        let tops = plan.clipBands.map(\.upperBound)
        XCTAssertEqual(tops[0], 0.4994, accuracy: 0.0005)
        XCTAssertEqual(tops[1], 0.5113, accuracy: 0.0005)
        XCTAssertEqual(tops[2], 0.6953, accuracy: 0.0005)
        XCTAssertEqual(tops[3], 0.7071, accuracy: 0.0005)
        XCTAssertEqual(tops[4], 0.88, accuracy: 1e-9)
        // The first burst spans ~1.2% of the bar.
        let burst = plan.clipBands[1]
        XCTAssertEqual(burst.upperBound - burst.lowerBound, 0.88 * 156.0 / 11562.0, accuracy: 1e-9)
    }
}

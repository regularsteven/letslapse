import XCTest
@testable import LetsLapseKit

final class TimeSliceTests: XCTestCase {

    // MARK: - Band geometry

    func testReferenceCardGeometryIsExact() throws {
        // The measured reference clip: 720 ÷ 24 = 30 px, exact.
        let ranges = try XCTUnwrap(TimeSliceGeometry.bandRanges(axisLength: 720, segments: 24))
        XCTAssertEqual(ranges.count, 24)
        XCTAssertTrue(ranges.allSatisfy { $0.count == 30 })
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, 720)
    }

    func testExactDivisionAt1080By24() throws {
        let ranges = try XCTUnwrap(TimeSliceGeometry.bandRanges(axisLength: 1080, segments: 24))
        XCTAssertTrue(ranges.allSatisfy { $0.count == 45 })
    }

    func testRemainderIsSpreadAcrossBandsNotDumpedAtOneEdge() throws {
        // 1920 ÷ 7 = 274.29 — the two spare pixels must not sit together.
        let ranges = try XCTUnwrap(TimeSliceGeometry.bandRanges(axisLength: 1920, segments: 7))
        let widths = ranges.map(\.count)
        XCTAssertEqual(widths.reduce(0, +), 1920)
        XCTAssertEqual(Set(widths), Set([274, 275]))
        let wideBands = widths.enumerated().filter { $0.element == 275 }.map(\.offset)
        XCTAssertEqual(wideBands.count, 2)
        XCTAssertGreaterThan(abs(wideBands[0] - wideBands[1]), 1, "remainder bands should interleave")
    }

    func testBandsTileTheAxisWithNoGapsOrOverlaps() throws {
        for (length, segments) in [(1920, 7), (1080, 24), (713, 11), (2160, 48)] {
            let ranges = try XCTUnwrap(TimeSliceGeometry.bandRanges(axisLength: length, segments: segments))
            var cursor = 0
            for range in ranges {
                XCTAssertEqual(range.lowerBound, cursor)
                cursor = range.upperBound
            }
            XCTAssertEqual(cursor, length)
        }
    }

    func testEvenBoundariesLandOnEvenPixels() throws {
        // 4:2:0 chroma siting: every interior boundary even, coverage intact.
        let ranges = try XCTUnwrap(
            TimeSliceGeometry.bandRanges(axisLength: 1920, segments: 7, evenBoundaries: true)
        )
        for range in ranges.dropFirst() {
            XCTAssertEqual(range.lowerBound % 2, 0)
        }
        let widths = ranges.map(\.count)
        XCTAssertEqual(widths.reduce(0, +), 1920)
        XCTAssertLessThanOrEqual((widths.max() ?? 0) - (widths.min() ?? 0), 2)
    }

    func testSubMinimumBandsAreRejected() {
        XCTAssertNil(TimeSliceGeometry.bandRanges(axisLength: 40, segments: 24), "1.67 px bands")
        XCTAssertNotNil(TimeSliceGeometry.bandRanges(axisLength: 48, segments: 24), "2 px bands are the floor")
        XCTAssertNil(TimeSliceGeometry.bandRanges(axisLength: 720, segments: 1), "one band is not a slice")
    }

    // MARK: - Lag ladder

    func testLinearLadderMatchesTheReferenceClip() {
        // Measured: 0, 2, 4 … 46 across 24 bands.
        let ladder = TimeSliceGeometry.lagLadder(segments: 24, offsetFrames: 2)
        XCTAssertEqual(ladder.count, 24)
        XCTAssertEqual(ladder.first, 0)
        XCTAssertEqual(ladder.last, 46)
        for (index, lag) in ladder.enumerated() {
            XCTAssertEqual(lag, index * 2)
        }
    }

    func testBandLagsFollowTheNewestEdge() {
        let ladder = [0, 2, 4]
        XCTAssertEqual(TimeSliceGeometry.bandLags(ladder: ladder, newestEdge: .left), [0, 2, 4])
        XCTAssertEqual(TimeSliceGeometry.bandLags(ladder: ladder, newestEdge: .top), [0, 2, 4])
        XCTAssertEqual(TimeSliceGeometry.bandLags(ladder: ladder, newestEdge: .right), [4, 2, 0])
        XCTAssertEqual(TimeSliceGeometry.bandLags(ladder: ladder, newestEdge: .bottom), [4, 2, 0])
    }

    func testSlicedFrameCountTrimsTheSpread() {
        XCTAssertEqual(TimeSliceGeometry.slicedFrameCount(masterFrames: 100, maxLag: 46), 54)
        XCTAssertEqual(TimeSliceGeometry.slicedFrameCount(masterFrames: 46, maxLag: 46), 0)
        XCTAssertEqual(TimeSliceGeometry.slicedFrameCount(masterFrames: 10, maxLag: 46), 0)
    }

    // MARK: - Poster

    func testPosterSpreadsAcrossTheEntireMasterNewestFirst() throws {
        let indices = try XCTUnwrap(TimeSliceGeometry.posterIndices(masterFrames: 100, segments: 24))
        XCTAssertEqual(indices.count, 24)
        XCTAssertEqual(indices.first, 99, "band 0 is the newest")
        XCTAssertEqual(indices.last, 0, "the far band is the shoot's first frame")
        for pair in zip(indices, indices.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.0, pair.1)
        }
    }

    func testPosterOverAShortMasterRepeatsRatherThanFailing() throws {
        let indices = try XCTUnwrap(TimeSliceGeometry.posterIndices(masterFrames: 10, segments: 24))
        XCTAssertEqual(indices.first, 9)
        XCTAssertEqual(indices.last, 0)
        XCTAssertTrue(indices.allSatisfy { (0...9).contains($0) })
    }

    // MARK: - Settings

    func testAxisFollowsTheNewestEdge() {
        XCTAssertEqual(TimeSliceEdge.left.axis, .vertical)
        XCTAssertEqual(TimeSliceEdge.right.axis, .vertical)
        XCTAssertEqual(TimeSliceEdge.top.axis, .horizontal)
        XCTAssertEqual(TimeSliceEdge.bottom.axis, .horizontal)
    }

    func testMaxLagComesFromTheOldestBand() {
        XCTAssertEqual(TimeSliceSettings().maxLagFrames, 46)
        XCTAssertEqual(TimeSliceSettings(segments: 12, offsetFrames: 3).maxLagFrames, 33)
    }

    func testDisplayNamesCarryTheKeyAttributes() {
        // Decided 2026-08-28: timeslice-{vert|horiz}-{edge}-segs_{n}-lag_{n};
        // width never appears, the poster drops the lag. The edge token names
        // the NEWEST edge — default .right since the same-day review flipped
        // reading order to earliest-first.
        XCTAssertEqual(TimeSliceSettings().displayName, "timeslice-vert-right-segs_24-lag_2")
        XCTAssertEqual(
            TimeSliceSettings(newestEdge: .top, segments: 12, offsetFrames: 3).displayName,
            "timeslice-horiz-top-segs_12-lag_3"
        )
        XCTAssertEqual(TimeSliceSettings().posterDisplayName, "timeslice-poster-vert-right-segs_24")
    }

    func testDefaultReadingOrderStartsAtTheEarliestTime() {
        // 2026-08-28 review: the first band in reading order holds the
        // earliest moment — so the default newest edge is the trailing one,
        // and the geometric lags DESCEND across the frame (leftmost band =
        // biggest lag = oldest).
        let settings = TimeSliceSettings()
        XCTAssertEqual(settings.newestEdge, .right)
        let ladder = TimeSliceGeometry.lagLadder(segments: 4, offsetFrames: 2)
        XCTAssertEqual(
            TimeSliceGeometry.bandLags(ladder: ladder, newestEdge: settings.newestEdge),
            [6, 4, 2, 0])
    }

    func testSpreadFractionMapsBothWaysExactly() {
        // 25% of a 602-frame clip across 16 bands → lag 10; and back.
        let lag = TimeSliceGeometry.offsetFrames(spreadFraction: 0.25, masterFrames: 602, segments: 16)
        XCTAssertEqual(lag, 10)
        let fraction = TimeSliceGeometry.spreadFraction(offsetFrames: 10, masterFrames: 602, segments: 16)
        XCTAssertEqual(fraction, 150.0 / 602.0, accuracy: 0.0001)
        // The defaults that shipped the seams finding: 16 × 2 on 602 = 5%.
        XCTAssertEqual(
            TimeSliceGeometry.spreadFraction(offsetFrames: 2, masterFrames: 602, segments: 16),
            0.0498, accuracy: 0.001)
        XCTAssertEqual(
            TimeSliceGeometry.offsetFrames(spreadFraction: 0.0, masterFrames: 100, segments: 8),
            1, "the lag floor is one frame")
        XCTAssertEqual(
            TimeSliceGeometry.spreadFraction(offsetFrames: 5, masterFrames: 0, segments: 8), 0)
    }

    func testSettingsRoundTripThroughJSON() throws {
        let settings = TimeSliceSettings(
            newestEdge: .bottom, segments: 30, offsetFrames: 5,
            featherPixels: 12, output: .image, includeRegularClip: false
        )
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(TimeSliceSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testSettingsDecodeFieldByFieldWithDefaults() throws {
        // A manifest written before a field existed still loads, the missing
        // field neutral — the PhotoAdjustments precedent.
        let decoded = try JSONDecoder().decode(TimeSliceSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, TimeSliceSettings())

        let partial = Data(#"{"segments": 36, "newestEdge": "right"}"#.utf8)
        let mixed = try JSONDecoder().decode(TimeSliceSettings.self, from: partial)
        XCTAssertEqual(mixed.segments, 36)
        XCTAssertEqual(mixed.newestEdge, .right)
        XCTAssertEqual(mixed.offsetFrames, 2)
        XCTAssertTrue(mixed.includeRegularClip)
    }

    func testUnknownFutureTokensDecodeToDefaultsNotErrors() throws {
        let future = Data(#"{"newestEdge": "spiral", "distribution": "easeInOut", "output": "hologram"}"#.utf8)
        let decoded = try JSONDecoder().decode(TimeSliceSettings.self, from: future)
        XCTAssertEqual(decoded.newestEdge, .right)
        XCTAssertEqual(decoded.distribution, .linear)
        XCTAssertEqual(decoded.output, .both)
    }
}

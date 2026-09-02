import XCTest
@testable import LetsLapseKit

/// Grid geometry and the variation generator — the pure core of the two-axis
/// slicing mode. Plan: `docs/time-slicing.md` §10.
final class TimeSliceGridTests: XCTestCase {

    // MARK: - Square cells (§5.1)

    func testCellsAreSquareAndDerivedRowsFollowTheAspect() throws {
        // 1920×1080, 24 columns → 80 px cells, 1080/80 = 13.5 → 14 rows.
        let layout = try XCTUnwrap(TimeSliceGridGeometry.layout(width: 1920, height: 1080, columns: 24))
        XCTAssertEqual(layout.columns, 24)
        XCTAssertEqual(layout.rows, 14)
        XCTAssertEqual(layout.cellPixels, 80)
        // Interior cells are exactly square; only the outer ones crop.
        for range in layout.columnRanges.dropFirst().dropLast() {
            XCTAssertEqual(range.count, 80)
        }
        for range in layout.rowRanges.dropFirst().dropLast() {
            XCTAssertEqual(range.count, 80)
        }
        // 14 × 80 = 1120 over a 1080 frame: 40 px of overhang, split.
        XCTAssertEqual(layout.croppedY, 40)
        XCTAssertEqual(layout.croppedX, 0)
        XCTAssertEqual(layout.rowRanges.first?.count, 60)
        XCTAssertEqual(layout.rowRanges.last?.count, 60)
    }

    func testRangesTileTheFrameWithNoGapAndNoOverlap() throws {
        // A cell that never divides evenly on either axis.
        let layout = try XCTUnwrap(TimeSliceGridGeometry.layout(width: 4032, height: 3024, columns: 17))
        assertTiles(layout.columnRanges, axisLength: 4032)
        assertTiles(layout.rowRanges, axisLength: 3024)
        // Portrait too — the rows are the long axis there.
        let portrait = try XCTUnwrap(TimeSliceGridGeometry.layout(width: 1080, height: 1920, columns: 9))
        assertTiles(portrait.columnRanges, axisLength: 1080)
        assertTiles(portrait.rowRanges, axisLength: 1920)
        XCTAssertEqual(portrait.cellPixels, 120)
        XCTAssertEqual(portrait.rows, 16)
    }

    /// Rounding the row count DOWN would leave an uncovered strip, which is
    /// unwritten (black) output rather than a crop — so it is bumped up.
    func testRowsAreBumpedWhereRoundingDownWouldLeaveAnUncoveredStrip() throws {
        // 1000 wide, 10 columns → 100 px cells. 1340 tall → 13.4 rows, which
        // rounds to 13 (1300 px) and would leave 40 px unwritten.
        let layout = try XCTUnwrap(TimeSliceGridGeometry.layout(width: 1000, height: 1340, columns: 10))
        XCTAssertEqual(layout.cellPixels, 100)
        XCTAssertEqual(layout.rows, 14)
        assertTiles(layout.rowRanges, axisLength: 1340)
    }

    func testCellsUnderTheFloorAndSingleRowGridsAreRefused() {
        // 8 px floor: 200 px across 40 columns = 5 px cells.
        XCTAssertNil(TimeSliceGridGeometry.layout(width: 200, height: 200, columns: 40))
        // A frame only one cell tall is a banded slice, not a grid.
        XCTAssertNil(TimeSliceGridGeometry.layout(width: 1920, height: 80, columns: 24))
    }

    private func assertTiles(_ ranges: [Range<Int>], axisLength: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(ranges.first?.lowerBound, 0, file: file, line: line)
        XCTAssertEqual(ranges.last?.upperBound, axisLength, file: file, line: line)
        for (a, b) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(a.upperBound, b.lowerBound, file: file, line: line)
        }
        XCTAssertEqual(ranges.reduce(0) { $0 + $1.count }, axisLength, file: file, line: line)
    }

    // MARK: - The distance ladder (§5.2)

    func testManhattanLadderStepsDiagonally() {
        let ladder = TimeSliceGridGeometry.lagLadder(
            columns: 4, rows: 3, origin: .topLeft, metric: .manhattan, offsetFrames: 2)
        // lag = (column + row) × 2, row-major.
        XCTAssertEqual(ladder, [0, 2, 4, 6,
                                2, 4, 6, 8,
                                4, 6, 8, 10])
        XCTAssertEqual(ladder.max(), 10)
        XCTAssertEqual(
            TimeSliceGridGeometry.maximumDistance(columns: 4, rows: 3, metric: .manhattan), 5)
    }

    func testEuclideanLadderCurvesAndRoundsToWholeFrames() {
        let ladder = TimeSliceGridGeometry.lagLadder(
            columns: 3, rows: 3, origin: .topLeft, metric: .euclidean, offsetFrames: 10)
        // √2 ≈ 1.414 → 14; √5 ≈ 2.236 → 22; √8 ≈ 2.828 → 28.
        XCTAssertEqual(ladder, [0, 10, 20,
                                10, 14, 22,
                                20, 22, 28])
        // The far corner is nearer than Manhattan's — a curved wavefront
        // reaches it sooner.
        XCTAssertLessThan(
            TimeSliceGridGeometry.maximumDistance(columns: 3, rows: 3, metric: .euclidean),
            TimeSliceGridGeometry.maximumDistance(columns: 3, rows: 3, metric: .manhattan))
    }

    func testOriginCornerMovesTheLagZero() {
        for origin in TimeSliceGridOrigin.allCases {
            let ladder = TimeSliceGridGeometry.lagLadder(
                columns: 4, rows: 3, origin: origin, metric: .manhattan, offsetFrames: 1)
            let column = origin.isLeft ? 0 : 3
            let row = origin.isTop ? 0 : 2
            XCTAssertEqual(ladder[row * 4 + column], 0, "\(origin) should hold the newest cell")
            // …and the opposite corner holds the oldest.
            let farColumn = origin.isLeft ? 3 : 0
            let farRow = origin.isTop ? 2 : 0
            XCTAssertEqual(ladder[farRow * 4 + farColumn], 5)
        }
    }

    /// §5.3: a grid with one row reduces to the banded ladder. The geometry
    /// stays separate (bands distribute their remainder differently), but the
    /// ladder generalises exactly, which is what the claim rests on.
    func testASingleRowGridReproducesTheBandedLadder() {
        let grid = TimeSliceGridGeometry.lagLadder(
            columns: 6, rows: 1, origin: .topLeft, metric: .manhattan, offsetFrames: 3)
        let banded = TimeSliceGeometry.lagLadder(segments: 6, offsetFrames: 3)
        XCTAssertEqual(grid, banded)
    }

    func testPosterSpreadsTheWholeShootByDistanceRank() throws {
        let indices = try XCTUnwrap(TimeSliceGridGeometry.posterIndices(
            masterFrames: 101, columns: 3, rows: 3, origin: .topLeft, metric: .manhattan))
        // Distance 0…4 over 100 frames: the origin holds the last frame, the
        // far corner the first.
        XCTAssertEqual(indices[0], 100)
        XCTAssertEqual(indices[8], 0)
        XCTAssertEqual(indices[4], 50)   // centre cell, distance 2 of 4
    }

    // MARK: - Variations (§6)

    private let master = 600
    private let width = 1920
    private let height = 1080

    private func generate(
        count: Int, mode: TimeSliceVariationMode, seed: UInt64 = 0xC0FFEE,
        baseline: TimeSliceSettings = TimeSliceSettings(segments: 24, offsetFrames: 6)
    ) -> [TimeSliceSettings] {
        TimeSliceVariationGenerator.variations(
            plan: TimeSliceVariationPlan(count: count, mode: mode, seed: seed),
            baseline: baseline, masterFrames: master, width: width, height: height)
    }

    func testBatchesAreTheRequestedSizeAndAllDistinct() {
        for count in TimeSliceVariationPlan.allowedCounts {
            for mode in TimeSliceVariationMode.allCases {
                let batch = generate(count: count, mode: mode)
                XCTAssertEqual(batch.count, count, "\(mode) × \(count)")
                let identities = batch.map { settings -> String in
                    let shape = settings.grid.map { "grid-\($0.origin.rawValue)-\($0.metric.rawValue)" }
                        ?? "band-\(settings.newestEdge.rawValue)"
                    return "\(shape)-\(settings.segments)-\(settings.offsetFrames)"
                }
                XCTAssertEqual(Set(identities).count, count, "\(mode) × \(count) had duplicates")
                // Display names are legible and unique too (§7).
                XCTAssertEqual(Set(batch.map(\.displayName)).count, count)
            }
        }
    }

    func testTheSameSeedRegeneratesTheSameBatch() {
        let first = generate(count: 8, mode: .mixed, seed: 42)
        let again = generate(count: 8, mode: .mixed, seed: 42)
        XCTAssertEqual(first, again)
        let different = generate(count: 8, mode: .mixed, seed: 43)
        XCTAssertNotEqual(first, different)
    }

    func testEveryVariationIsIndividuallyRenderable() {
        for mode in TimeSliceVariationMode.allCases {
            for settings in generate(count: 8, mode: mode) {
                if settings.grid != nil {
                    XCTAssertNotNil(TimeSliceGridGeometry.layout(
                        width: width, height: height, columns: settings.segments))
                } else {
                    let axisLength = settings.axis == .vertical ? width : height
                    XCTAssertNotNil(TimeSliceGeometry.bandRanges(
                        axisLength: axisLength, segments: settings.segments))
                }
                let spread = settings.maxLagFrames(width: width, height: height)
                XCTAssertGreaterThan(spread, 0)
                XCTAssertLessThan(spread, master, "\(settings.displayName) eats the clip")
            }
        }
    }

    func testModesConstrainTheShapeAndMixedSpansThemAll() {
        XCTAssertTrue(generate(count: 4, mode: .grid).allSatisfy { $0.grid != nil })
        XCTAssertTrue(generate(count: 4, mode: .vertical).allSatisfy {
            $0.grid == nil && $0.axis == .vertical })
        XCTAssertTrue(generate(count: 4, mode: .horizontal).allSatisfy {
            $0.grid == nil && $0.axis == .horizontal })

        let mixed = generate(count: 8, mode: .mixed)
        XCTAssertTrue(mixed.contains { $0.grid != nil })
        XCTAssertTrue(mixed.contains { $0.grid == nil && $0.axis == .vertical })
        XCTAssertTrue(mixed.contains { $0.grid == nil && $0.axis == .horizontal })
        // Both wavefront metrics appear once there are two grids to carry them.
        let metrics = Set(mixed.compactMap { $0.grid?.metric })
        XCTAssertEqual(metrics, Set(TimeSliceGridMetric.allCases))
    }

    /// §6: the batch spans the parameters with the largest visible effect
    /// before the subtler ones. Shape and origin must both move before two
    /// variations are left differing only in spread.
    func testTheLoudParametersMoveFirst() {
        let batch = generate(count: 4, mode: .mixed)
        XCTAssertGreaterThan(Set(batch.map { $0.grid == nil ? $0.axis.nameToken : "grid" }).count, 1)
        let origins = Set(batch.compactMap { $0.grid?.origin })
        let edges = Set(batch.filter { $0.grid == nil }.map(\.newestEdge))
        XCTAssertGreaterThanOrEqual(origins.count + edges.count, 3)
    }

    func testEveryVariationCarriesItsStamp() {
        let batch = generate(count: 4, mode: .mixed, seed: 7)
        for (position, settings) in batch.enumerated() {
            let stamp = settings.variation
            XCTAssertEqual(stamp?.index, position + 1)
            XCTAssertEqual(stamp?.count, 4)
            XCTAssertEqual(stamp?.seed, 7)
            XCTAssertEqual(stamp?.mode, .mixed)
            XCTAssertTrue(settings.displayName.hasSuffix("-v\(position + 1)of4"))
        }
    }

    /// A frame too small to carry eight distinct recipes returns fewer rather
    /// than duplicates — the caller reports what it got.
    func testATinyFrameYieldsFewerRatherThanDuplicates() {
        let batch = TimeSliceVariationGenerator.variations(
            plan: TimeSliceVariationPlan(count: 8, mode: .grid, seed: 1),
            baseline: TimeSliceSettings(segments: 4, offsetFrames: 1),
            masterFrames: 30, width: 64, height: 48)
        XCTAssertEqual(Set(batch.map(\.displayName)).count, batch.count)
        for settings in batch {
            XCTAssertLessThan(settings.maxLagFrames(width: 64, height: 48), 30)
        }
    }

    // MARK: - Persistence

    func testGridAndVariationSurviveARoundTripAndOldRecipesStillDecode() throws {
        var settings = TimeSliceSettings(newestEdge: .left, segments: 18, offsetFrames: 4)
        settings.grid = TimeSliceGrid(origin: .bottomRight, metric: .euclidean)
        settings.variation = TimeSliceVariationStamp(index: 3, count: 8, mode: .mixed, seed: 99)
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(TimeSliceSettings.self, from: data), settings)

        // A manifest written before either field existed.
        let legacy = Data(#"{"newestEdge":"right","segments":24,"offsetFrames":2,"featherPixels":0,"distribution":"linear","output":"both","includeRegularClip":true}"#.utf8)
        let decoded = try JSONDecoder().decode(TimeSliceSettings.self, from: legacy)
        XCTAssertNil(decoded.grid)
        XCTAssertNil(decoded.variation)
        XCTAssertEqual(decoded.displayName, "timeslice-vert-right-segs_24-lag_2")
    }
    // MARK: - Locks (the 2026-09-02 Adjust simplification)

    func testLockedEdgePinsEveryBandedMemberToTheBaselineEdge() {
        let baseline = TimeSliceSettings(newestEdge: .left, segments: 24, offsetFrames: 6)
        for mode in [TimeSliceVariationMode.vertical, .mixed] {
            let batch = TimeSliceVariationGenerator.variations(
                plan: TimeSliceVariationPlan(count: 8, mode: mode, seed: 7, lockEdge: true),
                baseline: baseline, masterFrames: master, width: width, height: height)
            XCTAssertEqual(batch.count, 8, "\(mode)")
            for member in batch where member.grid == nil && member.axis == .vertical {
                XCTAssertEqual(member.newestEdge, .left, "\(mode): \(member.displayName)")
            }
        }
        // Unlocked, the same seed walks both edges.
        let free = TimeSliceVariationGenerator.variations(
            plan: TimeSliceVariationPlan(count: 8, mode: .vertical, seed: 7),
            baseline: baseline, masterFrames: master, width: width, height: height)
        XCTAssertEqual(Set(free.map(\.newestEdge)), [.left, .right])
    }

    func testLockedSegmentsKeepTheBaselineCountAndStayDistinct() {
        let baseline = TimeSliceSettings(newestEdge: .right, segments: 16, offsetFrames: 6)
        let batch = TimeSliceVariationGenerator.variations(
            plan: TimeSliceVariationPlan(count: 4, mode: .vertical, seed: 11,
                                         lockEdge: true, lockSegments: true),
            baseline: baseline, masterFrames: master, width: width, height: height)
        XCTAssertEqual(batch.count, 4)
        // Edge and count are both pinned, so the lag is all that can differ —
        // and it must, or the batch would repeat itself.
        XCTAssertEqual(Set(batch.map(\.segments)), [16])
        XCTAssertEqual(Set(batch.map(\.newestEdge)), [.right])
        XCTAssertEqual(Set(batch.map(\.offsetFrames)).count, 4)
    }

    func testLockedOriginKeepsTheCornerAndAlternatesTheMetric() {
        var baseline = TimeSliceSettings(newestEdge: .right, segments: 24, offsetFrames: 6)
        baseline.grid = TimeSliceGrid(origin: .bottomRight, metric: .manhattan)
        let batch = TimeSliceVariationGenerator.variations(
            plan: TimeSliceVariationPlan(count: 4, mode: .grid, seed: 3, lockOrigin: true),
            baseline: baseline, masterFrames: master, width: width, height: height)
        XCTAssertEqual(batch.count, 4)
        XCTAssertEqual(Set(batch.compactMap { $0.grid?.origin }), [.bottomRight])
        XCTAssertEqual(Set(batch.compactMap { $0.grid?.metric }), [.manhattan, .euclidean])
    }

    func testPlanLocksRoundTripAndDefaultOffForOlderPlans() throws {
        let plan = TimeSliceVariationPlan(count: 4, mode: .vertical, seed: 5,
                                          lockEdge: true, lockSegments: false, lockOrigin: true)
        let data = try JSONEncoder().encode(plan)
        XCTAssertEqual(try JSONDecoder().decode(TimeSliceVariationPlan.self, from: data), plan)

        let legacy = Data(#"{"count":8,"mode":"mixed","seed":42}"#.utf8)
        let decoded = try JSONDecoder().decode(TimeSliceVariationPlan.self, from: legacy)
        XCTAssertEqual(decoded, TimeSliceVariationPlan(count: 8, mode: .mixed, seed: 42))
        XCTAssertFalse(decoded.lockEdge)
        XCTAssertFalse(decoded.lockSegments)
        XCTAssertFalse(decoded.lockOrigin)
    }
}

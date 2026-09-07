import XCTest
@testable import LetsLapseKit

/// The parametric masks' arithmetic. Every one of these is a claim the
/// renderer, the handles and the export all rely on: coverage is what the
/// gradient draws, and the handle geometry is where the user grabs it. A sign
/// error in either shows up as a mask applied somewhere other than where it
/// was drawn, which is exactly the bug a preview cannot make obvious.
final class MaskShapeTests: XCTestCase {

    /// A deliberately non-square frame: a square one hides every axis mix-up.
    private let frame = CGSize(width: 800, height: 600)

    // MARK: - Linear coverage

    func testLinearIsFullyCoveredAtTheStartAndEmptyAtTheEnd() {
        let shape = MaskShape.linear(
            from: CGPoint(x: 0.5, y: 0.9), to: CGPoint(x: 0.5, y: 0.1), feather: 0.5)
        XCTAssertEqual(shape.coverage(at: CGPoint(x: 400, y: 540), in: frame), 1, accuracy: 1e-9)
        XCTAssertEqual(shape.coverage(at: CGPoint(x: 400, y: 60), in: frame), 0, accuracy: 1e-9)
    }

    func testLinearIsHalfCoveredOnTheMidLineAtAnyFeather() {
        for feather in [0.0, 0.25, 0.5, 1.0] {
            let shape = MaskShape.linear(
                from: CGPoint(x: 0.2, y: 0.8), to: CGPoint(x: 0.8, y: 0.2), feather: feather)
            let mid = shape.linearMidpoint(in: frame)
            // Feather 0 is a step exactly on the line, so it is allowed to
            // answer either side of a half; everything softer must be 0.5.
            if feather > 0 {
                XCTAssertEqual(shape.coverage(at: mid, in: frame), 0.5, accuracy: 1e-9,
                               "feather \(feather)")
            }
        }
    }

    func testLinearCoverageIgnoresDistanceAlongTheMidLine() {
        let shape = MaskShape.linear(
            from: CGPoint(x: 0.5, y: 0.9), to: CGPoint(x: 0.5, y: 0.1), feather: 0.6)
        // Two points far apart perpendicular to the axis must read the same:
        // a linear gradient is a function of the projection only.
        let left = shape.coverage(at: CGPoint(x: 20, y: 300), in: frame)
        let right = shape.coverage(at: CGPoint(x: 780, y: 300), in: frame)
        XCTAssertEqual(left, right, accuracy: 1e-9)
    }

    func testLinearFeatherZeroIsAHardEdgeAtTheMidpoint() {
        let shape = MaskShape.linear(
            from: CGPoint(x: 0.5, y: 1.0), to: CGPoint(x: 0.5, y: 0.0), feather: 0)
        XCTAssertEqual(shape.coverage(at: CGPoint(x: 400, y: 310), in: frame), 1, accuracy: 1e-9)
        XCTAssertEqual(shape.coverage(at: CGPoint(x: 400, y: 290), in: frame), 0, accuracy: 1e-9)
    }

    func testLinearFeatherOneRampsTheWholeWayFromStartToEnd() {
        let shape = MaskShape.linear(
            from: CGPoint(x: 0, y: 0.5), to: CGPoint(x: 1, y: 0.5), feather: 1)
        // A quarter of the way along is three-quarters covered.
        XCTAssertEqual(shape.coverage(at: CGPoint(x: 200, y: 300), in: frame), 0.75, accuracy: 1e-9)
        XCTAssertEqual(shape.coverage(at: CGPoint(x: 600, y: 300), in: frame), 0.25, accuracy: 1e-9)
    }

    func testZeroLengthLinearSelectsEverythingRatherThanDividingByZero() {
        let point = CGPoint(x: 0.5, y: 0.5)
        let shape = MaskShape.linear(from: point, to: point, feather: 0.5)
        XCTAssertEqual(shape.coverage(at: CGPoint(x: 10, y: 10), in: frame), 1, accuracy: 1e-9)
        XCTAssertTrue(shape.isDegenerate(in: frame))
    }

    // MARK: - Radial coverage

    func testRadialIsFullInsideTheFeatherBoundaryAndEmptyOutsideTheEllipse() {
        let shape = MaskShape(
            kind: .radial, center: CGPoint(x: 0.5, y: 0.5),
            radiusX: 0.25, radiusY: 0.25, feather: 0.4)
        let centre = CGPoint(x: 400, y: 300)
        XCTAssertEqual(shape.coverage(at: centre, in: frame), 1, accuracy: 1e-9)
        // rx is 200 pt; well past it is nothing.
        XCTAssertEqual(shape.coverage(at: CGPoint(x: 700, y: 300), in: frame), 0, accuracy: 1e-9)
        // The 1 − feather boundary is still fully selected.
        XCTAssertEqual(shape.coverage(at: CGPoint(x: 400 + 200 * 0.6, y: 300), in: frame),
                       1, accuracy: 1e-9)
    }

    func testRadialFeatherRampsLinearlyToTheEdge() {
        let shape = MaskShape(
            kind: .radial, center: CGPoint(x: 0.5, y: 0.5),
            radiusX: 0.25, radiusY: 0.25, feather: 0.5)
        // Halfway through the band (r = 0.75 of the radius) is half covered.
        XCTAssertEqual(shape.coverage(at: CGPoint(x: 400 + 200 * 0.75, y: 300), in: frame),
                       0.5, accuracy: 1e-9)
    }

    func testRadialRespectsSeparateAxesOnANonSquareFrame() {
        // radiusX 0.25 of 800 = 200 pt; radiusY 0.25 of 600 = 150 pt. A point
        // 175 pt above the centre is OUTSIDE, one 175 pt to the side is inside.
        let shape = MaskShape(
            kind: .radial, center: CGPoint(x: 0.5, y: 0.5),
            radiusX: 0.25, radiusY: 0.25, feather: 0)
        XCTAssertEqual(shape.coverage(at: CGPoint(x: 575, y: 300), in: frame), 1, accuracy: 1e-9)
        XCTAssertEqual(shape.coverage(at: CGPoint(x: 400, y: 125), in: frame), 0, accuracy: 1e-9)
    }

    func testRadialCreatedFromPointsIsRoundOnScreen() {
        let shape = MaskShape.radial(
            center: CGPoint(x: 0.5, y: 0.5), radiusPoints: 120, in: frame)
        XCTAssertEqual(shape.radiusXPoints(in: frame), 120, accuracy: 1e-9)
        XCTAssertEqual(shape.radiusYPoints(in: frame), 120, accuracy: 1e-9)
        // Round means the coverage at 120 pt is the same in every direction.
        let east = shape.ellipseRadius(of: CGPoint(x: 520, y: 300), in: frame)
        let north = shape.ellipseRadius(of: CGPoint(x: 400, y: 180), in: frame)
        XCTAssertEqual(east, north, accuracy: 1e-9)
        XCTAssertEqual(east, 1, accuracy: 1e-9)
    }

    func testRotationTurnsTheEllipseInPictureSpace() {
        // A wide, flat ellipse turned a quarter turn: what was the long axis
        // (east) becomes the short one, so a point out east falls outside.
        var shape = MaskShape(
            kind: .radial, center: CGPoint(x: 0.5, y: 0.5),
            radiusX: 0.25, radiusY: 0.05, rotationDegrees: 0, feather: 0)
        XCTAssertEqual(shape.coverage(at: CGPoint(x: 550, y: 300), in: frame), 1, accuracy: 1e-9)
        shape.rotationDegrees = 90
        XCTAssertEqual(shape.coverage(at: CGPoint(x: 550, y: 300), in: frame), 0, accuracy: 1e-9)
        // …and one due south, on the turned long axis, is inside. rx is 200 pt
        // in the local frame, which maps onto 200 pt of screen going down.
        XCTAssertEqual(shape.coverage(at: CGPoint(x: 400, y: 450), in: frame), 1, accuracy: 1e-9)
    }

    // MARK: - Handles

    func testCardinalHandlesSitOnTheEllipse() {
        let shape = MaskShape(
            kind: .radial, center: CGPoint(x: 0.4, y: 0.6),
            radiusX: 0.18, radiusY: 0.12, rotationDegrees: 33, feather: 0.3)
        for cardinal in MaskShape.Cardinal.allCases {
            let point = shape.cardinalPoint(cardinal, in: frame)
            XCTAssertEqual(shape.ellipseRadius(of: point, in: frame), 1, accuracy: 1e-6,
                           "\(cardinal) handle is not on the outline")
        }
    }

    func testRotationHandleSitsOnTheStalkBeyondTheEastCardinal() {
        let shape = MaskShape(
            kind: .radial, center: CGPoint(x: 0.5, y: 0.5),
            radiusX: 0.2, radiusY: 0.1, rotationDegrees: -20)
        let east = shape.cardinalPoint(.east, in: frame)
        let handle = shape.rotationHandlePoint(in: frame)
        let distance = hypot(handle.x - east.x, handle.y - east.y)
        XCTAssertEqual(Double(distance), MaskShape.rotationStalkPoints, accuracy: 1e-6)
    }

    func testDraggingACardinalMovesOnlyItsOwnAxis() {
        let shape = MaskShape(
            kind: .radial, center: CGPoint(x: 0.5, y: 0.5),
            radiusX: 0.2, radiusY: 0.1, rotationDegrees: 0)
        let resized = shape.resized(.east, to: CGPoint(x: 700, y: 300), in: frame)
        XCTAssertEqual(resized.radiusXPoints(in: frame), 300, accuracy: 1e-6)
        XCTAssertEqual(resized.radiusY, shape.radiusY, accuracy: 1e-12)
        XCTAssertEqual(resized.center, shape.center)
        XCTAssertEqual(resized.rotationDegrees, shape.rotationDegrees)
    }

    func testDraggingACardinalOnATurnedEllipseMeasuresAlongTheTurnedAxis() {
        let shape = MaskShape(
            kind: .radial, center: CGPoint(x: 0.5, y: 0.5),
            radiusX: 0.1, radiusY: 0.1, rotationDegrees: 90)
        // With the ellipse turned a quarter, its local +x runs DOWN the
        // screen — so a drag 150 pt below the centre sets rx to 150 pt.
        let resized = shape.resized(.east, to: CGPoint(x: 400, y: 450), in: frame)
        XCTAssertEqual(resized.radiusXPoints(in: frame), 150, accuracy: 1e-6)
    }

    func testHandlesCollapseOnlyBelowTheSmallRadius() {
        var shape = MaskShape(
            kind: .radial, center: CGPoint(x: 0.5, y: 0.5), radiusX: 0.1, radiusY: 0.1)
        XCTAssertFalse(shape.handlesCollapse(in: frame))  // 80 × 60 pt
        shape.radiusY = 0.03  // 18 pt, under the 26 pt floor
        XCTAssertTrue(shape.handlesCollapse(in: frame))
    }

    func testFeatherBandStraddlesTheMidpointAndVanishesAtZero() {
        var shape = MaskShape.linear(
            from: CGPoint(x: 0, y: 0.5), to: CGPoint(x: 1, y: 0.5), feather: 0.5)
        let band = shape.linearFeatherPoints(in: frame)
        XCTAssertNotNil(band)
        // Feather 0.5 over an 800 pt span is a 400 pt band centred on 400.
        XCTAssertEqual(Double(band!.near.x), 200, accuracy: 1e-6)
        XCTAssertEqual(Double(band!.far.x), 600, accuracy: 1e-6)
        shape.feather = 0
        XCTAssertNil(shape.linearFeatherPoints(in: frame))
    }

    func testLinearNormalIsPerpendicularAndUnitLength() {
        let shape = MaskShape.linear(
            from: CGPoint(x: 0.2, y: 0.2), to: CGPoint(x: 0.7, y: 0.9))
        let normal = shape.linearNormal(in: frame)
        let a = shape.startPoint(in: frame), b = shape.endPoint(in: frame)
        let axis = CGVector(dx: b.x - a.x, dy: b.y - a.y)
        let dot = Double(normal.dx * axis.dx + normal.dy * axis.dy)
        XCTAssertEqual(dot, 0, accuracy: 1e-6)
        XCTAssertEqual(Double(hypot(normal.dx, normal.dy)), 1, accuracy: 1e-9)
    }

    // MARK: - Editing

    func testMovingARadialClampsItsCentreToTheFrame() {
        let shape = MaskShape(
            kind: .radial, center: CGPoint(x: 0.9, y: 0.5), radiusX: 0.1, radiusY: 0.1)
        let moved = shape.moved(by: CGSize(width: 400, height: 0), in: frame)
        XCTAssertEqual(Double(moved.center.x), 1, accuracy: 1e-9)
    }

    func testMovingALinearCarriesBothEndsAndDoesNotClampThem() {
        let shape = MaskShape.linear(
            from: CGPoint(x: 0.5, y: 0.9), to: CGPoint(x: 0.5, y: 0.2))
        let moved = shape.moved(by: CGSize(width: 0, height: 300), in: frame)
        // Both ends took the same translation…
        XCTAssertEqual(Double(moved.start.y), 1.4, accuracy: 1e-9)
        XCTAssertEqual(Double(moved.end.y), 0.7, accuracy: 1e-9)
        // …and the gradient it describes is unchanged in shape.
        XCTAssertEqual(moved.length(in: frame), shape.length(in: frame), accuracy: 1e-6)
    }

    func testRotatingFoldsIntoTheSliderTravel() {
        let shape = MaskShape(
            kind: .radial, center: CGPoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.1)
        // Straight up on screen is −90°, which is in range and stays put.
        let up = shape.rotated(toward: CGPoint(x: 400, y: 100), in: frame)
        XCTAssertEqual(up.rotationDegrees, -90, accuracy: 1e-6)
        // Due west is 180°, the same ellipse as 0°.
        let west = shape.rotated(toward: CGPoint(x: 100, y: 300), in: frame)
        XCTAssertEqual(west.rotationDegrees, 0, accuracy: 1e-6)
    }

    func testFoldedAngleCoversTheWholeCircle() {
        XCTAssertEqual(MaskShape.foldedAngle(0), 0, accuracy: 1e-9)
        XCTAssertEqual(MaskShape.foldedAngle(45), 45, accuracy: 1e-9)
        XCTAssertEqual(MaskShape.foldedAngle(135), -45, accuracy: 1e-9)
        XCTAssertEqual(MaskShape.foldedAngle(-135), 45, accuracy: 1e-9)
        XCTAssertEqual(MaskShape.foldedAngle(270), 90, accuracy: 1e-9)
        for degrees in stride(from: -720.0, through: 720.0, by: 7) {
            XCTAssertTrue(MaskShape.rotationRange.contains(MaskShape.foldedAngle(degrees)),
                          "\(degrees) folded out of range")
        }
    }

    func testFoldedAngleDescribesTheSameEllipse() {
        var straight = MaskShape(
            kind: .radial, center: CGPoint(x: 0.5, y: 0.5),
            radiusX: 0.2, radiusY: 0.08, rotationDegrees: 200, feather: 0.2)
        var folded = straight
        folded.rotationDegrees = MaskShape.foldedAngle(200)
        for point in [CGPoint(x: 300, y: 250), CGPoint(x: 520, y: 340), CGPoint(x: 400, y: 300)] {
            XCTAssertEqual(straight.coverage(at: point, in: frame),
                           folded.coverage(at: point, in: frame), accuracy: 1e-9)
        }
        // …and the fold is stable under a second application.
        straight.rotationDegrees = MaskShape.foldedAngle(straight.rotationDegrees)
        XCTAssertEqual(straight.rotationDegrees, folded.rotationDegrees, accuracy: 1e-9)
    }

    // MARK: - Degeneracy and persistence

    func testACreateDragUnderTheFloorIsDegenerate() {
        let tiny = MaskShape.linear(
            from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.505, y: 0.5))  // 4 pt
        XCTAssertTrue(tiny.isDegenerate(in: frame))
        let enough = MaskShape.linear(
            from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.53, y: 0.5))   // 24 pt
        XCTAssertFalse(enough.isDegenerate(in: frame))
    }

    func testRoundTripsThroughJSON() throws {
        let shape = MaskShape(
            kind: .radial, center: CGPoint(x: 0.31, y: 0.72),
            radiusX: 0.19, radiusY: 0.07, rotationDegrees: -37.5, feather: 0.42)
        let data = try JSONEncoder().encode(shape)
        XCTAssertEqual(try JSONDecoder().decode(MaskShape.self, from: data), shape)
    }

    func testAPayloadMissingEveryOptionalFieldStillDecodes() throws {
        // The tolerance `SceneOverlay` set: a sidecar from a build that only
        // knew linear masks must not throw the whole document away.
        let data = Data(#"{"k":"linear"}"#.utf8)
        let shape = try JSONDecoder().decode(MaskShape.self, from: data)
        XCTAssertEqual(shape.kind, .linear)
        XCTAssertEqual(shape.feather, MaskShape.defaultFeather, accuracy: 1e-9)
    }
}

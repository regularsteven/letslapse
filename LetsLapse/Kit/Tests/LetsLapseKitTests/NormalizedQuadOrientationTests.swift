import XCTest
@testable import LetsLapseKit

/// The Scanner overlay's coordinate chain, pinned to numbers a real Vision run
/// produced.
///
/// The fixtures below are not invented: a 800×600 landscape frame holding a
/// white rectangle at x 80…280, y 100…500 (bottom-left origin) was run through
/// `VNDetectRectanglesRequest` four times, once per non-mirrored orientation.
/// That experiment is what settled the question the overlay was getting wrong —
/// **Vision reports corners in the space of the *oriented* image, not the
/// buffer's own** — so the rotation this file tests is the conversion between
/// the two, and these expectations would catch the day that behaviour changes.
final class NormalizedQuadOrientationTests: XCTestCase {

    /// The detection as reported with `.up` (the sensor's own read-out).
    private let sensorQuad = NormalizedQuad(
        topLeft: .init(x: 0.098, y: 0.833),
        topRight: .init(x: 0.350, y: 0.835),
        bottomLeft: .init(x: 0.099, y: 0.162),
        bottomRight: .init(x: 0.351, y: 0.163),
        confidence: 0.9)

    /// The same rectangle as reported with `.right` — the orientation a
    /// portrait capture hands the request.
    private let portraitQuad = NormalizedQuad(
        topLeft: .init(x: 0.163, y: 0.898),
        topRight: .init(x: 0.833, y: 0.899),
        bottomLeft: .init(x: 0.163, y: 0.647),
        bottomRight: .init(x: 0.835, y: 0.647),
        confidence: 0.9)

    private func assertClose(
        _ lhs: NormalizedQuad, _ rhs: NormalizedQuad,
        accuracy: Double = 0.0001, file: StaticString = #filePath, line: UInt = #line
    ) {
        for (a, b) in zip(lhs.corners, rhs.corners) {
            XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
            XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
        }
    }

    func testSensorQuadRotatesOntoTheVisionResultForPortrait() {
        // One clockwise quarter turn is exactly what `.right` means, and the
        // labels travel with the corners: the sensor frame's bottom-left corner
        // is the portrait frame's top-left.
        //
        // The tolerance is 0.004 rather than the exact figure the rotation
        // itself achieves, because the two fixtures are two INDEPENDENT
        // detections of the same painted rectangle — the detector's own corners
        // disagree with themselves by ~0.3% of the frame between runs. That
        // spread is the measurement, not the maths: anything looser would stop
        // catching a wrong quarter turn (which moves a corner by tenths).
        assertClose(sensorQuad.rotatedClockwise(quarterTurns: 1), portraitQuad, accuracy: 0.004)
        assertClose(sensorQuad.converted(from: .up, to: .right), portraitQuad, accuracy: 0.004)
    }

    func testConversionRoundTrips() {
        for source in QuadOrientation.allCases {
            for target in QuadOrientation.allCases {
                let there = portraitQuad.converted(from: source, to: target)
                assertClose(there.converted(from: target, to: source), portraitQuad)
            }
        }
    }

    func testFourQuarterTurnsIsIdentity() {
        assertClose(portraitQuad.rotatedClockwise(quarterTurns: 4), portraitQuad)
        assertClose(portraitQuad.rotatedClockwise(quarterTurns: -4), portraitQuad)
    }

    func testNegativeTurnsAreTheOppositeRotation() {
        assertClose(
            portraitQuad.rotatedClockwise(quarterTurns: -1),
            portraitQuad.rotatedClockwise(quarterTurns: 3))
        // Same two-independent-detections tolerance as the fixture test above.
        assertClose(portraitQuad.converted(from: .right, to: .up), sensorQuad, accuracy: 0.004)
    }

    /// A rotation must not reshape the figure — the edges survive, they just
    /// change which side of the page they are. Turning the page clockwise makes
    /// its left edge the new top edge, which is exactly the label permutation
    /// the rotation applies, so this also pins that the two moved together.
    func testRotationPreservesEdgeLengthsAndPermutesTheLabels() {
        let rotated = portraitQuad.rotatedClockwise(quarterTurns: 1)
        XCTAssertEqual(
            portraitQuad.bottomLeft.distance(to: portraitQuad.topLeft),
            rotated.topLeft.distance(to: rotated.topRight),
            accuracy: 0.0001)
        XCTAssertEqual(
            portraitQuad.topLeft.distance(to: portraitQuad.topRight),
            rotated.topRight.distance(to: rotated.bottomRight),
            accuracy: 0.0001)
    }

    /// Sensor space is the preview layer's own convention: the sensor's
    /// landscape read-out with the origin at the TOP left. A portrait quad's
    /// top-left corner therefore comes back near the sensor frame's *bottom*
    /// left, which is where a page's top-left corner really sits when the phone
    /// is held upright.
    func testSensorCornersUndoTheOrientationAndFlipY() {
        let corners = portraitQuad.sensorCorners(measuredIn: .right)
        XCTAssertEqual(corners.topLeft.x, 0.102, accuracy: 0.01)
        XCTAssertEqual(corners.topLeft.y, 1 - 0.833, accuracy: 0.01)
        XCTAssertEqual(corners.bottomRight.x, 0.353, accuracy: 0.01)
        XCTAssertEqual(corners.bottomRight.y, 1 - 0.165, accuracy: 0.01)
    }

    func testSensorCornersAreTheIdentityFlipForAnUprightSensorQuad() {
        let corners = sensorQuad.sensorCorners(measuredIn: .up)
        XCTAssertEqual(corners.topLeft.x, sensorQuad.topLeft.x, accuracy: 0.0001)
        XCTAssertEqual(corners.topLeft.y, 1 - sensorQuad.topLeft.y, accuracy: 0.0001)
        XCTAssertEqual(corners.bottomLeft.x, sensorQuad.bottomLeft.x, accuracy: 0.0001)
        XCTAssertEqual(corners.bottomLeft.y, 1 - sensorQuad.bottomLeft.y, accuracy: 0.0001)
    }
    /// The point-wise twin agrees with `sensorCorners` for every orientation.
    /// `sensorCorners` relabels as it turns (the sensor frame's own top-left is
    /// called `topLeft`), the point map does not, so the four corners are
    /// compared as a set — and the documented portrait case directly: a
    /// portrait quad's top-left corner is the sensor frame's bottom left.
    func testSensorPointMatchesSensorCornersInEveryOrientation() {
        func tl(_ p: NormalizedQuad.Point) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }
        let corners = [portraitQuad.topLeft, portraitQuad.topRight, portraitQuad.bottomRight, portraitQuad.bottomLeft].map(tl)
        for orientation in QuadOrientation.allCases {
            let e = portraitQuad.sensorCorners(measuredIn: orientation)
            let expected = [e.topLeft, e.topRight, e.bottomRight, e.bottomLeft]
            for c in corners {
                let s = orientation.sensorPoint(c)
                XCTAssertTrue(expected.contains { abs($0.x - Double(s.x)) < 1e-9 && abs($0.y - Double(s.y)) < 1e-9 },
                              "\(orientation): \(s) not among the sensor corners")
                let back = orientation.uprightPoint(fromSensor: s)
                XCTAssertEqual(Double(back.x), Double(c.x), accuracy: 1e-9)
                XCTAssertEqual(Double(back.y), Double(c.y), accuracy: 1e-9)
            }
        }
        let portraitTL = QuadOrientation.right.sensorPoint(corners[0])
        let e = portraitQuad.sensorCorners(measuredIn: .right)
        XCTAssertEqual(Double(portraitTL.x), e.bottomLeft.x, accuracy: 1e-9)
        XCTAssertEqual(Double(portraitTL.y), e.bottomLeft.y, accuracy: 1e-9)
        // Portrait → upside-down portrait is a half turn.
        let q = QuadOrientation.convert(CGPoint(x: 0.2, y: 0.7), from: .right, to: .left)
        XCTAssertEqual(Double(q.x), 0.8, accuracy: 1e-9)
        XCTAssertEqual(Double(q.y), 0.3, accuracy: 1e-9)
    }
}

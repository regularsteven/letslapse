import XCTest
import CoreGraphics
@testable import LetsLapseKit

/// `DetectedShape.bounds(in:)` and `margins(in:)` — a shape's axis-aligned
/// box and its distance from each edge, in a frame's pixels. These exist
/// because the register stores the axes as fractions of the frame's WIDTH
/// and the centre per axis: `ShapeDetector.bbox`, which stays in that
/// normalised space, puts a width-fraction axis on y as if it were a height
/// fraction, so a circle's box comes out 3/4 as tall on a 4:3 frame and
/// 9/16 on a 16:9 one. `bbox` is left as it is — it is the IoU primitive
/// under fifteen tuned thresholds — and the pixel answer lives here.
final class ShapeBoundsTests: XCTestCase {
    private let fourThree = CGSize(width: 4032, height: 3024)
    private let sixteenNine = CGSize(width: 1920, height: 1080)

    func testCircleBoundsAreTheSameOnAnyFrameShape() {
        for frame in [fourThree, sixteenNine] {
            let circle = DetectedShape.ellipse(centre: CGPoint(x: 1000, y: 600), semiAxisX: 300, semiAxisY: 300, rotation: 0, frame: frame)
            let b = circle.bounds(in: frame)
            XCTAssertEqual(b.minX, 700, accuracy: 1e-6, "\(frame)")
            XCTAssertEqual(b.maxX, 1300, accuracy: 1e-6, "\(frame)")
            XCTAssertEqual(b.minY, 300, accuracy: 1e-6, "\(frame)")
            XCTAssertEqual(b.maxY, 900, accuracy: 1e-6, "\(frame)")
            let m = circle.margins(in: frame)
            XCTAssertEqual(m.left, 700, accuracy: 1e-6)
            XCTAssertEqual(m.top, 300, accuracy: 1e-6)
            XCTAssertEqual(m.right, Double(frame.width) - 1300, accuracy: 1e-6)
            XCTAssertEqual(m.bottom, Double(frame.height) - 900, accuracy: 1e-6)
        }
        // The trap itself, pinned: the detector's normalised box scaled back
        // to the 4:3 frame is 600 wide but only 450 tall.
        let circle = DetectedShape.ellipse(centre: CGPoint(x: 1000, y: 600), semiAxisX: 300, semiAxisY: 300, rotation: 0, frame: fourThree)
        let naive = ShapeDetector.bbox(circle)
        XCTAssertEqual(naive.width * fourThree.width, 600, accuracy: 1e-6)
        XCTAssertEqual(naive.height * fourThree.height, 450, accuracy: 1e-6)
    }

    func testRotatedEllipseBoundsMatchTheAnalyticExtents() {
        // Semi-axes 400 × 200 turned 30°: hw = √(a²cos² + b²sin²), hh = √(a²sin² + b²cos²).
        let rotation = 30.0 * Double.pi / 180
        let ellipse = DetectedShape.ellipse(centre: CGPoint(x: 1000, y: 600), semiAxisX: 400, semiAxisY: 200, rotation: rotation, frame: fourThree)
        let c = cos(rotation), s = sin(rotation)
        let hw = sqrt(400 * 400 * c * c + 200 * 200 * s * s)
        let hh = sqrt(400 * 400 * s * s + 200 * 200 * c * c)
        XCTAssertEqual(hw, sqrt(130_000), accuracy: 1e-9)
        XCTAssertEqual(hh, sqrt(70_000), accuracy: 1e-9)
        let b = ellipse.bounds(in: fourThree)
        XCTAssertEqual(b.minX, 1000 - hw, accuracy: 1e-6)
        XCTAssertEqual(b.maxX, 1000 + hw, accuracy: 1e-6)
        XCTAssertEqual(b.minY, 600 - hh, accuracy: 1e-6)
        XCTAssertEqual(b.maxY, 600 + hh, accuracy: 1e-6)
        // The same ellipse on the 16:9 frame has the same pixel box.
        let b2 = DetectedShape.ellipse(centre: CGPoint(x: 1000, y: 600), semiAxisX: 400, semiAxisY: 200, rotation: rotation, frame: sixteenNine)
            .bounds(in: sixteenNine)
        XCTAssertEqual(b2.minX, b.minX, accuracy: 1e-6)
        XCTAssertEqual(b2.maxY, b.maxY, accuracy: 1e-6)
    }

    func testQuadBoundsAreTheCornersExtremes() {
        let corners = [CGPoint(x: 500, y: 400), CGPoint(x: 1500, y: 450), CGPoint(x: 1480, y: 1200), CGPoint(x: 520, y: 1150)]
        let quad = DetectedShape.quad(corners: corners, frame: fourThree)
        let b = quad.bounds(in: fourThree)
        XCTAssertEqual(b.minX, 500, accuracy: 1e-6)
        XCTAssertEqual(b.minY, 400, accuracy: 1e-6)
        XCTAssertEqual(b.maxX, 1500, accuracy: 1e-6)
        XCTAssertEqual(b.maxY, 1200, accuracy: 1e-6)
        let m = quad.margins(in: fourThree)
        XCTAssertEqual(m.left, 500, accuracy: 1e-6)
        XCTAssertEqual(m.top, 400, accuracy: 1e-6)
        XCTAssertEqual(m.right, 4032 - 1500, accuracy: 1e-6)
        XCTAssertEqual(m.bottom, 3024 - 1200, accuracy: 1e-6)

        // A quad decoded without corners falls back to the rectangle its
        // sides span, turned by the top edge: level, 1000 × 600 about (1000, 600).
        // (Float literals throughout: integer ones would pick CGPoint's Int initialiser and divide to 0.)
        let sides = DetectedShape(kind: .quad, centre: CGPoint(x: 1000.0 / 4032, y: 600.0 / 3024), majorAxis: 1000.0 / 4032,
                                  minorAxis: 600.0 / 4032, rotation: 0, corners: nil, confidence: 1, nativeDiameterPx: 1000, wide: true)
        let sb = sides.bounds(in: fourThree)
        XCTAssertEqual(sb.minX, 500, accuracy: 1e-6)
        XCTAssertEqual(sb.maxX, 1500, accuracy: 1e-6)
        XCTAssertEqual(sb.minY, 300, accuracy: 1e-6)
        XCTAssertEqual(sb.maxY, 900, accuracy: 1e-6)
    }

    func testMarginsGoNegativeWhereTheShapeSpillsOut() {
        let circle = DetectedShape.ellipse(centre: CGPoint(x: 100, y: 600), semiAxisX: 300, semiAxisY: 300, rotation: 0, frame: sixteenNine)
        let m = circle.margins(in: sixteenNine)
        XCTAssertEqual(m.left, -200, accuracy: 1e-6, "200 px past the left edge")
        XCTAssertEqual(m.top, 300, accuracy: 1e-6)
        XCTAssertEqual(m.right, 1920 - 400, accuracy: 1e-6)
        XCTAssertEqual(m.bottom, 1080 - 900, accuracy: 1e-6)
    }
}

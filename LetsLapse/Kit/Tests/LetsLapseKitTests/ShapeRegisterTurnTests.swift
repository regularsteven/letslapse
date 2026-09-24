import CoreGraphics
import XCTest
@testable import LetsLapseKit

/// Rotate 90° is a record (2026-09-24): a project's shapes turn with the
/// picture instead of the picture being rewritten.
final class ShapeRegisterTurnTests: XCTestCase {

    private let frame = CGSize(width: 4000, height: 3000)

    func testAnEllipseFollowsTheSceneThroughATurn() {
        // A wide oval up and to the left, its major axis a little clockwise of horizontal.
        let oval = DetectedShape.ellipse(centre: CGPoint(x: 1000, y: 600), semiAxisX: 400, semiAxisY: 200,
                                         rotation: 0.2, frame: frame)
        let turned = oval.turnedQuarter(frame: frame)
        let after = CGSize(width: 3000, height: 4000)
        // (1000, 600) on 4000×3000 lands at (3000 − 600, 1000) on 3000×4000.
        XCTAssertEqual(Double(turned.centre.x) * 3000, 2400, accuracy: 1e-6)
        XCTAssertEqual(Double(turned.centre.y) * 4000, 1000, accuracy: 1e-6)
        // The same pixels across, the angle a quarter on.
        XCTAssertEqual(turned.majorAxis * Double(after.width), 800, accuracy: 1e-6)
        XCTAssertEqual(turned.minorAxis * Double(after.width), 400, accuracy: 1e-6)
        XCTAssertEqual(turned.rotation, 0.2 + .pi / 2 - .pi, accuracy: 1e-9, "wrapped into (−π/2, π/2]")
        XCTAssertEqual(turned.nativeDiameterPx, oval.nativeDiameterPx)
        // Four turns is where it started.
        var back = oval
        for size in [frame, after, frame, after] { back = back.turnedQuarter(frame: size) }
        XCTAssertEqual(Double(back.centre.x), Double(oval.centre.x), accuracy: 1e-9)
        XCTAssertEqual(Double(back.centre.y), Double(oval.centre.y), accuracy: 1e-9)
        XCTAssertEqual(back.majorAxis, oval.majorAxis, accuracy: 1e-9)
        XCTAssertEqual(back.rotation, oval.rotation, accuracy: 1e-9)
    }

    func testAQuadKeepsItsCornerOrderAndBecomesTall() {
        // A wide rectangle, 1200 × 600 px, square to the frame.
        let px = [CGPoint(x: 400, y: 300), CGPoint(x: 1600, y: 300), CGPoint(x: 1600, y: 900), CGPoint(x: 400, y: 900)]
        var quad = DetectedShape.quad(corners: px, frame: frame)
        quad.rectifiedAspect = 2
        XCTAssertTrue(quad.wide)
        let turned = quad.turnedQuarter(frame: frame)
        let after = CGSize(width: 3000, height: 4000)
        let corners = turned.corners!.map { CGPoint(x: $0.x * after.width, y: $0.y * after.height) }
        // Clockwise from top-left on the turned picture: the old bottom-left is the new top-left.
        XCTAssertEqual(corners[0].x, 2100, accuracy: 1e-6); XCTAssertEqual(corners[0].y, 400, accuracy: 1e-6)
        XCTAssertEqual(corners[1].x, 2700, accuracy: 1e-6); XCTAssertEqual(corners[1].y, 400, accuracy: 1e-6)
        XCTAssertEqual(corners[2].x, 2700, accuracy: 1e-6); XCTAssertEqual(corners[2].y, 1600, accuracy: 1e-6)
        XCTAssertEqual(corners[3].x, 2100, accuracy: 1e-6); XCTAssertEqual(corners[3].y, 1600, accuracy: 1e-6)
        XCTAssertFalse(turned.wide, "the long sides now stand upright")
        XCTAssertEqual(turned.rectifiedAspect!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(turned.majorAxis * 3000, 1200, accuracy: 1e-6)
        XCTAssertEqual(turned.bounds(in: after).width, 600, accuracy: 1e-6)
        XCTAssertEqual(turned.bounds(in: after).height, 1200, accuracy: 1e-6)
    }

    func testTheRegistersFrameAndLensTurn() {
        let rep = ShapeRegister.Representative(relativePath: "source/a.jpg", source: .sourceFrame,
                                               width: 4000, height: 3000, horizontalFieldOfView: 70)
        let register = ShapeRegister(representative: rep, shapes: [
            .ellipse(centre: CGPoint(x: 2000, y: 1500), semiAxisX: 300, semiAxisY: 300, rotation: 0, frame: frame),
        ])
        let turned = register.turnedQuarter()
        XCTAssertEqual(turned.representative.width, 3000)
        XCTAssertEqual(turned.representative.height, 4000)
        // The old vertical field of view: 2·atan(tan(35°)·3/4).
        let expected = 2 * atan(tan(35 * Double.pi / 180) * 0.75) * 180 / .pi
        XCTAssertEqual(turned.representative.horizontalFieldOfView!, expected, accuracy: 1e-9)
        XCTAssertEqual(Double(turned.shapes[0].centre.x), 0.5, accuracy: 1e-9)
        XCTAssertEqual(Double(turned.shapes[0].centre.y), 0.5, accuracy: 1e-9)
    }
}

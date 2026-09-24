import CoreGraphics
import XCTest
@testable import LetsLapseKit

/// A framing review measured before a Rotate 90° (a record, 2026-09-24)
/// is turned at load, so the lock keeps undoing the same knocks on the
/// turned picture.
final class FramingLockTurnTests: XCTestCase {

    private func review(quarterTurns: Int = 0) -> FramingReview {
        let offsets = (0 ..< 5).map { index in
            // A knock on the third photo: the scene sits 12 px right, 4 px down.
            FramingReview.Offset(name: "frame-\(index).jpg",
                                 dx: index == 2 ? 12 : 0, dy: index == 2 ? 4 : 0, confidence: 0.9)
        }
        return FramingReview.make(width: 4000, height: 3000, measurementScale: 0.5,
                                  offsets: offsets, quarterTurns: quarterTurns).applyingPlan()
    }

    func testAShiftFollowsTheSceneThroughAQuarterTurn() throws {
        let measured = review()
        let upright = try XCTUnwrap(FramingLock(review: measured))
        let turned = try XCTUnwrap(FramingLock(review: measured, turnedBy: 1))
        let before = upright.offset(forName: "frame-2.jpg")
        let after = turned.offset(forName: "frame-2.jpg")
        // Right becomes down, down becomes left.
        XCTAssertEqual(after.dx, -before.dy, accuracy: 1e-9)
        XCTAssertEqual(after.dy, before.dx, accuracy: 1e-9)
        XCTAssertEqual(turned.insetX, upright.insetY)
        XCTAssertEqual(turned.insetY, upright.insetX)
        XCTAssertEqual(turned.cropFraction, upright.cropFraction)
        // A full turn is the lock as measured.
        let around = try XCTUnwrap(FramingLock(review: measured, turnedBy: 4))
        XCTAssertEqual(around, upright)
    }

    func testTheReviewRecordsTheTurnItWasMeasuredAt() throws {
        XCTAssertNil(review().quarterTurns, "none is nil — reviews from before read the same")
        let atOne = review(quarterTurns: 1)
        XCTAssertEqual(atOne.quarterTurns, 1)
        let data = try atOne.data()
        XCTAssertEqual(try FramingReview.decode(data).quarterTurns, 1)
    }
}

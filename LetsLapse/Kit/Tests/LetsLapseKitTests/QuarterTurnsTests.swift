import CoreGraphics
import ImageIO
import XCTest
@testable import LetsLapseKit

final class QuarterTurnsTests: XCTestCase {

    func testNormalizedFoldsAnyTurnIntoOneRevolution() {
        XCTAssertEqual(QuarterTurns.normalized(0), 0)
        XCTAssertEqual(QuarterTurns.normalized(5), 1)
        XCTAssertEqual(QuarterTurns.normalized(-1), 3)
        XCTAssertEqual(QuarterTurns.normalized(-8), 0)
    }

    func testOrientationComposesClockwiseAndKeepsMirroring() {
        XCTAssertEqual(QuarterTurns.orientation(.up, turnedBy: 1), .right)
        XCTAssertEqual(QuarterTurns.orientation(.up, turnedBy: 2), .down)
        XCTAssertEqual(QuarterTurns.orientation(.up, turnedBy: 3), .left)
        XCTAssertEqual(QuarterTurns.orientation(.up, turnedBy: 4), .up)
        // A camera that tagged its portrait frame .right, turned once more.
        XCTAssertEqual(QuarterTurns.orientation(.right, turnedBy: 1), .down)
        XCTAssertEqual(QuarterTurns.orientation(.left, turnedBy: 1), .up)
        XCTAssertEqual(QuarterTurns.orientation(.upMirrored, turnedBy: 1), .rightMirrored)
        XCTAssertEqual(QuarterTurns.orientation(.leftMirrored, turnedBy: 1), .upMirrored)
        XCTAssertEqual(QuarterTurns.orientation(.down, turnedBy: -1), .right)
    }

    func testTheTableAgreesWithTheOneRotateUsed() {
        XCTAssertEqual(QuarterTurns.exifTurned90CW.map(UInt16.init), MediaRotator.exifRotated90CW)
    }

    func testSizesSwapOnOddTurns() {
        XCTAssertEqual(QuarterTurns.size(CGSize(width: 4000, height: 3000), turnedBy: 1), CGSize(width: 3000, height: 4000))
        XCTAssertEqual(QuarterTurns.size(CGSize(width: 4000, height: 3000), turnedBy: 2), CGSize(width: 4000, height: 3000))
        XCTAssertTrue(QuarterTurns.dimensions(width: 1920, height: 1080, turnedBy: 3) == (1080, 1920))
    }

    func testVideoTransformTurnsTheDisplayedPictureClockwiseAtTheOrigin() {
        let natural = CGSize(width: 1920, height: 1080)
        let turned = QuarterTurns.transform(.identity, naturalSize: natural, turnedBy: 1)
        // Top-left of a landscape frame lands top-right; its top-right lands bottom-right.
        assertPoint(CGPoint(x: 0, y: 0).applying(turned), CGPoint(x: 1080, y: 0))
        assertPoint(CGPoint(x: 1920, y: 0).applying(turned), CGPoint(x: 1080, y: 1920))
        XCTAssertEqual(QuarterTurns.displaySize(naturalSize: natural, transform: turned), CGSize(width: 1080, height: 1920))
        // Two turns is upside down, within the same box.
        let half = QuarterTurns.transform(.identity, naturalSize: natural, turnedBy: 2)
        assertPoint(CGPoint(x: 0, y: 0).applying(half), CGPoint(x: 1920, y: 1080))
        // Four turns is the track as it was.
        XCTAssertEqual(QuarterTurns.transform(.identity, naturalSize: natural, turnedBy: 4), .identity)
    }

    func testVideoTransformComposesWithAPortraitTrack() {
        // An iPhone portrait movie: 1920×1080 natural, shown 1080×1920 by its own transform.
        let natural = CGSize(width: 1920, height: 1080)
        let portrait = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        XCTAssertEqual(QuarterTurns.displaySize(naturalSize: natural, transform: portrait), CGSize(width: 1080, height: 1920))
        let turned = QuarterTurns.transform(portrait, naturalSize: natural, turnedBy: 1)
        XCTAssertEqual(QuarterTurns.displaySize(naturalSize: natural, transform: turned), CGSize(width: 1920, height: 1080))
        // The displayed picture's top-left (natural bottom-left) ends top-right, inside the box.
        let shown = CGRect(origin: .zero, size: natural).applying(turned)
        XCTAssertEqual(shown.minX, 0, accuracy: 0.001)
        XCTAssertEqual(shown.minY, 0, accuracy: 0.001)
    }

    func testACropFollowsTheSceneThroughATurn() {
        // A 16:9 band across the top third of a landscape frame.
        let crop = FrameCrop(x: 0.1, y: 0.05, width: 0.8, height: 0.3, aspect: .sixteenNine)
        let once = crop.turned(by: 1)
        XCTAssertEqual(once.x, 0.65, accuracy: 1e-9)   // 1 − 0.05 − 0.3: the band hugs the right edge
        XCTAssertEqual(once.y, 0.1, accuracy: 1e-9)
        XCTAssertEqual(once.width, 0.3, accuracy: 1e-9)
        XCTAssertEqual(once.height, 0.8, accuracy: 1e-9)
        XCTAssertEqual(once.aspect, .nineSixteen)
        for back in [crop.turned(by: 4), crop.turned(by: 1).turned(by: 3)] {
            XCTAssertEqual(back.rect.minX, crop.rect.minX, accuracy: 1e-9)
            XCTAssertEqual(back.rect.minY, crop.rect.minY, accuracy: 1e-9)
            XCTAssertEqual(back.width, crop.width, accuracy: 1e-9)
            XCTAssertEqual(back.height, crop.height, accuracy: 1e-9)
            XCTAssertEqual(back.aspect, crop.aspect)
        }
        XCTAssertEqual(FrameCrop(x: 0, y: 0, width: 0.5, height: 0.5, aspect: .fourFive).turned(by: 1).aspect, .custom)
        XCTAssertEqual(FrameCrop.full.turned(by: 1), FrameCrop.full)
    }

    private func assertPoint(_ point: CGPoint, _ expected: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(point.x, expected.x, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(point.y, expected.y, accuracy: 0.001, file: file, line: line)
    }
}

import CoreGraphics
import CoreImage
import XCTest
@testable import LetsLapseKit

/// The crop model's geometry: fitted aspects, the clamp a drag lands on, the
/// even-rounded pixel rect the encoders need, the two `apply` paths and the
/// point maps that keep overlays on the scene.
final class FrameCropTests: XCTestCase {

    // MARK: Fitting

    func testFittedRatiosInAFourThreeFrame() {
        let frame = 4.0 / 3.0
        // A 16:9 crop is wider than 4:3, so it fills the width and drops the
        // height to (4/3) ÷ (16/9) = 0.75 of the frame, centred.
        let wide = FrameCrop.fitted(.sixteenNine, frameAspect: frame)
        XCTAssertEqual(wide.width, 1, accuracy: 1e-12)
        XCTAssertEqual(wide.height, 0.75, accuracy: 1e-12)
        XCTAssertEqual(wide.x, 0, accuracy: 1e-12)
        XCTAssertEqual(wide.y, 0.125, accuracy: 1e-12)
        XCTAssertEqual(wide.aspect, .sixteenNine)
        // A square is narrower, so it fills the height at 0.75 of the width.
        let square = FrameCrop.fitted(.square, frameAspect: frame)
        XCTAssertEqual(square.height, 1, accuracy: 1e-12)
        XCTAssertEqual(square.width, 0.75, accuracy: 1e-12)
        XCTAssertEqual(square.x, 0.125, accuracy: 1e-12)
        // And the pixel ratio comes back out exactly.
        let pixels = square.pixelRect(in: CGSize(width: 4000, height: 3000))
        XCTAssertEqual(pixels.width / pixels.height, 1, accuracy: 1e-9)
        let tall = FrameCrop.fitted(.fourFive, frameAspect: frame)
        XCTAssertEqual(tall.height, 1, accuracy: 1e-12)
        XCTAssertEqual(tall.width, 0.6, accuracy: 1e-12)
        // No ratio, no fit: the whole frame under that aspect.
        XCTAssertEqual(FrameCrop.fitted(.original, frameAspect: frame), .full)
        XCTAssertEqual(FrameCrop.fitted(.custom, frameAspect: frame).rect, CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(FrameCrop.fitted(.custom, frameAspect: frame).aspect, .custom)
    }

    func testFittedRatiosInANineSixteenFrame() {
        let frame = 9.0 / 16.0
        // 9:16 in a 9:16 frame is the frame.
        let same = FrameCrop.fitted(.nineSixteen, frameAspect: frame)
        XCTAssertEqual(same.width, 1, accuracy: 1e-12)
        XCTAssertEqual(same.height, 1, accuracy: 1e-12)
        // 16:9 in a portrait frame: full width, height (9/16) ÷ (16/9).
        let wide = FrameCrop.fitted(.sixteenNine, frameAspect: frame)
        XCTAssertEqual(wide.width, 1, accuracy: 1e-12)
        XCTAssertEqual(wide.height, 81.0 / 256.0, accuracy: 1e-12)
        XCTAssertEqual(wide.y, (1 - 81.0 / 256.0) / 2, accuracy: 1e-12)
        let pixels = wide.pixelRect(in: CGSize(width: 1080, height: 1920))
        XCTAssertEqual(pixels.width / pixels.height, 16.0 / 9.0, accuracy: 0.01)
    }

    // MARK: Clamping

    func testClampedKeepsTheCropInsideAndHoldsTheRatio() {
        let frame = 4.0 / 3.0
        // Dragged past the right and bottom edges: slides back in, ratio kept.
        let spilled = FrameCrop(x: 0.6, y: 0.5, width: 0.75, height: 1, aspect: .square)
        let held = spilled.clamped(frameAspect: frame)
        XCTAssertEqual(held.width, 0.75, accuracy: 1e-12)
        XCTAssertEqual(held.height, 1, accuracy: 1e-12)
        XCTAssertEqual(held.x, 0.25, accuracy: 1e-12)
        XCTAssertEqual(held.y, 0, accuracy: 1e-12)
        // Too big for the frame: shrinks to the fitted size.
        let huge = FrameCrop(x: -0.2, y: -0.2, width: 1.4, height: 1.4, aspect: .sixteenNine)
        let fitted = huge.clamped(frameAspect: frame)
        XCTAssertEqual(fitted.width, 1, accuracy: 1e-12)
        XCTAssertEqual(fitted.height, 0.75, accuracy: 1e-12)
        XCTAssertEqual(fitted.x, 0, accuracy: 1e-12)
        XCTAssertEqual(fitted.y, 0, accuracy: 1e-12)
        // Too small: at least the minimum on each side, ratio still held.
        let tiny = FrameCrop(x: 0.5, y: 0.5, width: 0.01, height: 0.01, aspect: .square)
        let floor = tiny.clamped(frameAspect: frame)
        XCTAssertGreaterThanOrEqual(floor.width, FrameCrop.minimumSide - 1e-12)
        XCTAssertGreaterThanOrEqual(floor.height, FrameCrop.minimumSide - 1e-12)
        XCTAssertEqual(floor.width / floor.height, 1 / frame, accuracy: 1e-12)
        // A free crop clamps each side on its own.
        let free = FrameCrop(x: 0.9, y: -0.3, width: 0.5, height: 0.02, aspect: .custom)
        let freeHeld = free.clamped(frameAspect: frame)
        XCTAssertEqual(freeHeld.width, 0.5, accuracy: 1e-12)
        XCTAssertEqual(freeHeld.height, FrameCrop.minimumSide, accuracy: 1e-12)
        XCTAssertEqual(freeHeld.x, 0.5, accuracy: 1e-12)
        XCTAssertEqual(freeHeld.y, 0, accuracy: 1e-12)
    }

    // MARK: Pixels

    func testPixelRectIsEvenAndInside() {
        let crop = FrameCrop(x: 0.1003, y: 0.2001, width: 0.4999, height: 0.3333, aspect: .custom)
        let size = CGSize(width: 4031, height: 3023)
        let rect = crop.pixelRect(in: size)
        for value in [rect.minX, rect.minY, rect.width, rect.height] {
            XCTAssertEqual(value, value.rounded(), "integer")
            XCTAssertEqual(Int(value) % 2, 0, "even: \(rect)")
        }
        XCTAssertGreaterThanOrEqual(rect.minX, 0)
        XCTAssertGreaterThanOrEqual(rect.minY, 0)
        XCTAssertLessThanOrEqual(rect.maxX, size.width)
        XCTAssertLessThanOrEqual(rect.maxY, size.height)
        // Near the nominal values.
        XCTAssertEqual(rect.minX, 0.1003 * 4031, accuracy: 2)
        XCTAssertEqual(rect.width, 0.4999 * 4031, accuracy: 2)
        // A crop pushed to the far edge is pulled back inside, not truncated.
        let edge = FrameCrop(x: 0.7, y: 0.7, width: 0.4, height: 0.4, aspect: .custom)
        let edgeRect = edge.pixelRect(in: size)
        XCTAssertLessThanOrEqual(edgeRect.maxX, size.width)
        XCTAssertLessThanOrEqual(edgeRect.maxY, size.height)
        XCTAssertEqual(edgeRect.width, 0.4 * 4031, accuracy: 2)
        // Never below 2 × 2.
        let speck = FrameCrop(x: 0.5, y: 0.5, width: 0.0001, height: 0.0001, aspect: .custom)
        XCTAssertEqual(speck.pixelRect(in: size).size, CGSize(width: 2, height: 2))
        // Output size: the frame itself when the crop is full.
        XCTAssertEqual(FrameCrop.full.outputSize(for: size), size)
        XCTAssertEqual(crop.outputSize(for: size), rect.size)
        // A damaged crop — finite but far outside the unit square, which a
        // hand-edited file can carry through decoding — is the whole frame,
        // not a trap in `Int(_:)`.
        let whole = CGRect(x: 0, y: 0, width: 4030, height: 3022)
        let absurd = FrameCrop(x: 1e300, y: 0, width: 0.5, height: 0.5, aspect: .custom)
        XCTAssertEqual(absurd.pixelRect(in: size), whole)
        let negative = FrameCrop(x: -3, y: 0, width: 0.5, height: 0.5, aspect: .custom)
        XCTAssertEqual(negative.pixelRect(in: size), whole)
        let nan = FrameCrop(x: .nan, y: 0, width: 0.5, height: 0.5, aspect: .custom)
        XCTAssertEqual(nan.pixelRect(in: size), whole)
    }

    func testIsFullReadsSubPixelNoiseAsNoCrop() {
        XCTAssertTrue(FrameCrop.full.isFull)
        XCTAssertTrue(FrameCrop(x: 0.0002, y: 0, width: 0.9997, height: 0.9996, aspect: .custom).isFull)
        XCTAssertFalse(FrameCrop(x: 0, y: 0, width: 0.99, height: 1, aspect: .custom).isFull)
        XCTAssertFalse(FrameCrop.fitted(.square, frameAspect: 4.0 / 3.0).isFull)
    }

    // MARK: Applying

    func testApplyToCGImageCutsTheEvenRectAndLeavesAFullCropAlone() throws {
        // 64 × 48 with a gradient down the rows, so the cut's origin shows.
        let width = 64, height = 48
        let values = (0..<(width * height)).map { UInt8(($0 / width) * 5) }
        let image = makeGrayImage(width: width, height: height, values: values)
        let crop = FrameCrop(x: 0.25, y: 0.5, width: 0.5, height: 0.25, aspect: .custom)
        let cut = FrameCrop.apply(crop, to: image)
        XCTAssertEqual(cut.width, 32)
        XCTAssertEqual(cut.height, 12)
        XCTAssertEqual(CGSize(width: cut.width, height: cut.height), crop.outputSize(for: CGSize(width: width, height: height)))
        // The first row of the cut is source row 24 (y 0.5 × 48) — top-left
        // origin, as `CGImage` counts.
        XCTAssertEqual(grayValues(of: cut)[0], 24 * 5)
        let same = FrameCrop.apply(.full, to: image)
        XCTAssertEqual(same.width, width)
        XCTAssertEqual(same.height, height)
    }

    func testApplyToCIImageFlipsIntoYUpAndLandsAtTheOrigin() throws {
        let width = 64, height = 48
        let values = (0..<(width * height)).map { UInt8(($0 / width) * 5) }
        let image = CIImage(cgImage: makeGrayImage(width: width, height: height, values: values))
        let crop = FrameCrop(x: 0.25, y: 0.5, width: 0.5, height: 0.25, aspect: .custom)
        let cut = FrameCrop.apply(crop, to: image)
        XCTAssertEqual(cut.extent, CGRect(x: 0, y: 0, width: 32, height: 12))
        // Rendered, the cut's TOP row must be source row 24, the same row the
        // CGImage path cuts — the y-up flip is the whole point.
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let rendered = try XCTUnwrap(context.createCGImage(cut, from: cut.extent))
        XCTAssertEqual(grayValues(of: rendered)[0], 24 * 5)
        XCTAssertEqual(FrameCrop.apply(.full, to: image).extent, image.extent)
    }

    // MARK: Point maps

    func testPointMapsRoundTrip() {
        let crop = FrameCrop(x: 0.1, y: 0.2, width: 0.8, height: 0.6, aspect: .sixteenNine)
        let points = [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.9, y: 0.8), CGPoint(x: 0.05, y: 0.95)]
        for p in points {
            let inside = crop.mapPointIn(p)
            let back = crop.mapPointOut(inside)
            XCTAssertEqual(back.x, p.x, accuracy: 1e-12)
            XCTAssertEqual(back.y, p.y, accuracy: 1e-12)
        }
        // The crop's own corners are the cropped picture's corners.
        XCTAssertEqual(crop.mapPointIn(CGPoint(x: 0.1, y: 0.2)), CGPoint(x: 0, y: 0))
        let far = crop.mapPointIn(CGPoint(x: 0.9, y: 0.8))
        XCTAssertEqual(far.x, 1, accuracy: 1e-12)
        XCTAssertEqual(far.y, 1, accuracy: 1e-12)
        // A point in the cropped-away margin comes back outside 0…1.
        XCTAssertLessThan(crop.mapPointIn(CGPoint(x: 0.05, y: 0.5)).x, 0)
        // The full crop is the identity.
        XCTAssertEqual(FrameCrop.full.mapPointIn(CGPoint(x: 0.3, y: 0.7)), CGPoint(x: 0.3, y: 0.7))
    }

    // MARK: Token and coding

    func testCacheTokenAndCodableRoundTrip() throws {
        let crop = FrameCrop(x: 0.1, y: 0.2, width: 0.8, height: 0.6, aspect: .sixteenNine)
        XCTAssertEqual(crop.cacheToken, "c0.1000,0.2000,0.8000,0.6000:sixteenNine")
        let data = try JSONEncoder().encode(crop)
        XCTAssertEqual(try JSONDecoder().decode(FrameCrop.self, from: data), crop)
        XCTAssertEqual(FrameCrop.Aspect.allCases.map(\.label), ["Original", "1:1", "4:5", "16:9", "9:16", "Custom"])
    }
}

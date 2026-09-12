import CoreImage
import XCTest
@testable import LetsLapseKit

/// The display-referred chain and the masked stage — the one piece of
/// rendering the editor's preview, a stills export and the render bench all
/// share, which is why its promises are pinned here rather than in the app.
final class DisplayGradeTests: XCTestCase {

    private let context = CIContext(options: [.useSoftwareRenderer: false])

    /// A flat mid-grey picture with a brighter right half, so a mask that
    /// selects one side has something to change and the other side has
    /// something to keep.
    private func picture(width: Int = 64, height: Int = 32) -> CIImage {
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let left = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3))
            .cropped(to: CGRect(x: 0, y: 0, width: width / 2, height: height))
        let right = CIImage(color: CIColor(red: 0.6, green: 0.6, blue: 0.6))
            .cropped(to: CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        return right.composited(over: left).cropped(to: extent)
    }

    /// Mean red over `rect`, read back through the context's LINEAR working
    /// space (no output colour space), so the numbers are light, not code
    /// values — which is why the assertions below are ratios.
    private func mean(_ image: CIImage, in rect: CGRect) -> Double {
        var bytes = [UInt8](repeating: 0, count: Int(rect.width * rect.height) * 4)
        context.render(image, toBitmap: &bytes, rowBytes: Int(rect.width) * 4,
                       bounds: rect, format: .RGBA8, colorSpace: nil)
        var total = 0.0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            total += Double(bytes[index])
        }
        return total / Double(bytes.count / 4) / 255
    }

    // MARK: - DisplayGrade

    func testANeutralGradeHandsBackTheSameImage() {
        let image = picture()
        let out = DisplayGrade.apply(image, .neutral)
        XCTAssertTrue(out === image, "a neutral grade must cost nothing — no filter, no copy")
    }

    func testExposureMovesTheWholePictureTheWayItSays() {
        let image = picture()
        let whole = image.extent
        var up = DisplayGrade(); up.exposure = 1
        var down = DisplayGrade(); down.exposure = -1
        let base = mean(image, in: whole)
        // +1 EV doubles linear light, −1 EV halves it; the tolerance is for
        // the 8-bit readback.
        XCTAssertEqual(mean(DisplayGrade.apply(image, up), in: whole) / base, 2, accuracy: 0.15)
        XCTAssertEqual(mean(DisplayGrade.apply(image, down), in: whole) / base, 0.5, accuracy: 0.08)
    }

    func testTheGradeKeepsThePicturesExtent() {
        // Clarity's unsharp mask and the vignette both reach past the frame;
        // the chain crops back so a masked composite lines up pixel for pixel.
        let image = picture()
        var grade = DisplayGrade()
        grade.clarity = 0.8
        grade.vignette = 0.5
        grade.exposure = 0.3
        XCTAssertEqual(DisplayGrade.apply(image, grade).extent, image.extent)
    }

    /// The signed vignette on this path: positive takes a corner down,
    /// negative takes the same corner up, the centre stays put either way,
    /// and the midpoint moves `CIVignette`'s radius the way the engine's
    /// start moves — a wider midpoint shades the corner less.
    func testTheVignetteIsSignedAndTheMidpointWidensIt() {
        let width = 128, height = 96
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        let corner = CGRect(x: 0, y: 0, width: 4, height: 4)
        let centre = CGRect(x: width / 2 - 2, y: height / 2 - 2, width: 4, height: 4)
        let flat = mean(image, in: corner)

        var dark = DisplayGrade(); dark.vignette = 0.5
        var light = DisplayGrade(); light.vignette = -0.5
        var wide = DisplayGrade(); wide.vignette = 0.5; wide.vignetteMidpoint = 1
        XCTAssertLessThan(mean(DisplayGrade.apply(image, dark), in: corner), flat - 0.05)
        XCTAssertGreaterThan(mean(DisplayGrade.apply(image, light), in: corner), flat + 0.05)
        XCTAssertEqual(mean(DisplayGrade.apply(image, dark), in: centre), flat, accuracy: 0.02)
        XCTAssertEqual(mean(DisplayGrade.apply(image, light), in: centre), flat, accuracy: 0.02)
        XCTAssertGreaterThan(mean(DisplayGrade.apply(image, wide), in: corner),
                             mean(DisplayGrade.apply(image, dark), in: corner),
                             "a wider midpoint shades the corner less")
        XCTAssertEqual(DisplayGrade.vignetteRadius(midpoint: 0.5), DisplayGrade.vignetteRadius,
                       "the neutral midpoint is the radius this path always used")
    }

    func testTheMaskTravelClampIsTheEditorsOwn() {
        var grade = DisplayGrade()
        grade.exposure = 4          // Lightroom's local +4 EV
        grade.temperatureMired = 60 // past the ±25 nudge
        grade.shadows = 1.4
        grade.vignette = -1.6          // the vignette is signed; ±1 is its travel
        grade.vignetteMidpoint = 1.4
        let held = MaskedGradeStage.clampedToMaskTravel(grade)
        XCTAssertEqual(held.exposure, MaskedGradeStage.exposureRange.upperBound)
        XCTAssertEqual(held.temperatureMired, MaskedGradeStage.temperatureRange.upperBound)
        XCTAssertEqual(held.shadows, 1)
        XCTAssertEqual(held.vignette, -1)
        XCTAssertEqual(held.vignetteMidpoint, 1)
        XCTAssertEqual(MaskedGradeStage.exposureRange, -2...2)
        XCTAssertEqual(MaskedGradeStage.temperatureRange, -25...25)
    }

    // MARK: - MaskedGradeStage

    func testAWhiteSelectionIsTheWholeGradeAndABlackOneIsNone() {
        let image = picture()
        let whole = image.extent
        var grade = DisplayGrade(); grade.exposure = 1
        let white = CIImage(color: .white).cropped(to: whole)
        let black = CIImage(color: .black).cropped(to: whole)
        let everywhere = MaskedGradeStage.apply(grade, to: image, through: white)
        let nowhere = MaskedGradeStage.apply(grade, to: image, through: black)
        XCTAssertEqual(mean(everywhere, in: whole),
                       mean(DisplayGrade.apply(image, grade), in: whole), accuracy: 1.5 / 255)
        XCTAssertEqual(mean(nowhere, in: whole), mean(image, in: whole), accuracy: 1.5 / 255)
    }

    func testTheGradeStopsAtTheSelectionsEdge() {
        let image = picture()
        let leftHalf = CGRect(x: 0, y: 0, width: 32, height: 32)
        let rightHalf = CGRect(x: 32, y: 0, width: 32, height: 32)
        // Select the left half only.
        let selection = CIImage(color: .white).cropped(to: leftHalf)
            .composited(over: CIImage(color: .black).cropped(to: image.extent))
            .cropped(to: image.extent)
        var grade = DisplayGrade(); grade.exposure = 1
        let out = MaskedGradeStage.apply(grade, to: image, through: selection)
        XCTAssertEqual(mean(out, in: leftHalf) / mean(image, in: leftHalf), 2, accuracy: 0.15,
                       "the selected half is graded")
        XCTAssertEqual(mean(out, in: rightHalf), mean(image, in: rightHalf), accuracy: 1.5 / 255,
                       "the unselected half is untouched")
    }

    func testANeutralMaskedGradeIsFree() {
        let image = picture()
        let white = CIImage(color: .white).cropped(to: image.extent)
        XCTAssertTrue(MaskedGradeStage.apply(.neutral, to: image, through: white) === image)
    }

    // MARK: - The shape renderer draws the coverage the model defines

    private func sample(_ mask: CIImage, at point: CGPoint, size: CGSize) -> Double {
        // Picture space (top-left origin) → Core Image (bottom-left).
        let rect = CGRect(x: point.x.rounded(.down), y: (size.height - point.y).rounded(.down) - 1,
                          width: 1, height: 1)
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(mask, toBitmap: &bytes, rowBytes: 4, bounds: rect,
                       format: .RGBA8, colorSpace: nil)
        return Double(bytes[0]) / 255
    }

    func testTheRadialRendererAgreesWithMaskShapeCoverage() throws {
        let size = CGSize(width: 200, height: 120)
        let shape = MaskShape(kind: .radial, center: CGPoint(x: 0.4, y: 0.5),
                              radiusX: 0.3, radiusY: 0.3, rotationDegrees: 25, feather: 0.5)
        let mask = try XCTUnwrap(MaskShapeRenderer.maskImage(
            shape, extent: CGRect(origin: .zero, size: size)))
        for point in [CGPoint(x: 80, y: 60), CGPoint(x: 120, y: 60), CGPoint(x: 80, y: 20),
                      CGPoint(x: 190, y: 110), CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 75)] {
            let expected = shape.coverage(at: point, in: size)
            XCTAssertEqual(sample(mask, at: point, size: size), expected, accuracy: 0.08,
                           "at \(point)")
        }
        let inverted = try XCTUnwrap(MaskShapeRenderer.maskImage(
            shape, extent: CGRect(origin: .zero, size: size), inverted: true))
        XCTAssertEqual(sample(inverted, at: CGPoint(x: 80, y: 60), size: size), 0, accuracy: 0.02)
        XCTAssertEqual(sample(inverted, at: CGPoint(x: 10, y: 10), size: size), 1, accuracy: 0.02)
    }

    func testTheLinearRendererAgreesWithMaskShapeCoverage() throws {
        let size = CGSize(width: 200, height: 120)
        // Full at the bottom, fading to nothing at the top — a sky-darkening
        // gradient turned upside down, to catch the y flip.
        let shape = MaskShape.linear(from: CGPoint(x: 0.5, y: 0.8), to: CGPoint(x: 0.5, y: 0.2), feather: 1)
        let mask = try XCTUnwrap(MaskShapeRenderer.maskImage(
            shape, extent: CGRect(origin: .zero, size: size)))
        for y in stride(from: 6.0, through: 114, by: 18) {
            let point = CGPoint(x: 70, y: y)
            XCTAssertEqual(sample(mask, at: point, size: size), shape.coverage(at: point, in: size),
                           accuracy: 0.06, "at y \(y)")
        }
    }
}

import CoreImage
import XCTest
@testable import LetsLapseKit

/// The HSL panel's promises: neutral is identity, a band's slider moves that
/// band's colours and leaves the others alone, and the three axes do what
/// their names say.
final class HSLAdjustmentsTests: XCTestCase {

    private let context = CIContext(options: [
        .useSoftwareRenderer: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!,
    ])

    /// A flat patch of one linear colour.
    private func patch(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
    }

    /// The centre pixel as linear RGB.
    private func read(_ image: CIImage) -> (r: Double, g: Double, b: Double) {
        var pixel = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &pixel, rowBytes: 16,
                       bounds: CGRect(x: 4, y: 4, width: 1, height: 1),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))
        return (Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
    }

    private func saturation(_ p: (r: Double, g: Double, b: Double)) -> Double {
        let top = max(p.r, p.g, p.b), bottom = min(p.r, p.g, p.b)
        return top > 0 ? (top - bottom) / top : 0
    }

    func testNeutralIsTheSameImage() {
        let image = patch(0.5, 0.2, 0.1)
        XCTAssertTrue(HSLAdjustments.apply(.neutral, to: image) === image)
        XCTAssertTrue(HSLAdjustments.neutral.isNeutral)
        XCTAssertEqual(HSLAdjustments.neutral.cacheToken, "")
    }

    func testDesaturatingBlueGreysABlueAndLeavesAnOrangeAlone() throws {
        var panel = HSLAdjustments()
        panel[saturation: .blue] = -1
        // A blue on the band's centre (hue 240°: red and green equal). A blue
        // leaning toward aqua keeps the aqua share of its chroma — the bands
        // are triangular and neighbours share a pixel, which is why the
        // photographers in the corpus pull Aqua AND Blue to grey a sky.
        let blue = patch(0.05, 0.05, 0.6)
        let orange = patch(0.6, 0.25, 0.05)
        let greyedBlue = read(try XCTUnwrap(HSLAdjustments.apply(panel, to: blue)))
        let sameOrange = read(try XCTUnwrap(HSLAdjustments.apply(panel, to: orange)))
        XCTAssertLessThan(saturation(greyedBlue), 0.05, "blue at −100 saturation is grey")
        let before = read(orange)
        XCTAssertEqual(sameOrange.r, before.r, accuracy: 0.01)
        XCTAssertEqual(sameOrange.g, before.g, accuracy: 0.01)
        XCTAssertEqual(sameOrange.b, before.b, accuracy: 0.01)
    }

    func testSaturationUpRaisesChroma() throws {
        var panel = HSLAdjustments()
        panel[saturation: .orange] = 1
        let orange = patch(0.5, 0.25, 0.1)
        let out = read(try XCTUnwrap(HSLAdjustments.apply(panel, to: orange)))
        XCTAssertGreaterThan(saturation(out), saturation(read(orange)) + 0.1)
    }

    func testLuminanceDownDarkensTheBandOnly() throws {
        var panel = HSLAdjustments()
        panel[luminance: .green] = -1
        let green = patch(0.1, 0.5, 0.1)
        let red = patch(0.5, 0.1, 0.1)
        let darkGreen = read(try XCTUnwrap(HSLAdjustments.apply(panel, to: green)))
        let sameRed = read(try XCTUnwrap(HSLAdjustments.apply(panel, to: red)))
        XCTAssertLessThan(darkGreen.g, 0.2, "a saturated green at −100 luminance goes toward black")
        XCTAssertEqual(sameRed.r, 0.5, accuracy: 0.01)
    }

    func testLuminanceLeavesAGreyAlone() throws {
        var panel = HSLAdjustments()
        panel[luminance: .green] = -1
        panel[luminance: .blue] = 1
        let grey = patch(0.3, 0.3, 0.3)
        let out = read(try XCTUnwrap(HSLAdjustments.apply(panel, to: grey)))
        XCTAssertEqual(out.r, 0.3, accuracy: 0.01)
        XCTAssertEqual(out.g, 0.3, accuracy: 0.01)
        XCTAssertEqual(out.b, 0.3, accuracy: 0.01)
    }

    func testHueTurnsOrangeTowardYellow() throws {
        var panel = HSLAdjustments()
        panel[hue: .orange] = 1
        // A saturated orange: red high, green mid, blue low.
        let orange = patch(0.6, 0.25, 0.02)
        let before = read(orange)
        let after = read(try XCTUnwrap(HSLAdjustments.apply(panel, to: orange)))
        // Toward yellow means green climbs relative to red.
        XCTAssertGreaterThan(after.g / after.r, before.g / before.r + 0.1)
    }

    func testValuesAreHeldToTheSlidersTravel() {
        var panel = HSLAdjustments()
        panel[saturation: .red] = 3
        panel[hue: .aqua] = -4
        XCTAssertEqual(panel.clamped[saturation: .red], 1)
        XCTAssertEqual(panel.clamped[hue: .aqua], -1)
        XCTAssertEqual(panel.movedCount, 2)
    }

    func testTheImportCarriesThePanel() throws {
        var sidecar = LightroomSidecar()
        sidecar.settings["Exposure2012"] = "0"
        sidecar.settings["SaturationAdjustmentAqua"] = "-94"
        sidecar.settings["HueAdjustmentRed"] = "-16"
        sidecar.settings["LuminanceAdjustmentOrange"] = "+43"
        let map = LightroomImport.map(sidecar)
        let panel = try XCTUnwrap(map.hsl)
        XCTAssertEqual(panel[saturation: .aqua], -0.94, accuracy: 1e-6)
        XCTAssertEqual(panel[hue: .red], -0.16, accuracy: 1e-6)
        XCTAssertEqual(panel[luminance: .orange], 0.43, accuracy: 1e-6)
        XCTAssertEqual(panel.movedCount, 3)
        XCTAssertTrue(map.applied.contains { $0.contains("HSL panel") && $0.contains("3 sliders") })
        XCTAssertFalse(map.unsupported.contains { $0.contains("HSL") })
    }

    func testAFileWithoutHSLCarriesNone() {
        var sidecar = LightroomSidecar()
        sidecar.settings["Exposure2012"] = "0.5"
        XCTAssertNil(LightroomImport.map(sidecar).hsl)
    }
}

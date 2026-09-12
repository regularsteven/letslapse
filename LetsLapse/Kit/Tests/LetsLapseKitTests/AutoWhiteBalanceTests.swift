import CoreGraphics
import simd
import XCTest
@testable import LetsLapseKit

/// The grey-world estimator's arithmetic, through its pure entry point: a
/// neutral mean moves nothing, a warm cast declares a warmer white, a green
/// cast asks for magenta. Then the picture path on a synthetic frame, so the
/// draw-and-average and its gates are exercised too.
final class AutoWhiteBalanceTests: XCTestCase {

    // MARK: The maths

    func testANeutralGreyMeanReturnsTheCurrentWhite() throws {
        for (kelvin, tint) in [(5600.0, 0.0), (3200.0, 12.0), (7500.0, -40.0)] {
            let estimate = try XCTUnwrap(AutoWhiteBalance.estimate(
                meanLinearRGB: SIMD3<Double>(0.18, 0.18, 0.18), currentKelvin: kelvin, currentTint: tint))
            XCTAssertEqual(1_000_000 / estimate.kelvin, 1_000_000 / kelvin, accuracy: 1,
                           "a grey mean must keep the white within a mired")
            XCTAssertEqual(estimate.tint, tint, accuracy: 0.5, "and keep the tint")
        }
    }

    func testAnOrangeCastDeclaresAWarmerWhite() throws {
        // Roughly tungsten light on a grey card, as a D65-encoded picture
        // would show it: red well up, blue well down.
        let orange = SIMD3<Double>(0.30, 0.18, 0.08)
        let estimate = try XCTUnwrap(AutoWhiteBalance.estimate(
            meanLinearRGB: orange, currentKelvin: 5600, currentTint: 0))
        XCTAssertLessThan(estimate.kelvin, 5600, "the declared white moves warmer (lower Kelvin)")
        XCTAssertLessThan(estimate.kelvin, 4500, "and by a lot for a cast this strong")
        XCTAssertGreaterThan(estimate.kelvin, 1667, "but stays inside the converter's travel")
        // And the mirror: a blue cast declares a cooler white.
        let blue = SIMD3<Double>(0.10, 0.16, 0.30)
        let cooler = try XCTUnwrap(AutoWhiteBalance.estimate(
            meanLinearRGB: blue, currentKelvin: 5600, currentTint: 0))
        XCTAssertGreaterThan(cooler.kelvin, 5600)
    }

    func testAGreenCastReturnsAPositiveTintDelta() throws {
        // Green above the locus: the same red and blue, more green.
        let green = SIMD3<Double>(0.16, 0.22, 0.16)
        let estimate = try XCTUnwrap(AutoWhiteBalance.estimate(
            meanLinearRGB: green, currentKelvin: 5600, currentTint: 10))
        XCTAssertGreaterThan(estimate.tint, 10, "a green cast needs magenta, which is positive tint")
        XCTAssertLessThanOrEqual(estimate.tint, 150)
        // And a magenta cast asks for green.
        let magenta = SIMD3<Double>(0.20, 0.16, 0.20)
        let opposite = try XCTUnwrap(AutoWhiteBalance.estimate(
            meanLinearRGB: magenta, currentKelvin: 5600, currentTint: 10))
        XCTAssertLessThan(opposite.tint, 10)
    }

    func testTheEstimateIsClampedToTheConvertersTravel() throws {
        // A cast this extreme would push past the ends; the answer stays
        // inside 40…600 mired and ±150 tint.
        let extreme = try XCTUnwrap(AutoWhiteBalance.estimate(
            meanLinearRGB: SIMD3<Double>(0.9, 0.1, 0.01), currentKelvin: 2000, currentTint: 140))
        XCTAssertGreaterThanOrEqual(extreme.kelvin, 1666)
        XCTAssertLessThanOrEqual(extreme.kelvin, 25001)
        XCTAssertLessThanOrEqual(abs(extreme.tint), 150)
    }

    func testAMeanWithNoColourGivesNoEstimate() {
        XCTAssertNil(AutoWhiteBalance.estimate(
            meanLinearRGB: SIMD3<Double>(0, 0, 0), currentKelvin: 5600, currentTint: 0))
        XCTAssertNil(AutoWhiteBalance.estimate(
            meanLinearRGB: SIMD3<Double>(.nan, 0.2, 0.2), currentKelvin: 5600, currentTint: 0))
    }

    func testMcCamyReadsD65AsAboutSixtyFiveHundred() {
        let kelvin = AutoWhiteBalance.correlatedColorTemperature(x: 0.3127, y: 0.3290)
        XCTAssertEqual(kelvin, 6504, accuracy: 15)
        XCTAssertEqual(AutoWhiteBalance.correlatedColorTemperature(x: 0.4476, y: 0.4074), 2856, accuracy: 40,
                       "illuminant A")
    }

    // MARK: The picture path

    /// An sRGB frame filled with one 8-bit colour, plus a black border and a
    /// clipped white patch the gates should leave out.
    private func picture(r: UInt8, g: UInt8, b: UInt8, width: Int = 400, height: Int = 300) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let border = x < 20 || y < 20 || x >= width - 20 || y >= height - 20
                let patch = x >= width / 2 - 30 && x < width / 2 + 30 && y >= height / 2 - 30 && y < height / 2 + 30
                let (pr, pg, pb): (UInt8, UInt8, UInt8) = border ? (0, 0, 0) : patch ? (255, 255, 255) : (r, g, b)
                bytes[i] = pr; bytes[i + 1] = pg; bytes[i + 2] = pb; bytes[i + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    func testAGreyPictureKeepsTheWhiteAndTheGatesSkipBlackAndClipped() throws {
        // Mid grey with a black border and a blown patch: the gates drop
        // both, so the mean is the grey and the white does not move.
        let grey = try picture(r: 118, g: 118, b: 118)
        let mean = try XCTUnwrap(AutoWhiteBalance.meanLinearRGB(of: grey))
        let expected = AutoWhiteBalance.srgbToLinear(118.0 / 255)
        // The downscale blends a ring of pixels along the border and the
        // patch, which is why the absolute tolerance is loose; what matters
        // is that the mean is still grey, and that is exact.
        XCTAssertEqual(mean.x, expected, accuracy: 0.01)
        XCTAssertEqual(mean.y, mean.x, accuracy: 1e-9)
        XCTAssertEqual(mean.z, mean.x, accuracy: 1e-9)
        let estimate = try XCTUnwrap(AutoWhiteBalance.estimate(image: grey, currentKelvin: 5200, currentTint: -5))
        XCTAssertEqual(1_000_000 / estimate.kelvin, 1_000_000 / 5200, accuracy: 1.5)
        XCTAssertEqual(estimate.tint, -5, accuracy: 1)
    }

    func testAnOrangePictureDeclaresAWarmerWhite() throws {
        let warm = try picture(r: 190, g: 120, b: 60)
        let estimate = try XCTUnwrap(AutoWhiteBalance.estimate(image: warm, currentKelvin: 5600, currentTint: 0))
        XCTAssertLessThan(estimate.kelvin, 5000)
    }

    func testANearBlackPictureFallsBackToEveryPixelRatherThanNothing() throws {
        // Everything under the dark floor: the gate would leave nothing, so
        // every pixel counts and a (dim, warm) estimate still comes back.
        let dim = try picture(r: 4, g: 3, b: 1)
        XCTAssertNotNil(AutoWhiteBalance.meanLinearRGB(of: dim))
        let estimate = AutoWhiteBalance.estimate(image: dim, currentKelvin: 5600, currentTint: 0)
        XCTAssertNotNil(estimate)
    }
}

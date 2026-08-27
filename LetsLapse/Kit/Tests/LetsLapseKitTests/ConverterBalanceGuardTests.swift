import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import simd
@testable import LetsLapseKit

/// The guard that keeps `.cirawFilter` from *silently* losing, or violently
/// overdoing, the white balance it is supposed to own.
///
/// `.cirawFilter` is the only path that does not nudge pixels. It **declares
/// an illuminant** — it tells `CIRAWFilter` what light the picture was taken
/// under and lets the converter adapt away from it, in camera space, ahead of
/// Apple's device profile. That makes the path's whole behaviour a function of
/// one reading (`CIRAWFilter.neutralTemperature` / `.neutralTint`) and one
/// hand-off (the frame telling `ToneMath.wbMatrix` who applied the balance).
/// Both were unchecked, and both fail towards a wrecked picture rather than a
/// slightly wrong one:
///
/// - **A bad reading becomes a plausible extreme.** The declared mired is
///   clamped into 40…600, so a zero reading survives as 1667 K and a +60 mired
///   nudge on a daylight frame declares the light to be candlelight. The
///   converter dutifully adapts away from candlelight and the frame renders
///   violet. Bradford cannot fail this way: it uses the same anchor but as a
///   *relative* adaptation, so a bad anchor costs accuracy, not the picture.
/// - **A frame that could not be balanced in the converter still claimed it
///   had been.** `ToneMath.wbMatrix` returns identity for `.cirawFilter`
///   precisely because the pixels are already balanced — so a frame that
///   reported `.cirawFilter` without having been balanced dropped the
///   recipe's temperature and tint on the floor, at both ends of the pipeline.
///   That was reachable for every non-raw source under the path.
final class ConverterBalanceGuardTests: XCTestCase {

    // MARK: - What counts as a reading

    func testUsableNeutral_acceptsTheConvertersOwnTravel() {
        XCTAssertTrue(LinearFrameDecoder.isUsableNeutral(temperatureK: 6502, tint: 9.7))
        XCTAssertTrue(LinearFrameDecoder.isUsableNeutral(temperatureK: 1667, tint: -150))
        XCTAssertTrue(LinearFrameDecoder.isUsableNeutral(temperatureK: 25000, tint: 150))
    }

    /// The reading that produced the violet frame: nothing at all.
    func testUsableNeutral_rejectsAnUnreportedNeutral() {
        XCTAssertFalse(LinearFrameDecoder.isUsableNeutral(temperatureK: 0, tint: 0))
        XCTAssertFalse(LinearFrameDecoder.isUsableNeutral(temperatureK: -1, tint: 0))
    }

    func testUsableNeutral_rejectsOutOfTravelAndNonFinite() {
        XCTAssertFalse(LinearFrameDecoder.isUsableNeutral(temperatureK: 1666, tint: 0))
        XCTAssertFalse(LinearFrameDecoder.isUsableNeutral(temperatureK: 25001, tint: 0))
        XCTAssertFalse(LinearFrameDecoder.isUsableNeutral(temperatureK: 6500, tint: 151))
        XCTAssertFalse(LinearFrameDecoder.isUsableNeutral(temperatureK: .nan, tint: 0))
        XCTAssertFalse(LinearFrameDecoder.isUsableNeutral(temperatureK: 6500, tint: .infinity))
    }

    /// What the unguarded arithmetic did with a zero reading, spelled out so
    /// the number in the doc comment is a measurement and not a claim: it does
    /// not fail, it declares candlelight.
    func testUnguardedZeroReading_declaresCandlelight() {
        let reportedK: Double = 0
        let asShotMired = 1e6 / min(max(reportedK, 1667), 25000)
        let declaredMired = min(max(asShotMired - 60, 40), 600)
        let declaredK = 1e6 / declaredMired
        XCTAssertEqual(declaredK, 1852, accuracy: 1)
        XCTAssertFalse(LinearFrameDecoder.isUsableNeutral(temperatureK: reportedK, tint: 0))
    }

    // MARK: - Who owns the balance

    func testReportedPath_keepsThePathWhenTheConverterBalanced() {
        XCTAssertEqual(
            LinearFrameDecoder.reportedPath(
                .cirawFilter, balanceWasAsked: true, balancedInConverter: true),
            .cirawFilter)
        XCTAssertEqual(
            LinearFrameDecoder.reportedPath(
                .dcpProfile, balanceWasAsked: true, balancedInConverter: true),
            .dcpProfile)
    }

    /// Nothing was asked for, so nothing was owed — the frame reports what it
    /// ran, which is what `RawDecodePathTests.testDCPProfile_fallsBack` reads.
    func testReportedPath_keepsThePathWhenNoBalanceWasAsked() {
        XCTAssertEqual(
            LinearFrameDecoder.reportedPath(
                .cirawFilter, balanceWasAsked: false, balancedInConverter: false),
            .cirawFilter)
        XCTAssertEqual(
            LinearFrameDecoder.reportedPath(
                .dcpProfile, balanceWasAsked: false, balancedInConverter: false),
            .dcpProfile)
    }

    /// The hand-off that was dropping the balance entirely.
    func testReportedPath_handsTheBalanceBackToBradfordWhenTheConverterCouldNot() {
        XCTAssertEqual(
            LinearFrameDecoder.reportedPath(
                .cirawFilter, balanceWasAsked: true, balancedInConverter: false),
            .bradfordAdaptation)
        XCTAssertEqual(
            LinearFrameDecoder.reportedPath(
                .dcpProfile, balanceWasAsked: true, balancedInConverter: false),
            .bradfordAdaptation)
    }

    func testReportedPath_leavesTheDownstreamPathsAlone() {
        for path in [RawDecodePath.bradfordAdaptation, .forwardMatrix] {
            XCTAssertEqual(
                LinearFrameDecoder.reportedPath(
                    path, balanceWasAsked: true, balancedInConverter: false),
                path)
        }
    }

    // MARK: - End to end on a non-raw source

    /// A JPEG under `.cirawFilter`: there is no converter to balance inside,
    /// so the frame must hand the balance back rather than claim it.
    func testNonRawSource_underCIRAW_stillGetsItsWhiteBalance() throws {
        let url = try Self.writeGreyJPEG()
        defer { try? FileManager.default.removeItem(at: url) }

        var recipe = GradeRecipe()
        recipe.temperatureMired = 60
        recipe.tint = 0.4

        let decoder = try LinearFrameDecoder()
        let frame = try decoder.decode(url: url, path: .cirawFilter, recipe: recipe)

        XCTAssertEqual(
            frame.decodePath, .bradfordAdaptation,
            "a non-raw source cannot be balanced inside the raw converter")

        let matrix = ToneMath.wbMatrix(
            forDNG: url, recipe: recipe,
            reference: frame.reference(), path: frame.decodePath)
        XCTAssertFalse(
            Self.isIdentity(matrix),
            "the recipe's temperature and tint have to land somewhere")
    }

    /// The same source at a neutral recipe is still bit-identical across
    /// paths — the guard must not disturb an untouched render.
    func testNonRawSource_atNeutral_isStillIdentity() throws {
        let url = try Self.writeGreyJPEG()
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try LinearFrameDecoder()
        let frame = try decoder.decode(url: url, path: .cirawFilter, recipe: .neutral)
        let matrix = ToneMath.wbMatrix(
            forDNG: url, recipe: .neutral,
            reference: frame.reference(), path: frame.decodePath)
        XCTAssertTrue(Self.isIdentity(matrix))
    }

    // MARK: - Helpers

    private static func isIdentity(_ matrix: simd_float3x3, tolerance: Float = 1e-4) -> Bool {
        let identity = matrix_identity_float3x3
        for column in 0..<3 where simd_length(matrix[column] - identity[column]) > tolerance {
            return false
        }
        return true
    }

    /// A small flat-grey JPEG on disk — enough for the decoder's non-raw
    /// branch, which is the whole point of the test.
    private static func writeGreyJPEG() throws -> URL {
        let width = 32, height = 32
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw LapseError.gpuSetupFailed("could not build the test bitmap")
        }
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw LapseError.gpuSetupFailed("could not build the test image")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("converter-balance-\(UUID().uuidString).jpg")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw LapseError.gpuSetupFailed("could not open the test JPEG for writing")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw LapseError.gpuSetupFailed("could not write the test JPEG")
        }
        return url
    }
}

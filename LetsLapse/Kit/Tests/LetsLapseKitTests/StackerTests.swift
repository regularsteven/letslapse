import XCTest
@testable import LetsLapseKit

final class StackerTests: XCTestCase {
    func testStackingReducesNoise() throws {
        let core = try makeCore()
        let stacker = ImageStacker(core: core)
        let width = 96
        let height = 96
        var rng = SplitMix64(seed: 0xC0FFEE)

        // 12 frames of gray 128 with ±40 uniform noise per pixel.
        let frames: [[UInt8]] = (0..<12).map { _ in
            (0..<(width * height)).map { _ in
                UInt8(clamping: 128 + Int.random(in: -40...40, using: &rng))
            }
        }
        let images = frames.map { makeGrayImage(width: width, height: height, values: $0) }

        // Gamma-space averaging so the expected value is the plain byte mean.
        let stacked = try stacker.stack(images: images, linearLight: false)
        let stackedValues = grayValues(of: stacked)

        let singleDeviation = meanAbsoluteDeviation(frames[0], from: 128)
        let stackedDeviation = meanAbsoluteDeviation(stackedValues, from: 128)
        XCTAssertGreaterThan(singleDeviation, 15, "sanity: input should be noisy")
        // Averaging 12 frames should cut deviation by ~sqrt(12) ≈ 3.5×.
        XCTAssertLessThan(stackedDeviation, singleDeviation * 0.45,
            "stacking should reduce noise (single: \(singleDeviation), stacked: \(stackedDeviation))")
    }

    func testStackOfIdenticalImagesIsIdentity() throws {
        let core = try makeCore()
        let stacker = ImageStacker(core: core)
        let width = 32
        let height = 32
        let values = [UInt8](repeating: 100, count: width * height)
        let image = makeGrayImage(width: width, height: height, values: values)

        // Linear-light path: linearize → average identical values → re-encode
        // must round-trip to the original.
        let stacked = try stacker.stack(images: [image, image, image, image, image], linearLight: true)
        for value in grayValues(of: stacked) {
            XCTAssertLessThanOrEqual(abs(Int(value) - 100), 1)
        }
    }

    func testMismatchedSizesThrow() throws {
        let core = try makeCore()
        let stacker = ImageStacker(core: core)
        let a = makeGrayImage(width: 32, height: 32, values: [UInt8](repeating: 10, count: 32 * 32))
        let b = makeGrayImage(width: 16, height: 16, values: [UInt8](repeating: 10, count: 16 * 16))
        XCTAssertThrowsError(try stacker.stack(images: [a, b])) { error in
            guard case LapseError.sizeMismatch = error else {
                return XCTFail("expected sizeMismatch, got \(error)")
            }
        }
    }

    func testEmptyInputThrows() throws {
        let core = try makeCore()
        let stacker = ImageStacker(core: core)
        XCTAssertThrowsError(try stacker.stack(images: []))
    }
}

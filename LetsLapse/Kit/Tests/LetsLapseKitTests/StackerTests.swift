import CoreGraphics
import ImageIO
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

    func testStackDeepKeepsTheSubEightBitMean() throws {
        let core = try makeCore()
        let stacker = ImageStacker(core: core)
        let width = 8
        let height = 8

        // Two constant frames one 8-bit code apart: the true mean, code 100.5,
        // does not exist on the 8-bit grid, so only a deeper result can hold it.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = try [UInt8(100), UInt8(101)].enumerated().map { index, value -> URL in
            let image = makeGrayImage(
                width: width, height: height, values: [UInt8](repeating: value, count: width * height))
            let url = folder.appendingPathComponent("frame-\(index).png")
            try ImageExporter.write(image, to: url, format: .png)
            return url
        }

        // Gamma-space averaging so the expected value is the plain code mean.
        let deep = try stacker.stackDeep(imageURLs: urls, linearLight: false)
        XCTAssertEqual(deep.bitsPerComponent, 16)
        XCTAssertEqual(deep.bitsPerPixel, 64)

        // Tolerance covers the half-float mean hop (~4 of 65535 near this
        // value); the nearest 8-bit codes sit ~130 away, so a legacy-depth
        // result cannot sneak through.
        let expected = 100.5 / 255.0 * 65535.0
        for value in deepGrayValues(of: deep) {
            XCTAssertEqual(Double(value), expected, accuracy: 48,
                "deep stack should land between the 8-bit codes")
        }

        // The PNG hop must carry the depth: write, reload, same values.
        let pngURL = folder.appendingPathComponent("deep.png")
        try ImageExporter.write(deep, to: pngURL, format: .png)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(pngURL as CFURL, nil))
        let reloaded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(reloaded.bitsPerComponent, 16, "16-bpc CGImage should write a 16-bit PNG")
        for value in deepGrayValues(of: reloaded) {
            XCTAssertEqual(Double(value), expected, accuracy: 48,
                "16-bit PNG round-trip should preserve the deep mean")
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

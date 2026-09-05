import XCTest
@testable import LetsLapseKit

/// The Kit's lossless-JPEG decoder against the Kit's encoder, and against
/// the tiles the app has already written to real projects.
final class LosslessJPEGDecoderTests: XCTestCase {

    private func roundTrip(_ samples: [UInt16], width: Int, height: Int, components: Int,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let encoded = try LosslessJPEG.encode(interleaved: samples, width: width, height: height, components: components)
        let header = try LosslessJPEGDecoder.header(encoded)
        XCTAssertEqual(header, .init(width: width, height: height, components: components, precision: 16), file: file, line: line)
        let decoded = try LosslessJPEGDecoder.decode(encoded)
        XCTAssertEqual(decoded.width, width, file: file, line: line)
        XCTAssertEqual(decoded.height, height, file: file, line: line)
        XCTAssertEqual(decoded.components, components, file: file, line: line)
        XCTAssertEqual(decoded.samples, samples, "round trip must be bit-exact", file: file, line: line)
    }

    func testRoundTripsNoiseOneComponent() throws {
        var generator = SplitMix64(seed: 42)
        let samples = (0..<(64 * 48)).map { _ in UInt16(generator.next() & 0xFFFF) }
        try roundTrip(samples, width: 64, height: 48, components: 1)
    }

    func testRoundTripsNoiseThreeComponents() throws {
        var generator = SplitMix64(seed: 43)
        let samples = (0..<(40 * 30 * 3)).map { _ in UInt16(generator.next() & 0xFFFF) }
        try roundTrip(samples, width: 40, height: 30, components: 3)
    }

    func testRoundTripsGradientsWithDistinctPlanes() throws {
        let width = 128, height = 64
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 3
                samples[i] = UInt16((x * 400) % 65536)
                samples[i + 1] = UInt16((y * 900 + x) % 65536)
                samples[i + 2] = UInt16(65535 - ((x + y) * 200) % 65536)
            }
        }
        try roundTrip(samples, width: width, height: height, components: 3)
    }

    func testRoundTripsExtremesAndConstant() throws {
        let extremes: [UInt16] = (0..<(16 * 16)).map { $0 % 2 == 0 ? 0 : 65535 }
        try roundTrip(extremes, width: 16, height: 16, components: 1)
        try roundTrip([UInt16](repeating: 12345, count: 32 * 32 * 3), width: 32, height: 32, components: 3)
        try roundTrip([UInt16](repeating: 0, count: 8 * 8), width: 8, height: 8, components: 1)
    }

    func testRoundTripsFourComponents() throws {
        var generator = SplitMix64(seed: 7)
        let samples = (0..<(20 * 10 * 4)).map { _ in UInt16(generator.next() % 4096) }
        try roundTrip(samples, width: 20, height: 10, components: 4)
    }

    func testSingleComponentStreamIsUnchangedByTheGeneralisation() throws {
        // The one-component form must stay byte-identical: the app's Bayer
        // DNGs on disk are what it produced, and re-encoding a decoded tile
        // has to reproduce the file exactly (see the real-tile test).
        let samples = (0..<(32 * 32)).map { UInt16(($0 * 37) % 65536) }
        let single = try LosslessJPEG.encode(samples: samples, width: 32, height: 32)
        let general = try LosslessJPEG.encode(interleaved: samples, width: 32, height: 32, components: 1)
        XCTAssertEqual(single, general)
        XCTAssertEqual(Array(single.prefix(2)), [0xFF, 0xD8])
        XCTAssertEqual(Array(single.suffix(2)), [0xFF, 0xD9])
    }

    func testRejectsBaselineJPEG() {
        var stream = Data([0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 8, 0, 8, 0, 8, 1, 1, 0x11, 0])
        stream.append(contentsOf: [0xFF, 0xD9])
        XCTAssertThrowsError(try LosslessJPEGDecoder.decode(stream)) { error in
            XCTAssertEqual(error as? LosslessJPEGDecoder.DecodeError, .notLossless(marker: 0xC0))
        }
        XCTAssertThrowsError(try LosslessJPEGDecoder.decode(Data([1, 2, 3])))
    }

    /// A tile of a real LetsLapse capture: decode it, re-encode it with the
    /// Kit encoder, and the bytes must come back identical — the encoder is
    /// deterministic, so this pins the decoder to the files already on disk.
    func testDecodesARealCapturedTileAndReencodesItIdentically() throws {
        let url = URL(fileURLWithPath: "/Volumes/letslapse/Projects/F6387DFA-216D-4EFE-8398-FF18F243E454/source/frame-00001.dng")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path), "Set 2 fixture unavailable — mount /Volumes/letslapse")
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let reference = try DNGDocument.parseReference(data)
        let offsets = reference.raw.tag(324)!.ints
        let counts = reference.raw.tag(325)!.ints
        XCTAssertEqual(offsets.count, 192)
        let started = Date()
        var totalBytes = 0
        for index in [0, 1, 95, 191] {
            let tile = data.subdata(in: offsets[index]..<(offsets[index] + counts[index]))
            let decoded = try LosslessJPEGDecoder.decode(tile)
            XCTAssertEqual(decoded.width, 256)
            XCTAssertEqual(decoded.height, 256)
            XCTAssertEqual(decoded.components, 1)
            let reencoded = try LosslessJPEG.encode(samples: decoded.samples, width: 256, height: 256)
            XCTAssertEqual(reencoded, tile, "tile \(index) did not round-trip byte-for-byte")
            totalBytes += tile.count
        }
        // Whole-frame timing: every tile, in parallel.
        let parallelStart = Date()
        var failures = 0
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: offsets.count) { index in
            let tile = data.subdata(in: offsets[index]..<(offsets[index] + counts[index]))
            if (try? LosslessJPEGDecoder.decode(tile)) == nil {
                lock.lock(); failures += 1; lock.unlock()
            }
        }
        XCTAssertEqual(failures, 0)
        print(String(format: "  LJ92 decode: 4 tiles %.1f ms; all 192 tiles in parallel %.0f ms",
                     parallelStart.timeIntervalSince(started) * 1000, Date().timeIntervalSince(parallelStart) * 1000))
    }
}

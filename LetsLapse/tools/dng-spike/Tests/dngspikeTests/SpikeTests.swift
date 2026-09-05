import Foundation
import XCTest
@testable import dngspike
import LetsLapseKit

final class SpikeTests: XCTestCase {

    // MARK: - Curves

    /// Every carrier must round-trip a linear ramp through its own levels:
    /// encode, then undo with the DNG arithmetic a reader applies.
    func testCurvesRoundTripThroughTheirLevels() {
        let n = 4096
        let linear: [Float] = (0..<n).map { Float($0) / Float(n - 1) }
        for (curve, tolerance) in [(Curve.linear, 1.0 / 60000), (.gammaLUT(gamma: 2.2), 0.003), (.cubic(c1: 0.1), 0.002)] {
            let encoding = StoredEncoding(curve: curve, bitsPerSample: 16, pedestal: 2048)
            var stored = [UInt16](repeating: 0, count: n)
            linear.withUnsafeBufferPointer { source in
                stored.withUnsafeMutableBufferPointer { destination in
                    encoding.encode16(source.baseAddress!, count: n, into: destination.baseAddress!)
                }
            }
            let levels = encoding.levels(samplesPerPixel: 1)
            var worst = 0.0
            for i in 0..<n {
                var linearized = Double(stored[i])
                if let table = levels.linearizationTable { linearized = Double(table[min(table.count - 1, Int(stored[i]))]) }
                let black = levels.black[0], white = Double(levels.white[0])
                var value = (linearized - black) / (white - black)
                if let polynomials = levels.mapPolynomials {
                    var y = 0.0
                    for c in polynomials[0].reversed() { y = y * value + c }
                    value = y
                }
                worst = max(worst, abs(value - Double(linear[i])))
            }
            XCTAssertLessThan(worst, tolerance, "\(curve.label) round trip")
        }
    }

    func testGammaCarrierKeepsNoiseBelowBlack() {
        let encoding = StoredEncoding(curve: .gammaLUT(gamma: 2.2), bitsPerSample: 16, pedestal: 2048)
        let linear: [Float] = [-0.02, -0.01, 0, 0.01]
        var stored = [UInt16](repeating: 0, count: 4)
        linear.withUnsafeBufferPointer { source in
            stored.withUnsafeMutableBufferPointer { destination in
                encoding.encode16(source.baseAddress!, count: 4, into: destination.baseAddress!)
            }
        }
        XCTAssertLessThan(stored[0], stored[1])
        XCTAssertLessThan(stored[1], stored[2])
        XCTAssertEqual(Int(stored[2]), encoding.storedPedestal)
        XCTAssertGreaterThan(stored[3], stored[2])
        let table = encoding.levels(samplesPerPixel: 1).linearizationTable!
        XCTAssertEqual(table.count, 65536)
        XCTAssertEqual(Int(table[encoding.storedPedestal]), 2048, "the pedestal maps to the black level")
        XCTAssertEqual(table[65535], 65535)
    }

    func testEightBitCubicCarrierUsesStoredWhite() {
        let encoding = StoredEncoding(curve: .cubic(c1: 0.1), bitsPerSample: 8, pedestal: 0)
        let levels = encoding.levels(samplesPerPixel: 3)
        XCTAssertEqual(levels.white, [255])
        XCTAssertEqual(levels.black, [0])
        XCTAssertEqual(levels.mapPolynomials?.count, 3)
        var stored = [UInt8](repeating: 0, count: 3)
        let linear: [Float] = [0, 0.5, 1]
        linear.withUnsafeBufferPointer { source in
            stored.withUnsafeMutableBufferPointer { destination in
                encoding.encode8(source.baseAddress!, count: 3, into: destination.baseAddress!)
            }
        }
        XCTAssertEqual(stored[0], 0)
        XCTAssertEqual(stored[2], 255)
        XCTAssertGreaterThan(stored[1], 128, "the cubic spends more codes on the shadows")
    }

    // MARK: - Tiles

    func testTileEncoderPadsEdgesAndRoundTrips() throws {
        let width = 70, height = 45, spp = 3
        var samples = [UInt16](repeating: 0, count: width * height * spp)
        for i in 0..<samples.count { samples[i] = UInt16((i * 977) % 65536) }
        let encoded = try TileEncoder.encode16(samples, width: width, height: height, samplesPerPixel: spp, tile: 32, codec: .lj92)
        XCTAssertEqual(encoded.tiles.count, 3 * 2)
        for (index, tile) in encoded.tiles.enumerated() {
            let decoded = try LosslessJPEGDecoder.decode(tile)
            XCTAssertEqual(decoded.width, 32)
            XCTAssertEqual(decoded.height, 32)
            let tx = index % 3, ty = index / 3
            for y in 0..<32 {
                for x in 0..<32 {
                    let sx = min(tx * 32 + x, width - 1), sy = min(ty * 32 + y, height - 1)
                    for c in 0..<spp {
                        XCTAssertEqual(decoded.samples[(y * 32 + x) * spp + c], samples[(sy * width + sx) * spp + c])
                    }
                }
            }
        }
    }

    // MARK: - Demosaic

    /// A flat Bayer field of known R, G and B levels must demosaic to exactly
    /// those levels everywhere (every 5×5 filter sums to one per colour).
    func testMetalDemosaicReproducesAFlatField() throws {
        let demosaicer: MetalDemosaic
        do { demosaicer = try MetalDemosaic() } catch { throw XCTSkip("no Metal: \(error)") }
        let width = 64, height = 48
        let black = 512.0, white = 16383.0
        let levels: [Double] = [0.25, 0.5, 0.125]   // R, G, B in linear light
        var mosaic = [UInt16](repeating: 0, count: width * height)
        let pattern: [UInt8] = [0, 1, 1, 2]
        for y in 0..<height {
            for x in 0..<width {
                let colour = Int(pattern[((y & 1) << 1) | (x & 1)])
                mosaic[y * width + x] = UInt16(black + levels[colour] * (white - black))
            }
        }
        var metadata = FrameMetadata()
        metadata.colorTags = DNGArchive.sRGBColorTags()
        let frame = MosaicFrame(width: width, height: height, samples: mosaic, cfaPattern: pattern, black: black, white: white, metadata: metadata)
        for method in [MetalDemosaic.Method.mhc, .bin2] {
            let result = try demosaicer.run(frame, method: method, targetPixels: nil)
            let rgb = result.frame
            XCTAssertEqual(rgb.width, method == .bin2 ? width / 2 : width)
            var worst: Float = 0
            for i in 0..<(rgb.width * rgb.height) {
                for c in 0..<3 { worst = max(worst, abs(rgb.samples[i * 3 + c] - Float(levels[c]))) }
            }
            XCTAssertLessThan(worst, 1e-3, "\(method.rawValue) flat field")
        }
        // Resize path keeps the flat field flat (checked away from the
        // corners, where a Lanczos kernel sees the border).
        let resized = try demosaicer.run(frame, method: .mhc, targetPixels: 1000)
        XCTAssertLessThan(resized.frame.width * resized.frame.height, 1100)
        let centre = (resized.frame.height / 2 * resized.frame.width + resized.frame.width / 2) * 3
        for c in 0..<3 {
            XCTAssertEqual(resized.frame.samples[centre + c], Float(levels[c]), accuracy: 2e-3)
        }
    }

    // MARK: - Strategies

    func testStrategyLabelsAreDistinctAcrossTheMatrix() {
        for set in [1, 2] {
            let labels = BenchCommand.matrix(set: set).map(\.label)
            XCTAssertEqual(Set(labels).count, labels.count, "set \(set) has duplicate strategy labels: \(labels)")
        }
    }

    // MARK: - Real files

    func testNativeDecodeMatchesAppleDecodeOfTheSameFrame() throws {
        let url = URL(fileURLWithPath: "/Volumes/letslapse/Projects/F6387DFA-216D-4EFE-8398-FF18F243E454/source/frame-00001.dng")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path), "Set 2 fixture unavailable — mount /Volumes/letslapse")
        let mosaic = try NativeDecoder.decode(url: url).frame
        XCTAssertEqual(mosaic.width, 4032)
        XCTAssertEqual(mosaic.height, 3024)
        XCTAssertEqual(mosaic.cfaPattern, [0, 1, 1, 2])
        XCTAssertEqual(mosaic.black, 0)
        XCTAssertEqual(mosaic.white, 65535)
        XCTAssertTrue(mosaic.metadata.colorTags.contains { $0.tag == 50721 }, "ColorMatrix1 carried")
        XCTAssertTrue(mosaic.metadata.colorTags.contains { $0.tag == 50730 }, "BaselineExposure carried")
        XCTAssertFalse(mosaic.metadata.gps.isEmpty, "GPS IFD carried")
    }
}

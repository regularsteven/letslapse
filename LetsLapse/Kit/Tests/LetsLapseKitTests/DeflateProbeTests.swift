import XCTest
import ImageIO
import Compression
@testable import LetsLapseKit

/// Temporary probe: which compressed-DNG shapes will ImageIO's RAW codec
/// accept? Deleted once the answer is folded into the writer.
final class DeflateProbeTests: XCTestCase {
    func testProbeCompressedVariants() throws {
        let width = 1024
        let height = 768
        var rgb = Data(capacity: width * height * 6)
        for index in 0..<(width * height) {
            let value = UInt16((index * 13) % 60000)
            var pixel = value.littleEndian
            withUnsafeBytes(of: &pixel) { bytes in
                rgb.append(contentsOf: bytes)
                rgb.append(contentsOf: bytes)
                rgb.append(contentsOf: bytes)
            }
        }

        // 1. Self-verify: inflate our stream and reverse the predictor; it
        // must equal the quantised source exactly.
        let compressed = try DNGAuthor.deflateWithPredictor(rgb, width: width, height: height, samplesPerPixel: 3)
        print("PROBE compressed bytes \(compressed.count) from \(rgb.count)")
        let inflated = try inflate(zlibWrapped: compressed)
        XCTAssertEqual(inflated.count, rgb.count)
        var restored = [UInt16](repeating: 0, count: width * height * 3)
        inflated.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let diffed = raw.bindMemory(to: UInt16.self)
            for row in 0..<height {
                let base = row * width * 3
                for column in 0..<(width * 3) {
                    if column < 3 {
                        restored[base + column] = diffed[base + column]
                    } else {
                        restored[base + column] = restored[base + column - 3] &+ diffed[base + column]
                    }
                }
            }
        }
        var matches = true
        rgb.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let source = raw.bindMemory(to: UInt16.self)
            for index in 0..<restored.count where restored[index] != (source[index] & 0xFFF0) {
                matches = false
                break
            }
        }
        print("PROBE stream roundtrip valid: \(matches)")
        XCTAssertTrue(matches)

        // 2. ImageIO acceptance per variant.
        struct Variant { let label: String; let strip: DNGAuthor.CompressedStrip? }
        let noPred = try DNGAuthor.deflateWithPredictor(rgb, width: width, height: height, samplesPerPixel: 3, predict: false)
        let variants: [Variant] = [
            Variant(label: "uncompressed", strip: nil),
            Variant(label: "deflate+pred2", strip: DNGAuthor.CompressedStrip(payload: compressed, predictor: 2)),
            Variant(label: "deflate-nopred", strip: DNGAuthor.CompressedStrip(payload: noPred, predictor: 1)),
        ]
        for variant in variants {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("probe-\(variant.label)-\(UUID().uuidString).dng")
            defer { try? FileManager.default.removeItem(at: url) }
            try writeVariant(rgb: rgb, width: width, height: height, strip: variant.strip, to: url)
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            let type = source.flatMap(CGImageSourceGetType).map(String.init(describing:)) ?? "nil"
            let decodes = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } != nil
            print("PROBE \(variant.label): type=\(type) decodes=\(decodes)")
        }
    }

    private func writeVariant(rgb: Data, width: Int, height: Int, strip: DNGAuthor.CompressedStrip?, to url: URL) throws {
        var matrixPayload = Data()
        let matrix: [(Int32, Int32)] = [
            (32406, 10000), (-15372, 10000), (-4986, 10000),
            (-9689, 10000), (18758, 10000), (415, 10000),
            (557, 10000), (-2040, 10000), (10570, 10000),
        ]
        for (numerator, denominator) in matrix {
            matrixPayload.appendU32(UInt32(bitPattern: numerator))
            matrixPayload.appendU32(UInt32(bitPattern: denominator))
        }
        var neutralPayload = Data()
        for _ in 0..<3 { neutralPayload.appendU32(1); neutralPayload.appendU32(1) }
        var whitePayload = Data()
        for _ in 0..<3 { whitePayload.appendU16(65535) }
        var illuminantPayload = Data()
        illuminantPayload.appendU16(21)
        let reference = DNGReference(
            ifd0: [
                DNGTagValue(tag: 50706, type: 1, count: 4, payload: Data([1, 4, 0, 0])),
                DNGTagValue(tag: 50721, type: 10, count: 9, payload: matrixPayload),
                DNGTagValue(tag: 50728, type: 5, count: 3, payload: neutralPayload),
                DNGTagValue(tag: 50778, type: 3, count: 1, payload: illuminantPayload),
            ],
            raw: [DNGTagValue(tag: 50717, type: 3, count: 3, payload: whitePayload)])
        let data = try DNGAuthor.makeDNGData(
            image: rgb, width: width, height: height,
            samplesPerPixel: 3, photometric: 34892,
            reference: reference, preview: nil, compressedStrip: strip)
        try data.write(to: url)
    }

    private func inflate(zlibWrapped: Data) throws -> Data {
        let raw = zlibWrapped.dropFirst(2).dropLast(4)
        var output = Data(count: 64 * 1024 * 1024)
        let written = output.withUnsafeMutableBytes { destination in
            raw.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!,
                    destination.count,
                    source.bindMemory(to: UInt8.self).baseAddress!,
                    source.count,
                    nil,
                    COMPRESSION_ZLIB)
            }
        }
        output.removeSubrange(written..<output.count)
        return output
    }
}

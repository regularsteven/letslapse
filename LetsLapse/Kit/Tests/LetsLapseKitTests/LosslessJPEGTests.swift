import XCTest
@testable import LetsLapseKit

final class LosslessJPEGTests: XCTestCase {
    // MARK: - Reference decoder (independent inverse for round-trip proof)

    private func decode(_ data: Data, width: Int, height: Int) throws -> [UInt16] {
        var bits = [UInt8](repeating: 0, count: 16)
        var values: [UInt8] = []
        var index = data.startIndex
        func u8() -> UInt8 { defer { index += 1 }; return data[index] }
        func u16be() -> Int { Int(u8()) << 8 | Int(u8()) }

        XCTAssertEqual(u8(), 0xFF); XCTAssertEqual(u8(), 0xD8)
        var scanStart: Data.Index?
        while scanStart == nil {
            XCTAssertEqual(u8(), 0xFF)
            let marker = u8()
            let length = u16be() - 2
            switch marker {
            case 0xC4:
                _ = u8() // class/id
                for i in 0..<16 { bits[i] = u8() }
                let total = bits.reduce(0) { $0 + Int($1) }
                values = (0..<total).map { _ in u8() }
                let leftover = length - 1 - 16 - total
                for _ in 0..<max(0, leftover) { _ = u8() }
            case 0xC3, 0xDA:
                for _ in 0..<length { _ = u8() }
                if marker == 0xDA { scanStart = index }
            default:
                for _ in 0..<length { _ = u8() }
            }
        }

        // Canonical Huffman decode tables.
        var codeLengths: [(symbol: UInt8, length: Int)] = []
        var cursor = 0
        for lengthIndex in 0..<16 {
            for _ in 0..<Int(bits[lengthIndex]) {
                codeLengths.append((values[cursor], lengthIndex + 1))
                cursor += 1
            }
        }
        var codeMap: [UInt32: UInt8] = [:]
        var lengthOfCode: [UInt32: Int] = [:]
        var code: UInt32 = 0
        var previous = 0
        for entry in codeLengths {
            code <<= UInt32(entry.length - previous)
            previous = entry.length
            // Key combines length and code so different lengths don't clash.
            codeMap[(UInt32(entry.length) << 20) | code] = entry.symbol
            lengthOfCode[(UInt32(entry.length) << 20) | code] = entry.length
            code += 1
        }

        // Bit reader with FF00 unstuffing.
        var bitBuffer: UInt32 = 0
        var bitCount = 0
        var scanIndex = scanStart!
        func readBit() -> UInt32 {
            if bitCount == 0 {
                var byte = data[scanIndex]; scanIndex += 1
                if byte == 0xFF {
                    let next = data[scanIndex]
                    if next == 0x00 { scanIndex += 1 } else { byte = 0xFF } // EOI guard
                }
                bitBuffer = UInt32(byte)
                bitCount = 8
            }
            bitCount -= 1
            return (bitBuffer >> UInt32(bitCount)) & 1
        }
        func readSymbol() -> Int {
            var candidate: UInt32 = 0
            for length in 1...16 {
                candidate = (candidate << 1) | readBit()
                if let symbol = codeMap[(UInt32(length) << 20) | candidate] {
                    return Int(symbol)
                }
            }
            XCTFail("invalid Huffman code")
            return 0
        }

        var samples = [UInt16](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                let ssss = readSymbol()
                var difference: Int
                if ssss == 0 {
                    difference = 0
                } else if ssss == 16 {
                    difference = 32768
                } else {
                    var value = 0
                    for _ in 0..<ssss { value = (value << 1) | Int(readBit()) }
                    difference = value < (1 << (ssss - 1)) ? value - (1 << ssss) + 1 : value
                }
                let predicted: Int
                if row == 0 && column == 0 {
                    predicted = 32768
                } else if column == 0 {
                    predicted = Int(samples[(row - 1) * width])
                } else {
                    predicted = Int(samples[row * width + column - 1])
                }
                samples[row * width + column] = UInt16((predicted + difference) & 0xFFFF)
            }
        }
        return samples
    }

    private func assertRoundTrip(_ samples: [UInt16], width: Int, height: Int,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let encoded = try LosslessJPEG.encode(samples: samples, width: width, height: height)
        let decoded = try decode(encoded, width: width, height: height)
        XCTAssertEqual(decoded, samples, "round trip must be bit-exact", file: file, line: line)
    }

    // MARK: - Tests

    func testRoundTripsRandomNoise() throws {
        var generator = SplitMix64(seed: 42)
        let samples = (0..<(64 * 48)).map { _ in UInt16(generator.next() & 0xFFFF) }
        try assertRoundTrip(samples, width: 64, height: 48)
    }

    func testRoundTripsGradient() throws {
        let width = 256
        let height = 128
        let samples = (0..<(width * height)).map { UInt16(($0 * 7) % 65536) }
        try assertRoundTrip(samples, width: width, height: height)
    }

    func testRoundTripsConstantImage() throws {
        try assertRoundTrip([UInt16](repeating: 12345, count: 32 * 32), width: 32, height: 32)
    }

    /// Alternating extremes force the SSSS=16 (difference 32768) special
    /// case and maximum-magnitude codes.
    func testRoundTripsExtremeDifferences() throws {
        let samples: [UInt16] = (0..<(16 * 16)).map { $0 % 2 == 0 ? 0 : 65535 }
        try assertRoundTrip(samples, width: 16, height: 16)
    }

    func testCompressesSmoothData() throws {
        let width = 512
        let height = 512
        // Smooth-ish synthetic mosaic: gradients with mild noise.
        var generator = SplitMix64(seed: 7)
        let samples = (0..<(width * height)).map { index -> UInt16 in
            let base = (index % width) * 20 + (index / width) * 10
            let noise = Int(generator.next() % 33) - 16
            return UInt16(max(0, min(65535, base + noise + 2000)))
        }
        let encoded = try LosslessJPEG.encode(samples: samples, width: width, height: height)
        let ratio = Double(samples.count * 2) / Double(encoded.count)
        print("LJ92 smooth ratio: \(String(format: "%.2f", ratio))x (\(encoded.count) bytes)")
        XCTAssertGreaterThan(ratio, 1.5, "smooth data should compress meaningfully")
        try assertRoundTrip(samples, width: width, height: height)
    }
}

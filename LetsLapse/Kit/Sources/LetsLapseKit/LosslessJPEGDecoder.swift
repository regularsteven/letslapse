import Foundation

/// Lossless JPEG (ITU-T T.81 Annex H, process 14) **decoder** — the inverse
/// of `LosslessJPEG.encode`, and general enough for the tiles other DNG
/// writers produce: 2…16-bit precision, one to four interleaved components,
/// any of the seven predictors, a point transform, one Huffman table per
/// component, and restart intervals that fall on row boundaries.
///
/// Implemented from the public standard. Bit-exact by definition: the
/// codec is predictive coding plus Huffman, nothing else. Written for the
/// hot path — a 256×256 16-bit tile decodes in about a millisecond in a
/// Release build, and tiles are independent so callers decode them in
/// parallel (`DispatchQueue.concurrentPerform`).
public enum LosslessJPEGDecoder {

    public struct Image: Equatable {
        public let width: Int
        public let height: Int
        public let components: Int
        public let precision: Int
        /// Row-major, components interleaved:
        /// `samples[(y * width + x) * components + c]`.
        public let samples: [UInt16]
    }

    public enum DecodeError: Error, CustomStringConvertible, Equatable {
        case notAJPEG
        case notLossless(marker: UInt8)
        case truncated
        case unsupported(String)
        case badHuffmanCode
        case malformed(String)

        public var description: String {
            switch self {
            case .notAJPEG: return "no SOI marker"
            case .notLossless(let marker): return String(format: "frame marker 0xFF%02X is not SOF3 (lossless)", marker)
            case .truncated: return "truncated stream"
            case .unsupported(let why): return "unsupported: \(why)"
            case .badHuffmanCode: return "invalid Huffman code in the entropy-coded segment"
            case .malformed(let why): return "malformed: \(why)"
            }
        }
    }

    /// Only the frame header — cheap, for callers that size buffers before
    /// decoding.
    public struct Header: Equatable {
        public let width: Int
        public let height: Int
        public let components: Int
        public let precision: Int
    }

    public static func header(_ data: Data) throws -> Header {
        var parser = Parser(data: data)
        try parser.parseUntilScan()
        guard let frame = parser.frame else { throw DecodeError.malformed("no frame header") }
        return Header(width: frame.width, height: frame.height, components: frame.components.count, precision: frame.precision)
    }

    public static func decode(_ data: Data) throws -> Image {
        var parser = Parser(data: data)
        try parser.parseUntilScan()
        guard let frame = parser.frame, let scan = parser.scan else {
            throw DecodeError.malformed("no frame or scan header")
        }
        let components = frame.components.count
        guard components >= 1, components <= 4 else { throw DecodeError.unsupported("\(components) components") }
        guard scan.componentOrder.count == components else {
            throw DecodeError.unsupported("non-interleaved scan (\(scan.componentOrder.count) of \(components) components in one scan)")
        }
        for component in frame.components where component.h != 1 || component.v != 1 {
            throw DecodeError.unsupported("sampling factors \(component.h)x\(component.v)")
        }
        guard scan.predictor >= 1, scan.predictor <= 7 else { throw DecodeError.unsupported("predictor \(scan.predictor)") }
        guard frame.precision >= 2, frame.precision <= 16 else { throw DecodeError.unsupported("precision \(frame.precision)") }
        guard scan.pointTransform < frame.precision else { throw DecodeError.malformed("point transform \(scan.pointTransform)") }
        let width = frame.width, height = frame.height
        guard width > 0, height > 0 else { throw DecodeError.malformed("empty frame") }
        if parser.restartInterval > 0 {
            guard parser.restartInterval % width == 0 else {
                throw DecodeError.unsupported("restart interval \(parser.restartInterval) is not a whole number of rows")
            }
        }

        // Component order in the scan decides the sample order within an MCU;
        // the output is stored in frame order (the order of the SOF3 list).
        var tables: [HuffmanTable] = []
        var slots: [Int] = []
        for selector in scan.componentOrder {
            guard let index = frame.components.firstIndex(where: { $0.id == selector.component }) else {
                throw DecodeError.malformed("scan references component \(selector.component)")
            }
            guard let table = parser.tables[selector.table] else {
                throw DecodeError.malformed("scan references undefined Huffman table \(selector.table)")
            }
            tables.append(table)
            slots.append(index)
        }

        var samples = [UInt16](repeating: 0, count: width * height * components)
        try samples.withUnsafeMutableBufferPointer { output in
            var reader = BitReader(data: data, start: parser.scanStart)
            try decodeScan(
                into: output, width: width, height: height, components: components,
                slots: slots, tables: tables, predictor: scan.predictor,
                pointTransform: scan.pointTransform, precision: frame.precision,
                restartRows: parser.restartInterval > 0 ? parser.restartInterval / width : 0,
                reader: &reader)
        }
        return Image(width: width, height: height, components: components, precision: frame.precision, samples: samples)
    }

    // MARK: - Scan decoding

    private static func decodeScan(
        into output: UnsafeMutableBufferPointer<UInt16>,
        width: Int, height: Int, components: Int,
        slots: [Int], tables: [HuffmanTable], predictor: Int,
        pointTransform: Int, precision: Int, restartRows: Int,
        reader: inout BitReader
    ) throws {
        let rowStride = width * components
        let initial = 1 << (precision - pointTransform - 1)
        let out = output.baseAddress!
        var intervalStartRow = 0
        var restartsSeen = 0

        for y in 0..<height {
            if restartRows > 0, y > 0, (y - intervalStartRow) == restartRows {
                // End of a restart interval: byte-align and step over RSTn.
                try reader.consumeRestartMarker(expected: restartsSeen & 7)
                restartsSeen += 1
                intervalStartRow = y
            }
            let firstRowOfInterval = y == intervalStartRow
            let rowBase = y * rowStride
            for x in 0..<width {
                let pixelBase = rowBase + x * components
                for k in 0..<components {
                    let table = tables[k]
                    let index = pixelBase + slots[k]
                    let predicted: Int
                    if firstRowOfInterval {
                        predicted = x == 0 ? initial : Int(out[index - components])
                    } else if x == 0 {
                        predicted = Int(out[index - rowStride])
                    } else {
                        let ra = Int(out[index - components])
                        let rb = Int(out[index - rowStride])
                        switch predictor {
                        case 1: predicted = ra
                        case 2: predicted = rb
                        case 3: predicted = Int(out[index - rowStride - components])
                        case 4: predicted = ra + rb - Int(out[index - rowStride - components])
                        case 5: predicted = ra + ((rb - Int(out[index - rowStride - components])) >> 1)
                        case 6: predicted = rb + ((ra - Int(out[index - rowStride - components])) >> 1)
                        default: predicted = (ra + rb) >> 1
                        }
                    }
                    let difference = try reader.readDifference(table)
                    out[index] = UInt16(truncatingIfNeeded: predicted + difference)
                }
            }
        }
        if pointTransform > 0 {
            let shift = UInt16(pointTransform)
            for i in 0..<(width * height * components) { out[i] = out[i] << shift }
        }
    }

    // MARK: - Headers

    private struct Component { let id: Int; let h: Int; let v: Int }
    private struct Frame { let precision: Int; let width: Int; let height: Int; let components: [Component] }
    private struct Scan {
        struct Selector { let component: Int; let table: Int }
        let componentOrder: [Selector]
        let predictor: Int
        let pointTransform: Int
    }

    private struct Parser {
        let data: Data
        var cursor: Int
        var frame: Frame?
        var scan: Scan?
        var tables: [Int: HuffmanTable] = [:]
        var restartInterval = 0
        var scanStart = 0

        init(data: Data) {
            self.data = data
            self.cursor = data.startIndex
        }

        mutating func u8() throws -> Int {
            guard cursor < data.endIndex else { throw DecodeError.truncated }
            defer { cursor += 1 }
            return Int(data[cursor])
        }

        mutating func u16() throws -> Int {
            let high = try u8()
            return high << 8 | (try u8())
        }

        mutating func parseUntilScan() throws {
            guard try u8() == 0xFF, try u8() == 0xD8 else { throw DecodeError.notAJPEG }
            while true {
                var marker = try u8()
                guard marker == 0xFF else { throw DecodeError.malformed("expected a marker, found \(marker)") }
                while marker == 0xFF { marker = try u8() } // fill bytes
                switch marker {
                case 0xC4:
                    let length = try u16() - 2
                    let end = cursor + length
                    guard end <= data.endIndex else { throw DecodeError.truncated }
                    while cursor < end {
                        let tcTh = try u8()
                        guard tcTh >> 4 == 0 else { throw DecodeError.unsupported("AC Huffman table in a lossless stream") }
                        var counts = [Int](repeating: 0, count: 16)
                        for i in 0..<16 { counts[i] = try u8() }
                        let total = counts.reduce(0, +)
                        var symbols: [UInt8] = []
                        symbols.reserveCapacity(total)
                        for _ in 0..<total { symbols.append(UInt8(try u8())) }
                        tables[tcTh & 0x0F] = try HuffmanTable(counts: counts, symbols: symbols)
                    }
                    cursor = end
                case 0xC3:
                    let length = try u16() - 2
                    let end = cursor + length
                    let precision = try u8()
                    let height = try u16()
                    let width = try u16()
                    let count = try u8()
                    var components: [Component] = []
                    for _ in 0..<count {
                        let id = try u8()
                        let hv = try u8()
                        _ = try u8() // quantisation table selector — unused in lossless
                        components.append(Component(id: id, h: hv >> 4, v: hv & 0x0F))
                    }
                    frame = Frame(precision: precision, width: width, height: height, components: components)
                    cursor = end
                case 0xC0, 0xC1, 0xC2, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF:
                    throw DecodeError.notLossless(marker: UInt8(marker))
                case 0xDA:
                    let length = try u16() - 2
                    let end = cursor + length
                    let count = try u8()
                    var order: [Scan.Selector] = []
                    for _ in 0..<count {
                        let component = try u8()
                        let tdTa = try u8()
                        order.append(Scan.Selector(component: component, table: tdTa >> 4))
                    }
                    let ss = try u8()
                    _ = try u8() // Se
                    let ahAl = try u8()
                    scan = Scan(componentOrder: order, predictor: ss, pointTransform: ahAl & 0x0F)
                    cursor = end
                    scanStart = cursor
                    return
                case 0xDD:
                    _ = try u16()
                    restartInterval = try u16()
                case 0xD9:
                    throw DecodeError.malformed("EOI before any scan")
                default:
                    // APPn, COM, DQT and anything else: skip by length.
                    let length = try u16() - 2
                    guard length >= 0, cursor + length <= data.endIndex else { throw DecodeError.truncated }
                    cursor += length
                }
            }
        }
    }

    // MARK: - Huffman

    /// A 16-bit lookahead table: every code (at most 16 bits long) is
    /// expanded to the entries it prefixes, so one load resolves a symbol
    /// and its length. 128 KB per table, built once per tile.
    final class HuffmanTable {
        /// `(length << 8) | symbol`, or 0 for a bit pattern no code starts.
        let lookup: [UInt16]

        init(counts: [Int], symbols: [UInt8]) throws {
            var lookup = [UInt16](repeating: 0, count: 65536)
            var code = 0
            var symbolIndex = 0
            for length in 1...16 {
                for _ in 0..<counts[length - 1] {
                    guard symbolIndex < symbols.count else { throw DecodeError.malformed("Huffman table shorter than its counts") }
                    let symbol = symbols[symbolIndex]
                    symbolIndex += 1
                    guard code < (1 << length) else { throw DecodeError.malformed("over-subscribed Huffman table") }
                    let first = code << (16 - length)
                    let span = 1 << (16 - length)
                    let entry = UInt16(length << 8) | UInt16(symbol)
                    for i in first..<(first + span) { lookup[i] = entry }
                    code += 1
                }
                code <<= 1
            }
            self.lookup = lookup
        }
    }

    // MARK: - Bits

    struct BitReader {
        private let data: Data
        private var cursor: Int
        private let end: Int
        private var accumulator: UInt64 = 0
        private var bitCount = 0
        /// Set when a marker other than stuffing was met while filling; the
        /// reader then feeds zero bits and `consumeRestartMarker` steps over it.
        private var pendingMarker: Int? = nil

        init(data: Data, start: Int) {
            self.data = data
            self.cursor = start
            self.end = data.endIndex
        }

        @inline(__always)
        private mutating func fill() {
            while bitCount <= 56 {
                var byte: UInt64 = 0
                if pendingMarker == nil, cursor < end {
                    let b = data[cursor]
                    if b == 0xFF {
                        let next = cursor + 1 < end ? data[cursor + 1] : 0xD9
                        if next == 0x00 {
                            cursor += 2
                            byte = 0xFF
                        } else {
                            pendingMarker = Int(next)
                            // Leave the cursor on the marker; feed zeros.
                        }
                    } else {
                        cursor += 1
                        byte = UInt64(b)
                    }
                }
                accumulator |= byte << UInt64(56 - bitCount)
                bitCount += 8
            }
        }

        @inline(__always)
        mutating func readDifference(_ table: HuffmanTable) throws -> Int {
            if bitCount < 32 { fill() }
            let peek = Int(accumulator >> 48)
            let entry = table.lookup[peek]
            guard entry != 0 else { throw DecodeError.badHuffmanCode }
            let length = Int(entry >> 8)
            let ssss = Int(entry & 0xFF)
            accumulator <<= UInt64(length)
            bitCount -= length
            if ssss == 0 { return 0 }
            if ssss == 16 { return 32768 }
            if bitCount < ssss { fill() }
            let value = Int(accumulator >> UInt64(64 - ssss))
            accumulator <<= UInt64(ssss)
            bitCount -= ssss
            return value < (1 << (ssss - 1)) ? value - (1 << ssss) + 1 : value
        }

        /// Discards the bits left in the current byte and steps over the
        /// RSTn marker that starts the next interval.
        mutating func consumeRestartMarker(expected: Int) throws {
            // Drop buffered bits: they are padding plus (possibly) the marker's
            // zeros. Rewind the cursor by the whole bytes still buffered.
            let bufferedBytes = bitCount / 8
            bitCount = 0
            accumulator = 0
            if pendingMarker == nil {
                // Bytes were consumed into the accumulator ahead of the marker;
                // walk back over them (they were plain bytes or FF00 pairs).
                var remaining = bufferedBytes
                while remaining > 0, cursor > data.startIndex {
                    cursor -= 1
                    if cursor > data.startIndex, data[cursor] == 0x00, data[cursor - 1] == 0xFF { cursor -= 1 }
                    remaining -= 1
                }
            }
            pendingMarker = nil
            guard cursor + 1 < end, data[cursor] == 0xFF else { throw DecodeError.malformed("expected RST marker") }
            let marker = Int(data[cursor + 1])
            guard marker >= 0xD0, marker <= 0xD7 else { throw DecodeError.malformed(String(format: "expected RST marker, found 0xFF%02X", marker)) }
            _ = expected
            cursor += 2
        }
    }
}

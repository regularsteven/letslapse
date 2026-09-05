import Foundation

/// Lossless JPEG (ITU-T T.81 Annex H, process 14) encoder for 16-bit tiles —
/// the standard codec inside camera DNGs (Compression 7). Bit-exact by
/// definition: predictive coding plus Huffman, no transform, no
/// quantisation. Implemented from the public standard.
///
/// One component is the Bayer case (a CFA mosaic is a single plane). Three
/// interleaved components is the LinearRaw case — a demosaiced DNG stores
/// R, G, B per pixel and the standard codes them as one interleaved scan,
/// each component predicted from its own neighbours with its own Huffman
/// table. `LosslessJPEGDecoder` is the inverse.
public enum LosslessJPEG {
    /// Encodes one component with predictor 1 (left neighbour; first row
    /// seeds from 2^(P-1), later rows seed from the sample above).
    /// `samples` is row-major, `width * height` values.
    public static func encode(samples: [UInt16], width: Int, height: Int) throws -> Data {
        try encode(interleaved: samples, width: width, height: height, components: 1)
    }

    /// Encodes `components` interleaved planes (`samples[(y*width + x)*components + c]`)
    /// as one lossless scan, predictor 1, one Huffman table per component.
    /// Byte-identical to the single-component form when `components == 1`.
    public static func encode(interleaved samples: [UInt16], width: Int, height: Int, components: Int) throws -> Data {
        guard components >= 1, components <= 4 else {
            throw DNGError.unsupportedBuffer("\(components) components (1…4 supported)")
        }
        guard samples.count == width * height * components, width > 0, height > 0 else {
            throw DNGError.sizeMismatch(expected: "\(width * height * components) samples", actual: "\(samples.count)")
        }

        // Pass 1: per-component category histograms for the Huffman tables.
        var frequencies = [[Int]](repeating: [Int](repeating: 0, count: 17), count: components)
        forEachDifference(samples: samples, width: width, height: height, components: components) { component, difference in
            frequencies[component][category(of: difference)] += 1
        }
        let tables = frequencies.map { HuffmanTable(frequencies: $0) }

        var output = Data()
        output.append(contentsOf: [0xFF, 0xD8]) // SOI

        // DHT — one table per component (class 0, id = component index).
        for (index, table) in tables.enumerated() {
            var dht = Data()
            dht.append(UInt8(index)) // class 0 (DC), id
            dht.append(contentsOf: table.bits)
            dht.append(contentsOf: table.values)
            appendSegment(&output, marker: 0xC4, payload: dht)
        }

        // SOF3 (lossless)
        var sof = Data()
        sof.append(16) // precision
        sof.append(UInt8(height >> 8)); sof.append(UInt8(height & 0xFF))
        sof.append(UInt8(width >> 8)); sof.append(UInt8(width & 0xFF))
        sof.append(UInt8(components))
        for index in 0..<components {
            sof.append(UInt8(index + 1)) // component id
            sof.append(0x11)             // sampling 1x1
            sof.append(0)                // quant table (unused)
        }
        appendSegment(&output, marker: 0xC3, payload: sof)

        // SOS
        var sos = Data()
        sos.append(UInt8(components))
        for index in 0..<components {
            sos.append(UInt8(index + 1))   // component id
            sos.append(UInt8(index << 4))  // DC table = component index, AC unused
        }
        sos.append(1)  // Ss = predictor 1
        sos.append(0)  // Se
        sos.append(0)  // Ah/Al (no point transform)
        appendSegment(&output, marker: 0xDA, payload: sos)

        // Entropy-coded data with FF byte stuffing.
        var writer = BitWriter()
        forEachDifference(samples: samples, width: width, height: height, components: components) { component, difference in
            let table = tables[component]
            let ssss = category(of: difference)
            writer.append(bits: table.codes[ssss], count: table.lengths[ssss])
            if ssss > 0 && ssss < 16 {
                var magnitude = difference
                if difference < 0 { magnitude = difference - 1 }
                writer.append(bits: UInt32(magnitude & ((1 << ssss) - 1)), count: ssss)
            }
        }
        writer.finish(into: &output)

        output.append(contentsOf: [0xFF, 0xD9]) // EOI
        return output
    }

    // MARK: - Prediction

    /// Predictor 1 differences in scan order (pixel-major, component-minor),
    /// mod 2^16, mapped to [-32768, 32767].
    private static func forEachDifference(
        samples: [UInt16], width: Int, height: Int, components: Int,
        _ body: (Int, Int) -> Void
    ) {
        samples.withUnsafeBufferPointer { buffer in
            let pointer = buffer.baseAddress!
            let rowStride = width * components
            for row in 0..<height {
                let base = row * rowStride
                for column in 0..<width {
                    let pixel = base + column * components
                    for component in 0..<components {
                        let index = pixel + component
                        let predicted: UInt16
                        if row == 0 && column == 0 {
                            predicted = 32768
                        } else if column == 0 {
                            predicted = pointer[index - rowStride]
                        } else {
                            predicted = pointer[index - components]
                        }
                        let difference = Int(pointer[index]) - Int(predicted)
                        // Mod-2^16 wrap into signed range.
                        var wrapped = difference
                        if wrapped > 32767 { wrapped -= 65536 }
                        if wrapped < -32768 { wrapped += 65536 }
                        body(component, wrapped)
                    }
                }
            }
        }
    }

    static func category(of difference: Int) -> Int {
        if difference == -32768 { return 16 }
        var magnitude = difference < 0 ? -difference : difference
        var bits = 0
        while magnitude > 0 {
            magnitude >>= 1
            bits += 1
        }
        return bits
    }

    // MARK: - Huffman

    struct HuffmanTable {
        /// DHT BITS array: count of codes per length 1…16.
        let bits: [UInt8]
        /// Symbols in code order.
        let values: [UInt8]
        /// Per-symbol canonical code and length.
        let codes: [UInt32]
        let lengths: [Int]

        init(frequencies: [Int]) {
            // Length-limited Huffman via the JPEG Annex K approach is
            // overkill for 17 symbols; a plain Huffman rarely exceeds 16
            // bits, and a fixed table backstops the rare skewed case.
            var lengthsBySymbol = HuffmanTable.plainHuffmanLengths(frequencies: frequencies)
            if lengthsBySymbol == nil || (lengthsBySymbol!.max() ?? 0) > 16 {
                lengthsBySymbol = [3, 3, 3, 3, 3, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 13]
            }
            let assigned = lengthsBySymbol!

            // Canonical code assignment ordered by (length, symbol).
            let order = (0..<17).filter { assigned[$0] > 0 }
                .sorted { (assigned[$0], $0) < (assigned[$1], $1) }
            var bitsArray = [UInt8](repeating: 0, count: 16)
            var valuesArray: [UInt8] = []
            var codesBySymbol = [UInt32](repeating: 0, count: 17)
            var lengthsFinal = [Int](repeating: 0, count: 17)
            var code: UInt32 = 0
            var previousLength = 0
            for symbol in order {
                let length = assigned[symbol]
                code <<= UInt32(length - previousLength)
                previousLength = length
                codesBySymbol[symbol] = code
                lengthsFinal[symbol] = length
                bitsArray[length - 1] += 1
                valuesArray.append(UInt8(symbol))
                code += 1
            }
            self.bits = bitsArray
            self.values = valuesArray
            self.codes = codesBySymbol
            self.lengths = lengthsFinal
        }

        /// nil when fewer than one symbol occurs (degenerate) — the caller
        /// falls back to the fixed table. A lone symbol gets length 1.
        private static func plainHuffmanLengths(frequencies: [Int]) -> [Int]? {
            struct Node { var weight: Int; var symbols: [Int] }
            var nodes: [Node] = []
            for symbol in 0..<17 where frequencies[symbol] > 0 {
                nodes.append(Node(weight: frequencies[symbol], symbols: [symbol]))
            }
            guard !nodes.isEmpty else { return nil }
            var lengths = [Int](repeating: 0, count: 17)
            if nodes.count == 1 {
                lengths[nodes[0].symbols[0]] = 1
                return lengths
            }
            while nodes.count > 1 {
                nodes.sort { $0.weight < $1.weight }
                let first = nodes.removeFirst()
                let second = nodes.removeFirst()
                for symbol in first.symbols + second.symbols {
                    lengths[symbol] += 1
                }
                nodes.append(Node(weight: first.weight + second.weight, symbols: first.symbols + second.symbols))
            }
            return lengths
        }
    }

    // MARK: - Bit and segment plumbing

    private struct BitWriter {
        private var accumulator: UInt64 = 0
        private var bitCount = 0
        private(set) var bytes: [UInt8] = []

        mutating func append(bits: UInt32, count: Int) {
            guard count > 0 else { return }
            accumulator = (accumulator << UInt64(count)) | UInt64(bits)
            bitCount += count
            while bitCount >= 8 {
                let byte = UInt8((accumulator >> UInt64(bitCount - 8)) & 0xFF)
                bytes.append(byte)
                if byte == 0xFF { bytes.append(0x00) } // stuffing
                bitCount -= 8
            }
        }

        mutating func finish(into output: inout Data) {
            if bitCount > 0 {
                // Pad with 1-bits per the standard.
                let pad = 8 - bitCount
                append(bits: UInt32((1 << pad) - 1), count: pad)
            }
            output.append(contentsOf: bytes)
        }
    }

    private static func appendSegment(_ output: inout Data, marker: UInt8, payload: Data) {
        output.append(0xFF)
        output.append(marker)
        let length = payload.count + 2
        output.append(UInt8(length >> 8))
        output.append(UInt8(length & 0xFF))
        output.append(payload)
    }
}

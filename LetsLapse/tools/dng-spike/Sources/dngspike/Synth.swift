import Foundation
import LetsLapseKit

/// Synthetic CFA DNGs with known content, so a third-party decoder's stage
/// handling (Adobe DNG Converter `-l -u` in particular) can be measured:
/// how it places and interpolates a GainMap, and what it does to noise
/// around the black level. Sizes are 1024×768, RGGB, 12-bit range in 16-bit
/// samples like an Apple camera original (black 528, white 4095).
enum Synth {
    static func run(args: [String]) throws {
        guard args.count >= 2 else { throw SpikeError.usage("synth flat-gain|noise|gradient|flat <out.dng> [--mean V] [--sigma S] [--level L] [--black N] [--white N]") }
        let mode = args[0], output = URL(fileURLWithPath: args[1])
        var black = 528.0, white = 4095.0, mean = 0.003, sigma = 0.0025, level = 1.0
        var mapFrom: URL? = nil
        var i = 2
        while i + 1 < args.count {
            switch args[i] {
            case "--mean": mean = Double(args[i + 1]) ?? mean
            case "--sigma": sigma = Double(args[i + 1]) ?? sigma
            case "--black": black = Double(args[i + 1]) ?? black
            case "--white": white = Double(args[i + 1]) ?? white
            case "--level": level = Double(args[i + 1]) ?? level
            case "--map-from": mapFrom = URL(fileURLWithPath: args[i + 1])
            default: throw SpikeError.usage("synth: unknown \(args[i])")
            }
            i += 2
        }
        let width = 1024, height = 768
        let pattern: [UInt8] = [0, 1, 1, 2]
        let range = white - black
        var samples = [UInt16](repeating: 0, count: width * height)
        var opcodeList3: Data? = nil
        switch mode {
        case "flat-gain":
            // Flat field R 0.25 G 0.5 B 0.125 of the range; a 4×5-point GainMap
            // (origin 0, spacing 1/3 × 1/4) with gain 1 + 0.25·column + 0.5·row,
            // three identical map planes over planes 0..<3 — Apple's shape.
            for y in 0..<height {
                for x in 0..<width {
                    let colour = Int(pattern[((y & 1) << 1) | (x & 1)])
                    let v = [0.25, 0.5, 0.125][colour] * level
                    samples[y * width + x] = UInt16((black + v * range).rounded())
                }
            }
            var blob = Data()
            func u32(_ v: UInt32) { blob.append(contentsOf: withUnsafeBytes(of: v.bigEndian, Array.init)) }
            func f64(_ v: Double) { blob.append(contentsOf: withUnsafeBytes(of: v.bitPattern.bigEndian, Array.init)) }
            func f32(_ v: Float) { blob.append(contentsOf: withUnsafeBytes(of: v.bitPattern.bigEndian, Array.init)) }
            let pointsV = 4, pointsH = 5, mapPlanes = 3
            u32(1)
            u32(9); u32(0x0103_0000); u32(0); u32(UInt32(76 + pointsV * pointsH * mapPlanes * 4))
            u32(0); u32(0); u32(UInt32(height)); u32(UInt32(width))
            u32(0); u32(3); u32(1); u32(1)
            u32(UInt32(pointsV)); u32(UInt32(pointsH))
            f64(1.0 / Double(pointsV - 1)); f64(1.0 / Double(pointsH - 1))
            f64(0); f64(0)
            u32(UInt32(mapPlanes))
            for r in 0..<pointsV {
                for c in 0..<pointsH {
                    let g = Float(1 + 0.25 * Double(c) + 0.5 * Double(r))
                    for _ in 0..<mapPlanes { f32(g) }
                }
            }
            opcodeList3 = blob
            if let mapFrom {
                // Use a real file's OpcodeList3 instead (Apple's overhanging map).
                let frame = try NativeDecoder.decode(url: mapFrom).frame
                guard let real = frame.metadata.opcodeLists[51022] else { throw SpikeError.usage("\(mapFrom.lastPathComponent) has no OpcodeList3") }
                opcodeList3 = real
                print("using OpcodeList3 from \(mapFrom.lastPathComponent) (\(real.count) bytes)")
            }
        case "noise":
            // Flat field at `mean` of the range plus Gaussian noise `sigma`
            // (fractions of the range), clamped to [0, white]; deterministic.
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            func next() -> Double {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Double(state >> 11) / Double(1 << 53)
            }
            for i in 0..<samples.count {
                let u1 = max(1e-12, next()), u2 = next()
                let gaussian = (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
                let v = black + (mean + sigma * gaussian) * range
                samples[i] = UInt16(min(white, max(0, v)).rounded())
            }
        case "gradient":
            // Neutral ramp 0 → level across the width, no noise: a decoder's
            // precision shows as a staircase along the columns.
            for y in 0..<height {
                for x in 0..<width {
                    let v = level * Double(x) / Double(width - 1)
                    samples[y * width + x] = UInt16((black + v * range).rounded())
                }
            }
        case "flat":
            // Coloured flat field R 0.5 G 1.0 B 0.25 × level, no noise, no map.
            for y in 0..<height {
                for x in 0..<width {
                    let colour = Int(pattern[((y & 1) << 1) | (x & 1)])
                    let v = [0.5, 1.0, 0.25][colour] * level
                    samples[y * width + x] = UInt16((black + v * range).rounded())
                }
            }
        default:
            throw SpikeError.usage("synth: mode flat-gain, noise, gradient or flat")
        }
        var tiles: [Data] = []
        let tile = 256
        for ty in stride(from: 0, to: height, by: tile) {
            for tx in stride(from: 0, to: width, by: tile) {
                var block = [UInt16](repeating: 0, count: tile * tile)
                for y in 0..<tile { for x in 0..<tile { block[y * tile + x] = samples[(ty + y) * width + tx + x] } }
                tiles.append(try LosslessJPEG.encode(samples: block, width: tile, height: tile))
            }
        }
        let image = DNGArchive.Image(
            width: width, height: height, samplesPerPixel: 1, bitsPerSample: 16,
            photometric: .cfa(pattern: pattern, rows: 2, columns: 2), compression: .losslessJPEG,
            tileWidth: tile, tileHeight: tile, tiles: tiles, levels: .uniform(black: black, white: UInt32(white)))
        var metadata = DNGArchive.Metadata()
        metadata.ifd0 = DNGArchive.sRGBColorTags()
        if let opcodeList3 { metadata.opcodeLists = [51022: opcodeList3] }
        try DNGArchive.write(image: image, metadata: metadata, to: output)
        print("wrote \(output.lastPathComponent): \(mode) \(width)x\(height) black \(black) white \(white)" + (mode == "noise" ? String(format: " mean %.4f sigma %.4f", mean, sigma) : " gain 1+0.25·col+0.5·row over 5×4 points"))
    }
}

import Accelerate
import CoreImage
import Foundation
import LetsLapseKit

/// One row of the strategy matrix.
struct Strategy: Equatable {
    enum Decode: String, CaseIterable { case auto, apple, native, libraw, librawDemosaic = "libraw-demosaic" }
    enum Demosaic: String, CaseIterable { case metal, bin2 }
    enum Output: String, CaseIterable { case cfa, linear }

    var decode: Decode = .auto
    var demosaic: Demosaic = .metal
    var output: Output = .linear
    var codec: TileCodec = .lj92
    var curve: Curve = .linear
    /// Target size in megapixels; nil keeps the source size.
    var megapixels: Double?
    /// Tile edge in pixels; 0 = one tile for the whole frame.
    var tile = 512
    var librawQuality = 3
    var pedestal = 2048
    /// BaselineExposure (EV) to write when the source carries none — Adobe's
    /// per-camera value (0.35 for the ILCE-7M4) lives in its database, not in
    /// the raw file, and Apple applies its own only to CFA data.
    var baselineExposure: Double?
    /// WhiteLevel override for the 8-bit experiments (nil = the curve's own).
    var whiteLevelOverride: UInt32?
    /// Headroom stops for the Apple path (samples pre-divided, BaselineExposure raised).
    var appleHeadroom = 2

    var label: String {
        var parts = [decode.rawValue]
        if output == .linear { parts.append(decode == .apple || decode == .librawDemosaic ? "" : demosaic.rawValue) }
        parts.append(output.rawValue)
        parts.append(codec.label)
        if !codec.isLossless || curve != .linear { parts.append(curve.label) }
        parts.append(megapixels.map { "\(String(format: "%g", $0))mp" } ?? "keep")
        parts.append("t\(tile)")
        if let baselineExposure { parts.append("be\(String(format: "%.2f", baselineExposure))") }
        if let whiteLevelOverride { parts.append("w\(whiteLevelOverride)") }
        if decode == .apple, appleHeadroom != 2 { parts.append("h\(appleHeadroom)") }
        return parts.filter { !$0.isEmpty }.joined(separator: "_")
    }
}

struct ConversionReport {
    var input: URL
    var output: URL
    var strategy: String
    var decodePath = ""
    var width = 0
    var height = 0
    var stages: [(String, Double)] = []
    var totalMilliseconds = 0.0
    var inputBytes = 0
    var outputBytes = 0
    var peakFootprintMB = 0.0
    var notes: [String] = []

    func milliseconds(_ stage: String) -> Double { stages.filter { $0.0 == stage }.reduce(0) { $0 + $1.1 } }
    var ratio: Double { outputBytes > 0 ? Double(inputBytes) / Double(outputBytes) : 0 }

    var summary: String {
        let stageText = stages.map { String(format: "%@ %.0f", $0.0, $0.1) }.joined(separator: " · ")
        return String(format: "%@ → %@  %dx%d  %@  total %.0f ms  %@ → %@ (%.1fx)  peak %.0f MB%@",
                      input.lastPathComponent, output.lastPathComponent, width, height, stageText, totalMilliseconds,
                      mb(inputBytes), mb(outputBytes), ratio, peakFootprintMB,
                      notes.isEmpty ? "" : "\n    " + notes.joined(separator: "\n    "))
    }
}

/// Decode → (demosaic → resize) → curve → tiles → container.
final class Converter {
    private var demosaicer: MetalDemosaic?

    private func metal() throws -> MetalDemosaic {
        if let demosaicer { return demosaicer }
        let created = try MetalDemosaic()
        demosaicer = created
        return created
    }

    /// Pays the one-time costs (Metal shader compile, Core Image context)
    /// before anything is timed.
    func warmUp() {
        _ = try? metal()
        _ = AppleDecoder.context
    }

    static func nativePixelCount(_ url: URL) -> Int? {
        guard let raw = LossyLinearDNG.rawFilter(for: url) else { return nil }
        return Int(raw.nativeSize.width * raw.nativeSize.height)
    }

    func convert(_ input: URL, to output: URL, strategy: Strategy) throws -> ConversionReport {
        var report = ConversionReport(input: input, output: output, strategy: strategy.label)
        var watch = Stopwatch()
        var peak = Memory.footprintMB()
        func sample() { peak = max(peak, Memory.footprintMB()) }
        report.inputBytes = (try? FileManager.default.attributesOfItem(atPath: input.path)[.size] as? Int) ?? 0

        // 1. Decode.
        var decode = strategy.decode
        if decode == .auto {
            if NativeDecoder.canDecode(input) { decode = .native }
            else if LibRawDecoder.isAvailable { decode = .libraw }
            else { decode = .apple }
        }
        var frame: DecodedFrame
        switch decode {
        case .apple:
            let result = try AppleDecoder.decode(url: input, targetPixels: strategy.megapixels.map { Int($0 * 1e6) }, headroomStops: strategy.appleHeadroom)
            frame = .rgb(result.frame)
            if ProcessInfo.processInfo.environment["DNGSPIKE_DEBUG"] != nil {
                let f = result.frame
                var sums = [Double](repeating: 0, count: 3)
                for i in stride(from: 0, to: f.samples.count, by: 3) { for c in 0..<3 { sums[c] += Double(f.samples[i + c]) } }
                let n = Double(f.width * f.height)
                report.notes.append(String(format: "DEBUG apple linear-sRGB means ×4: R %.5f G %.5f B %.5f", sums[0] / n * 4, sums[1] / n * 4, sums[2] / n * 4))
            }
            report.notes.append(String(format: "CIRAWFilter native %.0fx%.0f, neutral %.0f K / %.1f, scale %.3f (setup %.0f + render %.0f ms)",
                                       result.nativeSize.width, result.nativeSize.height, result.neutralTemperatureK, result.neutralTint, result.scale,
                                       result.setupMilliseconds, result.renderMilliseconds))
        case .native:
            let result = try NativeDecoder.decode(url: input)
            frame = .mosaic(result.frame)
            report.notes.append(String(format: "native parse %.0f ms + %d LJ92 tiles %.0f ms", result.parseMilliseconds, result.tileCount, result.tileMilliseconds))
        case .libraw:
            let result = try LibRawDecoder.decode(url: input)
            frame = .mosaic(result.frame)
            report.notes.append(String(format: "LibRaw open %.0f + unpack %.0f + copy %.0f ms; %@", result.openMilliseconds, result.unpackMilliseconds, result.copyMilliseconds, result.frame.metadata.notes.joined(separator: "; ")))
        case .librawDemosaic:
            let result = try LibRawDecoder.demosaic(url: input, quality: strategy.librawQuality)
            frame = .rgb(result.frame)
            report.notes.append(String(format: "LibRaw process (q%d) %.0f ms + copy %.0f ms", strategy.librawQuality, result.processMilliseconds, result.copyMilliseconds))
        case .auto:
            fatalError("resolved above")
        }
        report.decodePath = frame.metadata.decodePath
        watch.lap("decode")
        sample()

        // 2. Shape the stored plane.
        let targetPixels = strategy.megapixels.map { Int($0 * 1e6) }
        var metadata = frame.metadata
        let image: DNGArchive.Image
        let encoded: EncodedTiles
        switch strategy.output {
        case .cfa:
            guard case .mosaic(let mosaic) = frame else {
                throw SpikeError.unsupported("CFA output needs a mosaic decode (\(decode.rawValue) gives demosaiced pixels)")
            }
            if targetPixels != nil { report.notes.append("CFA output cannot be resized; --megapixels ignored") }
            let levels: DNGArchive.Levels
            var stored: [UInt16]
            if strategy.curve == .linear {
                // The mosaic as stored, bit-exact, with the source's own levels.
                stored = mosaic.samples
                levels = .uniform(black: mosaic.black, white: UInt32(mosaic.white))
                watch.add("curve", milliseconds: 0)
            } else {
                let encoding = StoredEncoding(curve: strategy.curve, bitsPerSample: 16, pedestal: strategy.pedestal)
                var linear = [Float](repeating: 0, count: mosaic.samples.count)
                stored = [UInt16](repeating: 0, count: mosaic.samples.count)
                mosaic.samples.withUnsafeBufferPointer { source in
                    linear.withUnsafeMutableBufferPointer { destination in
                        var scale = Float(1 / (mosaic.white - mosaic.black)), offset = Float(-mosaic.black / (mosaic.white - mosaic.black))
                        var floats = [Float](repeating: 0, count: source.count)
                        vDSP_vfltu16(source.baseAddress!, 1, &floats, 1, vDSP_Length(source.count))
                        vDSP_vsmsa(floats, 1, &scale, &offset, destination.baseAddress!, 1, vDSP_Length(source.count))
                    }
                }
                linear.withUnsafeBufferPointer { source in
                    stored.withUnsafeMutableBufferPointer { destination in
                        encoding.encode16(source.baseAddress!, count: source.count, into: destination.baseAddress!)
                    }
                }
                levels = encoding.levels(samplesPerPixel: 1)
                watch.lap("curve")
            }
            sample()
            encoded = try TileEncoder.encode16(stored, width: mosaic.width, height: mosaic.height, samplesPerPixel: 1,
                                               tile: strategy.tile, codec: strategy.codec)
            watch.lap("encode")
            image = DNGArchive.Image(
                width: mosaic.width, height: mosaic.height, samplesPerPixel: 1, bitsPerSample: 16,
                photometric: .cfa(pattern: mosaic.cfaPattern, rows: 2, columns: 2), compression: strategy.codec.compression,
                tileWidth: encoded.tileWidth, tileHeight: encoded.tileHeight, tiles: encoded.tiles, levels: levels)
            report.width = mosaic.width
            report.height = mosaic.height
        case .linear:
            let rgb: RGBFrame
            switch frame {
            case .mosaic(let mosaic):
                let result = try metal().run(mosaic, method: strategy.demosaic == .bin2 ? .bin2 : .mhc, targetPixels: targetPixels)
                rgb = result.frame
                watch.lap("demosaic")
                report.notes.append(String(format: "Metal upload %.0f + %@ %.0f + resize %.0f + readback %.0f ms", result.uploadMilliseconds, strategy.demosaic.rawValue, result.demosaicMilliseconds, result.resizeMilliseconds, result.readbackMilliseconds))
            case .rgb(let decoded):
                if let targetPixels, targetPixels < decoded.width * decoded.height, decode != .apple {
                    let result = try metal().resize(decoded, targetPixels: targetPixels)
                    rgb = result.frame
                    watch.lap("resize")
                } else {
                    rgb = decoded
                }
            }
            metadata = rgb.metadata
            sample()
            let bits = strategy.codec.bitsPerSample
            var curve = strategy.curve
            if bits == 8, case .linear = curve, strategy.pedestal != 0 {
                report.notes.append("8-bit linear store: pedestal scaled to \(Int(Double(strategy.pedestal) / 65535 * 255)) of 255")
            }
            let encoding = StoredEncoding(curve: curve, bitsPerSample: bits, pedestal: strategy.pedestal)
            let count = rgb.width * rgb.height * 3
            if bits == 16 {
                var stored = [UInt16](repeating: 0, count: count)
                rgb.samples.withUnsafeBufferPointer { source in
                    stored.withUnsafeMutableBufferPointer { destination in
                        encoding.encode16(source.baseAddress!, count: count, into: destination.baseAddress!)
                    }
                }
                watch.lap("curve")
                sample()
                encoded = try TileEncoder.encode16(stored, width: rgb.width, height: rgb.height, samplesPerPixel: 3,
                                                   tile: strategy.tile, codec: strategy.codec)
            } else {
                var stored = [UInt8](repeating: 0, count: count)
                rgb.samples.withUnsafeBufferPointer { source in
                    stored.withUnsafeMutableBufferPointer { destination in
                        encoding.encode8(source.baseAddress!, count: count, into: destination.baseAddress!)
                    }
                }
                watch.lap("curve")
                sample()
                encoded = try TileEncoder.encode8(stored, width: rgb.width, height: rgb.height, tile: strategy.tile, codec: strategy.codec)
            }
            watch.lap("encode")
            var levels = encoding.levels(samplesPerPixel: 3)
            if let white = strategy.whiteLevelOverride { levels.white = [white] }
            image = DNGArchive.Image(
                width: rgb.width, height: rgb.height, samplesPerPixel: 3, bitsPerSample: bits,
                photometric: .linearRaw, compression: strategy.codec.compression,
                tileWidth: encoded.tileWidth, tileHeight: encoded.tileHeight, tiles: encoded.tiles,
                levels: levels)
            report.width = rgb.width
            report.height = rgb.height
        }
        report.notes.append(contentsOf: encoded.notes)
        sample()

        // 3. Container.
        var container = DNGArchive.Metadata()
        container.ifd0 = Self.colorTags(metadata)
        if let baseline = strategy.baselineExposure, metadata.isCameraNative {
            let existing = container.ifd0.tag(50730)?.doubles.first
            container.ifd0.removeAll { $0.tag == 50730 }
            container.ifd0.append(DNGArchive.srationalTag(50730, [(existing ?? 0) + baseline]))
            report.notes.append("BaselineExposure \(String(format: "%.2f", (existing ?? 0) + baseline)) written (\(existing == nil ? "source had none" : "source \(existing!) + \(baseline)"))")
        }
        container.raw = metadata.rawTags
        container.exif = metadata.exif
        container.gps = metadata.gps
        container.software = "LetsLapse dngspike"
        container.originalRawFileName = metadata.originalFileName
        container.defaultCropOrigin = [0, 0]
        container.defaultCropSize = [Double(image.width), Double(image.height)]
        try DNGArchive.write(image: image, metadata: container, to: output)
        watch.lap("write")
        sample()

        report.outputBytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        report.stages = watch.laps.map { ($0.name, $0.milliseconds) }
        report.totalMilliseconds = watch.totalMilliseconds
        report.peakFootprintMB = peak
        return report
    }

    /// The carried IFD0 tags with BaselineExposure raised by the headroom the
    /// stored samples were pre-divided by.
    static func colorTags(_ metadata: FrameMetadata) -> [DNGTagValue] {
        var tags = metadata.colorTags
        if metadata.headroomStops > 0 {
            let existing = tags.tag(50730)?.doubles.first ?? 0
            tags.removeAll { $0.tag == 50730 }
            tags.append(DNGArchive.srationalTag(50730, [existing + Double(metadata.headroomStops)]))
        }
        return tags
    }
}

extension MetalDemosaic {
    struct ResizeResult {
        let frame: RGBFrame
        let milliseconds: Double
    }

    /// Lanczos resample of an RGB frame on the GPU (for demosaiced inputs).
    func resize(_ rgb: RGBFrame, targetPixels: Int) throws -> ResizeResult {
        let started = ProcessInfo.processInfo.systemUptime
        var rgba = [Float](repeating: 0, count: rgb.width * rgb.height * 4)
        rgb.samples.withUnsafeBufferPointer { source in
            rgba.withUnsafeMutableBufferPointer { destination in
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress), height: vImagePixelCount(rgb.height), width: vImagePixelCount(rgb.width), rowBytes: rgb.width * 12)
                var dst = vImage_Buffer(data: destination.baseAddress, height: vImagePixelCount(rgb.height), width: vImagePixelCount(rgb.width), rowBytes: rgb.width * 16)
                vImageConvert_RGBFFFtoRGBAFFFF(&src, nil, 1.0, &dst, false, vImage_Flags(kvImageNoFlags))
            }
        }
        let scaled = try lanczos(rgba: rgba, width: rgb.width, height: rgb.height, targetPixels: targetPixels)
        var metadata = rgb.metadata
        metadata.decodePath += "+lanczos"
        return ResizeResult(frame: RGBFrame(width: scaled.width, height: scaled.height, samples: scaled.rgb, metadata: metadata),
                            milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000)
    }
}

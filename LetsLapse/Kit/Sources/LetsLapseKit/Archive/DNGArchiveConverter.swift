import Accelerate
import CoreImage
import Foundation

extension DNGArchive {

    /// One recipe of the conversion: which decoder, whether the mosaic is kept
    /// or demosaiced, the codec and its settings, the stored-value curve, the
    /// target size. `Strategy.archive(megapixels:distance:)` is the shape the
    /// spike recommends; the other fields exist so the bench can measure the
    /// alternatives.
    public struct Strategy: Equatable, Sendable {
        public enum Decode: String, CaseIterable, Sendable { case auto, apple, native, libraw, librawDemosaic = "libraw-demosaic" }
        public enum Demosaic: String, CaseIterable, Sendable { case metal, bin2 }
        public enum Output: String, CaseIterable, Sendable { case cfa, linear }

        public var decode: Decode = .auto
        public var demosaic: Demosaic = .metal
        public var output: Output = .linear
        public var codec: TileCodec = .lj92
        public var curve: Curve = .linear
        /// Target size in megapixels; nil keeps the source size.
        public var megapixels: Double?
        /// Tile edge in pixels; 0 = one tile for the whole frame (Apple's
        /// decoder mis-renders those at reduced scale — keep 256…512).
        public var tile = 512
        public var librawQuality = 3
        public var pedestal = 2048
        /// BaselineExposure (EV) to write when the source carries none. Adobe
        /// keeps the per-camera value in its own database, not in the raw
        /// file, and Apple applies its equivalent only to CFA data — so a
        /// camera-native LinearRaw made from a third-party raw needs it
        /// spelled out. nil consults `knownBaselineExposures`.
        public var baselineExposure: Double?
        /// WhiteLevel override (8-bit experiments only).
        public var whiteLevelOverride: UInt32?
        /// Headroom stops for the Apple path (samples pre-divided, BaselineExposure raised).
        public var appleHeadroom = 2

        public init() {}

        /// The recommended archive: camera-native LinearRaw JPEG XL, gamma
        /// table with a pedestal, effort 5, 512-px tiles. `distance` 0 is
        /// lossless JPEG XL; 0.5 is Adobe's default; 1.0 halves the file for
        /// ~4 dB. `megapixels` nil keeps the source size.
        public static func archive(megapixels: Double?, distance: Float, effort: Int = 5) -> Strategy {
            var strategy = Strategy()
            strategy.decode = .auto
            strategy.output = .linear
            strategy.codec = .jxl(distance: distance, effort: effort, decodeSpeed: 4, xyb: distance > 0)
            strategy.curve = distance > 0 ? .gammaLUT(gamma: 2.2) : .linear
            strategy.megapixels = megapixels
            return strategy
        }

        /// Keep the mosaic, losslessly, in JPEG XL — 5–9% under lossless JPEG.
        public static var losslessMosaic: Strategy {
            var strategy = Strategy()
            strategy.output = .cfa
            strategy.codec = .jxl(distance: 0, effort: 7, decodeSpeed: 4, xyb: false)
            return strategy
        }

        public var label: String {
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

        /// Per-camera BaselineExposure, keyed by "Make Model" as LibRaw
        /// reports it. The values are Adobe's, read from its DNG conversions
        /// of the same frames (see `docs/dng-archive-spike/README.md` §4);
        /// Adobe's own renders and Apple's CFA renders both include them.
        public static var knownBaselineExposures: [String: Double] = [
            "Sony ILCE-7M4": 0.35,
        ]
    }

    /// What one conversion did, for the bench and the app's job log.
    public struct ConversionReport: Sendable {
        public var input: URL
        public var output: URL
        public var strategy: String
        public var decodePath = ""
        public var width = 0
        public var height = 0
        public var stages: [(String, Double)] = []
        public var totalMilliseconds = 0.0
        public var inputBytes = 0
        public var outputBytes = 0
        public var peakFootprintMB = 0.0
        public var notes: [String] = []

        public init(input: URL, output: URL, strategy: String) {
            self.input = input
            self.output = output
            self.strategy = strategy
        }

        public func milliseconds(_ stage: String) -> Double { stages.filter { $0.0 == stage }.reduce(0) { $0 + $1.1 } }
        public var ratio: Double { outputBytes > 0 ? Double(inputBytes) / Double(outputBytes) : 0 }

        public var summary: String {
            let stageText = stages.map { String(format: "%@ %.0f", $0.0, $0.1) }.joined(separator: " · ")
            return String(format: "%@ → %@  %dx%d  %@  total %.0f ms  %.2f MB → %.2f MB (%.1fx)  peak %.0f MB%@",
                          input.lastPathComponent, output.lastPathComponent, width, height, stageText, totalMilliseconds,
                          Double(inputBytes) / 1e6, Double(outputBytes) / 1e6, ratio, peakFootprintMB,
                          notes.isEmpty ? "" : "\n    " + notes.joined(separator: "\n    "))
        }
    }

    /// Decode → (demosaic → resize) → curve → tiles → container. One instance
    /// holds the Metal pipeline; `convert` may be called from several threads
    /// at once (the bench runs three frames in flight through one converter).
    public final class Converter: @unchecked Sendable {
        private let lock = NSLock()
        private var demosaicer: MetalDemosaic?

        public init() {}

        private func metal() throws -> MetalDemosaic {
            lock.lock()
            defer { lock.unlock() }
            if let demosaicer { return demosaicer }
            let created = try MetalDemosaic()
            demosaicer = created
            return created
        }

        /// Pays the one-time costs (Metal shader compile, Core Image context)
        /// before anything is timed.
        public func warmUp() {
            _ = try? metal()
            AppleDecoder.warmUp()
        }

        /// Which decoder `auto` picks for a file, without decoding it.
        public static func resolvedDecode(for url: URL, strategy: Strategy) -> Strategy.Decode {
            guard strategy.decode == .auto else { return strategy.decode }
            if NativeDecoder.canDecode(url) { return .native }
            if LibRawDecoder.canDecode(url) { return .libraw }
            return .apple
        }

        /// Whether the file is something this pipeline can archive at all:
        /// a raw file by extension that one of the decoders opens.
        public static func canConvert(_ url: URL) -> Bool {
            guard ImportedStills.isRaw(url) else { return false }
            if NativeDecoder.canDecode(url) || LibRawDecoder.canDecode(url) { return true }
            return LossyLinearDNG.rawFilter(for: url) != nil
        }

        public func convert(_ input: URL, to output: URL, strategy: Strategy) throws -> ConversionReport {
            var report = ConversionReport(input: input, output: output, strategy: strategy.label)
            var watch = StageTimer()
            var peak = ProcessMemory.footprintMB()
            func sample() { peak = max(peak, ProcessMemory.footprintMB()) }
            report.inputBytes = (try? FileManager.default.attributesOfItem(atPath: input.path)[.size] as? Int) ?? 0

            // 1. Decode.
            let decode = Self.resolvedDecode(for: input, strategy: strategy)
            var frame: DecodedFrame
            switch decode {
            case .apple:
                let result = try AppleDecoder.decode(url: input, targetPixels: strategy.megapixels.map { Int($0 * 1e6) }, headroomStops: strategy.appleHeadroom)
                frame = .rgb(result.frame)
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
                    throw ConversionError.unsupported("CFA output needs a mosaic decode (\(decode.rawValue) gives demosaiced pixels)")
                }
                if targetPixels != nil { report.notes.append("CFA output cannot be resized; megapixels ignored") }
                let levels: DNGArchive.Levels
                var stored: [UInt16]
                if strategy.curve == .linear {
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
                if bits == 8, case .gammaLUT = curve {
                    // Apple renders an 8-bit lossy JPEG with a LinearizationTable
                    // black (report §4); the cubic is the shape that works.
                    curve = .cubic(c1: 0.1)
                    report.notes.append("8-bit codec: table carrier replaced by \(curve.label)")
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
            let baseline = strategy.baselineExposure
                ?? (metadata.isCameraNative && container.ifd0.tag(50730) == nil ? Strategy.knownBaselineExposures[metadata.cameraName] : nil)
            if let baseline, metadata.isCameraNative {
                let existing = container.ifd0.tag(50730)?.doubles.first
                container.ifd0.removeAll { $0.tag == 50730 }
                container.ifd0.append(DNGArchive.srationalTag(50730, [(existing ?? 0) + baseline]))
                report.notes.append("BaselineExposure \(String(format: "%.2f", (existing ?? 0) + baseline)) written (\(existing == nil ? "source had none" : "source \(existing!) + \(baseline)"))")
            }
            container.raw = metadata.rawTags
            container.exif = metadata.exif
            container.gps = metadata.gps
            container.software = "LetsLapse DNG archive"
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
        public static func colorTags(_ metadata: FrameMetadata) -> [DNGTagValue] {
            var tags = metadata.colorTags
            if metadata.headroomStops > 0 {
                let existing = tags.tag(50730)?.doubles.first ?? 0
                tags.removeAll { $0.tag == 50730 }
                tags.append(DNGArchive.srationalTag(50730, [existing + Double(metadata.headroomStops)]))
            }
            return tags
        }

        // MARK: - A sequence

        /// Progress of a sequence conversion, delivered after every frame.
        public struct SequenceProgress: Sendable {
            public var framesDone: Int
            public var framesTotal: Int
            public var inputBytes: Int
            public var outputBytes: Int
            public var lastReport: ConversionReport?
            public var elapsedSeconds: Double
        }

        public struct SequenceResult: Sendable {
            public var reports: [ConversionReport]
            public var failures: [(URL, String)]
            public var elapsedSeconds: Double
            public var inputBytes: Int { reports.reduce(0) { $0 + $1.inputBytes } }
            public var outputBytes: Int { reports.reduce(0) { $0 + $1.outputBytes } }
            public var framesPerSecond: Double { elapsedSeconds > 0 ? Double(reports.count) / elapsedSeconds : 0 }
        }

        /// Converts `files` in order into `directory` (same file name, `.dng`),
        /// `inFlight` frames at a time, reporting after each. `shouldContinue`
        /// is polled between frames; a false stops the run cleanly with what
        /// is done so far. Failed frames are reported, not thrown.
        public func convert(
            files: [URL], to directory: URL, strategy: Strategy, inFlight: Int = 2,
            shouldContinue: @escaping @Sendable () -> Bool = { true },
            progress: @escaping @Sendable (SequenceProgress) -> Void = { _ in }
        ) -> SequenceResult {
            let started = ProcessInfo.processInfo.systemUptime
            warmUp()
            var reports = [ConversionReport?](repeating: nil, count: files.count)
            var failures: [(URL, String)] = []
            let lock = NSLock()
            var done = 0, inBytes = 0, outBytes = 0
            let semaphore = DispatchSemaphore(value: max(1, inFlight))
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "letslapse.dng-archive", qos: .userInitiated, attributes: .concurrent)
            for (index, input) in files.enumerated() {
                guard shouldContinue() else { break }
                semaphore.wait()
                group.enter()
                queue.async {
                    defer { semaphore.signal(); group.leave() }
                    let output = directory.appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".dng")
                    do {
                        let report = try self.convert(input, to: output, strategy: strategy)
                        lock.lock()
                        reports[index] = report
                        done += 1
                        inBytes += report.inputBytes
                        outBytes += report.outputBytes
                        let snapshot = SequenceProgress(framesDone: done, framesTotal: files.count, inputBytes: inBytes, outputBytes: outBytes,
                                                        lastReport: report, elapsedSeconds: ProcessInfo.processInfo.systemUptime - started)
                        lock.unlock()
                        progress(snapshot)
                    } catch {
                        try? FileManager.default.removeItem(at: output)
                        lock.lock()
                        failures.append((input, "\(error)"))
                        done += 1
                        let snapshot = SequenceProgress(framesDone: done, framesTotal: files.count, inputBytes: inBytes, outputBytes: outBytes,
                                                        lastReport: nil, elapsedSeconds: ProcessInfo.processInfo.systemUptime - started)
                        lock.unlock()
                        progress(snapshot)
                    }
                }
            }
            group.wait()
            return SequenceResult(reports: reports.compactMap { $0 }, failures: failures,
                                  elapsedSeconds: ProcessInfo.processInfo.systemUptime - started)
        }
    }
}

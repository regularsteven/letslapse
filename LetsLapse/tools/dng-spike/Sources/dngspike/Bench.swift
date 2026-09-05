import Foundation
import LetsLapseKit

/// The strategy matrix over the spot frames, one CSV row per conversion.
enum BenchCommand {
    static let set1 = URL(fileURLWithPath: "/Volumes/letslapse/Projects/E854D311-96E3-49EC-8179-146DBC896E18/source")
    static let set2 = URL(fileURLWithPath: "/Volumes/letslapse/Projects/F6387DFA-216D-4EFE-8398-FF18F243E454/source")
    static let set1Frames = ["_WEX3879.ARW", "_WEX4159.ARW", "_WEX4319.ARW"]
    static let set2Frames = ["frame-00001.dng", "frame-00100.dng", "frame-00207.dng"]

    struct Options {
        var sets: [Int] = [1, 2]
        var outputDirectory: URL
        var csv: URL
        var only: [String] = []
        var frames: [String]?
        var whiteBalance = true
        var adobe = false
        var throughputFrames = 0
        var inFlight = 3
        var resume: URL?
    }

    static func run(arguments: [String]) throws {
        let stamp: String = {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmm"
            return formatter.string(from: Date())
        }()
        let home = FileManager.default.homeDirectoryForCurrentUser
        var options = Options(
            outputDirectory: home.appendingPathComponent("Library/Developer/LetsLapseRun/out/dng-spike/\(stamp)"),
            csv: home.appendingPathComponent("Library/Developer/LetsLapseRun/out/dng-spike/\(stamp)/matrix.csv"))
        var i = 0
        var csvGiven = false
        while i < arguments.count {
            func value() throws -> String { i += 1; guard i < arguments.count else { throw SpikeError.usage("value after \(arguments[i - 1])") }; return arguments[i] }
            switch arguments[i] {
            case "--set": let v = try value(); options.sets = v == "both" ? [1, 2] : [Int(v) ?? 1]
            case "--out": options.outputDirectory = URL(fileURLWithPath: try value())
            case "--csv": options.csv = URL(fileURLWithPath: try value()); csvGiven = true
            case "--only": options.only.append(try value())
            case "--frames": options.frames = try value().split(separator: ",").map(String.init)
            case "--no-wb": options.whiteBalance = false
            case "--adobe": options.adobe = true
            case "--throughput": options.throughputFrames = Int(try value()) ?? 0
            case "--inflight": options.inFlight = Int(try value()) ?? 3
            case "--resume": options.resume = URL(fileURLWithPath: try value())
            default: throw SpikeError.usage("unknown bench option \(arguments[i])")
            }
            i += 1
        }
        if !csvGiven { options.csv = options.outputDirectory.appendingPathComponent("matrix.csv") }
        try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: set1.path) || FileManager.default.fileExists(atPath: set2.path) else {
            throw SpikeError.io("/Volumes/letslapse is not mounted — nothing to bench")
        }

        let converter = Converter()
        converter.warmUp()
        let verifier = try Verifier()
        var csv = csvHeader + "\n"
        var done: Set<String> = []
        if let resume = options.resume, let existing = try? String(contentsOf: resume, encoding: .utf8) {
            // Keep every finished row of an interrupted run; redo the rest.
            let lines = existing.split(separator: "\n").map(String.init)
            if lines.first == csvHeader {
                for line in lines.dropFirst() {
                    csv += line + "\n"
                    let fields = line.split(separator: ",", maxSplits: 3).map { $0.replacingOccurrences(of: "\"", with: "") }
                    if fields.count >= 3 { done.insert("\(fields[0])|\(fields[1])|\(fields[2])") }
                }
                print("resuming: \(done.count) rows kept from \(resume.lastPathComponent)")
            } else {
                print("resume: \(resume.lastPathComponent) has a different header, starting fresh")
            }
        }
        let csvURL = options.csv
        func flush() { try? csv.write(to: csvURL, atomically: true, encoding: .utf8) }
        flush()

        print("dngspike bench → \(options.outputDirectory.path)")
        print("  \(JXLEncoder.version) · LibRaw \(LibRawDecoder.version) · thermal \(Thermal.state)")

        for set in options.sets {
            let directory = set == 1 ? set1 : set2
            guard FileManager.default.fileExists(atPath: directory.path) else { print("set \(set): not mounted, skipped"); continue }
            let frames = options.frames ?? (set == 1 ? set1Frames : set2Frames)
            let strategies = matrix(set: set).filter { strategy in
                options.only.isEmpty || options.only.contains { strategy.label.contains($0) }
            }
            print("set \(set): \(frames.count) frames × \(strategies.count) strategies")
            // Lossless twins: the reference for a lossy row is the lossless
            // output of the same decode/demosaic/size, made first.
            var losslessOutputs: [String: URL] = [:]
            for frame in frames {
                let input = directory.appendingPathComponent(frame)
                guard FileManager.default.fileExists(atPath: input.path) else { print("  \(frame) missing"); continue }
                for strategy in strategies {
                    let name = "\(set)-\(input.deletingPathExtension().lastPathComponent)-\(strategy.label).dng"
                    let output = options.outputDirectory.appendingPathComponent(name)
                    if done.contains("\(set)|\(frame)|\(strategy.label)") {
                        if strategy.codec.isLossless, FileManager.default.fileExists(atPath: output.path) {
                            losslessOutputs[twinKey(strategy, frame: frame)] = output
                        }
                        continue
                    }
                    var row = Row(set: set, frame: frame, strategy: strategy.label)
                    do {
                        let report = try converter.convert(input, to: output, strategy: strategy)
                        row.fill(report)
                        if strategy.codec.isLossless {
                            losslessOutputs[twinKey(strategy, frame: frame)] = output
                        }
                        let reference = strategy.codec.isLossless ? nil : losslessOutputs[twinKey(strategy, frame: frame)]
                        let verify = try verifier.verify(input: input, output: output, reference: reference,
                                                         whiteBalancePush: options.whiteBalance && !strategy.codec.isLossless,
                                                         adobeRoundTrip: options.adobe)
                        row.fill(verify)
                        print(String(format: "  %@  %6.0f ms  %@  ×%.1f  PSNR %.1f  SSIM %.4f  whole %.1f%%  block %.1f%%  direct %.1f%%%@",
                                     strategy.label as NSString, report.totalMilliseconds, mb(report.outputBytes), report.ratio,
                                     verify.psnr, verify.ssim, verify.wholeRelative * 100, verify.blockRelative * 100,
                                     verify.appleDirectWhole * 100, verify.repackApplies ? " (kit repacks)" : ""))
                    } catch {
                        row.error = "\(error)"
                        print("  \(strategy.label)  FAILED: \(error)")
                    }
                    row.thermal = Thermal.state
                    csv += row.csv + "\n"
                    flush()
                }
            }
            if options.throughputFrames > 0 {
                for strategy in strategies where !strategy.codec.isLossless || strategy.output == .cfa {
                    let inputs = throughputInputs(directory: directory, count: options.throughputFrames)
                    guard inputs.count >= 2 else { break }
                    let result = throughput(inputs: inputs, strategy: strategy, inFlight: options.inFlight, outputDirectory: options.outputDirectory)
                    var row = Row(set: set, frame: "throughput×\(inputs.count)", strategy: strategy.label)
                    row.totalMs = result.wallMilliseconds
                    row.fps = result.framesPerSecond
                    row.peakMB = result.peakMB
                    row.notes = "in-flight \(options.inFlight); \(result.note)"
                    row.thermal = Thermal.state
                    csv += row.csv + "\n"
                    flush()
                    print(String(format: "  throughput %@: %d frames in %.1f s = %.2f fps (%d in flight, peak %.0f MB) %@",
                                 strategy.label as NSString, inputs.count, result.wallMilliseconds / 1000, result.framesPerSecond, options.inFlight, result.peakMB, result.note))
                }
            }
        }
        print("csv → \(options.csv.path)")
    }

    static func twinKey(_ strategy: Strategy, frame: String) -> String {
        var twin = strategy
        twin.codec = .lj92
        twin.curve = .linear
        twin.tile = 512
        twin.whiteLevelOverride = nil
        return "\(frame)|\(twin.label)"
    }

    // MARK: - The matrix

    static func matrix(set: Int) -> [Strategy] {
        var rows: [Strategy] = []
        func add(_ decode: Strategy.Decode, _ output: Strategy.Output, _ codec: TileCodec, curve: Curve = .linear,
                 mp: Double? = nil, demosaic: Strategy.Demosaic = .metal, tile: Int = 512, librawQuality: Int = 3) {
            var s = Strategy()
            s.decode = decode; s.output = output; s.codec = codec; s.curve = curve
            s.megapixels = mp; s.demosaic = demosaic; s.tile = tile; s.librawQuality = librawQuality
            // Adobe's BaselineExposure for the ILCE-7M4, from its own DNG of these
            // frames; Apple applies its equivalent to CFA data by camera lookup but
            // not to LinearRaw, and LibRaw has no such table.
            if set == 1, decode == .libraw || decode == .librawDemosaic { s.baselineExposure = 0.35 }
            rows.append(s)
        }
        let lut = Curve.gammaLUT(gamma: 2.2)
        let cubic = Curve.cubic(c1: 0.1)
        func jxl(_ d: Float, _ e: Int = 7, xyb: Bool = true) -> TileCodec { .jxl(distance: d, effort: e, decodeSpeed: 4, xyb: xyb) }
        let haveLibRaw = LibRawDecoder.isAvailable
        let haveJXL = JXLEncoder.isAvailable

        if set == 1 {
            let target = 10.0
            // Apple decode (A1): the no-third-party path.
            add(.apple, .linear, .lj92)                                   // lossless twin, keep
            add(.apple, .linear, .lj92, mp: target)                       // lossless twin, 10 MP
            if haveJXL {
                add(.apple, .linear, jxl(0.5), curve: lut)
                add(.apple, .linear, jxl(0.5), curve: lut, mp: target)
                add(.apple, .linear, jxl(1.0), curve: lut, mp: target)
                add(.apple, .linear, jxl(2.0), curve: lut, mp: target)
                add(.apple, .linear, jxl(1.0, 3), curve: lut, mp: target)
                add(.apple, .linear, jxl(1.0, 5), curve: lut, mp: target)
                add(.apple, .linear, jxl(0.5), curve: cubic, mp: target)
                add(.apple, .linear, jxl(1.0, xyb: false), curve: .linear, mp: target)
            }
            add(.apple, .linear, .jpeg8(quality: 0.9), curve: cubic, mp: target)
            add(.apple, .linear, .hwjpeg(quality: 0.9), curve: cubic, mp: target)
            if haveLibRaw {
                // Camera-native mosaic (A2).
                add(.libraw, .cfa, .lj92)
                if haveJXL {
                    add(.libraw, .cfa, jxl(0))
                    add(.libraw, .cfa, jxl(0.5), curve: cubic)
                    add(.libraw, .cfa, jxl(1.0), curve: cubic)
                    add(.libraw, .cfa, jxl(0.5), curve: lut)                 // Apple ignores the table on JXL CFA (recorded)
                    add(.libraw, .cfa, jxl(1.0, xyb: false), curve: .linear) // no XYB, linear samples
                }
                // A2 + our Metal demosaic.
                add(.libraw, .linear, .lj92)
                add(.libraw, .linear, .lj92, mp: target)
                if haveJXL {
                    add(.libraw, .linear, jxl(0.5), curve: lut)
                    add(.libraw, .linear, jxl(0.5), curve: lut, mp: target)
                    add(.libraw, .linear, jxl(1.0), curve: lut, mp: target)
                    add(.libraw, .linear, jxl(2.0), curve: lut, mp: target)
                    add(.libraw, .linear, jxl(1.0, 3), curve: lut, mp: target)
                    add(.libraw, .linear, jxl(1.0, 5), curve: lut, mp: target)
                    add(.libraw, .linear, jxl(0.5), curve: cubic, mp: target)
                    add(.libraw, .linear, jxl(1.0, xyb: false), curve: .linear, mp: target)
                    add(.libraw, .linear, jxl(1.0), curve: lut, demosaic: .bin2, tile: 256)
                    add(.libraw, .linear, jxl(1.0), curve: lut, mp: target, tile: 256)
                    // LibRaw's own demosaic for comparison.
                    add(.librawDemosaic, .linear, .lj92, mp: target)
                    add(.librawDemosaic, .linear, jxl(1.0), curve: lut, mp: target)
                }
                add(.libraw, .linear, .jpeg8(quality: 0.9), curve: cubic, mp: target)
                add(.libraw, .linear, .hwjpeg(quality: 0.9), curve: cubic, mp: target)
                add(.libraw, .linear, .jpeg8(quality: 0.9), curve: lut, mp: target)   // Apple renders black (recorded)
            }
        } else {
            let target = 8.0
            // The app's own files: native parse (A3).
            add(.native, .cfa, .lj92)
            if haveJXL {
                add(.native, .cfa, jxl(0))
                add(.native, .cfa, jxl(0.5), curve: cubic)
                add(.native, .cfa, jxl(1.0), curve: cubic)
                add(.native, .cfa, jxl(0.5), curve: lut)                 // Apple ignores the table on JXL CFA (recorded)
                add(.native, .cfa, jxl(1.0, xyb: false), curve: .linear)
            }
            add(.native, .linear, .lj92)
            add(.native, .linear, .lj92, mp: target)
            if haveJXL {
                add(.native, .linear, jxl(0.5), curve: lut)
                add(.native, .linear, jxl(0.5), curve: lut, mp: target)
                add(.native, .linear, jxl(1.0), curve: lut, mp: target)
                add(.native, .linear, jxl(2.0), curve: lut, mp: target)
                add(.native, .linear, jxl(1.0, 3), curve: lut, mp: target)
                add(.native, .linear, jxl(1.0, 5), curve: lut, mp: target)
                add(.native, .linear, jxl(0.5), curve: cubic, mp: target)
                add(.native, .linear, jxl(1.0, xyb: false), curve: .linear, mp: target)
                add(.native, .linear, jxl(1.0), curve: lut, demosaic: .bin2, tile: 256)
                add(.native, .linear, jxl(1.0), curve: lut, mp: target, tile: 256)
            }
            add(.native, .linear, .jpeg8(quality: 0.9), curve: cubic, mp: target)
            add(.native, .linear, .hwjpeg(quality: 0.9), curve: cubic, mp: target)
            add(.native, .linear, .jpeg8(quality: 0.9), curve: lut, mp: target)   // Apple renders black (recorded)
            // Apple's decode of our own DNGs, for the comparison.
            add(.apple, .linear, .lj92)
            if haveJXL { add(.apple, .linear, jxl(1.0), curve: lut, mp: target) }
        }
        return rows
    }

    // MARK: - Throughput

    struct Throughput {
        let wallMilliseconds: Double
        let framesPerSecond: Double
        let peakMB: Double
        let note: String
    }

    static func throughputInputs(directory: URL, count: Int) -> [URL] {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { ImportedStills.isRaw(URL(fileURLWithPath: $0)) }
            .sorted()
        return files.prefix(count).map { directory.appendingPathComponent($0) }
    }

    static func throughput(inputs: [URL], strategy: Strategy, inFlight: Int, outputDirectory: URL) -> Throughput {
        let scratch = outputDirectory.appendingPathComponent("throughput")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let converter = Converter()
        let lock = NSLock()
        var failures = 0
        var peak = Memory.footprintMB()
        let started = ProcessInfo.processInfo.systemUptime
        let semaphore = DispatchSemaphore(value: inFlight)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "dngspike.throughput", attributes: .concurrent)
        for input in inputs {
            semaphore.wait()
            group.enter()
            queue.async {
                defer { semaphore.signal(); group.leave() }
                let output = scratch.appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".dng")
                do {
                    _ = try converter.convert(input, to: output, strategy: strategy)
                } catch {
                    lock.lock(); failures += 1; lock.unlock()
                }
                lock.lock(); peak = max(peak, Memory.footprintMB()); lock.unlock()
            }
        }
        group.wait()
        let wall = (ProcessInfo.processInfo.systemUptime - started) * 1000
        try? FileManager.default.removeItem(at: scratch)
        return Throughput(wallMilliseconds: wall, framesPerSecond: Double(inputs.count - failures) / (wall / 1000), peakMB: peak,
                          note: failures > 0 ? "\(failures) failed" : "thermal \(Thermal.state)")
    }

    // MARK: - CSV

    static let csvHeader = [
        "set", "frame", "strategy", "decode_path", "width", "height", "megapixels",
        "decode_ms", "demosaic_ms", "resize_ms", "readback_ms", "curve_ms", "encode_ms", "write_ms", "total_ms", "fps_single",
        "in_bytes", "out_bytes", "ratio", "peak_mb",
        "whole_rel", "block_rel", "block_abs", "green_ratio", "blue_ratio", "psnr_db", "ssim", "stops_rms",
        "wb_warm_psnr", "wb_cool_psnr", "wb_tintp_psnr", "wb_tintm_psnr", "wb_warm_stops", "wb_cool_stops", "wb_balanced",
        "apple_direct", "apple_direct_whole", "apple_direct_green", "apple_direct_blue", "repack_applies", "imageio_type", "imageio_decodes", "quicklook", "adobe", "adobe_gap",
        "thermal", "error", "notes",
    ].joined(separator: ",")

    struct Row {
        var set: Int
        var frame: String
        var strategy: String
        var decodePath = ""
        var width = 0, height = 0
        var stages: [String: Double] = [:]
        var totalMs = 0.0
        var fps = 0.0
        var inBytes = 0, outBytes = 0
        var peakMB = 0.0
        var verify: VerifyResult?
        var thermal = ""
        var error = ""
        var notes = ""

        mutating func fill(_ report: ConversionReport) {
            decodePath = report.decodePath
            width = report.width; height = report.height
            for (name, ms) in report.stages { stages[name, default: 0] += ms }
            totalMs = report.totalMilliseconds
            fps = totalMs > 0 ? 1000 / totalMs : 0
            inBytes = report.inputBytes; outBytes = report.outputBytes
            peakMB = report.peakFootprintMB
            notes = report.notes.joined(separator: " | ")
        }

        mutating func fill(_ result: VerifyResult) { verify = result }

        var csv: String {
            func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "'") + "\"" }
            func f(_ v: Double, _ d: Int = 2) -> String { String(format: "%.\(d)f", v) }
            let v = verify
            let wb: [(label: String, psnr: Double, stopsRMS: Double, balanced: Bool)] = v?.wbPushes ?? []
            func wbPSNR(_ i: Int) -> String { i < wb.count ? f(wb[i].psnr) : "" }
            func wbStops(_ i: Int) -> String { i < wb.count ? f(wb[i].stopsRMS, 3) : "" }
            var fields: [String] = []
            fields.append("\(set)")
            fields.append(q(frame))
            fields.append(q(strategy))
            fields.append(q(decodePath))
            fields.append("\(width)")
            fields.append("\(height)")
            fields.append(f(Double(width * height) / 1e6, 2))
            for stage in ["decode", "demosaic", "resize", "readback", "curve", "encode", "write"] {
                fields.append(f(stages[stage] ?? 0, 0))
            }
            fields.append(f(totalMs, 0))
            fields.append(f(fps, 3))
            fields.append("\(inBytes)")
            fields.append("\(outBytes)")
            fields.append(outBytes > 0 ? f(Double(inBytes) / Double(outBytes), 2) : "")
            fields.append(f(peakMB, 0))
            if let v {
                fields.append(f(v.wholeRelative, 4))
                fields.append(f(v.blockRelative, 4))
                fields.append(f(v.blockAbsolute, 5))
                fields.append(f(v.greenRatio, 4))
                fields.append(f(v.blueRatio, 4))
                fields.append(f(v.psnr, 2))
                fields.append(f(v.ssim, 4))
                fields.append(f(v.stopsRMS, 4))
            } else {
                fields.append(contentsOf: Array(repeating: "", count: 8))
            }
            fields.append(wbPSNR(0)); fields.append(wbPSNR(1)); fields.append(wbPSNR(2)); fields.append(wbPSNR(3))
            fields.append(wbStops(0)); fields.append(wbStops(1))
            fields.append(wb.isEmpty ? "" : (wb.allSatisfy { $0.balanced } ? "yes" : "no"))
            if let v {
                fields.append(v.appleDirectOpens ? "yes" : "no")
                fields.append(v.appleDirectWhole >= 0 ? f(v.appleDirectWhole, 4) : "")
                fields.append(f(v.appleDirectGreenRatio, 4))
                fields.append(f(v.appleDirectBlueRatio, 4))
                fields.append(v.repackApplies ? "yes" : "no")
                fields.append(q(v.imageIOType))
                fields.append(v.imageIODecodes ? "yes" : "no")
                fields.append(q(v.quickLook))
                fields.append(q(v.adobe))
                fields.append(v.adobeGap >= 0 ? f(v.adobeGap, 4) : "")
            } else {
                fields.append(contentsOf: Array(repeating: "", count: 10))
            }
            fields.append(q(thermal))
            fields.append(q(error))
            var allNotes = notes
            if let v, !v.notes.isEmpty { allNotes += " | " + v.notes.joined(separator: " | ") }
            fields.append(q(allNotes))
            return fields.joined(separator: ",")
        }
    }

    static func jsonLine(_ report: ConversionReport) -> String {
        var object: [String: Any] = [
            "input": report.input.path, "output": report.output.path, "strategy": report.strategy, "decodePath": report.decodePath,
            "width": report.width, "height": report.height, "totalMs": report.totalMilliseconds,
            "inBytes": report.inputBytes, "outBytes": report.outputBytes, "peakMB": report.peakFootprintMB, "notes": report.notes,
        ]
        var stages: [String: Double] = [:]
        for (name, ms) in report.stages { stages[name, default: 0] += ms }
        object["stages"] = stages
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

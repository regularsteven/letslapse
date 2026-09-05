import Foundation
import LetsLapseKit

// dngspike — the DNG archive-conversion spike. Hand-rolled arguments, like `lapse`.

let usage = """
dngspike — raw → lossy / resized DNG, measured (docs/dng-archive-spike-brief.md)

USAGE:
  dngspike probe [--json]                          Capability table for this machine
  dngspike convert <in> <out> [options]            Convert one frame
      --decode auto|apple|native|libraw|libraw-demosaic
      --demosaic metal|bin2                        For mosaic decodes → linear output (default metal)
      --output cfa|linear                          Bayer mosaic out, or demosaiced LinearRaw (default linear)
      --encode lj92|jxl|jpeg8|hwjpeg|raw           Tile codec (default lj92)
      --distance D  --effort E  --speed S          JPEG XL: distance 0 = lossless (defaults 0.5 / 7 / 4)
      --rgb                                        JPEG XL without XYB (original profile, linear)
      --quality Q                                  8-bit JPEG quality 0…1 (default 0.9)
      --curve linear|lut|cubic  --gamma G  --c1 C  Stored-value curve (lut γ default 2.2, cubic c1 default 0.1)
      --megapixels N                               Resample to N MP (linear output only)
      --tile N                                     Tile edge (default 512; 0 = whole frame)
      --pedestal N                                 Black pedestal in 16-bit units (default 2048)
      --libraw-quality Q                           LibRaw demosaic: 0 linear 1 VNG 2 PPG 3 AHD 11 DHT
      --baseline-exposure EV                       Add BaselineExposure to camera-native output (Adobe's ILCE-7M4 value is 0.35)
      --white-level N                              WhiteLevel override (8-bit experiments)
      --json                                       Machine-readable report
  dngspike verify <in> <out> [--wb] [--adobe] [--json]   Quality + compatibility of one pair
  dngspike bench [--set 1|2|both] [--out DIR] [--csv PATH] [--only PATTERN] [--parallel N] [--frames a,b,c]
"""

func parseStrategy(_ args: inout [String]) throws -> Strategy {
    var strategy = Strategy()
    var distance: Float = 0.5, effort = 7, speed = 4, xyb = true, quality = 0.9, gamma = 2.2, c1 = 0.1
    var encode = "lj92", curve = "linear"
    var i = 0
    var remaining: [String] = []
    func value() throws -> String {
        i += 1
        guard i < args.count else { throw SpikeError.usage("missing value after \(args[i - 1])") }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--decode": strategy.decode = try Strategy.Decode(rawValue: try value()) ?? { throw SpikeError.usage("decode") }()
        case "--demosaic": strategy.demosaic = try Strategy.Demosaic(rawValue: try value()) ?? { throw SpikeError.usage("demosaic") }()
        case "--output": strategy.output = try Strategy.Output(rawValue: try value()) ?? { throw SpikeError.usage("output") }()
        case "--encode": encode = try value()
        case "--distance": distance = Float(try value()) ?? 0.5
        case "--effort": effort = Int(try value()) ?? 7
        case "--speed": speed = Int(try value()) ?? 4
        case "--rgb": xyb = false
        case "--quality": quality = Double(try value()) ?? 0.9
        case "--curve": curve = try value()
        case "--gamma": gamma = Double(try value()) ?? 2.2
        case "--c1": c1 = Double(try value()) ?? 0.1
        case "--megapixels": strategy.megapixels = Double(try value())
        case "--tile": strategy.tile = Int(try value()) ?? 512
        case "--pedestal": strategy.pedestal = Int(try value()) ?? 2048
        case "--libraw-quality": strategy.librawQuality = Int(try value()) ?? 3
        case "--baseline-exposure": strategy.baselineExposure = Double(try value())
        case "--white-level": strategy.whiteLevelOverride = UInt32(try value())
        case "--headroom": strategy.appleHeadroom = Int(try value()) ?? 2
        default: remaining.append(args[i])
        }
        i += 1
    }
    switch encode {
    case "lj92": strategy.codec = .lj92
    case "jxl": strategy.codec = .jxl(distance: distance, effort: effort, decodeSpeed: speed, xyb: xyb)
    case "jpeg8": strategy.codec = .jpeg8(quality: quality)
    case "hwjpeg": strategy.codec = .hwjpeg(quality: quality)
    case "raw", "none": strategy.codec = .none
    default: throw SpikeError.usage("unknown encoder \(encode)")
    }
    switch curve {
    case "linear": strategy.curve = .linear
    case "lut", "gamma": strategy.curve = .gammaLUT(gamma: gamma)
    case "cubic", "poly": strategy.curve = .cubic(c1: c1)
    default: throw SpikeError.usage("unknown curve \(curve)")
    }
    args = remaining
    return strategy
}

func main() -> Int32 {
    // Line-buffered even through a pipe, so a long bench streams its rows.
    setlinebuf(stdout)
    var args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else { print(usage); return 64 }
    args.removeFirst()
    let json = args.contains("--json")
    args.removeAll { $0 == "--json" }
    do {
        switch command {
        case "probe":
            ProbeCommand.run(json: json)
        case "convert":
            let strategy = try parseStrategy(&args)
            guard args.count >= 2 else { throw SpikeError.usage("convert <in> <out>") }
            let input = URL(fileURLWithPath: args[0]), output = URL(fileURLWithPath: args[1])
            let report = try Converter().convert(input, to: output, strategy: strategy)
            if json { print(BenchCommand.jsonLine(report)) } else { print(report.summary) }
        case "verify":
            let wb = args.contains("--wb"), adobe = args.contains("--adobe")
            args.removeAll { $0 == "--wb" || $0 == "--adobe" }
            guard args.count >= 2 else { throw SpikeError.usage("verify <in> <out>") }
            let result = try Verifier().verify(input: URL(fileURLWithPath: args[0]), output: URL(fileURLWithPath: args[1]), whiteBalancePush: wb, adobeRoundTrip: adobe)
            print(json ? result.json : result.text)
        case "bench":
            try BenchCommand.run(arguments: args)
        case "xlinear":
            // Experiment: the same demosaiced samples through the Kit's shipped
            // LinearRaw writer (uncompressed strip, SHORT[3] white, no black).
            guard args.count >= 2 else { throw SpikeError.usage("xlinear <in> <out>") }
            try Experiments.kitLinear(input: URL(fileURLWithPath: args[0]), output: URL(fileURLWithPath: args[1]))
        case "help", "-h", "--help":
            print(usage)
        default:
            print(usage)
            return 64
        }
    } catch {
        FileHandle.standardError.write("dngspike: \(error)\n".data(using: .utf8)!)
        return 1
    }
    return 0
}

exit(main())

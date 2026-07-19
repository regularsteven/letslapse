import Foundation
import AVFoundation
import LetsLapseKit

// lapse — headless front end for the Let's Lapse blend engine (macOS).
// Hand-rolled argument parsing keeps the package dependency-free.

let usageText = """
lapse — GPU frame blending / stacking (Let's Lapse)

USAGE:
  lapse blend <video> -o <output> [options]     Blend a video with a moving window
      --window N            Constant blend window (default 10)
      --ramp A:B            Ramp the window from A to B across the clip
      --curve NAME          linear | ease-in | ease-out | ease-in-out (default linear)
      --fps N               Output frame rate (default 30)
      --codec NAME          h264 | hevc | prores | jpeg (default h264)
      --gamma               Average gamma-encoded values instead of linear light

  lapse stack <image...> -o <output> [options]  Average stills into one image
      --format NAME         png | jpeg | heic (default: inferred from output path)
      --gamma               Average gamma-encoded values instead of linear light

  lapse synth -o <output> [options]             Render a synthetic test clip
      --frames N            Frame count (default 120)
      --size WxH            Dimensions (default 320x240)
      --fps N               Frame rate (default 30)
      --pattern NAME        ramp | box (default ramp)

  lapse info <video>                            Print duration / fps / frame estimate

EXAMPLES:
  lapse synth -o test.mov --frames 240 --pattern box
  lapse blend test.mov -o blended.mp4 --ramp 1:40 --curve ease-in-out
  lapse stack shots/*.jpg -o stacked.png
"""

func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func fail(_ message: String) -> Never {
    printErr("error: \(message)")
    exit(1)
}

func usage() -> Never {
    print(usageText)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())

func takeOption(_ names: [String]) -> String? {
    for (index, argument) in args.enumerated() where names.contains(argument) {
        guard index + 1 < args.count else { fail("\(argument) needs a value") }
        let value = args[index + 1]
        args.removeSubrange(index...(index + 1))
        return value
    }
    return nil
}

func takeFlag(_ names: [String]) -> Bool {
    for (index, argument) in args.enumerated() where names.contains(argument) {
        args.remove(at: index)
        return true
    }
    return false
}

@Sendable func progressToStderr(_ fraction: Double) {
    let percent = Int((fraction * 100).rounded())
    FileHandle.standardError.write(Data("\rprocessing… \(percent)%\(percent >= 100 ? "\n" : "")".utf8))
}

guard let command = args.first, !["-h", "--help", "help"].contains(command) else {
    usage()
}
args.removeFirst()

do {
    switch command {
    case "blend":
        guard let outputPath = takeOption(["-o", "--output"]) else { fail("blend needs -o <output>") }
        let windowOption = takeOption(["--window", "-w"])
        let rampOption = takeOption(["--ramp", "-r"])
        let curveName = takeOption(["--curve"]) ?? "linear"
        let fpsOption = takeOption(["--fps"]) ?? "30"
        let codecName = takeOption(["--codec"]) ?? "h264"
        let gamma = takeFlag(["--gamma"])
        guard args.count == 1 else { fail("blend needs exactly one input video (got \(args.count))") }
        guard let curve = BlendCurve(rawValue: curveName) else {
            fail("unknown curve '\(curveName)' — choose from: \(BlendCurve.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        guard let codec = OutputCodec(rawValue: codecName) else {
            fail("unknown codec '\(codecName)' — choose from: \(OutputCodec.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        guard let fps = Double(fpsOption), fps > 0 else { fail("--fps needs a positive number") }

        let ramp: BlendRamp
        if let rampOption {
            let parts = rampOption.split(separator: ":")
            guard parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]), start >= 1, end >= 1 else {
                fail("--ramp expects START:END, e.g. --ramp 1:40")
            }
            ramp = BlendRamp(startWindow: start, endWindow: end, curve: curve)
        } else {
            let window = Int(windowOption ?? "10") ?? 0
            guard window >= 1 else { fail("--window needs a positive integer") }
            ramp = .constant(window)
        }

        let input = URL(fileURLWithPath: args[0])
        let output = URL(fileURLWithPath: outputPath)
        let core = try BlendCore()
        let blender = VideoBlender(core: core)
        let started = Date()
        let options = VideoBlendOptions(ramp: ramp, outputFPS: fps, codec: codec, linearLight: !gamma)
        let result = try await blender.blend(input: input, to: output, options: options, progress: progressToStderr)
        let elapsed = Date().timeIntervalSince(started)
        print("blended \(result.inputFrames) input frames → \(result.outputFrames) output frames "
            + "(\(result.width)x\(result.height), \(String(format: "%.2f", result.outputDuration))s) "
            + "in \(String(format: "%.1f", elapsed))s")
        print(result.outputURL.path)

    case "stack":
        guard let outputPath = takeOption(["-o", "--output"]) else { fail("stack needs -o <output>") }
        let formatName = takeOption(["--format"])
        let gamma = takeFlag(["--gamma"])
        guard !args.isEmpty else { fail("stack needs at least one input image") }
        let output = URL(fileURLWithPath: outputPath)
        let format: ImageFormat
        if let formatName {
            guard let parsed = ImageFormat(rawValue: formatName) else {
                fail("unknown format '\(formatName)' — choose from: \(ImageFormat.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            format = parsed
        } else {
            format = ImageFormat.infer(from: output) ?? .png
        }
        let inputs = args.map { URL(fileURLWithPath: $0) }
        let core = try BlendCore()
        let stacker = ImageStacker(core: core)
        let started = Date()
        let image = try stacker.stack(imageURLs: inputs, linearLight: !gamma) { progressToStderr($0) }
        try ImageExporter.write(image, to: output, format: format)
        let elapsed = Date().timeIntervalSince(started)
        print("stacked \(inputs.count) images (\(image.width)x\(image.height)) in \(String(format: "%.1f", elapsed))s")
        print(output.path)

    case "synth":
        guard let outputPath = takeOption(["-o", "--output"]) else { fail("synth needs -o <output>") }
        let frames = Int(takeOption(["--frames"]) ?? "120") ?? 0
        let sizeOption = takeOption(["--size"]) ?? "320x240"
        let fps = Double(takeOption(["--fps"]) ?? "30") ?? 0
        let patternName = takeOption(["--pattern"]) ?? "ramp"
        guard frames > 0 else { fail("--frames needs a positive integer") }
        guard fps > 0 else { fail("--fps needs a positive number") }
        let sizeParts = sizeOption.lowercased().split(separator: "x")
        guard sizeParts.count == 2, let width = Int(sizeParts[0]), let height = Int(sizeParts[1]),
              width > 0, height > 0 else {
            fail("--size expects WxH, e.g. --size 640x480")
        }
        guard let pattern = VideoSynthesizer.Pattern(rawValue: patternName) else {
            fail("unknown pattern '\(patternName)' — choose from: \(VideoSynthesizer.Pattern.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let output = URL(fileURLWithPath: outputPath)
        try VideoSynthesizer.makeVideo(at: output, frames: frames, width: width, height: height, fps: fps, pattern: pattern)
        print("wrote \(frames)-frame \(width)x\(height) \(patternName) clip")
        print(output.path)

    case "info":
        guard args.count == 1 else { fail("info needs exactly one input video") }
        let url = URL(fileURLWithPath: args[0])
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            fail("no video track in \(url.lastPathComponent)")
        }
        let (fps, size) = try await track.load(.nominalFrameRate, .naturalSize)
        let duration = try await asset.load(.duration)
        let frames = Int((duration.seconds * Double(fps)).rounded())
        print("duration: \(String(format: "%.2f", duration.seconds))s")
        print("fps: \(String(format: "%.2f", fps))")
        print("size: \(Int(size.width))x\(Int(size.height))")
        print("frames (estimated): \(frames)")

    default:
        printErr("unknown command '\(command)'\n")
        usage()
    }
} catch {
    let description = (error as? LapseError)?.errorDescription ?? error.localizedDescription
    fail(description)
}

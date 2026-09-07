import Foundation
import AVFoundation
import LetsLapseKit

// lapse — headless front end for the LetsLapse blend engine (macOS).
// Hand-rolled argument parsing keeps the package dependency-free.

let usageText = """
lapse — GPU frame blending / stacking (LetsLapse)

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
      --lock                Apply the committed framing lock (framing.json beside
                            the stills) to every still before averaging

  lapse framing <project-or-source-dir> [options]   Review the framing of an
                            interval shoot's stills: where each sits against one
                            locked reference, the knocks, and the crop that would
                            hold it still. Writes framing.json beside the stills
                            and prints the report; prints the existing review
                            when there is one.
      --apply               Commit the plan ("Stabilise photos")
      --withdraw            Remove a committed plan
      --force               Re-measure even when a review exists
      --scale S             Decode scale for the measurement (default 0.5)
      --workers N           Parallel chunks (default: half the cores, max 4)
      --range A-B           Measure only stills A…B (0-based); printed, not written
      --json PATH           Also write the review here

  lapse synth -o <output> [options]             Render a synthetic test clip
      --frames N            Frame count (default 120)
      --size WxH            Dimensions (default 320x240)
      --fps N               Frame rate (default 30)
      --pattern NAME        ramp | box (default ramp)

      (grade --recipe also takes declaredkelvin / declaredtint — the absolute
       anchor that replaces "as shot", in Kelvin and on the converter's ±150
       tint axis. Absent means as shot, which is not the same as zero.)

  lapse whitebalance <project-or-source-dir> [options]   Measure a shoot's as-shot
                            white balance frame by frame, write
                            frames.whitebalance beside the stills, and report the
                            steps the camera made. Prints WHITEBALANCE PASS/FAIL.
      --report              Report the existing series without re-measuring
      --force               Re-measure even when a series exists
      --anchor P            Level the corrected curve to the frame at P (0…1)
      --json PATH           Also write measured + corrected series here

  lapse info <video>                            Print duration / fps / frame estimate

  lapse lightroom <file.xmp> [--json]           Read a Lightroom sidecar and report the import
  lapse craft [options]                         Drive the Crafted Text path headless
                            The Text tab's "Add Crafted Text" without the app: a
                            brief (or a model's raw answer) in, the laid-out
                            layers out. No model, no device, no window — which is
                            what makes it testable in CI.
      --brief TEXT          The brief. On its own this runs the NO-MODEL path —
                            the same splitter the app uses when nothing is
                            installed.
      --response PATH       A model's raw answer to parse instead of splitting;
                            `-` reads stdin, so a real generation can be piped
                            in. Exit 65 if it cannot be used.
      --prompt KIND         Print the prompt that WOULD be sent (split |
                            candidates) and stop. Needs --brief.
      --options             Read --response as a "Needs work" answer (three
                            directions) rather than as parts.
      --aspect W:H          Output frame aspect (default 4:3)
      --playhead N          Where the copy lands, 0…1 (default 0.35)
      --font-display NAME   Imported face for the payoff line (--measure coretext)
      --font-hand NAME      Imported face for the lines around it
      --measure NAME        estimate (default, font-free and identical on every
                            machine) | coretext (real metrics, for a true fit)
      --json                Machine-readable report
      --expect-lines N      Exit 65 unless exactly N lines came out
      --expect-payoff TEXT  Exit 65 unless that line is the priority-1 payoff

  lapse slice <blended-clip> [options]          Time-slice a finished blended clip
      -o PATH               Write the sliced animation here (mp4)
      --poster PATH         Write the full-source poster here (png)
      --segments N          Band count (default 24)
      --lag N               Frames of lag per band (default 2)
      --newest EDGE         left | right | top | bottom — the edge holding the
                            newest band (default right, so time starts at the
                            left; top/bottom = horizontal)
      --grid CORNER         topLeft | topRight | bottomLeft | bottomRight —
                            switches to grid mode: both axes banded into square
                            cells, the lag following each cell's distance from
                            this corner. --segments is then the COLUMN count and
                            the row count is derived from the aspect.
      --metric NAME         manhattan | euclidean (default manhattan) — stepped
                            diagonal bands vs a curved radial wavefront
      --variations N        Render a batch of N variations from one decode-per-
                            variation over the same clip, instead of one slice.
                            Output paths gain the variation's name before the
                            extension.
      --variation-mode NAME horizontal | vertical | grid | mixed (default mixed)
      --seed N              The batch's seed, for reproducibility (default random)
      --codec NAME          h264 | hevc | prores | jpeg (default h264)

  lapse poster <image...> -o <output.png> [options]
                                                Time-slice poster straight from stills:
                                                renders only the master frames the
                                                ladder needs (each blended at --depth)
                                                and never encodes a clip
      --depth N             Stills per master frame — the blend depth (default 1)
      --segments N          Band count, or column count with --grid (default 24)
      --newest EDGE         left | right | top | bottom (default right)
      --grid CORNER         topLeft | topRight | bottomLeft | bottomRight
      --metric NAME         manhattan | euclidean (default manhattan)
      --variations N        A batch of N posters from one walk over the stills
      --variation-mode NAME horizontal | vertical | grid | mixed (default mixed)
      --seed N              The batch's seed (default random)
      --recipe JSON         Grade recipe, as for `lapse grade`
      --gamma               Average gamma-encoded values (the legacy 8-bit path)

  lapse grade <image> [options]                 Grade one frame through the tone engine
      --recipe JSON         Slider values, Lightroom-style ±100 numbers, e.g.
                            '{"highlights":-100,"shadows":49,"vibrance":53}'
                            (exposure is EV; temperature is a mired offset)
      --out PATH            Write the graded JPEG here (Display P3 for raw,
                            sRGB for a JPEG/HEIF/PNG source)
      --scale N             Decode scale, 1 = full resolution (default 1)
      --quality N           JPEG quality 1…100 (default 95)
      --decode-path NAME    Raw decode pipeline: bradford | forwardmatrix |
                            ciraw | dcp (default bradford). Sets the same
                            switch the app's Settings picker writes.
      --probe               Instead of grading: report linear max/mean and
                            headroom for the RAW and ImageIO decode paths

EXAMPLES:
  lapse synth -o test.mov --frames 240 --pattern box
  lapse blend test.mov -o blended.mp4 --ramp 1:40 --curve ease-in-out
  lapse stack shots/*.jpg -o stacked.png
  lapse lightroom "/path/_WEX3825.xmp"
  lapse craft --brief "A little sand between your toes helps wash away the woes"
  lapse craft --response reply.json --json --expect-lines 2
"""

func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func fail(_ message: String) -> Never {
    printErr("error: \(message)")
    exit(1)
}

/// `out.mp4` + `-v3of8` → `out-v3of8.mp4`. Empty suffix leaves the path alone,
/// so the single-slice call sites are byte-identical.
func insertSuffix(_ suffix: String, into path: String) -> String {
    guard !suffix.isEmpty else { return path }
    let url = URL(fileURLWithPath: path)
    let ext = url.pathExtension
    let base = url.deletingPathExtension().path
    return ext.isEmpty ? base + suffix : base + suffix + "." + ext
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
        let lock = takeFlag(["--lock"])
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
        var loadFrame: ((URL) throws -> CGImage)?
        if lock {
            guard let folder = inputs.first?.deletingLastPathComponent(),
                  let framingLock = FramingLock.load(inSourceFolder: folder) else {
                fail("--lock needs a committed framing.json beside the stills (lapse framing <dir> --apply)")
            }
            printErr(String(format: "framing lock: %d photos measured, crop %.2f%%", framingLock.frameCount, framingLock.cropFraction * 100))
            loadFrame = framingLock.loader(base: { try ImageStacker.loadImage(at: $0) })
        }
        let image = try stacker.stack(
            imageURLs: inputs, linearLight: !gamma, loadFrame: loadFrame, progress: { progressToStderr($0) })
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

    case "slice":
        let outputPath = takeOption(["-o", "--output"])
        let posterPath = takeOption(["--poster"])
        let segments = Int(takeOption(["--segments"]) ?? "24") ?? 0
        let lag = Int(takeOption(["--lag"]) ?? "2") ?? 0
        let newestName = takeOption(["--newest"]) ?? TimeSliceSettings().newestEdge.rawValue
        let gridName = takeOption(["--grid"])
        let metricName = takeOption(["--metric"]) ?? TimeSliceGridMetric.manhattan.rawValue
        let variationCount = Int(takeOption(["--variations"]) ?? "0") ?? 0
        let variationModeName = takeOption(["--variation-mode"]) ?? TimeSliceVariationMode.mixed.rawValue
        let seed = UInt64(takeOption(["--seed"]) ?? "") ?? TimeSliceVariationPlan.freshSeed()
        let codecName = takeOption(["--codec"]) ?? "h264"
        guard args.count == 1 else { fail("slice needs exactly one input clip (got \(args.count))") }
        guard outputPath != nil || posterPath != nil else {
            fail("slice needs -o <animation> and/or --poster <image>")
        }
        guard segments >= 2 else { fail("--segments needs an integer ≥ 2") }
        guard lag >= 1 else { fail("--lag needs a positive integer") }
        guard let newest = TimeSliceEdge(rawValue: newestName) else {
            fail("unknown edge '\(newestName)' — choose from: \(TimeSliceEdge.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        guard let metric = TimeSliceGridMetric(rawValue: metricName) else {
            fail("unknown metric '\(metricName)' — choose from: \(TimeSliceGridMetric.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        guard let variationMode = TimeSliceVariationMode(rawValue: variationModeName) else {
            fail("unknown variation mode '\(variationModeName)' — choose from: \(TimeSliceVariationMode.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        guard let codec = OutputCodec(rawValue: codecName) else {
            fail("unknown codec '\(codecName)' — choose from: \(OutputCodec.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        var settings = TimeSliceSettings(newestEdge: newest, segments: segments, offsetFrames: lag)
        if let gridName {
            guard let origin = TimeSliceGridOrigin(rawValue: gridName) else {
                fail("unknown grid corner '\(gridName)' — choose from: \(TimeSliceGridOrigin.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            settings.grid = TimeSliceGrid(origin: origin, metric: metric)
        }
        let input = URL(fileURLWithPath: args[0])

        // A batch varies the recipe, never the source: the blended clip is
        // read once per variation and the expensive blend never re-runs.
        var recipes = [settings]
        if variationCount >= 2 {
            let asset = AVURLAsset(url: input)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                fail("no video track in \(input.lastPathComponent)")
            }
            let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
            let display = size.applying(transform)
            let counter = try await AssetFrameProvider(url: input)
            recipes = TimeSliceVariationGenerator.variations(
                plan: TimeSliceVariationPlan(count: variationCount, mode: variationMode, seed: seed),
                baseline: settings, masterFrames: counter.frameCount,
                width: Int(abs(display.width).rounded()), height: Int(abs(display.height).rounded()))
            guard !recipes.isEmpty else { fail("no valid variation fits this clip") }
            print("batch of \(recipes.count) (\(variationMode.rawValue), seed \(seed))")
        }

        for recipe in recipes {
            let suffix = recipe.variation.map { "-\($0.label)" } ?? ""
            let animation = outputPath.map { URL(fileURLWithPath: insertSuffix(suffix, into: $0)) }
            let poster = posterPath.map { URL(fileURLWithPath: insertSuffix(suffix, into: $0)) }
            let provider = try await AssetFrameProvider(url: input)
            let renderer = TimeSliceRenderer()
            let started = Date()
            let result = try renderer.render(
                provider: provider, settings: recipe,
                animationURL: animation, posterURL: poster,
                codec: codec, progress: progressToStderr)
            let elapsed = Date().timeIntervalSince(started)
            print("\(recipe.displayName): \(result.masterFrames) master frames → "
                + "\(result.outputFrames) sliced frames"
                + (result.wrotePoster ? " + poster" : "")
                + " (\(result.width)x\(result.height)"
                + (result.grid.map { ", \($0.summary)" } ?? "")
                + ") in \(String(format: "%.1f", elapsed))s")
            if let animation { print(animation.path) }
            if let poster { print(poster.path) }
        }

    case "grade":
        let probe = takeFlag(["--probe"])
        let recipeJSON = takeOption(["--recipe"])
        let outPath = takeOption(["--out", "-o"])
        let scale = Float(takeOption(["--scale"]) ?? "1") ?? 1
        let quality = Double(takeOption(["--quality"]) ?? "95") ?? 95
        if let decodePath = takeOption(["--decode-path"]) {
            guard let path = RawDecodePath(rawValue: decodePath.lowercased()) else {
                fail("--decode-path is one of: "
                    + RawDecodePath.allCases.map(\.rawValue).joined(separator: ", "))
            }
            guard RawDecodePathRegistry.isAvailable(path) else {
                fail("--decode-path \(path.rawValue) is not implemented in this build "
                    + "(available: "
                    + RawDecodePathRegistry.available.map(\.rawValue).joined(separator: ", ") + ")")
            }
            RawDecodePath.current = path
        }
        guard args.count == 1 else { fail("grade needs exactly one input image") }
        let inputURL = URL(fileURLWithPath: args[0])
        if probe {
            runGradeProbe(url: inputURL)
        } else {
            guard let recipeJSON, let outPath else {
                fail("grade needs --recipe '<json>' and --out <path> (or --probe)")
            }
            try runGradeRender(
                url: inputURL, recipeJSON: recipeJSON, outPath: outPath, scale: scale,
                quality: min(max(quality, 1), 100) / 100)
        }

    case "lightroom":
        let asJSON = takeFlag(["--json"])
        guard args.count == 1 else { fail("lightroom needs exactly one .xmp sidecar") }
        try runLightroomReport(
            url: URL(fileURLWithPath: args[0]), asJSON: asJSON)

    case "craft":
        let brief = takeOption(["--brief"])
        let responsePath = takeOption(["--response"])
        let promptKind = takeOption(["--prompt"])
        let wantsOptions = takeFlag(["--options"])
        let aspectText = takeOption(["--aspect"]) ?? "4:3"
        let playhead = Double(takeOption(["--playhead"]) ?? "0.35") ?? 0.35
        let measure = takeOption(["--measure"]) ?? "estimate"
        let asJSON = takeFlag(["--json"])
        let expectLines = takeOption(["--expect-lines"]).flatMap(Int.init)
        let expectPayoff = takeOption(["--expect-payoff"])
        var fonts: [CraftedTextFontRole: String] = [:]
        if let display = takeOption(["--font-display"]) { fonts[.display] = display }
        if let hand = takeOption(["--font-hand"]) { fonts[.hand] = hand }
        // "4:3", "16:9" or a bare ratio — the frame the lines are fitted to.
        let aspect: Double
        let parts = aspectText.split(separator: ":")
        if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), h > 0 {
            aspect = w / h
        } else if let ratio = Double(aspectText), ratio > 0 {
            aspect = ratio
        } else {
            fail("--aspect expects W:H (e.g. 4:3) or a ratio")
        }
        guard args.isEmpty else { fail("craft takes options only (unexpected: \(args.joined(separator: " ")))") }
        try runCraft(
            brief: brief, responsePath: responsePath, promptKind: promptKind,
            wantsOptions: wantsOptions, aspect: aspect, playhead: playhead,
            fonts: fonts, measure: measure, asJSON: asJSON,
            expectLines: expectLines, expectPayoff: expectPayoff)

    case "poster":
        guard let outputPath = takeOption(["-o", "--output"]) else { fail("poster needs -o <output.png>") }
        let depth = Int(takeOption(["--depth"]) ?? "1") ?? 0
        let segments = Int(takeOption(["--segments"]) ?? "24") ?? 0
        let newestName = takeOption(["--newest"]) ?? TimeSliceSettings().newestEdge.rawValue
        let gridName = takeOption(["--grid"])
        let metricName = takeOption(["--metric"]) ?? TimeSliceGridMetric.manhattan.rawValue
        let variationCount = Int(takeOption(["--variations"]) ?? "0") ?? 0
        let variationModeName = takeOption(["--variation-mode"]) ?? TimeSliceVariationMode.mixed.rawValue
        let seed = UInt64(takeOption(["--seed"]) ?? "") ?? TimeSliceVariationPlan.freshSeed()
        let recipeJSON = takeOption(["--recipe"])
        let gamma = takeFlag(["--gamma"])
        guard depth >= 1 else { fail("--depth needs a positive integer") }
        guard segments >= 2 else { fail("--segments needs an integer ≥ 2") }
        guard args.count >= 1 else { fail("poster needs at least one input image") }
        guard let newest = TimeSliceEdge(rawValue: newestName) else {
            fail("unknown edge '\(newestName)' — choose from: \(TimeSliceEdge.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        guard let metric = TimeSliceGridMetric(rawValue: metricName) else {
            fail("unknown metric '\(metricName)' — choose from: \(TimeSliceGridMetric.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        guard let variationMode = TimeSliceVariationMode(rawValue: variationModeName) else {
            fail("unknown variation mode '\(variationModeName)' — choose from: \(TimeSliceVariationMode.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        var settings = TimeSliceSettings(
            newestEdge: newest, segments: segments, offsetFrames: 1,
            output: .image, includeRegularClip: false)
        if let gridName {
            guard let origin = TimeSliceGridOrigin(rawValue: gridName) else {
                fail("unknown grid corner '\(gridName)' — choose from: \(TimeSliceGridOrigin.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            settings.grid = TimeSliceGrid(origin: origin, metric: metric)
        }
        try runPoster(
            urls: args.map { URL(fileURLWithPath: $0) }, outputPath: outputPath, depth: depth,
            settings: settings, variations: variationCount, variationMode: variationMode,
            seed: seed, recipeJSON: recipeJSON, gamma: gamma)

    case "framing":
        let apply = takeFlag(["--apply"])
        let withdraw = takeFlag(["--withdraw"])
        let force = takeFlag(["--force"])
        let jsonPath = takeOption(["--json"])
        let scale = Double(takeOption(["--scale"]) ?? "0.5") ?? 0
        let workers = takeOption(["--workers"]).map { Int($0) ?? 0 }
        var range: ClosedRange<Int>?
        if let text = takeOption(["--range"]) {
            let parts = text.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2, parts[0] <= parts[1] else { fail("--range needs A-B") }
            range = parts[0]...parts[1]
        }
        guard scale > 0, scale <= 1 else { fail("--scale needs a value in (0, 1]") }
        guard args.count == 1 else { fail("framing needs one project or source directory") }
        try runFraming(
            path: args[0], apply: apply, withdraw: withdraw, force: force, jsonPath: jsonPath,
            scale: scale, workers: workers, range: range)

    case "whitebalance", "wb":
        let report = takeFlag(["--report"])
        let force = takeFlag(["--force"])
        let jsonPath = takeOption(["--json"])
        let anchor = Double(takeOption(["--anchor"]) ?? "0") ?? 0
        guard anchor >= 0, anchor <= 1 else { fail("--anchor needs a value in [0, 1]") }
        guard args.count == 1 else { fail("whitebalance needs one project or source directory") }
        try runWhiteBalance(
            path: args[0], report: report, force: force, anchor: anchor, jsonPath: jsonPath)

    case "stackseq":
        guard let outputPath = takeOption(["-o", "--output"]) else { fail("stackseq needs -o <output>") }
        let window = Int(takeOption(["--window", "-w"]) ?? "1") ?? 1
        let fps = Double(takeOption(["--fps"]) ?? "30") ?? 30
        let profileName = takeOption(["--profile"]) ?? "h264"
        let recipeJSON = takeOption(["--recipe"])
        guard ["h264", "hevc10"].contains(profileName) else { fail("--profile is h264 or hevc10") }
        guard args.count >= 2 else { fail("stackseq needs at least two input images") }
        try runStackSequence(
            urls: args.map { URL(fileURLWithPath: $0) }, outputPath: outputPath,
            window: max(1, window), fps: fps, profileName: profileName, recipeJSON: recipeJSON)

    default:
        printErr("unknown command '\(command)'\n")
        usage()
    }
} catch {
    let description = (error as? LapseError)?.errorDescription ?? error.localizedDescription
    fail(description)
}


// MARK: - Lightroom sidecar

/// Reads a Lightroom `.xmp` and prints what an import would carry, what it
/// would approximate, and what it would lose.
///
/// The point of a subcommand rather than a test: the losses are the whole
/// question, and they change per FILE. A photographer wants to know what
/// happens to THIS picture before importing it, and a measurement run wants
/// the same answer without launching an editor.
func runLightroomReport(url: URL, asJSON: Bool) throws {
    let sidecar = try LightroomSidecar.read(contentsOf: url)
    let map = LightroomImport.map(sidecar)

    if asJSON {
        var payload: [String: Any] = [
            "rawFileName": sidecar.rawFileName ?? "",
            "cameraProfile": sidecar.cameraProfile ?? "",
            "processVersion": sidecar.processVersion ?? "",
            "whiteBalance": sidecar.whiteBalance ?? "",
            "adjustments": map.adjustments,
            "applied": map.applied,
            "unsupported": map.unsupported,
        ]
        payload["masks"] = map.masks.map { mask in
            [
                "name": mask.name,
                "kind": mask.shape.kind.rawValue,
                "inverted": mask.inverted,
                "centerX": mask.shape.center.x, "centerY": mask.shape.center.y,
                "radiusX": mask.shape.radiusX, "radiusY": mask.shape.radiusY,
                "rotationDegrees": mask.shape.rotationDegrees,
                "feather": mask.shape.feather,
                "adjustments": mask.adjustments,
            ] as [String: Any]
        }
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8) ?? "{}")
        return
    }

    print("Lightroom sidecar: \(url.lastPathComponent)")
    print("  raw file       \(sidecar.rawFileName ?? "—")")
    print("  camera profile \(sidecar.cameraProfile ?? "—")")
    print("  process        \(sidecar.processVersion ?? "—")")
    print("  white balance  \(sidecar.whiteBalance ?? "—")")
    print("  corrections    \(sidecar.corrections.count)   mask bitmaps \(sidecar.maskTables.count)")

    print("\nCARRIED (\(map.applied.count))")
    for line in map.applied { print("  ✓ \(line)") }

    if !map.masks.isEmpty {
        print("\nMASKS REBUILT (\(map.masks.count))")
        for mask in map.masks {
            let where_ = mask.inverted ? "outside" : "inside"
            print(String(
                format: "  ✓ %@ — %@, centre %.3f/%.3f, r %.3f×%.3f, feather %.0f%%, grade %@",
                mask.name, mask.shape.kind.displayName,
                mask.shape.center.x, mask.shape.center.y,
                mask.shape.radiusX, mask.shape.radiusY,
                mask.shape.feather * 100, where_))
            for (field, value) in mask.adjustments.sorted(by: { $0.key < $1.key }) {
                print(String(format: "      %@ %+.4f", field, value))
            }
        }
    }

    print("\nNOT CARRIED (\(map.unsupported.count))")
    for line in map.unsupported { print("  ✗ \(line)") }
    if map.unsupported.isEmpty { print("  (nothing — this file imports whole)") }
}

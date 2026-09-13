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

  lapse shapes <image> [options]     Run the shape detector on one picture and
                            print what it finds — the Photo viewfinder's and
                            Find shapes' machine, gates on the command line.
      --family F            The SHAPES dial: all | circular | rectangular
      --sensitivity S       The SENSITIVITY dial: high | medium | low
      --size Z              The SIZE dial: all | large | mid | small
      --residual R          Ellipse fit residual gate (file pass 0.04, live 0.06)
      --live                The viewfinder's profile (384 px, no edge maps)
      --long-edge N         Detection resolution (default 1024; live 384)
      --contrast A,B        Contour contrast sweep (file 1,2,3; live 2)
      --edges A,B           CIEdges thresholds for the edge-map passes (file 0.06,0.15; live none)
      --contour-dimension N Vision's tracer resolution (file 512, live 384)
      --regions / --no-regions
                            Force the region-proposal pass on or off (file on, live off)
      --floor F             Size floor as a share of the short edge, no pixel minimum
                            (an experiment's floor; the SIZE dial's is 1/6)
      --region-edges A,B    Long edges the region pass traces at (default 1024; the
                            benchmark reference used 1024,2048)
      --region-gates loose  Loosen the region pass's own §3 gates (propose only; for a
                            rig that measures at full resolution afterwards)
      --edge-chains / --no-edge-chains
                            Force the edge-chain pass (Edge Drawing's closed chains) on
                            or off (off by default)
      --edge-chain-edges A,B
                            Long edges the edge-chain pass traces at (default 1024,2048)
      --verbose             Also print what each pass looked at and refused, and why
      --json                The pass's shapes, diagnostics and the register as JSON
      --trail               First print the register beside a project picture: its
                            shapes, and the viewfinder's account of the capture
                            (dials, lens, samples, what the live and file passes refused)

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

  lapse audit <root> [--json] [--plist FILE]    Audit a LetsLapse library against its
                            manifest: counts, orphan folders, dangling records,
                            missing or unlisted media, .json names among the
                            frames, unlisted or missing blend renders, sidecar
                            presence, origin-id coverage, tombstones and hash
                            coverage. <root> is the storage root (the folder
                            holding Projects/) or the Projects folder itself — a
                            devicectl copy of a phone's container works too.
                            Exit 0 when consistent, 1 otherwise. Never writes.
      --json                Machine-readable report
      --plist FILE          A preferences plist copy to read the device id from
      --rebuild-index       Instead: rebuild the manifest from every project's
                            project.json (live and .trash) and diff it against
                            the real library.json, record by record, in one
                            canonical form (dates to the millisecond). Exit 0
                            when identical. The Phase 2 dual-write check.
      --out FILE            With --rebuild-index: also write the rebuilt
                            manifest here (never into the library)

  lapse project-diff <a.json> <b.json> [--ignore k1,k2]
                            Diff two project.json documents (or one against an
                            archive's manifest) in the same canonical form;
                            --ignore drops top-level capture keys and the blend
                            keys an install re-mints (id, captureID,
                            outputFileName). Exit 0 when nothing differs.

  lapse metadata <image> [--json]               Read what an import would carry as the asset's
                            metadata record — IPTC Core / XMP fields, camera,
                            exposure, GPS — from the file's own header, its
                            embedded XMP and the .xmp sidecar beside a raw
                            (sidecar wins). The panel's Info and Metadata
                            groups, headless.
      --sidecar FILE        Lay this .xmp on top instead of the one beside the file
  lapse lightroom <file.xmp> [--json]           Read a Lightroom sidecar and report the import
  lapse lightroom <file.xmp> --render <out.jpg> [--variant ID] [--scale S] [--no-masks | --flip-masks] [--no-dehaze] [--no-hsl]
                                                Render the sidecar's raw through a variant
  lapse variants                                List the render variants
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
                            (exposure is EV; temperature is a mired offset;
                            vignette is signed with POSITIVE darkening, and
                            vignettemidpoint is 0…100, default 50)
      --lut FILE.cube       A 3D LUT applied last, as an imported LUT preset is;
                            --lut-strength 0…1 mixes it back toward the input
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

    case "audit":
        let asJSON = takeFlag(["--json"])
        let plistPath = takeOption(["--plist"])
        let rebuild = takeFlag(["--rebuild-index"])
        let outPath = takeOption(["--out"])
        guard args.count == 1 else { fail("audit needs one library root (the folder holding Projects/, or Projects/ itself)") }
        if rebuild {
            let root = URL(fileURLWithPath: args[0])
            let report = LibraryIndexRebuild.run(root: root)
            if asJSON {
                FileHandle.standardOutput.write(try LibraryIndexRebuild.json(report))
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                print(LibraryIndexRebuild.text(report))
            }
            if let outPath {
                let out = URL(fileURLWithPath: outPath)
                if out.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") {
                    fail("--out must point outside the library (\(root.path))")
                }
                try LibraryIndexRebuild.rebuiltManifest(root: root).write(to: out, options: .atomic)
                printErr("wrote the rebuilt manifest to \(out.path)")
            }
            exit(report.identical ? 0 : 1)
        }
        var options = LibraryAudit.Options()
        options.preferencesPlist = plistPath.map { URL(fileURLWithPath: $0) }
        let report = LibraryAudit.run(root: URL(fileURLWithPath: args[0]), options: options)
        if asJSON {
            FileHandle.standardOutput.write(try LibraryAudit.json(report))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            print(LibraryAudit.text(report))
        }
        exit(report.consistent ? 0 : 1)

    case "project-diff":
        let ignored = Set((takeOption(["--ignore"]) ?? "").split(separator: ",").map { String($0) })
        guard args.count == 2 else { fail("project-diff needs two project.json paths") }
        func load(_ path: String) throws -> [String: Any] {
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any] else {
                fail("\(path) is not a JSON object")
            }
            return object
        }
        let a = try load(args[0]), b = try load(args[1])
        var found: [LibraryIndexRebuild.Difference] = []
        var captureA = LibraryIndexRebuild.canonical(a["capture"] as? [String: Any] ?? [:])
        var captureB = LibraryIndexRebuild.canonical(b["capture"] as? [String: Any] ?? [:])
        for key in ignored { captureA[key] = nil; captureB[key] = nil }
        found += LibraryIndexRebuild.differences(between: captureA, and: captureB, record: "capture")
        // Blends pair up by position: an install re-mints their ids.
        let blendsA = (a["blends"] as? [[String: Any]] ?? []).map(LibraryIndexRebuild.canonical)
        let blendsB = (b["blends"] as? [[String: Any]] ?? []).map(LibraryIndexRebuild.canonical)
        if blendsA.count != blendsB.count {
            found.append(LibraryIndexRebuild.Difference(record: "blends", path: "", index: "\(blendsA.count) items", document: "\(blendsB.count) items"))
        }
        for (offset, pair) in zip(blendsA, blendsB).enumerated() {
            var x = pair.0, y = pair.1
            for key in ignored { x[key] = nil; y[key] = nil }
            found += LibraryIndexRebuild.differences(between: x, and: y, record: "blend[\(offset)]")
        }
        if let va = a["formatVersion"] as? Int, let vb = b["formatVersion"] as? Int, va != vb {
            printErr("note: formatVersion \(va) vs \(vb)")
        }
        if found.isEmpty {
            print("IDENTICAL (ignoring \(ignored.sorted().joined(separator: ", ")))")
        } else {
            for difference in found { print("  \(difference.record) · \(difference.path.isEmpty ? "(record)" : difference.path): \(difference.index) → \(difference.document)") }
            print("\(found.count) differences")
        }
        exit(found.isEmpty ? 0 : 1)

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
        // `--lut <file.cube> [--lut-strength 0…1]`: the cube rides the recipe
        // as the last colour operation, exactly as the app applies an
        // imported LUT (`EnginePostPasses`). Registered here because the Kit
        // has no store to look it up in.
        let lutPath = takeOption(["--lut"])
        let lutStrength = Float(takeOption(["--lut-strength"]) ?? "1") ?? 1
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
            var lut: LUTLayer?
            if let lutPath {
                let cube = try CubeLUT.parse(contentsOf: URL(fileURLWithPath: lutPath))
                LUTRegistry.shared.register(cube)
                lut = LUTLayer(id: cube.contentHash, strength: lutStrength)
                if cube.isLikelyLogInput {
                    FileHandle.standardError.write(Data(
                        ("note: \(URL(fileURLWithPath: lutPath).lastPathComponent) looks like a log-input LUT "
                         + "(50 % grey → \(String(format: "%.2f", cube.luma(ofGrey: 0.5)))); "
                         + "expect a crushed picture on a display-referred frame\n").utf8))
                }
            }
            try runGradeRender(
                url: inputURL, recipeJSON: recipeJSON, outPath: outPath, scale: scale,
                quality: min(max(quality, 1), 100) / 100, lut: lut)
        }

    case "lightroom":
        let asJSON = takeFlag(["--json"])
        let renderPath = takeOption(["--render"])
        let variantID = takeOption(["--variant"])
        let renderScale = Float(takeOption(["--scale"]) ?? "1") ?? 1
        let axesOverride = takeOption(["--axes"])
        // Attribution: the whole-picture grade alone, masks left off, so a
        // masked file's residual can be split into inside and outside.
        let noMasks = takeFlag(["--no-masks"])
        // Verification: every parametric mask applied on the OTHER side. The
        // importer's inside/outside rule for a radial is inferred from two
        // undocumented flags; rendering both ways and scoring them against
        // Lightroom's export is what settles it, and this is that render.
        let flipMasks = takeFlag(["--flip-masks"])
        // Attribution: the import's own dehaze left off, so its worth can be
        // measured the way the masks' can.
        let noDehaze = takeFlag(["--no-dehaze"])
        let noHSL = takeFlag(["--no-hsl"])
        guard args.count == 1 else { fail("lightroom needs exactly one .xmp sidecar or raw file") }
        let variant: RenderVariant
        if let variantID {
            guard let found = RenderVariantRegistry.variant(id: variantID) else {
                fail("unknown --variant \(variantID) — choose from: "
                    + RenderVariantRegistry.all.map(\.id).joined(separator: ", "))
            }
            guard RenderVariantRegistry.isAvailable(found) else {
                fail("variant \(found.id) is unavailable on this machine "
                    + "(needs decode path \(found.axes.decodePath.rawValue))")
            }
            variant = found
        } else {
            variant = RenderVariantRegistry.baseline
        }
        if let renderPath {
            // `--axes` is EXPLORATION: an unregistered point in the space, for
            // sweeping. It deliberately cannot be recorded in the ledger under
            // a name — only a variant in the registry can, which is what keeps
            // a named id meaning one thing forever. Promote a winner by adding
            // it to `RenderVariantRegistry.all`.
            var explored = variant
            if let axesOverride {
                explored = RenderVariant(
                    id: "ad-hoc", title: "ad-hoc axes",
                    hypothesis: "exploration; not a registered variant",
                    axes: try parseAxes(axesOverride, from: variant.axes))
            }
            try runLightroomRender(
                sidecar: URL(fileURLWithPath: args[0]), variant: explored,
                outPath: renderPath, scale: renderScale, applyMasks: !noMasks,
                flipMasks: flipMasks, applyImportedDehaze: !noDehaze,
                applyImportedHSL: !noHSL)
        } else {
            try runLightroomReport(
                url: URL(fileURLWithPath: args[0]), asJSON: asJSON)
        }

    case "metadata":
        let asJSON = takeFlag(["--json"])
        let sidecarPath = takeOption(["--sidecar"])
        guard args.count == 1 else { fail("metadata needs exactly one image file") }
        let result = MetadataReader.read(
            fileAt: URL(fileURLWithPath: args[0]), sidecar: sidecarPath.map { URL(fileURLWithPath: $0) })
        if asJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var payload: [String: Any] = ["source": result.source]
            if let sidecar = result.sidecarURL { payload["sidecar"] = sidecar.path }
            if let object = try JSONSerialization.jsonObject(with: try encoder.encode(result.metadata)) as? [String: Any] {
                payload["metadata"] = object
            }
            print(String(data: try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8) ?? "{}")
        } else {
            print("metadata · \(URL(fileURLWithPath: args[0]).lastPathComponent) · from \(result.source)"
                + (result.sidecarURL.map { " (\($0.lastPathComponent))" } ?? ""))
            for field in MetadataField.allCases {
                guard let value = result.metadata[field] else { continue }
                print("  \(field.rawValue.padding(toLength: 26, withPad: " ", startingAt: 0)) \(value.textValue ?? "")")
            }
            if let line = result.metadata.exposureLine { print("  exposure line: \(line)") }
            if let line = result.metadata.gpsLine { print("  gps line: \(line)") }
        }

    case "variants":
        if takeFlag(["--json"]) {
            let payload = RenderVariantRegistry.all.map { v -> [String: Any] in
                [
                    "id": v.id, "title": v.title, "hypothesis": v.hypothesis,
                    "axes": v.axes.summary,
                    "available": RenderVariantRegistry.isAvailable(v) && !v.isRetired,
                    "retired": v.retired ?? "",
                ]
            }
            let data = try JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8) ?? "[]")
            break
        }
        print("Render variants — one build, several methodologies.")
        print("The registry is APPEND-ONLY: a measured variant is never redefined.")
        print("Results: docs/render-variants/ledger.md\n")
        for v in RenderVariantRegistry.all {
            let mark = v.isRetired ? "×" : (RenderVariantRegistry.isAvailable(v) ? " " : "!")
            print("\(mark) \(v.id.padding(toLength: 6, withPad: " ", startingAt: 0)) \(v.title)")
            print("         \(v.axes.summary)")
            if let retired = v.retired {
                print("         RETIRED — \(retired.replacingOccurrences(of: "\n", with: " "))")
            } else if !RenderVariantRegistry.isAvailable(v) {
                print("         UNAVAILABLE on this machine")
            }
        }

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

    case "shapes":
        let residual = takeOption(["--residual"]).map { Double($0) ?? 0 }
        let live = takeFlag(["--live"])
        let longEdge = takeOption(["--long-edge"]).map { Int($0) ?? 0 }
        let verbose = takeFlag(["--verbose", "-v"])
        let contrasts = takeOption(["--contrast"]).map { $0.split(separator: ",").compactMap { Float($0) } }
        let edges = takeOption(["--edges"]).map { $0.split(separator: ",").compactMap { Float($0) } }
        let contourDimension = takeOption(["--contour-dimension"]).map { Int($0) ?? 0 }
        var search = ShapeSearch()
        if let raw = takeOption(["--family"]) {
            guard let v = ShapeSearch.Family(rawValue: raw) else { fail("--family needs all | circular | rectangular") }
            search.family = v
        }
        if let raw = takeOption(["--sensitivity"]) {
            guard let v = ShapeSearch.Sensitivity(rawValue: raw) else { fail("--sensitivity needs high | medium | low") }
            search.sensitivity = v
        }
        if let raw = takeOption(["--size"]) {
            guard let v = ShapeSearch.Size(rawValue: raw) else { fail("--size needs all | large | mid | small") }
            search.size = v
        }
        let trail = takeFlag(["--trail"])
        let json = takeFlag(["--json"])
        var regions: Bool?
        if takeFlag(["--regions"]) { regions = true }
        if takeFlag(["--no-regions"]) { regions = false }
        let floor = takeOption(["--floor"]).map { Double($0) ?? 0 }
        let regionGates = takeOption(["--region-gates"])
        let regionEdges = takeOption(["--region-edges"]).map { $0.split(separator: ",").compactMap { Int($0) } }
        var edgeChains: Bool?
        if takeFlag(["--edge-chains"]) { edgeChains = true }
        if takeFlag(["--no-edge-chains"]) { edgeChains = false }
        let edgeChainEdges = takeOption(["--edge-chain-edges"]).map { $0.split(separator: ",").compactMap { Int($0) } }
        guard args.count == 1 else { fail("shapes needs one image") }
        try runShapes(path: args[0], residual: residual, live: live, longEdge: longEdge, verbose: verbose,
                      contrasts: contrasts, edges: edges, contourDimension: contourDimension, search: search, trail: trail, json: json,
                      regions: regions, floor: floor, regionGates: regionGates, regionEdges: regionEdges,
                      edgeChains: edgeChains, edgeChainEdges: edgeChainEdges)

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
    let (sidecar, _) = try resolveLightroomInput(url)
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
        payload["masks"] = map.masks.map { mask -> [String: Any] in
            var entry: [String: Any] = [
                "name": mask.name,
                "inverted": mask.inverted,
                "adjustments": mask.adjustments,
            ]
            if let shape = mask.shape {
                entry["kind"] = shape.kind.rawValue
                entry["centerX"] = shape.center.x
                entry["centerY"] = shape.center.y
                entry["radiusX"] = shape.radiusX
                entry["radiusY"] = shape.radiusY
                entry["rotationDegrees"] = shape.rotationDegrees
                entry["feather"] = shape.feather
            } else if case .semantic(let region) = mask.target {
                entry["kind"] = "semantic"
                entry["region"] = region
            }
            return entry
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
            if let shape = mask.shape {
                print(String(
                    format: "  ✓ %@ — %@, centre %.3f/%.3f, r %.3f×%.3f, feather %.0f%%, grade %@",
                    mask.name, shape.kind.displayName,
                    shape.center.x, shape.center.y,
                    shape.radiusX, shape.radiusY,
                    shape.feather * 100, where_))
            } else if case .semantic(let region) = mask.target {
                print("  ✓ \(mask.name) — this app's own \(region.capitalized) region, grade \(where_)")
                print("      (\(LightroomImport.skySubstitutionNote))")
            }
            for (field, value) in mask.adjustments.sorted(by: { $0.key < $1.key }) {
                print(String(format: "      %@ %+.4f", field, value))
            }
        }
    }

    print("\nNOT CARRIED (\(map.unsupported.count))")
    for line in map.unsupported { print("  ✗ \(line)") }
    if map.unsupported.isEmpty { print("  (nothing — this file imports whole)") }
}

/// Renders the raw a sidecar describes, through one render variant.
///
/// This is the bench's engine room: `tools/render_bench.py` calls it once per
/// (file × variant) and scores the results against Lightroom's own export.
///
/// The order, after the engine: dehaze, then the masked grades, then the
/// point curve. The masked stage is the Kit's `MaskedGradeStage` — the same
/// code the editor's preview and a stills export run — so a masked file's
/// score is the whole render. The one thing the CLI still cannot draw is an
/// AI SKY mask: that needs the app's segmentation model, so a sky-masked
/// file is rendered without it and says so on the summary line
/// (`masks=applied/total`), which the ledger carries through.
func runLightroomRender(
    sidecar: URL, variant: RenderVariant, outPath: String, scale: Float,
    applyMasks: Bool = true, flipMasks: Bool = false, applyImportedDehaze: Bool = true,
    applyImportedHSL: Bool = true
) throws {
    let (parsed, raw) = try resolveLightroomInput(sidecar)
    let mapped = LightroomImport.map(parsed)

    // The whole-picture grade, with the variant's tone-response calibration
    // applied to the two sliders it scales.
    var recipe = GradeRecipe()
    func value(_ key: String) -> Float { Float(mapped.adjustments[key] ?? 0) }
    recipe.exposure = value("exposure") + Float(variant.axes.exposureOffset)
    recipe.contrast = value("contrast")
    recipe.highlights = value("highlights") * Float(variant.axes.highlightsScale)
    recipe.shadows = value("shadows") * Float(variant.axes.shadowsScale)
    recipe.whites = value("whites")
    recipe.blacks = value("blacks")
    recipe.vibrance = value("vibrance")
    recipe.saturation = value("saturation")
    recipe.clarity = value("clarity")
    recipe.texture = value("texture")
    recipe.sharpen = value("sharpen")
    recipe.sharpenMasking = value("sharpenMasking")
    recipe.noiseReduction = value("noiseReduction")
    recipe.colorNoiseReduction = value("colorNoiseReduction")
    recipe.vignette = value("vignetteIntensity")
    // Centred at 0.5, so an absent midpoint is the middle, not zero.
    recipe.vignetteMidpoint = Float(mapped.adjustments["vignetteMidpoint"] ?? 0.5)
    // The import's dehaze, through the fitted response — a control now, not
    // a bench axis. The axis below still adds the sidecar's raw value × scale
    // on top, which is what `--axes dehaze=` sweeps and what retired `G`.
    recipe.dehaze = applyImportedDehaze ? value("dehaze") : 0
    recipe.hsl = applyImportedHSL ? mapped.hsl : nil
    if variant.axes.honoursWhiteBalance, let mired = mapped.adjustments["whiteMired"], mired > 0 {
        recipe.declaredKelvin = Float(1_000_000 / mired)
        recipe.declaredTint = Float(mapped.adjustments["whiteTint"] ?? 0)
    }

    let decoder = try LinearFrameDecoder()
    let frame = try decoder.decode(
        url: raw, scale: scale, path: variant.axes.decodePath, recipe: recipe)
    let engine = try GradeEngine(device: decoder.device)
    let renderer = engine.makeRenderer(recipe, reference: frame.reference())
    let output = try renderer.apply(to: frame.texture, ditherFor8Bit: true)
    var image = EnginePostPasses.apply(
        try decoder.image(from: output), recipe: recipe, context: decoder.ciContext)

    // The bench axis: the sidecar's raw Dehaze (±100 → ±1) × the variant's
    // scale, ON TOP of whatever the import carried. Exploration only now.
    let dehaze = (parsed.double("Dehaze") ?? 0) / 100 * variant.axes.dehazeScale
    if abs(dehaze) > 1e-6, let hazed = Dehaze.apply(image, amount: dehaze, context: decoder.ciContext) {
        image = hazed
    }

    // The masked grades, through the Kit's stage — the editor's own.
    var masksApplied = 0
    var masksSkipped: [String] = []
    if applyMasks {
        for mask in mapped.masks {
            guard let shape = mask.shape else {
                masksSkipped.append(mask.name)   // a sky: needs the segmenter
                continue
            }
            guard let selection = MaskShapeRenderer.maskImage(
                shape, extent: image.extent, inverted: mask.inverted != flipMasks) else { continue }
            image = MaskedGradeStage.apply(mask.displayGrade, to: image, through: selection)
            masksApplied += 1
        }
    }

    // The curves the variant honours, as ONE table applied after everything
    // else. Late rather than in the kernel because that is where a point
    // curve sits in Lightroom's own pipeline, and because it keeps the
    // engine's math out of an experiment's way.
    let curve = curveFor(variant: variant, sidecar: parsed)
    if !curve.isIdentity, let curved = ToneCurve.apply(curve.byteTable(), to: image) {
        image = curved
    }

    let data = try decoder.jpegData(
        from: image, quality: 0.98,
        colorSpace: frame.displayReferred ? CGColorSpace.sRGB : CGColorSpace.displayP3)
    try data.write(to: URL(fileURLWithPath: outPath))
    let maskNote = applyMasks
        ? "masks=\(masksApplied)/\(mapped.masks.count)"
            // One token, so the bench's whitespace split keeps whole names.
            + (masksSkipped.isEmpty ? "" : " skipped="
                + masksSkipped.map { $0.replacingOccurrences(of: " ", with: "_") }.joined(separator: "+"))
            + (flipMasks ? " FLIPPED" : "")
        : "masks=off/\(mapped.masks.count)"
    let dehazeNote = applyImportedDehaze
        ? String(format: "dehaze=%.3f", recipe.dehaze) : "dehaze=off"
    let hslNote = applyImportedHSL ? "hsl=\(recipe.hsl?.movedCount ?? 0)" : "hsl=off"
    print("\(variant.id)\t\(raw.lastPathComponent)\t\(frame.texture.width)x\(frame.texture.height)"
        + "\t\(variant.axes.summary)\tcurve=\(curve.isIdentity ? "none" : "\(curve.points.count)pt")"
        + "\t\(maskNote)\t\(dehazeNote)\t\(hslNote)")
    print(outPath)
}

/// The tone curve a variant honours for this file: the image's own, then the
/// profile look's, composed into one.
func curveFor(variant: RenderVariant, sidecar: LightroomSidecar) -> ToneCurve {
    func toCurve(_ points: [LightroomSidecar.ToneCurvePoint]) -> ToneCurve {
        ToneCurve(lightroomPoints: points.map { ($0.input, $0.output) })
    }
    switch variant.axes.toneCurves {
    case .ignore:
        return .identity
    case .image:
        return toCurve(sidecar.toneCurve)
    case .imageAndLook:
        let image = toCurve(sidecar.toneCurve)
        let look = toCurve(sidecar.lookToneCurve)
        if image.isIdentity { return look }
        if look.isIdentity { return image }
        // Composed by sampling: the image's curve first, the look's over it,
        // which is the order Lightroom applies them in.
        return ToneCurve(points: (0...64).map { step in
            let x = Double(step) / 64
            return ToneCurve.Point(input: x, output: look.value(at: image.value(at: x)))
        })
    }
}


/// `--axes "shadows=0.7,exposure=-0.47,highlights=0.85"` — an unregistered
/// point in the rendering space, for sweeps.
func parseAxes(_ text: String, from base: RenderAxes) throws -> RenderAxes {
    var axes = base
    for clause in text.split(separator: ",") {
        let parts = clause.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { fail("--axes clause '\(clause)' is not key=value") }
        let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
        let raw = parts[1].trimmingCharacters(in: .whitespaces)
        switch key {
        case "highlights": axes.highlightsScale = Double(raw) ?? 1
        case "shadows": axes.shadowsScale = Double(raw) ?? 1
        case "exposure": axes.exposureOffset = Double(raw) ?? 0
        case "dehaze": axes.dehazeScale = Double(raw) ?? 0
        case "curves":
            guard let mode = RenderAxes.ToneCurveHandling(rawValue: raw) else {
                fail("--axes curves= must be ignore | image | imageAndLook")
            }
            axes.toneCurves = mode
        case "decode":
            guard let path = RawDecodePath(rawValue: raw) else {
                fail("--axes decode= must be one of: "
                    + RawDecodePath.allCases.map(\.rawValue).joined(separator: ", "))
            }
            axes.decodePath = path
        case "wb": axes.honoursWhiteBalance = (raw != "asShot")
        default: fail("--axes: unknown key '\(key)'")
        }
    }
    return axes
}


/// Resolves whatever the user pointed at — a `.xmp`, or a raw whose settings
/// live inside it — into (settings, raw file).
///
/// A DNG that has been through Enhance or Denoise comes back with no sidecar
/// at all: Adobe writes into its own container. Accepting only sidecars skips
/// those silently, which on the first mixed corpus was two files in five.
func resolveLightroomInput(_ input: URL) throws -> (LightroomSidecar, URL) {
    let isSidecar = input.pathExtension.lowercased() == "xmp"
    if !isSidecar {
        guard let parsed = try LightroomSidecar.read(forRawFile: input) else {
            fail("\(input.lastPathComponent) carries no Lightroom settings, and has no .xmp beside it")
        }
        return (parsed, input)
    }
    let parsed = try LightroomSidecar.read(contentsOf: input)
    let folder = input.deletingLastPathComponent()
    // Named by the file itself where it says so, since a renamed sidecar
    // should still find its picture.
    let named = parsed.rawFileName.map { folder.appendingPathComponent($0) }
    let stem = input.deletingPathExtension().lastPathComponent
    let guessed = ["ARW", "arw", "DNG", "dng", "NEF", "nef", "CR3", "cr3", "RAF", "raf"]
        .map { folder.appendingPathComponent(stem).appendingPathExtension($0) }
    guard let raw = ([named].compactMap { $0 } + guessed)
        .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
        fail("no raw file found beside \(input.lastPathComponent)")
    }
    return (parsed, raw)
}

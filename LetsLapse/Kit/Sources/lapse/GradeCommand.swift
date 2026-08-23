import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import LetsLapseKit
import Metal

// lapse grade — decode diagnostics for the grading engine (Stage 0 skeleton).
//
// `--probe` answers the question the whole grading rebuild depends on: does
// `CIRAWFilter` with boost 0 hand back scene-linear pixels with the DNG's
// above-1.0 highlight headroom intact, in wide-gamut primaries? The ImageIO
// float decode is probed alongside it because that is the designated fallback
// if CIRAWFilter misbehaves on the app's own LinearRaw files.

/// Parses the human-facing recipe JSON — Lightroom-style ±100 numbers — into
/// the engine's normalized `GradeRecipe`. Exposure is EV and temperature is a
/// mired offset, both passed through unscaled.
func parseRecipe(json: String) throws -> GradeRecipe {
    guard let data = json.data(using: .utf8),
          let values = try JSONSerialization.jsonObject(with: data) as? [String: Double] else {
        fail("--recipe expects a JSON object of slider values")
    }
    var recipe = GradeRecipe()
    let knownKeys = [
        "exposure", "contrast", "highlights", "shadows", "whites", "blacks",
        "temperature", "tint", "vibrance", "saturation", "clarity", "vignette",
        "texture", "sharpen", "noise", "colornoise",
    ]
    for key in values.keys where !knownKeys.contains(key) {
        fail("unknown recipe key '\(key)' — choose from: \(knownKeys.joined(separator: ", "))")
    }
    func scaled(_ key: String) -> Float { Float(values[key] ?? 0) / 100 }
    recipe.exposure = Float(values["exposure"] ?? 0)
    recipe.contrast = scaled("contrast")
    recipe.highlights = scaled("highlights")
    recipe.shadows = scaled("shadows")
    recipe.whites = scaled("whites")
    recipe.blacks = scaled("blacks")
    recipe.temperatureMired = Float(values["temperature"] ?? 0)
    recipe.tint = scaled("tint")
    recipe.vibrance = scaled("vibrance")
    recipe.saturation = scaled("saturation")
    recipe.clarity = scaled("clarity")
    recipe.texture = scaled("texture")
    recipe.sharpen = scaled("sharpen")
    recipe.noiseReduction = scaled("noise")
    recipe.colorNoiseReduction = scaled("colornoise")
    recipe.vignette = scaled("vignette")
    return recipe
}

/// `lapse grade <in> --recipe '<json>' --out <path>` — the grading engine end
/// to end on one frame: linear decode → tone kernel → Display P3 JPEG. This
/// is the permanent regression rig for the engine's look.
func runGradeRender(url: URL, recipeJSON: String, outPath: String, scale: Float) throws {
    let recipe = try parseRecipe(json: recipeJSON)
    let decoder = try LinearFrameDecoder()
    let started = Date()
    let frame = try decoder.decode(url: url, scale: scale)
    let decodeSeconds = Date().timeIntervalSince(started)

    let reference = GradeReference(
        asShotTemperatureK: frame.asShotTemperatureK,
        asShotTint: frame.asShotTint,
        longEdge: Double(max(frame.texture.width, frame.texture.height)))
    let engine = try GradeEngine(device: decoder.device)
    let renderer = engine.makeRenderer(recipe, reference: reference)
    let gradeStarted = Date()
    let output = try renderer.apply(to: frame.texture)
    let gradeSeconds = Date().timeIntervalSince(gradeStarted)

    let data = try decoder.jpegData(from: output)
    let outputURL = URL(fileURLWithPath: outPath)
    try data.write(to: outputURL)
    print("graded \(frame.texture.width)x\(frame.texture.height) "
        + String(format: "(decode %.2fs, grade %.3fs, as-shot %.0f K)",
                 decodeSeconds, gradeSeconds, frame.asShotTemperatureK))
    print(outputURL.path)
}

/// `lapse stackseq` — the linear blend path end to end on a directory of
/// stills: half-float decode → float32 window average → tone engine per
/// OUTPUT frame → dithered H.264 or 10-bit HEVC. The blend-side regression
/// rig, as `lapse grade` is the single-frame one.
func runStackSequence(
    urls: [URL], outputPath: String, window: Int, fps: Double,
    profileName: String, recipeJSON: String?
) throws {
    let profile: VideoEncodePolicy.Profile = profileName == "hevc10" ? .hevcMain10 : .h264High8Bit
    let recipe = try recipeJSON.map { try parseRecipe(json: $0) } ?? GradeRecipe()
    let decoder = try LinearFrameDecoder()
    let engine = try GradeEngine(device: decoder.device)
    var renderer: GradeRenderer?
    let decode: (URL) throws -> MTLTexture = { url in
        let frame = try decoder.decode(url: url)
        if renderer == nil {
            renderer = engine.makeRenderer(recipe, reference: GradeReference(
                asShotTemperatureK: frame.asShotTemperatureK,
                asShotTint: frame.asShotTint,
                longEdge: Double(max(frame.texture.width, frame.texture.height))))
        }
        return frame.texture
    }
    let core = try BlendCore()
    let stacker = ImageStacker(core: core)
    let started = Date()
    let result = try stacker.stackSequenceLinear(
        imageURLs: urls,
        ramp: .constant(window),
        outputFPS: fps,
        outputURL: URL(fileURLWithPath: outputPath),
        profile: profile,
        decodeLinear: decode,
        outputGrade: { texture, commandBuffer, _ in
            guard let renderer else { return texture }
            return try renderer.encode(from: texture, commandBuffer: commandBuffer)
        },
        progress: progressToStderr)
    let elapsed = Date().timeIntervalSince(started)
    print("stacked \(urls.count) stills → \(result.outputFrames) output frames "
        + "(\(result.width)x\(result.height), \(profileName)) in \(String(format: "%.1f", elapsed))s")
    print(outputPath)
}

struct ProbeStats {
    var maxComponent: Float = -.infinity
    var minComponent: Float = .infinity
    var mean: Double = 0
    var fractionAboveOne: Double = 0
}

private func probeStats(of image: CIImage, context: CIContext, colorSpace: CGColorSpace) -> ProbeStats {
    let extent = image.extent.integral
    let width = Int(extent.width)
    let height = Int(extent.height)
    let bytesPerRow = width * 16
    var data = Data(count: bytesPerRow * height)
    data.withUnsafeMutableBytes { raw in
        context.render(
            image, toBitmap: raw.baseAddress!, rowBytes: bytesPerRow,
            bounds: extent, format: .RGBAf, colorSpace: colorSpace)
    }
    var stats = ProbeStats()
    var sum = 0.0
    var above = 0
    data.withUnsafeBytes { raw in
        let floats = raw.bindMemory(to: Float.self)
        let pixelCount = width * height
        var i = 0
        for _ in 0..<pixelCount {
            for channel in 0..<3 {
                let v = floats[i + channel]
                if v > stats.maxComponent { stats.maxComponent = v }
                if v < stats.minComponent { stats.minComponent = v }
                sum += Double(v)
                if v > 1.0 { above += 1 }
            }
            i += 4
        }
    }
    let samples = Double(width * height * 3)
    stats.mean = sum / samples
    stats.fractionAboveOne = Double(above) / samples
    return stats
}

func runGradeProbe(url: URL) {
    guard let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else {
        fail("extended linear Display P3 color space unavailable")
    }
    let context = CIContext(options: [
        .workingColorSpace: linearP3,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
    ])

    if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
       let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
        let dng = properties[kCGImagePropertyDNGDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        print("== metadata ==")
        print("DNG BaselineExposure: \(dng[kCGImagePropertyDNGBaselineExposure] ?? "absent")")
        print("DNG version: \(dng[kCGImagePropertyDNGVersion] ?? "absent")")
        print("TIFF software: \(tiff[kCGImagePropertyTIFFSoftware] ?? "absent")")
        print("TIFF make/model: \(tiff[kCGImagePropertyTIFFMake] ?? "?") \(tiff[kCGImagePropertyTIFFModel] ?? "?")")
    }

    guard let raw = CIRAWFilter(imageURL: url) else {
        print("CIRAWFilter could not open \(url.lastPathComponent)")
        return probeImageIO(url: url, context: context, colorSpace: linearP3)
    }
    print("native size: \(Int(raw.nativeSize.width))x\(Int(raw.nativeSize.height))")
    print("neutral: \(raw.neutralTemperature) K / tint \(raw.neutralTint)")
    print("defaults: boost \(raw.boostAmount), EDR \(raw.extendedDynamicRangeAmount), gamut mapping \(raw.isGamutMappingEnabled)")

    let variants: [(label: String, configure: (CIRAWFilter) -> Void)] = [
        ("boost 0", { $0.boostAmount = 0 }),
        ("boost 0, EDR 2", { $0.boostAmount = 0; $0.extendedDynamicRangeAmount = 2 }),
        ("boost 0, EDR 2, gamut mapping off", {
            $0.boostAmount = 0; $0.extendedDynamicRangeAmount = 2; $0.isGamutMappingEnabled = false
        }),
        ("defaults untouched", { _ in }),
    ]
    for variant in variants {
        guard let filter = CIRAWFilter(imageURL: url) else { continue }
        filter.scaleFactor = 0.5
        variant.configure(filter)
        guard let output = filter.outputImage else {
            print("[\(variant.label)] no output image")
            continue
        }
        let stats = probeStats(of: output, context: context, colorSpace: linearP3)
        print(String(
            format: "[%@] linear max %.4f  min %.6f  mean %.4f  above-1.0 %.3f%%",
            variant.label, stats.maxComponent, stats.minComponent, stats.mean,
            stats.fractionAboveOne * 100))
    }

    probeImageIO(url: url, context: context, colorSpace: linearP3)
}

private func probeImageIO(url: URL, context: CIContext, colorSpace: CGColorSpace) {

    print("== ImageIO float decode (fallback candidate) ==")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let decoded = CGImageSourceCreateImageAtIndex(source, 0, [
              kCGImageSourceShouldAllowFloat: true,
          ] as CFDictionary) else {
        print("ImageIO could not decode \(url.lastPathComponent)")
        return
    }
    let spaceName = decoded.colorSpace?.name.map { String($0) } ?? "untagged"
    let isFloat = decoded.bitmapInfo.contains(.floatComponents)
    print("bits/component: \(decoded.bitsPerComponent), float: \(isFloat), space: \(spaceName)")
    let image = CIImage(cgImage: decoded)
        .transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
    let stats = probeStats(of: image, context: context, colorSpace: colorSpace)
    print(String(
        format: "linear max %.4f  min %.6f  mean %.4f  above-1.0 %.3f%%",
        stats.maxComponent, stats.minComponent, stats.mean, stats.fractionAboveOne * 100))
}

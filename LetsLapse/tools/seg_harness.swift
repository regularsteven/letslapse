// seg_harness.swift — standalone sky-segmentation harness for the text-overlay
// spike (docs/text-overlay-spike.md). Proves a Core ML semantic-segmentation
// model on real project DNGs before any app wiring, and doubles as the
// regression check after post-processing tweaks.
//
// Compile:
//   swiftc -O LetsLapse/tools/seg_harness.swift -o /tmp/seg_harness
// Usage:
//   seg_harness describe <model.mlpackage>
//   seg_harness run <model.mlpackage> <outdir> <frame.dng> [...]
//
// `describe` prints the model's inputs, outputs and embedded class labels.
// `run` decodes each frame display-referred (CIRAWFilter's own tone map — the
// model wants display-referred input, not scene-linear), stretch-resizes to the
// model's square input (the same geometry contract the app uses: no letterbox,
// no crop, so the mask grid covers the frame's unit square exactly), predicts,
// and writes per frame:
//   mask_<name>.png       — the raw sky mask at model-grid resolution
//   composite_<name>.png  — the frame at ~700px with the sky mask tinted over it
// plus a per-frame class histogram, sky fraction and inference timings.

import Foundation
import CoreML
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Model loading

/// Compiles the .mlpackage next to itself once and reuses the .mlmodelc.
func compiledModelURL(for packageURL: URL) throws -> URL {
    let compiled = packageURL.deletingPathExtension().appendingPathExtension("mlmodelc")
    let fm = FileManager.default
    if fm.fileExists(atPath: compiled.path) { return compiled }
    let temp = try MLModel.compileModel(at: packageURL)
    try? fm.removeItem(at: compiled)
    try fm.moveItem(at: temp, to: compiled)
    return compiled
}

func loadModel(_ path: String) throws -> MLModel {
    let url = URL(fileURLWithPath: path)
    let compiled = url.pathExtension == "mlmodelc" ? url : try compiledModelURL(for: url)
    let config = MLModelConfiguration()
    config.computeUnits = .all
    return try MLModel(contentsOf: compiled, configuration: config)
}

/// The class labels Apple embeds in the preview params metadata.
func classLabels(of model: MLModel) -> [String] {
    guard let creator = model.modelDescription.metadata[.creatorDefinedKey] as? [String: Any],
          let params = creator["com.apple.coreml.model.preview.params"] as? String,
          let data = params.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let labels = json["labels"] as? [String]
    else { return [] }
    return labels
}

func describe(_ model: MLModel) {
    let desc = model.modelDescription
    print("== inputs ==")
    for (name, input) in desc.inputDescriptionsByName {
        if let c = input.imageConstraint {
            print("  \(name): image \(c.pixelsWide)x\(c.pixelsHigh) format \(c.pixelFormatType)")
        } else if let c = input.multiArrayConstraint {
            print("  \(name): multiarray \(c.shape) \(c.dataType.rawValue)")
        } else {
            print("  \(name): \(input.type.rawValue)")
        }
    }
    print("== outputs ==")
    for (name, output) in desc.outputDescriptionsByName {
        if let c = output.multiArrayConstraint {
            print("  \(name): multiarray \(c.shape) dataType=\(c.dataType.rawValue)")
        } else {
            print("  \(name): \(output.type.rawValue)")
        }
    }
    let labels = classLabels(of: model)
    print("== labels (\(labels.count)) ==")
    for (i, label) in labels.enumerated() { print(String(format: "  %3d  %@", i, label)) }
}

// MARK: - Decode

let ciContext = CIContext(options: [.cacheIntermediates: false])

/// Display-referred decode of a RAW (or any) frame at the given long edge.
func decodeDisplay(url: URL, longEdge: CGFloat) -> CGImage? {
    var image: CIImage?
    if let raw = CIRAWFilter(imageURL: url) {
        // Rough decode scale keeps the CIRAWFilter render cheap; exact sizing
        // happens at draw time below.
        raw.scaleFactor = Float(min(1, longEdge / 4032))
        image = raw.outputImage
    } else {
        image = CIImage(contentsOf: url)
    }
    guard let image else { return nil }
    let extent = image.extent
    guard extent.width > 0, extent.height > 0 else { return nil }
    let scale = longEdge / max(extent.width, extent.height)
    let scaled = image.transformed(by: .init(scaleX: scale, y: scale))
    return ciContext.createCGImage(
        scaled, from: scaled.extent, format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
}

/// Stretch-resizes a CGImage into a BGRA pixel buffer of exactly w×h —
/// the harness's copy of the app's MaskGeometry.stretch contract.
func pixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ]
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
    guard let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let ctx = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
}

// MARK: - Prediction

struct LabelGrid {
    let width: Int, height: Int
    let values: [Int32]
}

func predictLabels(model: MLModel, inputName: String, outputName: String,
                   buffer: CVPixelBuffer) throws -> LabelGrid {
    let value = MLFeatureValue(pixelBuffer: buffer)
    let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: value])
    let result = try model.prediction(from: provider)
    guard let array = result.featureValue(for: outputName)?.multiArrayValue else {
        throw NSError(domain: "seg", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "no multiarray output \(outputName)"])
    }
    let shape = array.shape.map(\.intValue)
    let height = shape[shape.count - 2], width = shape[shape.count - 1]
    var values = [Int32](repeating: 0, count: width * height)
    let strides = array.strides.map(\.intValue)
    let rowStride = strides[strides.count - 2], colStride = strides[strides.count - 1]
    switch array.dataType {
    case .int32:
        let ptr = array.dataPointer.bindMemory(to: Int32.self, capacity: array.count)
        for y in 0..<height {
            for x in 0..<width { values[y * width + x] = ptr[y * rowStride + x * colStride] }
        }
    case .float32:
        let ptr = array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)
        for y in 0..<height {
            for x in 0..<width { values[y * width + x] = Int32(ptr[y * rowStride + x * colStride]) }
        }
    default:
        throw NSError(domain: "seg", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "unhandled dataType \(array.dataType.rawValue)"])
    }
    return LabelGrid(width: width, height: height, values: values)
}

// MARK: - Output images

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

func grayscaleImage(mask: [UInt8], width: Int, height: Int) -> CGImage? {
    let data = CFDataCreate(nil, mask, mask.count)!
    let provider = CGDataProvider(data: data)!
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
        bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

/// Magenta-tinted RGBA image of the mask, for compositing over the frame.
func tintImage(mask: [UInt8], width: Int, height: Int) -> CGImage? {
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    for i in 0..<(width * height) where mask[i] > 0 {
        rgba[i * 4 + 0] = 140  // premultiplied magenta at ~55% alpha
        rgba[i * 4 + 1] = 0
        rgba[i * 4 + 2] = 140
        rgba[i * 4 + 3] = 140
    }
    let data = CFDataCreate(nil, rgba, rgba.count)!
    let provider = CGDataProvider(data: data)!
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}

func composite(frame: CGImage, tint: CGImage) -> CGImage? {
    let w = frame.width, h = frame.height
    guard let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.interpolationQuality = .medium
    ctx.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
    ctx.draw(tint, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: seg_harness describe <model.mlpackage>")
    print("       seg_harness run <model.mlpackage> <outdir> <frame.dng> [...]")
    exit(2)
}

let model = try loadModel(args[2])

if args[1] == "describe" {
    describe(model)
    exit(0)
}

guard args[1] == "run", args.count >= 5 else {
    print("usage: seg_harness run <model.mlpackage> <outdir> <frame.dng> [...]")
    exit(2)
}

let desc = model.modelDescription
guard let (inputName, constraint) = desc.inputDescriptionsByName
    .compactMap({ name, input in input.imageConstraint.map { (name, $0) } }).first
else { fatalError("model has no image input") }
let outputName = desc.outputDescriptionsByName.keys.first ?? "semanticPredictions"
let labels = classLabels(of: model)
let skyIndices = Set(labels.enumerated().filter { $0.element.lowercased().contains("sky") }.map(\.offset))
print("model input \(inputName) \(constraint.pixelsWide)x\(constraint.pixelsHigh); output \(outputName)")
print("sky label indices: \(skyIndices.sorted().map { "\($0)=\(labels[$0])" }.joined(separator: ", "))")
guard !skyIndices.isEmpty else { fatalError("no sky class in this model's labels — wrong model") }

let outDir = URL(fileURLWithPath: args[3])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for path in args[4...] {
    let url = URL(fileURLWithPath: path)
    let name = url.deletingPathExtension().lastPathComponent
    let t0 = CFAbsoluteTimeGetCurrent()
    guard let display = decodeDisplay(url: url, longEdge: 700) else {
        print("\(name): decode FAILED"); continue
    }
    let tDecode = CFAbsoluteTimeGetCurrent()
    guard let buffer = pixelBuffer(from: display,
                                   width: constraint.pixelsWide, height: constraint.pixelsHigh)
    else { print("\(name): buffer FAILED"); continue }

    var grid: LabelGrid!
    var inferMS: [Double] = []
    for _ in 0..<3 {
        let t = CFAbsoluteTimeGetCurrent()
        grid = try predictLabels(model: model, inputName: inputName, outputName: outputName, buffer: buffer)
        inferMS.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
    }

    var histogram: [Int32: Int] = [:]
    for v in grid.values { histogram[v, default: 0] += 1 }
    let top = histogram.sorted { $0.value > $1.value }.prefix(6)
        .map { idx, count in
            let label = idx >= 0 && Int(idx) < labels.count ? labels[Int(idx)] : "#\(idx)"
            return String(format: "%@ %.1f%%", label, Double(count) * 100 / Double(grid.values.count))
        }
    let mask = grid.values.map { skyIndices.contains(Int($0)) ? UInt8(255) : UInt8(0) }
    let skyFraction = Double(mask.lazy.filter { $0 > 0 }.count) / Double(mask.count)

    if let maskImage = grayscaleImage(mask: mask, width: grid.width, height: grid.height) {
        writePNG(maskImage, to: outDir.appendingPathComponent("mask_\(name).png"))
    }
    if let tint = tintImage(mask: mask, width: grid.width, height: grid.height),
       let comp = composite(frame: display, tint: tint) {
        writePNG(comp, to: outDir.appendingPathComponent("composite_\(name).png"))
    }
    print(String(format: "%@: decode %.0fms, infer %@ms, sky %.1f%%  |  %@",
                 name, (tDecode - t0) * 1000,
                 inferMS.map { String(format: "%.0f", $0) }.joined(separator: "/"),
                 skyFraction * 100, top.joined(separator: ", ")))
}

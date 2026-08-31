import CoreGraphics
import CoreML
import Foundation

/// The sky-segmentation catalog entry's identity, shared between the catalog
/// JSON, the download validation and the locator below.
enum SkySegmentationModel {
    static let catalogID = "detr-semantic-f16"
    static let repoID = "apple/coreml-detr-semantic-segmentation"
    static let revision = "7c771f8867a479d1441ac5fb0a8de31feea76bb6"
}

/// The Core ML adapter behind `SceneMaskService`: finds the installed model,
/// compiles it once, and turns a display-referred frame into a sky
/// probability grid. DETR's output is an argmax label map, so today's
/// per-frame "probability" is 0 or 1 — real confidences appear at the
/// sequence level (vote fractions) or with a probability-emitting model
/// (SegFormer, the recorded upgrade path).
final class CoreMLSceneSegmenter {

    struct Source {
        let url: URL
        /// Cache-key identity: catalog id + pinned revision for an installed
        /// model, path + mtime for a debug override.
        let identity: String
    }

    /// Where the model is, or nil when it isn't installed — the panel's
    /// "download it in Settings ▸ AI Models" state. Pure file-system work on
    /// purpose: `ModelManager` is main-actor, and mask fetches are not.
    static func locate() -> Source? {
        let fileManager = FileManager.default
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["LL_SEG_MODEL"], !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            if fileManager.fileExists(atPath: url.path) {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 ?? 0
                return Source(url: url, identity: "env|\(url.lastPathComponent)|\(Int(mtime))")
            }
        }
        #endif
        // The installed snapshot, in ModelManager's own layout:
        // Application Support/Models/<catalog-id>/models--org--repo/snapshots/<sha>/.
        // Path built here rather than through ModelManager because that class
        // is main-actor and this lookup runs wherever a mask fetch runs.
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let repoFolder = "models--" + SkySegmentationModel.repoID
            .replacingOccurrences(of: "/", with: "--")
        let snapshots = support
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(SkySegmentationModel.catalogID, isDirectory: true)
            .appendingPathComponent(repoFolder, isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
        let pinned = snapshots.appendingPathComponent(
            SkySegmentationModel.revision, isDirectory: true)
        let candidates = [pinned] + ((try? fileManager.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
        for candidate in candidates {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: candidate, includingPropertiesForKeys: nil) else { continue }
            if let package = contents.first(where: { $0.pathExtension == "mlpackage" }),
               fileManager.fileExists(atPath: package
                   .appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin").path) {
                let revision = candidate.lastPathComponent
                return Source(
                    url: package,
                    identity: "\(SkySegmentationModel.catalogID)@\(revision.prefix(8))")
            }
        }
        return nil
    }

    let source: Source
    private let model: MLModel
    private let inputName: String
    private let inputWidth: Int
    private let inputHeight: Int
    private let outputName: String
    private let skyLabelIndices: Set<Int>

    init(source: Source) throws {
        self.source = source
        let compiled = try Self.compiledURL(for: source)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try MLModel(contentsOf: compiled, configuration: configuration)

        let description = model.modelDescription
        guard let (name, constraint) = description.inputDescriptionsByName
            .compactMap({ name, input in input.imageConstraint.map { (name, $0) } }).first
        else { throw SegmentationError.unusableModel("no image input") }
        inputName = name
        inputWidth = constraint.pixelsWide
        inputHeight = constraint.pixelsHigh
        guard let output = description.outputDescriptionsByName.first(where: {
            $0.value.multiArrayConstraint != nil
        })?.key else { throw SegmentationError.unusableModel("no multiarray output") }
        outputName = output

        // The class list Apple embeds in the preview-params metadata; any
        // label containing "sky" counts. A model without one can't do this
        // job, whatever else it segments.
        let labels = Self.classLabels(of: model)
        skyLabelIndices = Set(labels.enumerated()
            .filter { $0.element.lowercased().contains("sky") }.map(\.offset))
        guard !skyLabelIndices.isEmpty else {
            throw SegmentationError.unusableModel("no sky class among \(labels.count) labels")
        }
    }

    /// Sky probability grid for one display-referred frame. The input is
    /// stretch-resized to the model's square (`MaskGeometry.stretch`): the
    /// grid covers the frame's unit square exactly, and the way back is a
    /// pure per-axis scale.
    func skyMask(for image: CGImage) throws -> SceneMask {
        guard let buffer = Self.pixelBuffer(
            from: image, width: inputWidth, height: inputHeight)
        else { throw SegmentationError.inferenceFailed("input buffer") }
        let started = CFAbsoluteTimeGetCurrent()
        let provider = try MLDictionaryFeatureProvider(
            dictionary: [inputName: MLFeatureValue(pixelBuffer: buffer)])
        let result = try model.prediction(from: provider)
        guard let array = result.featureValue(for: outputName)?.multiArrayValue else {
            throw SegmentationError.inferenceFailed("no output \(outputName)")
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000

        let shape = array.shape.map(\.intValue)
        guard shape.count >= 2 else { throw SegmentationError.inferenceFailed("shape \(shape)") }
        let height = shape[shape.count - 2], width = shape[shape.count - 1]
        let strides = array.strides.map(\.intValue)
        let rowStride = strides[strides.count - 2], columnStride = strides[strides.count - 1]
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard array.dataType == .int32 else {
            throw SegmentationError.inferenceFailed("dataType \(array.dataType.rawValue)")
        }
        let values = array.dataPointer.bindMemory(to: Int32.self, capacity: array.count)
        let sky = skyLabelIndices
        for y in 0..<height {
            for x in 0..<width where sky.contains(Int(values[y * rowStride + x * columnStride])) {
                pixels[y * width + x] = 255
            }
        }
        return SceneMask(
            region: .sky, width: width, height: height, pixels: pixels,
            geometry: .stretch,
            provenance: String(format: "%@ · %.0f ms", source.identity, elapsed))
    }

    // MARK: - Compilation

    /// `.mlpackage` compiles once into Caches, keyed by the source identity,
    /// and every later launch loads the compiled model directly.
    private static func compiledURL(for source: Source) throws -> URL {
        if source.url.pathExtension == "mlmodelc" { return source.url }
        let fileManager = FileManager.default
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let folder = caches.appendingPathComponent("SegmentationModels", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = source.identity
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "|", with: "-")
        let compiled = folder.appendingPathComponent("\(name).mlmodelc")
        if fileManager.fileExists(atPath: compiled.path) { return compiled }
        let temporary = try MLModel.compileModel(at: source.url)
        try? fileManager.removeItem(at: compiled)
        try fileManager.moveItem(at: temporary, to: compiled)
        return compiled
    }

    private static func classLabels(of model: MLModel) -> [String] {
        guard let creator = model.modelDescription.metadata[.creatorDefinedKey] as? [String: Any],
              let params = creator["com.apple.coreml.model.preview.params"] as? String,
              let data = params.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let labels = json["labels"] as? [String]
        else { return [] }
        return labels
    }

    /// Stretch-resize into a BGRA buffer in sRGB — the space these models
    /// were trained against; the graded preview arrives Display P3.
    private static func pixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}

enum SegmentationError: LocalizedError {
    case modelNotInstalled
    case unusableModel(String)
    case inferenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled:
            return "The segmentation model is not installed."
        case .unusableModel(let reason):
            return "The segmentation model can't be used: \(reason)."
        case .inferenceFailed(let reason):
            return "Segmentation failed: \(reason)."
        }
    }
}

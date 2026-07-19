import SwiftUI
import AVFoundation
import CoreGraphics
import ImageIO
import LetsLapseKit
#if os(iOS)
import Photos
#endif

@MainActor
final class AppModel: ObservableObject {
    private enum DefaultsKey {
        static let constantWindow = "letslapse.constantWindow"
        static let outputFPS = "letslapse.outputFPS"
        static let linearLight = "letslapse.linearLight"
        static let trimVideoEnds = "letslapse.trimVideoEnds"
        static let trimHeadTailSeconds = "letslapse.trimHeadTailSeconds"
        static let maxCPUWorkers = "letslapse.maxCPUWorkers"
        static let maxBlendBatches = "letslapse.maxBlendBatches"
    }

    enum CaptureKind: String, Codable {
        case video
        case photos

        var label: String {
            switch self {
            case .video: return "Video"
            case .photos: return "Interval photos"
            }
        }
    }

    enum BlendKind: String, Codable {
        case video
        case image
    }

    struct CaptureProject: Identifiable, Codable, Equatable {
        var id: UUID
        var kind: CaptureKind
        var createdAt: Date
        var originalName: String
        var mode: String
        var sourceFileNames: [String]
        var sourceFPS: Double?

        var summary: String {
            switch kind {
            case .video:
                if let sourceFPS {
                    return "\(mode) · \(String(format: "%.0f", sourceFPS)) fps"
                }
                return mode
            case .photos:
                return "\(sourceFileNames.count) source frames"
            }
        }
    }

    struct BlendProject: Identifiable, Codable, Equatable {
        var id: UUID
        var captureID: UUID
        var kind: BlendKind
        var createdAt: Date
        var outputFileName: String
        var summary: String
        var compressionRatio: Int?
        var outputFPS: Int?
        var linearLight: Bool
        var useRamp: Bool
        var rampStart: Int
        var rampEnd: Int
        var curve: String
        var trimHeadTailSeconds: Double?
        var width: Int?
        var height: Int?
        var inputFrames: Int?
        var outputFrames: Int?

        var parameterSummary: String {
            switch kind {
            case .video:
                let timing = outputFPS.map { "\($0) fps" } ?? "video"
                let trim = trimHeadTailSeconds.map { $0 > 0 ? " · trim \(String(format: "%.1f", $0))s" : "" } ?? ""
                if useRamp {
                    return "\(rampStart)→\(rampEnd):1 · \(timing)\(trim)"
                }
                if let compressionRatio {
                    return "\(compressionRatio):1 · \(timing)\(trim)"
                }
                return "\(timing)\(trim)"
            case .image:
                return linearLight ? "Linear-light stack" : "Stack"
            }
        }
    }

    private struct LibraryManifest: Codable {
        var captures: [CaptureProject] = []
        var blends: [BlendProject] = []
    }

    private struct ProcessingOutput {
        var kind: BlendKind
        var url: URL
        var image: CGImage?
        var summary: String
        var inputFrames: Int?
        var outputFrames: Int?
        var width: Int?
        var height: Int?
    }

    enum Source: Equatable {
        case video(URL)
        case photos([URL])

        var summary: String {
            switch self {
            case .video(let url):
                return "Video · \(url.lastPathComponent)"
            case .photos(let urls):
                return "\(urls.count) photos"
            }
        }

        var isVideo: Bool {
            if case .video = self { return true }
            return false
        }
    }

    enum Stage {
        case home
        case configure
        case processing
        case done
    }

    @Published var stage: Stage = .home
    @Published var source: Source?
    @Published var errorMessage: String?
    @Published private(set) var captures: [CaptureProject] = []
    @Published private(set) var blends: [BlendProject] = []
    @Published var currentCaptureID: UUID?
    @Published var resultBlendID: UUID?

    // Blend options
    @Published var useRamp = false
    @Published var constantWindow = UserDefaults.standard.object(forKey: DefaultsKey.constantWindow) as? Int ?? 10 {
        didSet { UserDefaults.standard.set(constantWindow, forKey: DefaultsKey.constantWindow) }
    }
    @Published var rampStart = 1
    @Published var rampEnd = 30
    @Published var curve: BlendCurve = .easeInOut
    @Published var outputFPS = UserDefaults.standard.object(forKey: DefaultsKey.outputFPS) as? Int ?? 25 {
        didSet { UserDefaults.standard.set(outputFPS, forKey: DefaultsKey.outputFPS) }
    }
    @Published var linearLight = UserDefaults.standard.object(forKey: DefaultsKey.linearLight) as? Bool ?? true {
        didSet { UserDefaults.standard.set(linearLight, forKey: DefaultsKey.linearLight) }
    }
    @Published var trimVideoEnds = UserDefaults.standard.object(forKey: DefaultsKey.trimVideoEnds) as? Bool ?? false {
        didSet { UserDefaults.standard.set(trimVideoEnds, forKey: DefaultsKey.trimVideoEnds) }
    }
    @Published var trimHeadTailSeconds = UserDefaults.standard.object(forKey: DefaultsKey.trimHeadTailSeconds) as? Double ?? 1 {
        didSet { UserDefaults.standard.set(trimHeadTailSeconds, forKey: DefaultsKey.trimHeadTailSeconds) }
    }

    // Performance options
    @Published var maxCPUWorkers = UserDefaults.standard.object(forKey: DefaultsKey.maxCPUWorkers) as? Int ?? max(1, ProcessInfo.processInfo.activeProcessorCount - 2) {
        didSet { UserDefaults.standard.set(maxCPUWorkers, forKey: DefaultsKey.maxCPUWorkers) }
    }
    @Published var maxBlendBatches = UserDefaults.standard.object(forKey: DefaultsKey.maxBlendBatches) as? Int ?? 2 {
        didSet { UserDefaults.standard.set(maxBlendBatches, forKey: DefaultsKey.maxBlendBatches) }
    }

    // Progress / results
    @Published var progress: Double = 0
    @Published var resultVideoURL: URL?
    @Published var resultImage: CGImage?
    @Published var resultImageURL: URL?
    @Published var resultSummary: String?
    @Published var saveConfirmation: String?
    @Published var statusMessage = ""
    @Published var jobFolderURL: URL?
    @Published var jobLogLines: [String] = []

    private var blendTask: Task<Void, Never>?

    init() {
        loadLibrary()
    }

    var currentCapture: CaptureProject? {
        guard let currentCaptureID else { return nil }
        return captures.first { $0.id == currentCaptureID }
    }

    var currentBlend: BlendProject? {
        guard let resultBlendID else { return nil }
        return blends.first { $0.id == resultBlendID }
    }

    func blends(for capture: CaptureProject) -> [BlendProject] {
        blends
            .filter { $0.captureID == capture.id }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func setSource(_ source: Source, mode: String = "Import") {
        do {
            let capture = try registerCapture(from: source, mode: mode)
            openCapture(capture)
        } catch {
            errorMessage = "Couldn't preserve the capture: \(error.localizedDescription)"
        }
    }

    func reset() {
        blendTask?.cancel()
        blendTask = nil
        source = nil
        currentCaptureID = nil
        resultBlendID = nil
        progress = 0
        resultVideoURL = nil
        resultImage = nil
        resultImageURL = nil
        resultSummary = nil
        saveConfirmation = nil
        statusMessage = ""
        jobFolderURL = nil
        jobLogLines = []
        errorMessage = nil
        stage = .home
    }

    func openCapture(_ capture: CaptureProject) {
        do {
            source = try source(for: capture)
            currentCaptureID = capture.id
            resultBlendID = nil
            resultVideoURL = nil
            resultImage = nil
            resultImageURL = nil
            resultSummary = nil
            saveConfirmation = nil
            errorMessage = nil
            stage = .configure
        } catch {
            errorMessage = "Couldn't open that capture: \(error.localizedDescription)"
        }
    }

    func openBlend(_ blend: BlendProject) {
        guard let capture = captures.first(where: { $0.id == blend.captureID }) else {
            errorMessage = "The source capture for that blend is missing."
            return
        }

        do {
            source = try source(for: capture)
            currentCaptureID = capture.id
            resultBlendID = blend.id
            resultVideoURL = nil
            resultImage = nil
            resultImageURL = nil
            resultSummary = blend.summary

            if let compressionRatio = blend.compressionRatio {
                constantWindow = compressionRatio
            }
            if let outputFPS = blend.outputFPS {
                self.outputFPS = outputFPS
            }
            linearLight = blend.linearLight
            useRamp = blend.useRamp
            rampStart = blend.rampStart
            rampEnd = blend.rampEnd
            if let savedCurve = BlendCurve(rawValue: blend.curve) {
                curve = savedCurve
            }
            trimVideoEnds = (blend.trimHeadTailSeconds ?? 0) > 0
            if let trimHeadTailSeconds = blend.trimHeadTailSeconds {
                self.trimHeadTailSeconds = max(0.1, trimHeadTailSeconds)
            }

            let outputURL = blendOutputURL(for: blend)
            switch blend.kind {
            case .video:
                resultVideoURL = outputURL
            case .image:
                resultImageURL = outputURL
                resultImage = loadImage(at: outputURL)
            }

            saveConfirmation = nil
            errorMessage = nil
            stage = .done
        } catch {
            errorMessage = "Couldn't open that blend: \(error.localizedDescription)"
        }
    }

    func cancelProcessing() {
        blendTask?.cancel()
    }

    var ramp: BlendRamp {
        useRamp && source?.isVideo == true
            ? BlendRamp(startWindow: rampStart, endWindow: rampEnd, curve: curve)
            : .constant(constantWindow)
    }

    func startProcessing() {
        guard let source, let captureID = currentCaptureID else { return }
        stage = .processing
        progress = 0
        statusMessage = "Preparing job..."
        jobFolderURL = nil
        jobLogLines = []
        resultVideoURL = nil
        resultImage = nil
        resultImageURL = nil
        resultSummary = nil
        resultBlendID = nil
        errorMessage = nil
        let ramp = self.ramp
        let fps = Double(outputFPS)
        let linear = linearLight
        let trim = source.isVideo && trimVideoEnds ? max(0, trimHeadTailSeconds) : 0
        let parameters = currentBlendParameters()
        blendTask = Task { [weak self] in
            do {
                guard let self else { return }
                let output: ProcessingOutput
                switch source {
                case .video(let url):
                    output = try await self.blendVideo(url: url, ramp: ramp, fps: fps, linear: linear, trimHeadTailSeconds: trim)
                case .photos(let urls):
                    output = try await self.stackPhotos(urls: urls, linear: linear)
                }
                let blend = try self.storeBlend(output, captureID: captureID, parameters: parameters)
                self.apply(output, from: blend)
                self.stage = .done
            } catch is CancellationError {
                self?.stage = .configure
            } catch LapseError.cancelled {
                self?.stage = .configure
            } catch {
                self?.errorMessage = (error as? LapseError)?.errorDescription ?? error.localizedDescription
                self?.stage = .configure
            }
        }
    }

    private func blendVideo(
        url: URL,
        ramp: BlendRamp,
        fps: Double,
        linear: Bool,
        trimHeadTailSeconds: Double
    ) async throws -> ProcessingOutput {
        #if os(macOS)
        if ramp.startWindow == ramp.endWindow {
            let result = try await MacVideoJobRunner.run(
                inputURL: url,
                options: MacVideoJobOptions(
                    blendWindow: ramp.startWindow,
                    outputFPS: fps,
                    linearLight: linear,
                    trimHeadTailSeconds: trimHeadTailSeconds,
                    maxCPUWorkers: maxCPUWorkers,
                    maxBlendBatches: maxBlendBatches
                )
            ) { update in
                Task { @MainActor [weak self] in
                    self?.progress = update.fraction
                    self?.statusMessage = update.message
                    self?.jobFolderURL = update.jobFolderURL
                    self?.jobLogLines = update.recentLogLines
                }
            }
            jobFolderURL = result.jobFolderURL
            let trimSummary = trimHeadTailSeconds > 0 ? " · trimmed \(String(format: "%.1f", trimHeadTailSeconds))s each end" : ""
            let summary = "\(result.inputFrames) frames in → \(result.outputFrames) frames out · "
                + "\(result.width)×\(result.height)"
                + trimSummary
            return ProcessingOutput(
                kind: .video,
                url: result.outputURL,
                image: nil,
                summary: summary,
                inputFrames: result.inputFrames,
                outputFrames: result.outputFrames,
                width: result.width,
                height: result.height
            )
        }
        #endif

        let core = try BlendCore()
        let blender = VideoBlender(core: core)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("LetsLapse-\(Int(Date().timeIntervalSince1970)).mp4")
        let options = VideoBlendOptions(
            ramp: ramp,
            outputFPS: fps,
            codec: .h264,
            linearLight: linear,
            trimHeadTailSeconds: trimHeadTailSeconds
        )
        let result = try await blender.blend(input: url, to: output, options: options) { fraction in
            Task { @MainActor [weak self] in
                self?.progress = fraction
            }
        }
        let trimSummary = trimHeadTailSeconds > 0 ? " · trimmed \(String(format: "%.1f", trimHeadTailSeconds))s each end" : ""
        let summary = "\(result.inputFrames) frames in → \(result.outputFrames) frames out · "
            + String(format: "%.1fs", result.outputDuration)
            + " · \(result.width)×\(result.height)"
            + trimSummary
        return ProcessingOutput(
            kind: .video,
            url: result.outputURL,
            image: nil,
            summary: summary,
            inputFrames: result.inputFrames,
            outputFrames: result.outputFrames,
            width: result.width,
            height: result.height
        )
    }

    private func stackPhotos(urls: [URL], linear: Bool) async throws -> ProcessingOutput {
        let image = try await Task.detached(priority: .userInitiated) { [weak self] () throws -> CGImage in
            let core = try BlendCore()
            let stacker = ImageStacker(core: core)
            return try stacker.stack(imageURLs: urls, linearLight: linear) { fraction in
                Task { @MainActor in
                    self?.progress = fraction
                }
            }
        }.value
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("LetsLapse-\(Int(Date().timeIntervalSince1970)).png")
        try ImageExporter.write(image, to: output, format: .png)
        let summary = "\(urls.count) photos stacked · \(image.width)×\(image.height)"
        return ProcessingOutput(
            kind: .image,
            url: output,
            image: image,
            summary: summary,
            inputFrames: urls.count,
            outputFrames: 1,
            width: image.width,
            height: image.height
        )
    }

    private func currentBlendParameters() -> BlendProject {
        BlendProject(
            id: UUID(),
            captureID: currentCaptureID ?? UUID(),
            kind: source?.isVideo == true ? .video : .image,
            createdAt: Date(),
            outputFileName: "",
            summary: "",
            compressionRatio: source?.isVideo == true ? constantWindow : nil,
            outputFPS: source?.isVideo == true ? outputFPS : nil,
            linearLight: linearLight,
            useRamp: useRamp && source?.isVideo == true,
            rampStart: rampStart,
            rampEnd: rampEnd,
            curve: curve.rawValue,
            trimHeadTailSeconds: source?.isVideo == true && trimVideoEnds ? max(0, trimHeadTailSeconds) : nil,
            width: nil,
            height: nil,
            inputFrames: nil,
            outputFrames: nil
        )
    }

    private func apply(_ output: ProcessingOutput, from blend: BlendProject) {
        let storedURL = blendOutputURL(for: blend)
        resultBlendID = blend.id
        resultSummary = blend.summary
        resultVideoURL = nil
        resultImage = nil
        resultImageURL = nil

        switch output.kind {
        case .video:
            resultVideoURL = storedURL
        case .image:
            resultImageURL = storedURL
            resultImage = output.image ?? loadImage(at: storedURL)
        }
    }

    private func storeBlend(_ output: ProcessingOutput, captureID: UUID, parameters: BlendProject) throws -> BlendProject {
        let id = parameters.id
        let extensionName = output.kind == .video ? "mp4" : "png"
        let outputFileName = "blends/\(id.uuidString).\(extensionName)"
        let destination = captureFolderURL(for: captureID).appendingPathComponent(outputFileName)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try copyReplacingItem(at: output.url, to: destination)

        var blend = parameters
        blend.captureID = captureID
        blend.kind = output.kind
        blend.outputFileName = outputFileName
        blend.summary = output.summary
        blend.inputFrames = output.inputFrames
        blend.outputFrames = output.outputFrames
        blend.width = output.width
        blend.height = output.height

        blends.append(blend)
        blends.sort { $0.createdAt > $1.createdAt }
        try persistLibrary()
        return blend
    }

    private func registerCapture(from source: Source, mode: String) throws -> CaptureProject {
        let id = UUID()
        let root = captureFolderURL(for: id)
        let sourceFolder = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)

        let capture: CaptureProject
        switch source {
        case .video(let url):
            let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
            let relativeName = "source/original.\(ext)"
            let destination = root.appendingPathComponent(relativeName)
            try copySecurityScopedItem(at: url, to: destination)
            capture = CaptureProject(
                id: id,
                kind: .video,
                createdAt: Date(),
                originalName: url.lastPathComponent,
                mode: mode,
                sourceFileNames: [relativeName],
                sourceFPS: nil
            )
        case .photos(let urls):
            var relativeNames: [String] = []
            for (index, url) in urls.enumerated() {
                let ext = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
                let relativeName = String(format: "source/frame-%05d%@", index + 1, ext)
                let destination = root.appendingPathComponent(relativeName)
                try copySecurityScopedItem(at: url, to: destination)
                relativeNames.append(relativeName)
            }
            capture = CaptureProject(
                id: id,
                kind: .photos,
                createdAt: Date(),
                originalName: "\(relativeNames.count) photos",
                mode: mode,
                sourceFileNames: relativeNames,
                sourceFPS: nil
            )
        }

        captures.insert(capture, at: 0)
        try persistLibrary()
        if capture.kind == .video {
            Task { [weak self] in
                await self?.refreshVideoMetadata(for: capture.id)
            }
        }
        return capture
    }

    private func source(for capture: CaptureProject) throws -> Source {
        let urls = capture.sourceFileNames.map {
            captureFolderURL(for: capture.id).appendingPathComponent($0)
        }
        for url in urls where !FileManager.default.fileExists(atPath: url.path) {
            throw CocoaError(.fileNoSuchFile)
        }

        switch capture.kind {
        case .video:
            guard let url = urls.first else { throw CocoaError(.fileNoSuchFile) }
            return .video(url)
        case .photos:
            return .photos(urls)
        }
    }

    private func loadLibrary() {
        do {
            try migrateLegacyApplicationSupportFolderIfNeeded()
            try FileManager.default.createDirectory(at: projectsRootURL, withIntermediateDirectories: true)
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { return }
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(LibraryManifest.self, from: data)
            captures = manifest.captures.sorted { $0.createdAt > $1.createdAt }
            blends = manifest.blends.sorted { $0.createdAt > $1.createdAt }
            for capture in captures where capture.kind == .video && capture.sourceFPS == nil {
                Task { [weak self] in
                    await self?.refreshVideoMetadata(for: capture.id)
                }
            }
        } catch {
            errorMessage = "Couldn't load the project library: \(error.localizedDescription)"
        }
    }

    private func persistLibrary() throws {
        try FileManager.default.createDirectory(at: projectsRootURL, withIntermediateDirectories: true)
        let manifest = LibraryManifest(captures: captures, blends: blends)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    private var applicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LetsLapse", isDirectory: true)
    }

    private var legacyApplicationSupportURL: URL {
        let legacyName = ["Let", "s Lapse"].joined(separator: "'")
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(legacyName, isDirectory: true)
    }

    private func migrateLegacyApplicationSupportFolderIfNeeded() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacyApplicationSupportURL.path),
              !fileManager.fileExists(atPath: applicationSupportURL.path)
        else { return }

        try fileManager.moveItem(at: legacyApplicationSupportURL, to: applicationSupportURL)
    }

    private var projectsRootURL: URL {
        applicationSupportURL.appendingPathComponent("Projects", isDirectory: true)
    }

    private var manifestURL: URL {
        projectsRootURL.appendingPathComponent("library.json")
    }

    private func captureFolderURL(for id: UUID) -> URL {
        projectsRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func blendOutputURL(for blend: BlendProject) -> URL {
        captureFolderURL(for: blend.captureID).appendingPathComponent(blend.outputFileName)
    }

    private func copySecurityScopedItem(at source: URL, to destination: URL) throws {
        let didAccess = source.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                source.stopAccessingSecurityScopedResource()
            }
        }
        try copyReplacingItem(at: source, to: destination)
    }

    private func copyReplacingItem(at source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func refreshVideoMetadata(for captureID: UUID) async {
        guard let capture = captures.first(where: { $0.id == captureID }) else { return }
        guard let captureSource = try? source(for: capture), case .video(let url) = captureSource else { return }

        do {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
            let fps = try await track.load(.nominalFrameRate)
            guard fps > 0, let index = captures.firstIndex(where: { $0.id == captureID }) else { return }
            captures[index].sourceFPS = Double(fps)
            try persistLibrary()
        } catch {
            return
        }
    }

    #if os(iOS)
    func saveResultToPhotos() {
        let videoURL = resultVideoURL
        let imageURL = resultImageURL
        guard videoURL != nil || imageURL != nil else { return }
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                saveConfirmation = "Photos access was denied."
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    if let videoURL {
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
                    } else if let imageURL {
                        PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: imageURL)
                    }
                }
                saveConfirmation = "Saved to Photos."
            } catch {
                saveConfirmation = "Save failed: \(error.localizedDescription)"
            }
        }
    }
    #endif
}

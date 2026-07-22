import SwiftUI
import AVFoundation
import CoreGraphics
import ImageIO
import LetsLapseKit
import VideoToolbox
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
        static let defaultSpeed = "letslapse.defaultSpeed"
        static let scratchFrameFormat = "letslapse.scratchFrameFormat"
        static let keepExtractedFrames = "letslapse.keepExtractedFrames"
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

    enum MediaKind: Hashable {
        case video
        case image
    }

    /// One codec variant of a single source clip. The original capture file is
    /// itself an encoding (usually ProRes); conversions are siblings inside the
    /// project's `source/` folder. `fileName` is relative to the capture folder.
    struct ClipEncoding: Codable, Equatable, Identifiable {
        var codec: String
        var fileName: String

        var id: String { fileName }

        var isProRes: Bool { codec == OutputCodec.prores.rawValue }

        var codecLabel: String {
            switch codec {
            case OutputCodec.prores.rawValue: return "ProRes"
            case OutputCodec.h264.rawValue: return "H.264"
            case OutputCodec.hevc.rawValue: return "HEVC"
            default: return "Video"
            }
        }
    }

    struct CaptureProject: Identifiable, Codable, Equatable {
        var id: UUID
        var kind: CaptureKind
        var createdAt: Date
        var originalName: String
        var mode: String
        var sourceFileNames: [String]
        var sourceFPS: Double?
        var name: String?
        var sourceDurationSeconds: Double?
        var sourceWidth: Int?
        var sourceHeight: Int?
        /// Extra codec variants per source clip, keyed by the clip's original
        /// relative file name. Absent (nil) until a clip is first converted.
        var clipEncodings: [String: [ClipEncoding]]?

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

        var sourceMediaCount: Int {
            sourceFileNames.filter { !$0.hasSuffix(".json") }.count
        }

        /// A project title people can recognize: the custom name, an imported
        /// file's name, or a dated fallback.
        var displayTitle: String {
            if let name, !name.isEmpty { return name }
            if kind == .video, mode == "Import" {
                let base = (originalName as NSString).deletingPathExtension
                if !base.isEmpty { return base }
            }
            let stamp = createdAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())
            return kind == .photos ? "Stack \(stamp)" : "Capture \(stamp)"
        }

        /// "Video · 1080p · 24 fps" / "Interval · 214 photos"
        var formatLine: String {
            switch kind {
            case .video:
                var parts = ["Video"]
                if let sourceWidth, let sourceHeight {
                    parts.append(Self.resolutionLabel(width: sourceWidth, height: sourceHeight))
                }
                if let sourceFPS {
                    parts.append("\(Int(sourceFPS.rounded())) fps")
                }
                return parts.joined(separator: " · ")
            case .photos:
                return "Interval · \(sourceMediaCount) photos"
            }
        }

        static func resolutionLabel(width: Int, height: Int) -> String {
            switch (max(width, height), min(width, height)) {
            case (3840, 2160): return "4K"
            case (1920, 1080): return "1080p"
            case (1280, 720): return "720p"
            default: return "\(width)×\(height)"
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
        /// The source codec this version was blended from, when the user picked
        /// one explicitly (nil = automatic / best-available). Its `OutputCodec`
        /// raw value, e.g. "h264".
        var sourceCodec: String?

        /// "ProRes" / "H.264" / "HEVC" for display, when recorded.
        var sourceCodecLabel: String? {
            switch sourceCodec {
            case "prores": return "ProRes"
            case "h264": return "H.264"
            case "hevc": return "HEVC"
            default: return nil
            }
        }

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

        /// "100×" / "1→30× ramp" / "Long exposure"
        var speedLabel: String {
            switch kind {
            case .video:
                if useRamp { return "\(rampStart)→\(rampEnd)× ramp" }
                if let compressionRatio { return "\(compressionRatio)×" }
                return "Video"
            case .image:
                return "Long exposure"
            }
        }

        var outputSeconds: Double? {
            guard kind == .video, let outputFrames, let outputFPS, outputFPS > 0 else { return nil }
            return Double(outputFrames) / Double(outputFPS)
        }

        /// The thumbnail badge: "100× · 2.2s" / "Long exposure"
        var badgeLabel: String {
            if kind == .image { return "Long exposure" }
            if let outputSeconds {
                return "\(speedLabel) · \(SpeedMath.clipLengthCompact(outputSeconds))"
            }
            return speedLabel
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

    private final class ExportSessionBox: @unchecked Sendable {
        let session: AVAssetExportSession

        init(_ session: AVAssetExportSession) {
            self.session = session
        }
    }

    struct LiveCaptureSource: Equatable {
        var sequence: LiveCaptureSequence
        var segmentURLs: [URL]
        var metadataURL: URL
        /// Maps each segment's original file name (as recorded in the sequence
        /// metadata) to the file actually used, after per-clip encoding choices.
        var resolvedByOriginalName: [String: URL] = [:]

        var primaryVideoURL: URL? {
            segmentURLs.first
        }
    }

    enum Source: Equatable {
        case video(URL)
        case liveSequence(LiveCaptureSource)
        case photos([URL])

        var summary: String {
            switch self {
            case .video(let url):
                return "Video · \(url.lastPathComponent)"
            case .liveSequence(let source):
                return "Video · \(source.sequence.summary)"
            case .photos(let urls):
                return "\(urls.count) photos"
            }
        }

        var isVideo: Bool {
            if case .video = self { return true }
            if case .liveSequence = self { return true }
            return false
        }
    }

    enum Stage {
        case home
        case configure
        case processing
        case done
    }

    /// Named stages for the processing screen — people see a checklist, not a log.
    enum ProcessingStage: Int, CaseIterable, Comparable {
        case preparing
        case blending
        case encoding
        case saving

        var title: String {
            switch self {
            case .preparing: return "Preparing footage"
            case .blending: return "Blending frames"
            case .encoding: return "Encoding video"
            case .saving: return "Saving to project"
            }
        }

        static func < (lhs: ProcessingStage, rhs: ProcessingStage) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    var processingStage: ProcessingStage {
        if progress < 0.02 { return .preparing }
        if progress < 0.93 { return .blending }
        if progress < 0.999 { return .encoding }
        return .saving
    }

    enum LibraryDeletionError: LocalizedError {
        case activeCapture
        case unsafeBlendPath

        var errorDescription: String? {
            switch self {
            case .activeCapture:
                return "This capture is currently being processed. Cancel the job before deleting it."
            case .unsafeBlendPath:
                return "The blend file is outside its capture folder and could not be deleted safely."
            }
        }
    }

    @Published var stage: Stage = .home
    @Published var source: Source?
    @Published var errorMessage: String?
    @Published private(set) var captures: [CaptureProject] = []
    @Published private(set) var blends: [BlendProject] = []
    @Published var currentCaptureID: UUID?
    @Published var resultBlendID: UUID?

    // Blend options
    /// Which codec each source clip contributes to the blend. `nil` = automatic
    /// (best surviving encoding per clip). Only meaningful once a clip has more
    /// than one encoding; drives the "Blend from" picker in Adjust.
    @Published var blendSourceCodec: OutputCodec?
    @Published var useRamp = false
    @Published var constantWindow = UserDefaults.standard.object(forKey: DefaultsKey.constantWindow) as? Int
        ?? UserDefaults.standard.object(forKey: DefaultsKey.defaultSpeed) as? Int
        ?? 100 {
        didSet { UserDefaults.standard.set(constantWindow, forKey: DefaultsKey.constantWindow) }
    }
    @Published var defaultSpeed = UserDefaults.standard.object(forKey: DefaultsKey.defaultSpeed) as? Int ?? 100 {
        didSet { UserDefaults.standard.set(defaultSpeed, forKey: DefaultsKey.defaultSpeed) }
    }

    /// Blend depth for interval-stills output, kept separate from the video
    /// `constantWindow` (whose default is a fast video speed). 1 = a crisp
    /// timelapse, one frame per photo; higher values blend more stills into
    /// each frame for motion blur; at or above the photo count every still
    /// folds into a single long-exposure image.
    @Published var photoBlendDepth = 1
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

    // Recording options
    @Published var rememberRecordingSettings = RecordingSettingsStore.isEnabled {
        didSet {
            UserDefaults.standard.set(rememberRecordingSettings, forKey: RecordingSettingsStore.isEnabledKey)
            if !rememberRecordingSettings {
                RecordingSettingsStore.clear()
            }
        }
    }
    /// Off by default: shoots are silent, no mic permission is requested, and
    /// audio playing on the device keeps running during capture. The camera
    /// picks changes up the next time the capture screen starts.
    @Published var recordAudio = RecordingSettingsStore.isAudioEnabled {
        didSet { RecordingSettingsStore.save(isAudioEnabled: recordAudio) }
    }
    /// Extra capture rate offered alongside the built-in ones whenever the
    /// active camera supports it. nil = off.
    @Published var customCaptureFrameRate = RecordingSettingsStore.customFrameRate {
        didSet { RecordingSettingsStore.save(customFrameRate: customCaptureFrameRate) }
    }

    // Performance options
    @Published var maxCPUWorkers = UserDefaults.standard.object(forKey: DefaultsKey.maxCPUWorkers) as? Int ?? max(1, ProcessInfo.processInfo.activeProcessorCount - 2) {
        didSet { UserDefaults.standard.set(maxCPUWorkers, forKey: DefaultsKey.maxCPUWorkers) }
    }
    @Published var maxBlendBatches = UserDefaults.standard.object(forKey: DefaultsKey.maxBlendBatches) as? Int ?? 2 {
        didSet { UserDefaults.standard.set(maxBlendBatches, forKey: DefaultsKey.maxBlendBatches) }
    }
    /// Format for the macOS job runner's scratch frames. PNG is lossless but
    /// ~8 MB per 4K frame; HEIC/JPEG are a fraction of the size and cheaper to
    /// encode, with a quality cost the final video encode swamps anyway.
    @Published var scratchFrameFormat: ImageFormat = ImageFormat(
        rawValue: UserDefaults.standard.string(forKey: DefaultsKey.scratchFrameFormat) ?? ""
    ) ?? .png {
        didSet { UserDefaults.standard.set(scratchFrameFormat.rawValue, forKey: DefaultsKey.scratchFrameFormat) }
    }
    /// When on, decoded frames stay in the job folder for inspection and for
    /// instant re-blends at other speeds. When off (default) each blend
    /// window's scratch is deleted as soon as its blended frame lands, so
    /// scratch stays bounded no matter how long the clip is.
    @Published var keepExtractedFrames = UserDefaults.standard.bool(forKey: DefaultsKey.keepExtractedFrames) {
        didSet { UserDefaults.standard.set(keepExtractedFrames, forKey: DefaultsKey.keepExtractedFrames) }
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
    @Published var processingStartedAt: Date?
    @Published var processingTotalInputFrames: Int?
    /// Live numbers reported by the macOS job runner; nil on the streaming
    /// (iOS) path, where the view falls back to extrapolating from progress.
    @Published var processingETASeconds: Double?
    @Published var processingFramesDone: Int?
    @Published var processingFramesTotal: Int?

    /// Set by screens that want the Projects tab to open a specific project
    /// (e.g. Result → Done). ContentView consumes and clears it.
    @Published var requestedProjectDetailID: UUID?

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

    func capture(for blend: BlendProject) -> CaptureProject? {
        captures.first { $0.id == blend.captureID }
    }

    func mediaKind(for capture: CaptureProject) -> MediaKind {
        capture.kind == .video ? .video : .image
    }

    func mediaKind(for blend: BlendProject) -> MediaKind {
        blend.kind == .video ? .video : .image
    }

    func mediaURL(for capture: CaptureProject) -> URL? {
        guard let source = try? source(for: capture) else { return nil }
        switch source {
        case .video(let url):
            return url
        case .liveSequence(let source):
            return source.primaryVideoURL
        case .photos(let urls):
            return urls.first
        }
    }

    func mediaURL(for blend: BlendProject) -> URL {
        blendOutputURL(for: blend)
    }

    /// The individual source video segments backing a capture. Live sequences
    /// have several; single imports have one; photo stacks have none.
    func sourceClipURLs(for capture: CaptureProject) -> [URL] {
        guard let source = try? source(for: capture) else { return [] }
        switch source {
        case .video(let url):
            return [url]
        case .liveSequence(let liveSource):
            return liveSource.segmentURLs
        case .photos:
            return []
        }
    }

    func deleteCapture(_ capture: CaptureProject) throws {
        guard captures.contains(where: { $0.id == capture.id }) else { return }
        if currentCaptureID == capture.id && stage == .processing {
            throw LibraryDeletionError.activeCapture
        }

        let folder = captureFolderURL(for: capture.id)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }

        captures.removeAll { $0.id == capture.id }
        blends.removeAll { $0.captureID == capture.id }
        try persistLibrary()

        if currentCaptureID == capture.id {
            reset()
        }
    }

    func deleteBlend(_ blend: BlendProject) throws {
        guard blends.contains(where: { $0.id == blend.id }) else { return }

        let captureFolder = captureFolderURL(for: blend.captureID).standardizedFileURL
        let output = blendOutputURL(for: blend).standardizedFileURL
        let capturePrefix = captureFolder.path.hasSuffix("/") ? captureFolder.path : captureFolder.path + "/"
        guard output.path.hasPrefix(capturePrefix) else {
            throw LibraryDeletionError.unsafeBlendPath
        }

        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }

        blends.removeAll { $0.id == blend.id }
        try persistLibrary()

        let blendsFolder = output.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: blendsFolder.path).isEmpty) == true {
            try? FileManager.default.removeItem(at: blendsFolder)
        }

        if resultBlendID == blend.id {
            resultBlendID = nil
            resultVideoURL = nil
            resultImage = nil
            resultImageURL = nil
            resultSummary = nil
            saveConfirmation = nil
            jobFolderURL = nil
            jobLogLines = []
            stage = source == nil ? .home : .configure
        }
    }

    func setSource(_ source: Source, mode: String = "Import") {
        do {
            let capture = try registerCapture(from: source, mode: mode)
            openCapture(capture)
        } catch {
            errorMessage = "Couldn't preserve the capture: \(error.localizedDescription)"
        }
    }

    func setSequenceSource(_ result: LiveCaptureResult) {
        do {
            let capture = try registerSequenceCapture(result)
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
        photoBlendDepth = 1
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
        processingStartedAt = nil
        processingTotalInputFrames = nil
        processingETASeconds = nil
        processingFramesDone = nil
        processingFramesTotal = nil
        stage = .home
    }

    /// Wrap up the flow. When `openProject` is set the Projects tab opens the
    /// project this run belonged to, so a finished clip is never a dead end.
    func finishFlow(openProject: Bool) {
        let captureID = currentCaptureID
        reset()
        if openProject, let captureID {
            requestedProjectDetailID = captureID
        }
    }

    func openCapture(_ capture: CaptureProject) {
        do {
            blendSourceCodec = nil
            source = try source(for: capture)
            currentCaptureID = capture.id
            photoBlendDepth = 1
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
            blendSourceCodec = nil
            source = try source(for: capture)
            currentCaptureID = capture.id
            resultBlendID = blend.id
            resultVideoURL = nil
            resultImage = nil
            resultImageURL = nil
            resultSummary = blend.summary

            if let compressionRatio = blend.compressionRatio {
                if source?.isVideo == true {
                    constantWindow = compressionRatio
                } else {
                    photoBlendDepth = compressionRatio
                }
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
        useRamp
            ? BlendRamp(startWindow: rampStart, endWindow: rampEnd, curve: curve)
            : .constant(constantWindow)
    }

    /// For a photo source, how many output frames the current blend depth
    /// yields — each window of `photoBlendDepth` stills becomes one frame.
    var photoOutputFrameCount: Int? {
        guard let capture = currentCapture, capture.kind == .photos else { return nil }
        let count = capture.sourceMediaCount
        guard count > 0 else { return nil }
        return WindowSchedule.make(totalInputFrames: count, ramp: .constant(photoBlendDepth)).count
    }

    /// True when the blend depth folds every still into one frame — the classic
    /// single stacked long-exposure image rather than a video sequence.
    var photosProduceSingleImage: Bool {
        guard let capture = currentCapture, capture.kind == .photos else { return false }
        let count = capture.sourceMediaCount
        return count > 0 && photoBlendDepth >= count
    }

    // MARK: - Estimates

    /// Source frames the current settings would feed into the blend, after trim.
    var estimatedInputFrames: Double? {
        guard let capture = currentCapture else { return nil }
        switch capture.kind {
        case .photos:
            return Double(capture.sourceMediaCount)
        case .video:
            guard var duration = capture.sourceDurationSeconds else {
                if let known = blends(for: capture).compactMap(\.inputFrames).max() {
                    return Double(known)
                }
                return nil
            }
            if case .video = source, trimVideoEnds {
                duration = max(0, duration - 2 * max(0, trimHeadTailSeconds))
            }
            return duration * (capture.sourceFPS ?? 30)
        }
    }

    /// The one number that matters: how long the clip will be. `speed` defaults
    /// to the current setting; ramps are approximated by their average window.
    func estimatedOutputSeconds(speed: Int? = nil) -> Double? {
        guard source?.isVideo == true, let frames = estimatedInputFrames else { return nil }
        let window: Int
        if let speed {
            window = speed
        } else if useRamp {
            window = max(1, (rampStart + rampEnd) / 2)
        } else {
            window = constantWindow
        }
        return SpeedMath.outputSeconds(inputFrames: frames, speed: window, outputFPS: outputFPS)
    }

    /// A different speed worth trying next, for the Result screen's suggestion.
    func suggestedAlternateSpeed() -> Int? {
        guard source?.isVideo == true, !useRamp else { return nil }
        let current = constantWindow
        let candidate = current >= 50 ? current / 2 : current * 2
        let clamped = min(max(candidate, SpeedMath.range.lowerBound), SpeedMath.range.upperBound)
        return clamped == current ? nil : clamped
    }

    // MARK: - Projects & versions

    func versionNumber(for blend: BlendProject) -> Int {
        let siblings = blends
            .filter { $0.captureID == blend.captureID }
            .sorted { $0.createdAt < $1.createdAt }
        return (siblings.firstIndex { $0.id == blend.id } ?? max(0, siblings.count - 1)) + 1
    }

    func renameProject(_ capture: CaptureProject, to newName: String) {
        guard let index = captures.firstIndex(where: { $0.id == capture.id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        captures[index].name = trimmed.isEmpty ? nil : trimmed
        try? persistLibrary()
    }

    // MARK: - Storage

    struct LibraryStorage: Equatable {
        var originalsBytes: Int64 = 0
        var versionsBytes: Int64 = 0
        var cacheBytes: Int64 = 0

        var totalBytes: Int64 { originalsBytes + versionsBytes + cacheBytes }
    }

    func computeLibraryStorage() async -> LibraryStorage {
        let root = projectsRootURL
        let temporary = FileManager.default.temporaryDirectory
        return await Task.detached(priority: .utility) {
            var storage = LibraryStorage()
            let fileManager = FileManager.default
            if let folders = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
                for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    storage.originalsBytes += Self.directorySize(folder.appendingPathComponent("source"))
                    storage.versionsBytes += Self.directorySize(folder.appendingPathComponent("blends"))
                }
            }
            if let items = try? fileManager.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil) {
                for item in items where Self.isCacheItem(item) {
                    storage.cacheBytes += Self.directorySize(item)
                }
            }
            return storage
        }.value
    }

    func storageBytes(for capture: CaptureProject) async -> Int64 {
        let folder = captureFolderURL(for: capture.id)
        return await Task.detached(priority: .utility) {
            Self.directorySize(folder)
        }.value
    }

    /// Deletes reproducible temp files (imports, live-capture staging, blend
    /// scratch). Returns the number of bytes freed.
    @discardableResult
    func clearCache() async -> Int64 {
        let temporary = FileManager.default.temporaryDirectory
        return await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            var freed: Int64 = 0
            guard let items = try? fileManager.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil) else {
                return freed
            }
            for item in items where Self.isCacheItem(item) {
                let size = Self.directorySize(item)
                do {
                    try fileManager.removeItem(at: item)
                    freed += size
                } catch {
                    continue
                }
            }
            return freed
        }.value
    }

    nonisolated private static func isCacheItem(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasPrefix("letslapse") || name.hasPrefix(".letslapse")
            || name.hasPrefix("live-capture") || name.hasPrefix("picked-")
            || name.hasPrefix("import-")
    }

    nonisolated static func directorySize(_ url: URL) -> Int64 {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
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
        processingStartedAt = Date()
        processingTotalInputFrames = estimatedInputFrames.map { Int($0.rounded()) }
        processingETASeconds = nil
        processingFramesDone = nil
        processingFramesTotal = nil
        let ramp = self.ramp
        let fps = Double(outputFPS)
        let linear = linearLight
        let trim = source.isVideo && trimVideoEnds ? max(0, trimHeadTailSeconds) : 0
        let photoDepth = photoBlendDepth
        let parameters = currentBlendParameters()
        blendTask = Task { [weak self] in
            do {
                guard let self else { return }
                let output: ProcessingOutput
                switch source {
                case .video(let url):
                    output = try await self.blendVideo(url: url, ramp: ramp, fps: fps, linear: linear, trimHeadTailSeconds: trim)
                case .liveSequence(let liveSource):
                    output = try await self.blendLiveSequence(liveSource, ramp: ramp, fps: fps, linear: linear)
                case .photos(let urls):
                    if photoDepth >= urls.count {
                        // The blend depth spans every still, so fold them all
                        // into one frame: the classic single long exposure.
                        output = try await self.stackPhotos(urls: urls, linear: linear)
                    } else {
                        // A depth of 1 gives a straight timelapse; larger
                        // depths blend consecutive stills into each frame for
                        // motion blur. Output is a video sequence.
                        output = try await self.blendPhotosSequence(
                            urls: urls, ramp: .constant(photoDepth), fps: fps, linear: linear)
                    }
                }
                let blend = try self.storeBlend(output, captureID: captureID, parameters: parameters)
                self.apply(output, from: blend)
                self.processingStartedAt = nil
                self.stage = .done
            } catch is CancellationError {
                self?.processingStartedAt = nil
                self?.stage = .configure
            } catch LapseError.cancelled {
                self?.processingStartedAt = nil
                self?.stage = .configure
            } catch {
                self?.processingStartedAt = nil
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
                    maxBlendBatches: maxBlendBatches,
                    extractFormat: scratchFrameFormat,
                    keepExtractedFrames: keepExtractedFrames
                )
            ) { update in
                Task { @MainActor [weak self] in
                    // Batches still in flight after a cancel keep reporting;
                    // once the processing screen is gone, drop their updates.
                    guard let self, self.stage == .processing else { return }
                    self.progress = update.fraction
                    self.statusMessage = update.message
                    self.jobFolderURL = update.jobFolderURL
                    self.jobLogLines = update.recentLogLines
                    self.processingETASeconds = update.etaSeconds
                    if let done = update.framesDone { self.processingFramesDone = done }
                    if let total = update.framesTotal { self.processingFramesTotal = total }
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

    private func blendLiveSequence(
        _ source: LiveCaptureSource,
        ramp: BlendRamp,
        fps: Double,
        linear: Bool
    ) async throws -> ProcessingOutput {
        guard !source.segmentURLs.isEmpty else { throw LapseError.noInputFrames }

        guard source.sequence.mode == .ramp else {
            return try await blendMarkerSequence(source, ramp: ramp, fps: fps, linear: linear)
        }

        let segmentURLByName = source.resolvedByOriginalName
        let orderedSegments = source.sequence.segments.sorted { $0.index < $1.index }
        guard !orderedSegments.isEmpty else {
            let fallbackURL = source.segmentURLs[0]
            return try await blendVideo(url: fallbackURL, ramp: ramp, fps: fps, linear: linear, trimHeadTailSeconds: 0)
        }

        var processedURLs: [URL] = []
        var inputFrames = 0
        var outputFrames = 0
        var outputWidth: Int?
        var outputHeight: Int?
        let totalSegments = orderedSegments.count

        for (index, segment) in orderedSegments.enumerated() {
            guard let segmentURL = segmentURLByName[segment.fileName] else {
                throw CocoaError(.fileNoSuchFile)
            }
            let isRampOn = segmentIsRampOn(segment, in: source.sequence)
            statusMessage = isRampOn
                ? "Blending ramp segment \(index + 1) / \(totalSegments) at playback speed..."
                : "Blending base segment \(index + 1) / \(totalSegments)..."
            let segmentOutput = try await blendVideo(
                url: segmentURL,
                ramp: isRampOn ? .constant(1) : ramp,
                fps: fps,
                linear: linear,
                trimHeadTailSeconds: 0
            )
            processedURLs.append(segmentOutput.url)
            inputFrames += segmentOutput.inputFrames ?? 0
            outputFrames += segmentOutput.outputFrames ?? 0
            outputWidth = outputWidth ?? segmentOutput.width
            outputHeight = outputHeight ?? segmentOutput.height
            progress = Double(index + 1) / Double(max(1, totalSegments)) * 0.9
        }

        statusMessage = "Stitching \(processedURLs.count) processed segments..."
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("LetsLapse-sequence-\(Int(Date().timeIntervalSince1970)).mp4")
        let stitched = try await stitchVideos(processedURLs, to: output)
        progress = 1

        let summary = "\(inputFrames) frames in → \(outputFrames) frames out · "
            + "\(stitched.width)×\(stitched.height) · "
            + "\(source.sequence.rampIntervals.count) ramp intervals stitched"
        return ProcessingOutput(
            kind: .video,
            url: output,
            image: nil,
            summary: summary,
            inputFrames: inputFrames,
            outputFrames: outputFrames,
            width: outputWidth ?? stitched.width,
            height: outputHeight ?? stitched.height
        )
    }

    private struct MarkerSequencePiece {
        var range: ClosedRange<Double>
        var isRampOn: Bool
    }

    private func blendMarkerSequence(
        _ source: LiveCaptureSource,
        ramp: BlendRamp,
        fps: Double,
        linear: Bool
    ) async throws -> ProcessingOutput {
        guard let sourceURL = source.primaryVideoURL else { throw LapseError.noInputFrames }
        let pieces = try await markerSequencePieces(for: source, sourceURL: sourceURL)
        guard !pieces.isEmpty else {
            return try await blendVideo(url: sourceURL, ramp: ramp, fps: fps, linear: linear, trimHeadTailSeconds: 0)
        }

        var processedURLs: [URL] = []
        var inputFrames = 0
        var outputFrames = 0
        var outputWidth: Int?
        var outputHeight: Int?

        for (index, piece) in pieces.enumerated() {
            statusMessage = piece.isRampOn
                ? "Rendering marker interval \(index + 1) / \(pieces.count) at playback speed..."
                : "Blending marker interval \(index + 1) / \(pieces.count)..."

            let clipURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("LetsLapse-marker-piece-\(UUID().uuidString).mov")
            try await extractVideoRange(
                sourceURL,
                from: piece.range.lowerBound,
                to: piece.range.upperBound,
                outputURL: clipURL
            )

            let pieceOutput = try await blendVideo(
                url: clipURL,
                ramp: piece.isRampOn ? .constant(1) : ramp,
                fps: fps,
                linear: linear,
                trimHeadTailSeconds: 0
            )
            processedURLs.append(pieceOutput.url)
            inputFrames += pieceOutput.inputFrames ?? 0
            outputFrames += pieceOutput.outputFrames ?? 0
            outputWidth = outputWidth ?? pieceOutput.width
            outputHeight = outputHeight ?? pieceOutput.height
            progress = Double(index + 1) / Double(max(1, pieces.count)) * 0.9
        }

        statusMessage = "Stitching \(processedURLs.count) processed marker intervals..."
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("LetsLapse-marker-sequence-\(Int(Date().timeIntervalSince1970)).mp4")
        let stitched = try await stitchVideos(processedURLs, to: output)
        progress = 1

        let summary = "\(inputFrames) frames in → \(outputFrames) frames out · "
            + "\(stitched.width)×\(stitched.height) · "
            + "\(source.sequence.rampIntervals.count) marker ramp intervals stitched"
        return ProcessingOutput(
            kind: .video,
            url: output,
            image: nil,
            summary: summary,
            inputFrames: inputFrames,
            outputFrames: outputFrames,
            width: outputWidth ?? stitched.width,
            height: outputHeight ?? stitched.height
        )
    }

    private func markerSequencePieces(
        for source: LiveCaptureSource,
        sourceURL: URL
    ) async throws -> [MarkerSequencePiece] {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { return [] }

        let sequenceStart = source.sequence.segments.first?.relativeStart ?? 0
        let sequenceEnd = source.sequence.segments.first?.relativeEnd ?? (sequenceStart + duration)
        let rampRanges = source.sequence.rampIntervals
            .compactMap { interval -> ClosedRange<Double>? in
                let intervalEnd = interval.relativeEnd ?? sequenceEnd
                let start = max(0, interval.relativeStart - sequenceStart)
                let end = min(duration, intervalEnd - sequenceStart)
                guard end > start else { return nil }
                return start...end
            }
            .sorted { $0.lowerBound < $1.lowerBound }

        guard !rampRanges.isEmpty else { return [] }

        var mergedRampRanges: [ClosedRange<Double>] = []
        for range in rampRanges {
            guard let last = mergedRampRanges.last else {
                mergedRampRanges.append(range)
                continue
            }
            if range.lowerBound <= last.upperBound {
                mergedRampRanges[mergedRampRanges.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                mergedRampRanges.append(range)
            }
        }

        let minimumDuration = 0.05
        var pieces: [MarkerSequencePiece] = []
        var cursor = 0.0
        for range in mergedRampRanges {
            if range.lowerBound - cursor > minimumDuration {
                pieces.append(MarkerSequencePiece(range: cursor...range.lowerBound, isRampOn: false))
            }
            if range.upperBound - range.lowerBound > minimumDuration {
                pieces.append(MarkerSequencePiece(range: range.lowerBound...range.upperBound, isRampOn: true))
            }
            cursor = max(cursor, range.upperBound)
        }
        if duration - cursor > minimumDuration {
            pieces.append(MarkerSequencePiece(range: cursor...duration, isRampOn: false))
        }
        return pieces
    }

    private func extractVideoRange(
        _ sourceURL: URL,
        from start: Double,
        to end: Double,
        outputURL: URL
    ) async throws {
        guard end > start else { throw LapseError.noInputFrames }
        try? FileManager.default.removeItem(at: outputURL)

        let asset = AVURLAsset(url: sourceURL)
        guard let export = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw LapseError.writerFailed("could not create marker interval export session")
        }
        export.outputURL = outputURL
        export.outputFileType = .mov
        export.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: end - start, preferredTimescale: 600)
        )
        export.shouldOptimizeForNetworkUse = true
        let exportBox = ExportSessionBox(export)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportBox.session.exportAsynchronously {
                switch exportBox.session.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: LapseError.writerFailed(
                        exportBox.session.error?.localizedDescription ?? "marker interval export failed"
                    ))
                case .cancelled:
                    continuation.resume(throwing: LapseError.cancelled)
                default:
                    continuation.resume(throwing: LapseError.writerFailed("marker interval export did not complete"))
                }
            }
        }
    }

    private func segmentIsRampOn(
        _ segment: LiveCaptureSequence.Segment,
        in sequence: LiveCaptureSequence
    ) -> Bool {
        if sequence.mode == .ramp {
            return segment.frameRate > sequence.baseFrameRate
        }
        return sequence.rampIntervals.contains { interval in
            let intervalEnd = interval.relativeEnd ?? segment.relativeEnd
            return interval.relativeStart < segment.relativeEnd
                && intervalEnd > segment.relativeStart
        }
    }

    private func stitchVideos(_ urls: [URL], to outputURL: URL) async throws -> (width: Int, height: Int) {
        guard !urls.isEmpty else { throw LapseError.noInputFrames }
        try? FileManager.default.removeItem(at: outputURL)

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw LapseError.writerFailed("could not create composition track")
        }

        var cursor = CMTime.zero
        var outputSize: CGSize?
        var transform = CGAffineTransform.identity
        // Created lazily on the first segment that carries sound (Record
        // audio setting); a failed audio insert never fails the stitch.
        var audioCompositionTrack: AVMutableCompositionTrack?

        for (index, url) in urls.enumerated() {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw LapseError.noVideoTrack(url)
            }
            let duration = try await asset.load(.duration)
            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: track,
                at: cursor
            )
            if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first {
                if audioCompositionTrack == nil {
                    audioCompositionTrack = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                }
                try? audioCompositionTrack?.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: audioTrack,
                    at: cursor
                )
            }
            cursor = cursor + duration

            if index == 0 {
                let naturalSize = try await track.load(.naturalSize)
                transform = try await track.load(.preferredTransform)
                outputSize = CGRect(origin: .zero, size: naturalSize)
                    .applying(transform)
                    .standardized
                    .size
            }
        }
        compositionTrack.preferredTransform = transform

        guard let export = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw LapseError.writerFailed("could not create export session")
        }
        export.outputURL = outputURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        let exportBox = ExportSessionBox(export)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportBox.session.exportAsynchronously {
                switch exportBox.session.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: LapseError.writerFailed(
                        exportBox.session.error?.localizedDescription ?? "sequence export failed"
                    ))
                case .cancelled:
                    continuation.resume(throwing: LapseError.cancelled)
                default:
                    continuation.resume(throwing: LapseError.writerFailed("sequence export did not complete"))
                }
            }
        }

        let size = outputSize ?? .zero
        return (Int(abs(size.width).rounded()), Int(abs(size.height).rounded()))
    }

    /// Blends a sequence of interval stills into a timelapse video. Each output
    /// frame averages `ramp`-worth of consecutive stills, so `constantWindow`
    /// doubles as the blend depth (1 = crisp timelapse, higher = motion blur).
    private func blendPhotosSequence(
        urls: [URL],
        ramp: BlendRamp,
        fps: Double,
        linear: Bool
    ) async throws -> ProcessingOutput {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("LetsLapse-\(Int(Date().timeIntervalSince1970)).mp4")
        let result = try await Task.detached(priority: .userInitiated) { [weak self] () throws -> StackSequenceResult in
            let core = try BlendCore()
            let stacker = ImageStacker(core: core)
            return try stacker.stackSequence(
                imageURLs: urls,
                ramp: ramp,
                outputFPS: fps,
                linearLight: linear,
                outputURL: output
            ) { fraction in
                Task { @MainActor in
                    self?.progress = fraction
                }
            }
        }.value
        let summary = "\(urls.count) photos → \(result.outputFrames) frames · \(result.width)×\(result.height)"
        return ProcessingOutput(
            kind: .video,
            url: output,
            image: nil,
            summary: summary,
            inputFrames: urls.count,
            outputFrames: result.outputFrames,
            width: result.width,
            height: result.height
        )
    }

    /// Legacy single-image stack: averages every still into one synthetic long
    /// exposure. No longer the default for interval capture — kept for callers
    /// that explicitly want one frame out.
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
            compressionRatio: source?.isVideo == true ? constantWindow : photoBlendDepth,
            outputFPS: outputFPS,
            linearLight: linearLight,
            useRamp: useRamp && source?.isVideo == true,
            rampStart: rampStart,
            rampEnd: rampEnd,
            curve: curve.rawValue,
            trimHeadTailSeconds: source?.isVideo == true && trimVideoEnds ? max(0, trimHeadTailSeconds) : nil,
            width: nil,
            height: nil,
            inputFrames: nil,
            outputFrames: nil,
            sourceCodec: source?.isVideo == true ? blendSourceCodec?.rawValue : nil
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
        case .liveSequence(let liveSource):
            return try registerSequenceCapture(LiveCaptureResult(
                sequence: liveSource.sequence,
                segmentURLs: liveSource.segmentURLs,
                metadataURL: liveSource.metadataURL
            ))
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

    private func registerSequenceCapture(_ result: LiveCaptureResult) throws -> CaptureProject {
        let id = UUID()
        let root = captureFolderURL(for: id)
        let sourceFolder = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)

        var relativeNames: [String] = []
        for (index, url) in result.segmentURLs.enumerated() {
            let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
            let relativeName = String(format: "source/segment-%03d.%@", index, ext)
            let destination = root.appendingPathComponent(relativeName)
            try copyReplacingItem(at: url, to: destination)
            relativeNames.append(relativeName)
        }

        let metadataName = "source/sequence.json"
        try copyReplacingItem(at: result.metadataURL, to: root.appendingPathComponent(metadataName))
        relativeNames.append(metadataName)

        let capture = CaptureProject(
            id: id,
            kind: .video,
            createdAt: result.sequence.createdAt,
            originalName: result.sequence.mode == .ramp ? "Ramp capture" : "Marker capture",
            mode: result.sequence.summary,
            sourceFileNames: relativeNames,
            sourceFPS: nil
        )

        captures.insert(capture, at: 0)
        try persistLibrary()
        Task { [weak self] in
            await self?.refreshVideoMetadata(for: capture.id)
        }
        return capture
    }

    private func source(
        for capture: CaptureProject,
        preferring codec: OutputCodec? = nil
    ) throws -> Source {
        let root = captureFolderURL(for: capture.id)
        let metadataURL = root.appendingPathComponent("source/sequence.json")
        let clipNames = capture.sourceFileNames.filter { !$0.hasSuffix(".json") }

        switch capture.kind {
        case .photos:
            let urls = clipNames.map { root.appendingPathComponent($0) }
            for url in urls where !FileManager.default.fileExists(atPath: url.path) {
                throw CocoaError(.fileNoSuchFile)
            }
            return .photos(urls)
        case .video:
            // Each logical clip resolves to the preferred codec when present,
            // else its best surviving encoding — so deleting a ProRes original
            // (once converted) doesn't break playback or blending.
            var resolvedURLs: [URL] = []
            var resolvedByName: [String: URL] = [:]
            for relName in clipNames {
                guard let url = activeEncodingURL(for: capture, clip: relName, preferring: codec) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                resolvedURLs.append(url)
                resolvedByName[(relName as NSString).lastPathComponent] = url
            }

            if FileManager.default.fileExists(atPath: metadataURL.path) {
                let data = try Data(contentsOf: metadataURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let sequence = try decoder.decode(LiveCaptureSequence.self, from: data)
                return .liveSequence(LiveCaptureSource(
                    sequence: sequence,
                    segmentURLs: resolvedURLs,
                    metadataURL: metadataURL,
                    resolvedByOriginalName: resolvedByName
                ))
            }
            guard let url = resolvedURLs.first else { throw CocoaError(.fileNoSuchFile) }
            return .video(url)
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
            for capture in captures
            where capture.kind == .video
                && (capture.sourceFPS == nil || capture.sourceDurationSeconds == nil || capture.sourceWidth == nil) {
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
        guard let capture = captures.first(where: { $0.id == captureID }),
              let captureSource = try? source(for: capture) else { return }

        let urls: [URL]
        switch captureSource {
        case .video(let url):
            urls = [url]
        case .liveSequence(let liveSource):
            urls = liveSource.segmentURLs
        case .photos:
            return
        }

        var totalDuration: Double = 0
        var fps: Double?
        var width: Int?
        var height: Int?

        for url in urls {
            let asset = AVURLAsset(url: url)
            if let duration = try? await asset.load(.duration).seconds, duration.isFinite {
                totalDuration += duration
            }
            guard fps == nil || width == nil,
                  let track = try? await asset.loadTracks(withMediaType: .video).first else { continue }
            if fps == nil, let rate = try? await track.load(.nominalFrameRate), rate > 0 {
                fps = Double(rate)
            }
            if width == nil,
               let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let rect = CGRect(origin: .zero, size: size).applying(transform).standardized
                if rect.width > 0, rect.height > 0 {
                    width = Int(abs(rect.width).rounded())
                    height = Int(abs(rect.height).rounded())
                }
            }
        }

        guard let index = captures.firstIndex(where: { $0.id == captureID }) else { return }
        if let fps { captures[index].sourceFPS = fps }
        if totalDuration > 0 { captures[index].sourceDurationSeconds = totalDuration }
        if let width, let height {
            captures[index].sourceWidth = width
            captures[index].sourceHeight = height
        }
        try? persistLibrary()
    }

    // MARK: - Clip conversion

    enum ConvertClipError: LocalizedError {
        case noVideoTrack
        case encodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:
                return "This clip has no video track to convert."
            case .encodingFailed(let reason):
                return "Couldn't convert the clip: \(reason)"
            }
        }
    }

    private static let conversionQueue = DispatchQueue(
        label: "com.letslapse.convert", qos: .userInitiated)

    /// FourCC subtypes for the ProRes family, matching the capture-side check
    /// in `CameraController`: 'apcn' 422, 'apch' 422 HQ, 'apcs' 422 LT,
    /// 'apco' 422 Proxy, 'ap4h' 4444, 'ap4x' 4444 XQ.
    private static let proResFourCCs: Set<FourCharCode> = [
        0x6170636e, 0x61706368, 0x61706373, 0x6170636f, 0x61703468, 0x61703478,
    ]

    /// Whether a clip's video track is encoded with a ProRes codec — the cue
    /// for offering a smaller-file H.264/HEVC conversion.
    nonisolated static func sourceClipIsProRes(at url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let descriptions = try? await track.load(.formatDescriptions)
        else { return false }
        return descriptions.contains {
            proResFourCCs.contains(CMFormatDescriptionGetMediaSubType($0))
        }
    }

    enum EncodingDeletionError: LocalizedError {
        case lastEncoding

        var errorDescription: String? {
            switch self {
            case .lastEncoding:
                return "This is the clip's only file. Convert it to another format before deleting this one."
            }
        }
    }

    /// The logical source clips of a capture, as their original relative file
    /// names (the stable identity used to key encodings).
    func sourceClipNames(for capture: CaptureProject) -> [String] {
        capture.sourceFileNames.filter { !$0.hasSuffix(".json") }
    }

    /// Absolute URL of a specific encoding inside the capture folder.
    func encodingURL(for capture: CaptureProject, _ encoding: ClipEncoding) -> URL {
        captureFolderURL(for: capture.id).appendingPathComponent(encoding.fileName)
    }

    /// Every encoding of one logical clip: the stored list once the clip has
    /// been converted, otherwise the implicit single original file.
    func encodings(for capture: CaptureProject, clip clipFileName: String) -> [ClipEncoding] {
        if let stored = capture.clipEncodings?[clipFileName], !stored.isEmpty {
            return stored
        }
        return [ClipEncoding(codec: "", fileName: clipFileName)]
    }

    /// The file the app should actually use for a logical clip — the preferred
    /// codec when it exists, else the best surviving encoding (quality-first).
    func activeEncodingURL(
        for capture: CaptureProject,
        clip clipFileName: String,
        preferring codec: OutputCodec? = nil
    ) -> URL? {
        let existing = encodings(for: capture, clip: clipFileName).filter {
            FileManager.default.fileExists(atPath: encodingURL(for: capture, $0).path)
        }
        guard !existing.isEmpty else { return nil }
        if let codec, let match = existing.first(where: { $0.codec == codec.rawValue }) {
            return encodingURL(for: capture, match)
        }
        let priority = [OutputCodec.prores.rawValue, OutputCodec.hevc.rawValue, OutputCodec.h264.rawValue]
        let chosen = priority.compactMap { rawValue in
            existing.first { $0.codec == rawValue }
        }.first ?? existing[0]
        return encodingURL(for: capture, chosen)
    }

    /// Codecs the blend can draw from across all of a capture's clips, ordered
    /// quality-first. Empty when there's no real choice (nothing converted yet).
    func availableBlendCodecs(for capture: CaptureProject) -> [OutputCodec] {
        var present: Set<String> = []
        for clipName in sourceClipNames(for: capture) {
            for encoding in encodings(for: capture, clip: clipName)
            where FileManager.default.fileExists(atPath: encodingURL(for: capture, encoding).path) {
                present.insert(encoding.codec)
            }
        }
        let available: [OutputCodec] = [.prores, .hevc, .h264].filter { present.contains($0.rawValue) }
        return available.count > 1 ? available : []
    }

    /// Re-point the in-flight blend source at a specific codec (`nil` = auto,
    /// best surviving encoding per clip). Used by the Adjust "Blend from" picker.
    func setBlendSourceCodec(_ codec: OutputCodec?) {
        blendSourceCodec = codec
        guard let capture = currentCapture else { return }
        source = try? source(for: capture, preferring: codec)
    }

    /// Re-encodes a ProRes source clip into a sibling file inside the project's
    /// `source/` folder and registers it as an extra encoding of that clip.
    @discardableResult
    func addEncoding(
        for capture: CaptureProject,
        clip clipFileName: String,
        codec: OutputCodec
    ) async throws -> URL {
        let root = captureFolderURL(for: capture.id)
        let sourceURL = root.appendingPathComponent(clipFileName)
        let base = ((clipFileName as NSString).lastPathComponent as NSString).deletingPathExtension
        let newRelName = "source/\(base)-\(codec.rawValue).\(codec.preferredExtension)"
        let outputURL = root.appendingPathComponent(newRelName)
        try await Self.transcode(from: sourceURL, to: outputURL, codec: codec)

        guard let index = captures.firstIndex(where: { $0.id == capture.id }) else { return outputURL }
        // Materialise the original as its own (ProRes) encoding the first time.
        var list = captures[index].clipEncodings?[clipFileName]
            ?? [ClipEncoding(codec: OutputCodec.prores.rawValue, fileName: clipFileName)]
        if !list.contains(where: { $0.fileName == newRelName }) {
            list.append(ClipEncoding(codec: codec.rawValue, fileName: newRelName))
        }
        var map = captures[index].clipEncodings ?? [:]
        map[clipFileName] = list
        captures[index].clipEncodings = map
        try persistLibrary()
        return outputURL
    }

    /// Deletes one encoding of a clip, including the ProRes original once a
    /// conversion exists. Refuses to remove a clip's only remaining file.
    func deleteEncoding(
        for capture: CaptureProject,
        clip clipFileName: String,
        _ encoding: ClipEncoding
    ) throws {
        guard let index = captures.firstIndex(where: { $0.id == capture.id }) else { return }
        // Read the live capture, not the caller's snapshot, so a delete that
        // follows a convert (e.g. bulk purge) sees the newly added encoding.
        let fresh = captures[index]
        let list = encodings(for: fresh, clip: clipFileName)
        let existing = list.filter {
            FileManager.default.fileExists(atPath: encodingURL(for: fresh, $0).path)
        }
        guard existing.count > 1 else { throw EncodingDeletionError.lastEncoding }

        let url = encodingURL(for: fresh, encoding)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let newList = list.filter { $0.fileName != encoding.fileName }
        var map = captures[index].clipEncodings ?? [:]
        map[clipFileName] = newList
        captures[index].clipEncodings = map.isEmpty ? nil : map
        try persistLibrary()
    }

    /// One-tap storage reclaim: convert every ProRes clip in a capture to H.264
    /// and delete the ProRes originals. Skips clips already free of ProRes.
    func convertAllProResToH264Purging(for capture: CaptureProject) async throws {
        for clipName in sourceClipNames(for: capture) {
            let originalURL = captureFolderURL(for: capture.id).appendingPathComponent(clipName)
            guard FileManager.default.fileExists(atPath: originalURL.path),
                  await Self.sourceClipIsProRes(at: originalURL) else { continue }
            _ = try await addEncoding(for: capture, clip: clipName, codec: .h264)
            let proResEncoding = ClipEncoding(codec: OutputCodec.prores.rawValue, fileName: clipName)
            try deleteEncoding(for: capture, clip: clipName, proResEncoding)
        }
    }

    nonisolated private static func transcode(
        from sourceURL: URL,
        to outputURL: URL,
        codec: OutputCodec
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            throw ConvertClipError.noVideoTrack
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let nominalFPS = (try? await videoTrack.load(.nominalFrameRate)) ?? 30
        let fps = nominalFPS > 0 ? Double(nominalFPS) : 30
        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conversionQueue.async {
                do {
                    try runConversion(
                        asset: asset,
                        videoTrack: videoTrack,
                        naturalSize: naturalSize,
                        transform: transform,
                        fps: fps,
                        audioTrack: audioTrack ?? nil,
                        outputURL: outputURL,
                        codec: codec
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Blocking reader → writer transcode. Runs on `conversionQueue`; the media
    /// pumps run on their own queues so the `DispatchGroup.wait()` here is safe.
    nonisolated private static func runConversion(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        naturalSize: CGSize,
        transform: CGAffineTransform,
        fps: Double,
        audioTrack: AVAssetTrack?,
        outputURL: URL,
        codec: OutputCodec
    ) throws {
        try? FileManager.default.removeItem(at: outputURL)

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: outputURL, fileType: codec.fileType)
        } catch {
            throw ConvertClipError.encodingFailed(error.localizedDescription)
        }

        // HEVC is encoded 10-bit (Main10) to preserve the ProRes gradient, so it
        // decodes to a 10-bit pixel format; every other codec path stays 8-bit.
        let readerPixelFormat: OSType = codec == .hevc
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_32BGRA
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: readerPixelFormat])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw ConvertClipError.encodingFailed("cannot read the video track")
        }
        reader.add(videoOutput)

        let width = Int(abs(naturalSize.width))
        let height = Int(abs(naturalSize.height))
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        // Generous, resolution-aware bitrate so re-encoding doesn't introduce
        // compression banding that would unfairly sink the blend-quality test.
        let keyframeInterval = max(1, Int(fps.rounded()))
        let pixelsPerSecond = Double(width * height) * fps
        switch codec {
        case .h264:
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(pixelsPerSecond * 0.24),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: keyframeInterval,
            ]
        case .hevc:
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(pixelsPerSecond * 0.18),
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
                AVVideoMaxKeyFrameIntervalKey: keyframeInterval,
            ]
        case .jpeg:
            videoSettings[AVVideoCompressionPropertiesKey] = [AVVideoQualityKey: 0.95]
        case .prores:
            break
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else {
            throw ConvertClipError.encodingFailed("cannot write the video track")
        }
        writer.add(videoInput)

        // Passthrough audio: nil settings on both ends copies samples verbatim.
        var audioPair: (output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(output), writer.canAdd(input) {
                reader.add(output)
                writer.add(input)
                audioPair = (output, input)
            }
        }

        guard reader.startReading() else {
            throw ConvertClipError.encodingFailed(
                reader.error?.localizedDescription ?? "could not start reading")
        }
        guard writer.startWriting() else {
            throw ConvertClipError.encodingFailed(
                writer.error?.localizedDescription ?? "could not start writing")
        }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()

        group.enter()
        videoInput.requestMediaDataWhenReady(
            on: DispatchQueue(label: "com.letslapse.convert.video")) {
            while videoInput.isReadyForMoreMediaData {
                if let sample = videoOutput.copyNextSampleBuffer() {
                    if !videoInput.append(sample) {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                } else {
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
            }
        }

        if let audioPair {
            group.enter()
            audioPair.input.requestMediaDataWhenReady(
                on: DispatchQueue(label: "com.letslapse.convert.audio")) {
                while audioPair.input.isReadyForMoreMediaData {
                    if let sample = audioPair.output.copyNextSampleBuffer() {
                        if !audioPair.input.append(sample) {
                            audioPair.input.markAsFinished()
                            group.leave()
                            return
                        }
                    } else {
                        audioPair.input.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }

        group.wait()

        if reader.status == .reading { reader.cancelReading() }
        if reader.status == .failed {
            throw ConvertClipError.encodingFailed(
                reader.error?.localizedDescription ?? "reading failed")
        }

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw ConvertClipError.encodingFailed(
                writer.error?.localizedDescription ?? "could not finalize the file")
        }
    }

    #if os(iOS)
    enum SourceClipSaveError: LocalizedError {
        case accessDenied
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "Photos access was denied. Enable it in Settings to save clips."
            case .saveFailed(let reason):
                return "Couldn't save the clip: \(reason)"
            }
        }
    }

    /// Saves a single source clip to the Photos library. Requests add-only
    /// authorisation first and throws a descriptive error on denial or failure.
    func saveSourceClip(at url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw SourceClipSaveError.accessDenied
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
        } catch {
            throw SourceClipSaveError.saveFailed(error.localizedDescription)
        }
    }

    /// Saves every source clip of a capture to Photos, one after another.
    func saveAllSourceClips(for capture: CaptureProject) async throws {
        for url in sourceClipURLs(for: capture) {
            try await saveSourceClip(at: url)
        }
    }

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

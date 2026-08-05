import AVFoundation
import CoreLocation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The product-facing shape of on-device scene labelling.
///
/// Deliberately thin, and deliberately not `SceneAnalyser`: the actor speaks MLX and per-frame
/// generation, while callers want one call per capture and a result they can put on screen.
protocol SceneAnalyzing {
    var isAvailable: Bool { get }
    /// `status` is the progress line the row shows — a multi-frame pass takes long enough that one
    /// undifferentiated spinner reads as a hang.
    func analyze(
        _ request: SceneAnalysisRequest,
        status: (@Sendable (String) -> Void)?
    ) async throws -> SceneAnalysisResult
}

extension SceneAnalyzing {
    func analyze(_ request: SceneAnalysisRequest) async throws -> SceneAnalysisResult {
        try await analyze(request, status: nil)
    }
}

/// Which analyser the user's choice in Settings › AI Models resolves to.
///
/// The catalog entry names its own engine, so adding a backend is a catalog line plus a case here
/// rather than a decision spread across the callers.
enum SceneAnalyzerFactory {
    @MainActor
    static func active(models: ModelManager = .shared) -> any SceneAnalyzing {
        switch models.activeModel?.engine {
        case .visionFramework:
            return VisionSceneAnalyzer.shared
        case .mlx, nil:
            // Nil too: with nothing selected there is nothing to run, and the MLX path is the one
            // that says so properly (`Failure.noModel` names the screen that fixes it).
            return MLXSceneAnalyzer.shared
        }
    }
}

struct SceneAnalysisRequest {
    /// The frames to look at, in capture order. More than one is a sample of the whole capture,
    /// not alternatives — the result merges them.
    let imageURLs: [URL]
    let place: String?
    let light: String?
}

struct SceneAnalysisResult {
    /// Empty when the backend can't write natural language — Vision classifies, it doesn't
    /// describe. Callers keep the name the project already has rather than inventing one.
    let title: String
    let subjectTags: [String]
    let elements: [String]
    /// The light word, echoed back from the request where the caller supplied one. An analyser may
    /// infer it when the caller didn't; nobody overrides a light the app derived from the clock.
    let light: String?

    init(title: String, subjectTags: [String], elements: [String], light: String? = nil) {
        self.title = title
        self.subjectTags = subjectTags
        self.elements = elements
        self.light = light
    }
}

/// `SceneAnalyser` (Gemma 4 on MLX), driven by the model the user installed.
///
/// Multi-frame prompts need a patched engine and roughly half a gigabyte per extra frame, which an
/// 8 GB phone has no room for, so a multi-frame request is run one frame at a time and merged here
/// — the fallback Phase 0 measured and recommended for iOS.
@MainActor
final class MLXSceneAnalyzer: SceneAnalyzing {
    static let shared = MLXSceneAnalyzer()

    private let models: ModelManager

    init(models: ModelManager = .shared) {
        self.models = models
    }

    var isAvailable: Bool { models.isReady }

    func analyze(
        _ request: SceneAnalysisRequest,
        status: (@Sendable (String) -> Void)?
    ) async throws -> SceneAnalysisResult {
        guard let model = models.activeModel,
              let snapshot = models.snapshotDirectory(for: model)
        else { throw SceneAnalyser.Failure.noModel }

        guard !request.imageURLs.isEmpty else { throw SceneAnalyser.Failure.noModel }

        // The last gate before several gigabytes get touched. Past this line a device without the
        // headroom is killed rather than thrown from, so the check has to happen here.
        if let blocker = models.runtimeBlocker(for: model) {
            throw SceneAnalyser.Failure.insufficientMemory(blocker.message)
        }

        await SceneAnalyser.shared.use(snapshot: snapshot)

        var passes: [SceneMetadata] = []
        var lastError: Error?

        for (index, url) in request.imageURLs.enumerated() {
            let label = request.imageURLs.count > 1
                ? "Analysing frame \(index + 1) of \(request.imageURLs.count)…"
                : "Analysing…"
            status?(label)
            do {
                passes.append(try await SceneAnalyser.shared.analyse(
                    imageURL: url,
                    place: request.place,
                    light: request.light,
                    status: { line in status?(line) }))
            } catch let failure as SceneAnalyser.Failure {
                // A malformed generation on one frame is survivable when others succeed; a missing
                // model or an unloadable one is not, and rethrows immediately.
                switch failure {
                case .unavailable, .noModel, .insufficientMemory:
                    throw failure
                case .noJSON, .missingTitle:
                    lastError = failure
                }
            } catch {
                // Load and shape errors mean this model doesn't work on this engine — say so on
                // its row instead of leaving it looking installed and healthy.
                models.recordLoadFailure(error.localizedDescription, for: model.id)
                throw error
            }
        }

        guard !passes.isEmpty else {
            throw lastError ?? SceneAnalyser.Failure.noJSON("")
        }

        return Self.merge(passes, light: request.light)
    }

    /// Merges per-frame passes into one answer.
    ///
    /// Title: whichever wording two frames agreed on, else the middle frame's — the middle of a
    /// capture describes it better than its first instant does. Tags and elements: the union in
    /// first-seen order, which is how Phase 0 recovered the tag a single frame happened to drop.
    static func merge(_ passes: [SceneMetadata], light: String? = nil) -> SceneAnalysisResult {
        var titleCounts: [String: Int] = [:]
        for pass in passes { titleCounts[pass.title, default: 0] += 1 }
        let agreed = titleCounts.filter { $0.value > 1 }.max { $0.value < $1.value }?.key
        let title = agreed ?? passes[passes.count / 2].title

        var tags: [String] = []
        var elements: [String] = []
        for pass in passes {
            for tag in pass.tags where !tags.contains(tag) { tags.append(tag) }
            for element in pass.elements {
                let normalized = element.lowercased()
                if !elements.contains(where: { $0.lowercased() == normalized }) {
                    elements.append(element)
                }
            }
        }

        return SceneAnalysisResult(
            title: title,
            subjectTags: Array(tags.prefix(6)),
            elements: Array(elements.prefix(4)),
            light: light ?? passes.first?.light)
    }
}

// MARK: - Frame sampling

/// Turns a capture into the handful of frames the model should look at.
///
/// Every sampled frame is re-encoded as a ≤1024 px JPEG in a temporary folder first. That is the
/// size the vision tower resizes to anyway (280 soft tokens per frame), and it is the only way a
/// DNG interval frame is affordable — this app's own DNGs embed no preview, so handing one over
/// whole would mean a full-sensor RAW decode per frame.
enum SceneFrameSampler {
    /// What the capture is, in the only terms the sampler cares about.
    enum Source: Sendable {
        /// One photo — a Photo-mode capture's single asset.
        case photo(URL)
        /// An interval shoot's frames, in capture order.
        case stills([URL])
        /// A recording; frames are pulled from the movie itself.
        case video(URL)
    }

    /// Frames per source. A Photo project is one asset by definition; an interval shoot is
    /// summarised by its first, middle and last frame; a recording gets five spread across it,
    /// which is what catches a timelapse that changes light partway through.
    static func frameCount(for source: Source) -> Int {
        switch source {
        case .photo: return 1
        case .stills: return 3
        case .video: return 5
        }
    }

    /// The sampled frames as file URLs, plus the folder to delete when the analysis is done.
    struct Sample: Sendable {
        let frameURLs: [URL]
        let workingDirectory: URL
    }

    static func sample(_ source: Source) async throws -> Sample {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scene-analysis/\(UUID().uuidString)", isDirectory: true)

        return try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let frames: [URL]
            switch source {
            case .photo(let url):
                frames = stillFrames([url], into: directory)
            case .stills(let urls):
                frames = stillFrames(pick(urls, count: 3), into: directory)
            case .video(let url):
                frames = try await videoFrames(from: url, count: 5, into: directory)
            }
            guard !frames.isEmpty else { throw SamplingError.noFrames }
            return Sample(frameURLs: frames, workingDirectory: directory)
        }.value
    }

    static func cleanUp(_ sample: Sample) {
        try? FileManager.default.removeItem(at: sample.workingDirectory)
    }

    enum SamplingError: LocalizedError {
        case noFrames

        var errorDescription: String? {
            "Couldn't read any frames from this project."
        }
    }

    // MARK: Internals

    private static let maxPixelSize = 1024

    /// First, middle, last — evenly spread when more are asked for. Never duplicates a frame.
    private static func pick(_ urls: [URL], count: Int) -> [URL] {
        guard urls.count > count else { return urls }
        let step = Double(urls.count - 1) / Double(count - 1)
        var picked: [URL] = []
        for index in 0..<count {
            let position = Int((Double(index) * step).rounded())
            let url = urls[min(position, urls.count - 1)]
            if !picked.contains(url) { picked.append(url) }
        }
        return picked
    }

    private static func stillFrames(_ urls: [URL], into directory: URL) -> [URL] {
        urls.enumerated().compactMap { index, url in
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                // Bake EXIF orientation: a portrait frame described as landscape is a portrait
                // frame the model reads sideways.
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return nil }
            return write(image, index: index, into: directory)
        }
    }

    private static func videoFrames(from url: URL, count: Int, into directory: URL) async throws -> [URL] {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        // A timelapse source is long; an exact-frame seek per sample would decode from the
        // preceding keyframe every time for no gain in what the model sees.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        let seconds = try await asset.load(.duration).seconds
        guard seconds.isFinite, seconds > 0 else { throw SamplingError.noFrames }

        // Inset from both ends: the first and last instants of a handheld take are the grab and
        // the stop, which is exactly what Adjust's trim exists to remove.
        var frames: [URL] = []
        for index in 0..<count {
            let fraction = count == 1 ? 0.5 : 0.1 + 0.8 * Double(index) / Double(count - 1)
            let time = CMTime(seconds: seconds * fraction, preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image else { continue }
            if let written = write(image, index: index, into: directory) {
                frames.append(written)
            }
        }
        return frames
    }

    private static func write(_ image: CGImage, index: Int, into directory: URL) -> URL? {
        let url = directory.appendingPathComponent(String(format: "frame-%02d.jpg", index))
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? url : nil
    }
}

// MARK: - Context

/// The place and light words handed to the model as context. Both are app knowledge, not model
/// output: the capture's own GPS fix and its clock.
enum SceneContext {
    /// A light word for a moment in the day. Deliberately coarse — the model only needs a phrase
    /// it can drop into a title verbatim.
    static func light(at date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 0..<5: return "night"
        case 5..<7: return "dawn"
        case 7..<9: return "morning"
        case 9..<17: return "day"
        case 17..<19: return "golden hour"
        case 19..<22: return "dusk"
        default: return "night"
        }
    }

    /// The same, over a span — a timelapse that runs from afternoon into the evening earns the
    /// "day to dusk" phrasing the prompt was tuned for.
    static func light(from start: Date, duration: TimeInterval, timeZone: TimeZone = .current) -> String {
        let startWord = light(at: start, timeZone: timeZone)
        guard duration > 60 * 20 else { return startWord }
        let endWord = light(at: start.addingTimeInterval(duration), timeZone: timeZone)
        return startWord == endWord ? startWord : "\(startWord) to \(endWord)"
    }

    /// A place name for a fix, or nil. Nil is a supported answer — the title grammar handles a
    /// placeless capture app-side, because the model asked to work without one produced
    /// "day in outdoor with leaves".
    static func place(for location: CLLocation?) async -> String? {
        guard let location else { return nil }
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location)
        guard let placemark = placemarks?.first else { return nil }
        let name = placemark.locality
            ?? placemark.subLocality
            ?? placemark.subAdministrativeArea
            ?? placemark.administrativeArea
            ?? placemark.name
        guard let name, !name.isEmpty else { return nil }
        return name
    }
}

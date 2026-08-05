import Foundation
import Vision

/// Scene labelling through Apple's own Vision framework — the free, instant half of the feature.
///
/// It is not a smaller VLM and shouldn't be sold as one: `VNClassifyImageRequest` returns
/// confidences over a fixed taxonomy of about a thousand identifiers, so it can say a frame holds a
/// waterfall but cannot write "Golden hour in Skógar with waterfall". That is the whole trade — no
/// download, no memory floor, results in milliseconds, and no title. `SceneAnalysisResult.title`
/// comes back empty and callers keep the name the project already has.
///
/// No `#if canImport(MLX)` anywhere: Vision ships with the OS, so this file needs no guards. It is
/// only compiled into the phone/pad/Mac target, because the watch has no analysis UI to drive it.
@MainActor
final class VisionSceneAnalyzer: SceneAnalyzing {
    static let shared = VisionSceneAnalyzer()

    /// Always. There is nothing to install and nothing to load.
    var isAvailable: Bool { true }

    enum Failure: LocalizedError {
        case noFrames
        /// Every frame failed to classify — a folder of unreadable files, not a scene with nothing
        /// in it. An empty-but-successful pass is a legitimate answer and is *not* this. Carries
        /// the last frame's own error: "couldn't read them" on its own sends you looking at the
        /// files when the fault was the request.
        case unreadable(Error?)

        var errorDescription: String? {
            switch self {
            case .noFrames:
                return "This project has no frames to analyse."
            case .unreadable(let underlying):
                guard let underlying else { return "Couldn't read any of this project's frames." }
                return "Couldn't read any of this project's frames: \(underlying.localizedDescription)"
            }
        }
    }

    func analyze(
        _ request: SceneAnalysisRequest,
        status: (@Sendable (String) -> Void)?
    ) async throws -> SceneAnalysisResult {
        guard !request.imageURLs.isEmpty else { throw Failure.noFrames }

        status?("Analysing…")
        let urls = request.imageURLs
        let observed = try await Task.detached(priority: .userInitiated) {
            try Self.classify(urls)
        }.value

        return Self.assemble(observed, contextLight: request.light)
    }

    // MARK: - Vision

    /// What one frame yielded, before it is mapped onto the app's own vocabulary.
    private struct FrameObservations: Sendable {
        /// Identifier and confidence, above threshold, most confident first.
        var identifiers: [(identifier: String, confidence: Float)] = []
        /// Whether the frame carried legible text.
        var hasText = false
    }

    /// Below this a Vision identifier is noise — the classifier returns the full taxonomy every
    /// time, most of it at confidences in the thousandths, so an unfiltered result is a thousand
    /// labels of which three are true.
    /// `nonisolated` because `classify` runs off the main actor — the whole point of it is to keep
    /// several frames of Core ML work off the thread drawing the capture screen.
    nonisolated private static let confidenceThreshold: Float = 0.3

    private nonisolated static func classify(_ urls: [URL]) throws -> [FrameObservations] {
        var frames: [FrameObservations] = []
        var lastError: Error?

        for url in urls {
            let handler = VNImageRequestHandler(url: url, options: [:])
            let classify = VNClassifyImageRequest()
            // Read, but not transcribed anywhere: what a sign *says* is not scene information, and
            // putting a stranger's shopfront into a searchable field is not something a silent
            // background pass should do. Only the fact that legible text was present is kept, as
            // the "signage" element below.
            let readText = VNRecognizeTextRequest()
            readText.recognitionLevel = .fast
            readText.usesLanguageCorrection = false

            do {
                try handler.perform([classify, readText])
            } catch {
                // One unreadable frame is survivable — a capture is sampled at several points and
                // the others still describe it.
                lastError = error
                continue
            }

            let results = (classify.results ?? [])
                .filter { $0.confidence >= confidenceThreshold }
                .sorted { $0.confidence > $1.confidence }
                .map { (identifier: $0.identifier, confidence: $0.confidence) }
            let text = (readText.results ?? []).contains { $0.confidence >= confidenceThreshold }
            frames.append(FrameObservations(identifiers: results, hasText: text))
        }

        guard !frames.isEmpty else { throw Failure.unreadable(lastError) }
        return frames
    }

    // MARK: - Mapping

    /// Vision's taxonomy onto `SceneMetadata.orderedTaxonomy`.
    ///
    /// Matched on identifier *components* rather than whole strings: Vision returns hierarchical
    /// identifiers like `outdoor`, `sky`, `bird`, and a great many leaves that a whole-string table
    /// would have to enumerate one by one. So the identifier is split on the taxonomy's own
    /// separators and any component that is a known word decides the tag.
    ///
    /// Only two entries per app tag are load-bearing; the rest are the leaves that actually show up
    /// on capture footage. Anything unrecognised is simply not mapped — an unmapped identifier
    /// still reaches the "In frame" row, where a raw word is honest, rather than being forced into
    /// a tag it doesn't belong to.
    private static let tagMap: [String: String] = [
        // urban
        "cityscape": "urban", "urban_area": "urban", "city": "urban", "street": "urban",
        "architecture": "urban", "building": "urban", "skyscraper": "urban", "bridge": "urban",
        "road": "urban", "alley": "urban", "downtown": "urban",
        // vehicles
        "vehicle": "vehicles", "car": "vehicles", "bus": "vehicles", "tram": "vehicles",
        "train": "vehicles", "truck": "vehicles", "motorcycle": "vehicles", "bicycle": "vehicles",
        "boat": "vehicles", "ship": "vehicles", "aircraft": "vehicles", "airplane": "vehicles",
        // nature
        "nature": "nature", "forest": "nature", "mountain": "nature", "beach": "nature",
        "tree": "nature", "plant": "nature", "flower": "nature", "grass": "nature",
        "field": "nature", "desert": "nature", "valley": "nature", "canyon": "nature",
        "hill": "nature", "foliage": "nature", "garden": "nature", "park": "nature",
        // water — its own tag in this app's taxonomy, so it isn't folded into nature
        "water": "water", "ocean": "water", "sea": "water", "river": "water", "lake": "water",
        "waterfall": "water", "waves": "water", "harbor": "water", "harbour": "water",
        "pond": "water", "stream": "water", "coast": "water",
        // sky & weather
        "sky": "skyWeather", "cloud": "skyWeather", "clouds": "skyWeather",
        "sunset": "skyWeather", "sunrise": "skyWeather", "dusk": "skyWeather",
        "dawn": "skyWeather", "storm": "skyWeather", "rain": "skyWeather", "snow": "skyWeather",
        "fog": "skyWeather", "rainbow": "skyWeather", "lightning": "skyWeather",
        "moon": "skyWeather", "star": "skyWeather", "sun": "skyWeather",
        // people
        "people": "people", "person": "people", "crowd": "people", "portrait": "people",
        "child": "people", "man": "people", "woman": "people",
        // animals
        "animal": "animals", "dog": "animals", "cat": "animals", "bird": "animals",
        "horse": "animals", "fish": "animals", "insect": "animals", "wildlife": "animals",
        // landmark
        "landmark": "landmark", "monument": "landmark", "castle": "landmark",
        "cathedral": "landmark", "church": "landmark", "temple": "landmark", "tower": "landmark",
        "statue": "landmark", "ruins": "landmark",
        // construction
        "construction": "construction", "crane": "construction", "scaffolding": "construction",
        "machinery": "construction",
        // interior
        "indoor": "interior", "interior": "interior", "room": "interior", "kitchen": "interior",
        "office": "interior", "furniture": "interior",
        // event
        "concert": "event", "festival": "event", "parade": "event", "wedding": "event",
        "sport": "event", "market": "event", "party": "event",
        // light trails
        "traffic": "lightTrails", "night_traffic": "lightTrails",
    ]

    /// Identifiers that are real, confident and useless to read.
    ///
    /// Vision returns the whole hierarchy it walked, and the parents score highest — a photo of a
    /// waterfall comes back `outdoor`, `land`, `liquid`, `water body`, `water`, in that order. Left
    /// alone, the "In frame" row fills up with the five vaguest words available and the specific
    /// ones fall off the end. These are dropped from `elements` only: as *tags* the same
    /// identifiers are still informative, and `outdoor` in particular is what rescues an otherwise
    /// untagged frame.
    private static let genericElements: Set<String> = [
        "outdoor", "indoor", "land", "liquid", "material", "structure", "object", "scene",
        "background", "surface", "substance", "environment", "landscape",
    ]

    /// Identifiers that name a moment in the day rather than a subject.
    private static let lightMap: [String: String] = [
        "sunrise": "Golden hour", "sunset": "Golden hour", "golden_hour": "Golden hour",
        "dusk": "Golden hour", "dawn": "Golden hour",
        "night": "Night", "nighttime": "Night", "moon": "Night", "starry_sky": "Night",
    ]

    /// The tag an identifier implies, if any. `outdoor` is handled here rather than in the table
    /// because it is the single most common identifier Vision returns and mapping it to `nature`
    /// outright would tag every city street as countryside — it only counts when nothing more
    /// specific was seen, which `assemble` decides.
    private static func tag(for identifier: String) -> String? {
        for component in components(of: identifier) {
            if let tag = tagMap[component] { return tag }
        }
        return nil
    }

    /// `city_street` → `["city_street", "city", "street"]`. The whole identifier is tried first so
    /// a compound with its own entry (`urban_area`) wins over its parts.
    private static func components(of identifier: String) -> [String] {
        let lowered = identifier.lowercased()
        let parts = lowered.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
            .map(String.init)
        return parts.count > 1 ? [lowered] + parts : [lowered]
    }

    /// Turns per-frame identifiers into the app's own answer.
    ///
    /// Tags are the union across frames in taxonomy order — a capture that starts in daylight and
    /// ends at dusk should carry both of the things it was, which is the same merge rule the MLX
    /// path uses. Elements are the raw identifiers, most confident first, because they are the only
    /// place Vision's actual vocabulary ("waterfall", "canyon") reaches the user.
    private static func assemble(
        _ frames: [FrameObservations],
        contextLight: String?
    ) -> SceneAnalysisResult {
        var tags: Set<String> = []
        var inferredLight: String?
        /// Best confidence per identifier across every frame, so an element seen faintly three
        /// times doesn't outrank one seen clearly once.
        var best: [String: Float] = [:]
        var sawOutdoor = false

        for frame in frames {
            for entry in frame.identifiers {
                let lowered = entry.identifier.lowercased()
                best[lowered] = max(best[lowered] ?? 0, entry.confidence)

                if let tag = tag(for: lowered) {
                    tags.insert(tag)
                } else if lowered == "outdoor" {
                    sawOutdoor = true
                }

                // First one wins: identifiers arrive most-confident-first within a frame, so the
                // strongest reading of the light is the one that sticks.
                if inferredLight == nil {
                    for component in components(of: lowered) {
                        if let word = lightMap[component] {
                            inferredLight = word
                            break
                        }
                    }
                }
            }
        }

        // `outdoor` on its own is the one identifier worth rescuing: with nothing more specific
        // found it is still better than an untagged project, and it can only mean nature here.
        if tags.isEmpty, sawOutdoor { tags.insert("nature") }

        // Filtered before the cap, not after — dropping five vague words from a list of five
        // leaves nothing, and the specific identifiers sit below them.
        var elements = best
            .filter { !genericElements.contains($0.key) }
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { readable($0.key) }
        if frames.contains(where: \.hasText), elements.count < 5 {
            elements.append("signage")
        }

        return SceneAnalysisResult(
            // Vision writes no natural language. Empty rather than invented, so the project keeps
            // the name it has.
            title: "",
            subjectTags: SceneMetadata.orderedTaxonomy.filter(tags.contains),
            elements: elements,
            // The capture's own clock wins where the caller has one: it *knows* the shot began at
            // 6pm, while this is a guess from pixels. The inference is what a caller with no
            // timestamp to hand gets instead of nothing.
            light: contextLight ?? inferredLight)
    }

    /// `city_street` → `city street`. Vision's identifiers are machine-shaped; the "In frame" row
    /// is read by people.
    private static func readable(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }
}

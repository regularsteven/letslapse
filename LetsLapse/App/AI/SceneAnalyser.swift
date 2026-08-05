import Foundation
import os

#if canImport(MLX)
import CoreGraphics
import MLX
import MLXLMCommon
import MLXVLM
import Tokenizers
#endif

/// On-device scene labelling for captures, via a Gemma 4 VLM running on MLX.
///
/// Everything MLX-facing is behind `#if canImport(MLX)` so the watchOS target (which never links
/// the MLX packages) still compiles against the same type. Engine and model are pinned together —
/// a Hub re-conversion can break an older engine, so treat the pair as one contract
/// (docs/ai/phase0-findings.md).
actor SceneAnalyser {
    static let shared = SceneAnalyser()

    /// The Phase 0 gate winner. Loads and runs on the vendored (PR #384 + multi-image patched)
    /// mlx-swift-lm; stock 3.31.4 cannot load it.
    static let modelID = "mlx-community/gemma-4-e2b-it-4bit"

    private static let log = Logger(subsystem: "com.regularsteven.letslapse", category: "ai")

    enum Failure: LocalizedError {
        case unavailable
        case noModel
        /// Raised *before* loading, from a measured peak-memory figure. There is no catchable error
        /// for the alternative — iOS terminates the process mid-generation (docs/ai/phase0-findings.md).
        case insufficientMemory(String)
        case noJSON(String)
        case missingTitle(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "On-device analysis isn't available on this platform."
            case .noModel:
                return "No model is installed. Download one in Settings › AI Models."
            case .insufficientMemory(let reason):
                return reason
            case .noJSON(let raw):
                return "The model returned no JSON object.\n\n\(raw.prefix(400))"
            case .missingTitle(let raw):
                return "The model's JSON had no title.\n\n\(raw.prefix(400))"
            }
        }
    }

    /// Kept in sync with tools/mlx-vlm-spike/Prompts/scene-prompt.txt — prompt v3, the one the
    /// Phase 0 matrix was measured against. Changing it invalidates those numbers.
    private static let promptTemplate = """
        You label captures for a timelapse app. You will see {N} frames sampled from one capture. Context: place = "{PLACE}", light = "{LIGHT}". Identify the most salient visible elements. Respond with ONLY a JSON object with these keys: "title" (MUST be 7 words or fewer — count the words before answering and rewrite shorter if the count is 8 or more; prefer the pattern "<light> in <place> with <element>" or "<place> <subject> with <element>" and use the provided place and light words verbatim, but when doing so would run past 7 words, shorten or drop them: the 7-word cap outranks the pattern. Word-counted examples — "Dusk in Prague with river" = 5 words, OK; "Golden hour in Skógar with waterfall" = 6 words, OK; "Day to dusk in Skógar with mossy rocks" = 8 words, TOO LONG, use "Day to dusk in Skógar" = 5 words instead), "subjectTags" (JSON array, always an array even for one tag; every entry must be one of these exact values and nothing else: water, skyWeather, urban, nature, landmark, people, vehicles, lightTrails, animals, construction, interior, event), "elements" (JSON array of up to 4 short nouns), "confidence" (number 0-1). No prose, no markdown.
        """

    private static func prompt(frameCount: Int, place: String?, light: String?) -> String {
        promptTemplate
            .replacingOccurrences(of: "{N}", with: String(frameCount))
            .replacingOccurrences(of: "{PLACE}", with: place ?? "")
            .replacingOccurrences(of: "{LIGHT}", with: light ?? "")
    }

    // MARK: - Analysis

    #if canImport(MLX)

    /// Longest edge the frame is resized to before the vision tower sees it. 1024 px is what the
    /// Phase 0 matrix used (280 soft tokens per frame).
    private let resize = CGSize(width: 1024, height: 1024)
    private var container: ModelContainer?

    /// Where the loaded snapshot came from.
    private(set) var snapshotPath: String?

    /// The snapshot `ModelManager` has selected. Downloading is the manager's job — this actor only
    /// ever loads what is already on disk, so a rename tap can't quietly start a 3.5 GB fetch.
    private var selectedSnapshot: URL?

    /// The generation currently running, if any.
    ///
    /// An actor is only serial between suspension points, and a generation is nothing but
    /// suspension points — so `unload()` can and does land in the middle of one. This is what it
    /// waits on: dropping the container mid-decode frees nothing (the session still holds the
    /// weights) and loses the answer.
    private var inFlight: Task<SceneMetadata, Error>?

    /// Points the analyser at an installed snapshot. Switching models drops the resident weights,
    /// because keeping two sets alive is 5.6 GB the phone does not have.
    func use(snapshot directory: URL?) async {
        guard directory?.standardizedFileURL != selectedSnapshot?.standardizedFileURL else { return }
        await unload()
        selectedSnapshot = directory?.standardizedFileURL
    }

    /// Drops the resident weights and hands the GPU's cached blocks back.
    ///
    /// Nilling the container alone is not enough: MLX keeps freed buffers in its own cache rather
    /// than returning them, so the 2.8 GB stays charged to the process and the next model's load
    /// has nowhere to go. Both halves have to happen, and they have to happen *before* the
    /// replacement is loaded — which is why `ModelManager` calls this on the switch rather than
    /// leaving it to the next analysis.
    func unload() async {
        // Nothing resident, nothing to do — and importantly nothing to touch: `clearCache()` is the
        // call that brings the Metal device up, so an unconditional one here would pay for MLX
        // initialisation on every cold launch (the app adopts a default model in `init`).
        guard container != nil || inFlight != nil else { return }

        // Reentrancy, not deletion: awaiting the running generation is the only way to know the
        // session that owns the weights is gone before the cache is cleared.
        if let inFlight {
            _ = try? await inFlight.value
        }
        inFlight = nil

        Self.log.notice("[AI] evicting model, clearing GPU cache")
        container = nil
        snapshotPath = nil
        MLX.Memory.clearCache()
    }

    func analyse(
        imageURL: URL,
        place: String? = nil,
        light: String? = nil,
        status: (@Sendable (String) -> Void)? = nil
    ) async throws -> SceneMetadata {
        let task = Task {
            try await generate(imageURL: imageURL, place: place, light: light, status: status)
        }
        inFlight = task
        defer { if inFlight == task { inFlight = nil } }
        let result = try await task.value

        // Per run, not per model. The weights stay resident (that is the point of the container),
        // but MLX holds every intermediate buffer a generation allocated in its own cache rather
        // than returning them — across a 3-frame pass, or several passes in a session, that
        // accumulates until the next allocation has nowhere to go. Only on success: a failed run
        // may have left the container in a state `unload()` should handle, not this.
        MLX.Memory.clearCache()
        return result
    }

    private func generate(
        imageURL: URL,
        place: String?,
        light: String?,
        status: (@Sendable (String) -> Void)?
    ) async throws -> SceneMetadata {
        let container = try await loadContainer(status: status)

        let session = ChatSession(
            container,
            generateParameters: GenerateParameters(maxTokens: 256, temperature: 0.0),
            processing: .init(resize: resize))

        status?("Generating…")
        var text = ""
        for try await generation in session.streamDetails(
            to: Self.prompt(frameCount: 1, place: place, light: light),
            images: [.url(imageURL)])
        {
            if case .chunk(let chunk) = generation { text += chunk }
        }

        return try Self.parse(text, place: place, light: light)
    }

    /// Loads once and keeps the weights resident — reload costs ~2 s and ~2.8 GB of churn.
    private func loadContainer(status: (@Sendable (String) -> Void)?) async throws -> ModelContainer {
        if let container { return container }

        #if os(iOS)
        // Headroom matters more than cache hit rate on an 8 GB phone; the weights alone are 2.8 GB.
        MLX.GPU.set(cacheLimit: 64 * 1024 * 1024)
        #endif

        guard let directory = selectedSnapshot ?? Self.cachedSnapshotDirectory() else {
            throw Failure.noModel
        }

        status?("Loading model…")
        let loaded = try await VLMModelFactory.shared.loadContainer(
            from: directory, using: TransformersTokenizerLoader())
        snapshotPath = directory.path

        container = loaded
        return loaded
    }

    /// The Python-compatible Hub cache layout `HubClient` writes into. On iOS `NSHomeDirectory()`
    /// is the app container, so this is the sandboxed equivalent of `~/.cache/huggingface`.
    private static func cachedSnapshotDirectory() -> URL? {
        let repoFolder = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
        let home = ProcessInfo.processInfo.environment["HF_HOME"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache/huggingface")
        let snapshots = home.appendingPathComponent("hub/\(repoFolder)/snapshots")

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: nil)) ?? []
        // A snapshot dir is only usable if the config actually landed — a truncated or
        // interrupted download leaves the folder in place (Phase 0 hit exactly this).
        return entries.sorted { $0.path < $1.path }.first {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("config.json").path)
        }
    }

    // MARK: - Parsing

    /// Defensive by design: the model emits a bare string where an array is specified often
    /// enough that coercion is a requirement, not a nicety, and it occasionally invents a tag
    /// outside the taxonomy. Both are handled here rather than by retrying generation.
    static func parse(_ raw: String, place: String?, light: String?) throws -> SceneMetadata {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
            let data = String(raw[start ... end]).data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw Failure.noJSON(raw) }

        guard let title = (object["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { throw Failure.missingTitle(raw) }

        var tags: [String] = []
        if let array = object["subjectTags"] as? [String] {
            tags = array
        } else if let single = object["subjectTags"] as? String {
            tags = [single]
        }
        tags = tags.filter { SceneMetadata.taxonomy.contains($0) }

        // `elements` is free-form (short nouns), so the same string/array coercion applies but no
        // taxonomy filter does — it is the model's own description of what it saw.
        var elements: [String] = []
        if let array = object["elements"] as? [String] {
            elements = array
        } else if let single = object["elements"] as? String {
            elements = [single]
        }
        elements = elements
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return SceneMetadata(
            title: title, tags: tags, elements: elements, place: place, light: light)
    }

    // MARK: - Hub bridges

    /// Hand-written equivalent of the `#huggingFaceTokenizerLoader()` macro in `MLXHuggingFace`, so
    /// the app doesn't pull the swift-syntax macro build into every compile. Same shape as the
    /// Phase 0 harness.
    private struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
        func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
            TokenizerBridge(try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
        }
    }

    private struct TokenizerBridge: MLXLMCommon.Tokenizer {
        private let upstream: any Tokenizers.Tokenizer
        init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

        func encode(text: String, addSpecialTokens: Bool) -> [Int] {
            upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
        }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
            upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
        }
        func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
        func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
        var bosToken: String? { upstream.bosToken }
        var eosToken: String? { upstream.eosToken }
        var unknownToken: String? { upstream.unknownToken }

        func applyChatTemplate(
            messages: [[String: any Sendable]],
            tools: [[String: any Sendable]]?,
            additionalContext: [String: any Sendable]?
        ) throws -> [Int] {
            do {
                return try upstream.applyChatTemplate(
                    messages: messages, tools: tools, additionalContext: additionalContext)
            } catch Tokenizers.TokenizerError.missingChatTemplate {
                throw MLXLMCommon.TokenizerError.missingChatTemplate
            }
        }
    }

    #else

    func analyse(
        imageURL: URL,
        place: String? = nil,
        light: String? = nil,
        status: (@Sendable (String) -> Void)? = nil
    ) async throws -> SceneMetadata {
        throw Failure.unavailable
    }

    /// Nothing is ever resident on a platform without MLX; the call still exists so callers don't
    /// have to carry the same `#if` a second time.
    func unload() async {}

    #endif
}

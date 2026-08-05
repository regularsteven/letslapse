// SpikeCore — shared Phase 0 harness logic, consumed by both the macOS CLI
// (main.swift) and the iOS harness app (../../mlx-vlm-spike-ios).

import CoreGraphics
import Foundation
import HuggingFace
import MLX
import MLXLMCommon
import MLXVLM
import Tokenizers

// MARK: - Configuration

struct SpikeConfig {
    var model: String
    var imageURLs: [URL]
    var multi = false
    var place = "Prague"
    var light = "dusk"
    var maxTokens = 256
    var resize: Double = 1024
    var promptTemplate: String?
    /// When set and the directory exists, the model is loaded from it directly
    /// (no hub download) — used on iOS after pushing the snapshot over USB.
    var localModelDirectory: URL?
}

// MARK: - Hub bridges
// Hand-inlined equivalents of the #hubDownloader / #huggingFaceTokenizerLoader macro
// expansions from MLXHuggingFace, so the spike can log snapshot paths and skip the
// macro (swift-syntax) build.

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

let snapshotPath = Box<String?>(nil)

struct LoggingHubDownloader: MLXLMCommon.Downloader {
    let client = HubClient()
    let log: @Sendable (String) -> Void

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Foundation.Progress) -> Void
    ) async throws -> URL {
        guard let repoID = HuggingFace.Repo.ID(rawValue: id) else {
            throw NSError(domain: "vlm-spike", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid repo id: \(id)"])
        }
        let url = try await client.downloadSnapshot(
            of: repoID,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: { @MainActor progress in
                progressHandler(progress)
            }
        )
        snapshotPath.value = url.path
        log("[hub] snapshot at \(url.path) (patterns: \(patterns))")
        return url
    }
}

struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream)
    }
}

struct TokenizerBridge: MLXLMCommon.Tokenizer {
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

// MARK: - Prompt

// Keep in sync with Prompts/scene-prompt.txt (the CLI passes that file via --prompt-file and the
// iOS harness bundles it; this literal is the fallback when neither supplies one).
let defaultPrompt = """
You label captures for a timelapse app. You will see {N} frames sampled from one capture. Context: place = "{PLACE}", light = "{LIGHT}". Identify the most salient visible elements. Respond with ONLY a JSON object with these keys: "title" (MUST be 7 words or fewer — count the words before answering and rewrite shorter if the count is 8 or more; prefer the pattern "<light> in <place> with <element>" or "<place> <subject> with <element>" and use the provided place and light words verbatim, but when doing so would run past 7 words, shorten or drop them: the 7-word cap outranks the pattern. Word-counted examples — "Dusk in Prague with river" = 5 words, OK; "Golden hour in Skógar with waterfall" = 6 words, OK; "Day to dusk in Skógar with mossy rocks" = 8 words, TOO LONG, use "Day to dusk in Skógar" = 5 words instead), "subjectTags" (JSON array, always an array even for one tag; every entry must be one of these exact values and nothing else: water, skyWeather, urban, nature, landmark, people, vehicles, lightTrails, animals, construction, interior, event), "elements" (JSON array of up to 4 short nouns), "confidence" (number 0-1). No prose, no markdown.
"""

func promptText(n: Int, config: SpikeConfig) -> String {
    (config.promptTemplate ?? defaultPrompt)
        .replacingOccurrences(of: "{N}", with: String(n))
        .replacingOccurrences(of: "{PLACE}", with: config.place)
        .replacingOccurrences(of: "{LIGHT}", with: config.light)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - JSON contract validation

let taxonomy: Set<String> = [
    "water", "skyWeather", "urban", "nature", "landmark", "people",
    "vehicles", "lightTrails", "animals", "construction", "interior", "event",
]

struct ParsedScene {
    var title: String?
    var subjectTags: [String] = []
    var elements: [String] = []
    var confidence: Double?
    var violations: [String] = []
}

func parseScene(_ raw: String) -> ParsedScene? {
    guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else {
        return nil
    }
    let jsonText = String(raw[start ... end])
    guard let data = jsonText.data(using: .utf8),
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return nil }

    var scene = ParsedScene()
    scene.title = object["title"] as? String
    // Models sometimes emit a bare string for single-tag results (observed with prompt v2) —
    // coerce but record the shape violation so the contract data stays honest.
    if let tags = object["subjectTags"] as? [String] {
        scene.subjectTags = tags
    } else if let tag = object["subjectTags"] as? String {
        scene.subjectTags = [tag]
        scene.violations.append("subjectTags was a string, not an array")
    }
    if let elements = object["elements"] as? [String] {
        scene.elements = elements
    } else if let element = object["elements"] as? String {
        scene.elements = [element]
        scene.violations.append("elements was a string, not an array")
    }
    if let c = object["confidence"] as? Double { scene.confidence = c }
    else if let c = object["confidence"] as? Int { scene.confidence = Double(c) }

    if scene.title == nil { scene.violations.append("missing title") }
    if let title = scene.title, title.split(separator: " ").count > 7 {
        scene.violations.append("title over 7 words")
    }
    let unknown = scene.subjectTags.filter { !taxonomy.contains($0) }
    if !unknown.isEmpty { scene.violations.append("unknown tags: \(unknown.joined(separator: ","))") }
    if scene.confidence == nil { scene.violations.append("missing confidence") }
    return scene
}

// MARK: - Reports

struct CallReport: Codable {
    var label: String
    var images: [String]
    var ok: Bool
    var error: String?
    var ttftSeconds: Double?
    var promptTokens: Int?
    var promptSeconds: Double?
    var promptTokensPerSecond: Double?
    var generateTokens: Int?
    var generateSeconds: Double?
    var tokensPerSecond: Double?
    var wallSeconds: Double
    var peakMemoryMB: Int
    var stopReason: String?
    var output: String
    var jsonValid: Bool
    var title: String?
    var subjectTags: [String]?
    var elements: [String]?
    var confidence: Double?
    var contractViolations: [String]?
}

struct RunReport: Codable {
    var model: String
    var date: String
    var host: String
    var snapshotPath: String?
    var loadSeconds: Double = 0
    var peakMemoryAfterLoadMB: Int = 0
    var loadError: String?
    var calls: [CallReport] = []
}

func mb(_ bytes: Int) -> Int { bytes / (1024 * 1024) }

// MARK: - Analysis

func analyze(container: ModelContainer, imageURLs: [URL], config: SpikeConfig, label: String) async -> CallReport {
    let prompt = promptText(n: imageURLs.count, config: config)
    let session = ChatSession(
        container,
        generateParameters: GenerateParameters(maxTokens: config.maxTokens, temperature: 0.0),
        processing: .init(resize: CGSize(width: config.resize, height: config.resize))
    )

    var report = CallReport(
        label: label, images: imageURLs.map { $0.lastPathComponent },
        ok: false, wallSeconds: 0, peakMemoryMB: 0, output: "", jsonValid: false)

    var text = ""
    var ttft: Double?
    var info: GenerateCompletionInfo?
    let start = Date()
    do {
        for try await generation in session.streamDetails(to: prompt, images: imageURLs.map { .url($0) }) {
            switch generation {
            case .chunk(let chunk):
                if ttft == nil { ttft = Date().timeIntervalSince(start) }
                text += chunk
            case .info(let i):
                info = i
            default:
                break
            }
        }
        report.ok = true
    } catch {
        report.error = String(describing: error)
    }
    report.wallSeconds = Date().timeIntervalSince(start)
    report.peakMemoryMB = mb(GPU.peakMemory)
    report.output = text
    report.ttftSeconds = ttft
    if let info {
        report.promptTokens = info.promptTokenCount
        report.promptSeconds = info.promptTime
        report.promptTokensPerSecond = info.promptTokensPerSecond
        report.generateTokens = info.generationTokenCount
        report.generateSeconds = info.generateTime
        report.tokensPerSecond = info.tokensPerSecond
        report.stopReason = String(describing: info.stopReason)
    }
    if let scene = parseScene(text) {
        report.jsonValid = scene.violations.isEmpty
        report.title = scene.title
        report.subjectTags = scene.subjectTags
        report.elements = scene.elements
        report.confidence = scene.confidence
        report.contractViolations = scene.violations.isEmpty ? nil : scene.violations
    }
    return report
}

func summaryLines(_ call: CallReport) -> [String] {
    var lines = ["--- \(call.label) [\(call.images.joined(separator: ", "))]"]
    if let error = call.error { lines.append("    ERROR: \(error)") }
    lines.append("    output: \(call.output.replacingOccurrences(of: "\n", with: " "))")
    let ttft = call.ttftSeconds.map { String(format: "%.2f", $0) } ?? "-"
    let tps = call.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "-"
    let ptps = call.promptTokensPerSecond.map { String(format: "%.1f", $0) } ?? "-"
    lines.append("    ttft \(ttft)s · prompt \(call.promptTokens ?? 0) tok @ \(ptps) tok/s · gen \(call.generateTokens ?? 0) tok @ \(tps) tok/s · wall \(String(format: "%.2f", call.wallSeconds))s · peak \(call.peakMemoryMB) MB")
    lines.append("    json valid: \(call.jsonValid) \(call.contractViolations.map { "(violations: \($0.joined(separator: "; ")))" } ?? "")")
    return lines
}

// MARK: - Entry point shared by CLI and iOS app

func runSpike(config: SpikeConfig, log: @escaping @Sendable (String) -> Void) async -> RunReport {
    var run = RunReport(
        model: config.model,
        date: ISO8601DateFormatter().string(from: Date()),
        host: ProcessInfo.processInfo.hostName,
        snapshotPath: nil)

    let progressPercent = Box<Int>(-1)
    let loadStart = Date()
    let container: ModelContainer
    do {
        if let localDirectory = config.localModelDirectory,
            FileManager.default.fileExists(atPath: localDirectory.path)
        {
            log("[load] local directory \(localDirectory.path)")
            container = try await VLMModelFactory.shared.loadContainer(
                from: localDirectory, using: TransformersTokenizerLoader())
            snapshotPath.value = localDirectory.path
        } else {
            container = try await VLMModelFactory.shared.loadContainer(
                from: LoggingHubDownloader(log: log),
                using: TransformersTokenizerLoader(),
                configuration: ModelConfiguration(id: config.model)
            ) { progress in
                let percent = Int(progress.fractionCompleted * 100)
                if percent != progressPercent.value {
                    progressPercent.value = percent
                    log("[download] \(percent)%")
                }
            }
        }
    } catch {
        run.loadError = String(describing: error)
        run.loadSeconds = Date().timeIntervalSince(loadStart)
        log("LOAD FAILED after \(String(format: "%.1f", run.loadSeconds))s: \(String(describing: error))")
        return run
    }
    run.loadSeconds = Date().timeIntervalSince(loadStart)
    run.snapshotPath = snapshotPath.value
    run.peakMemoryAfterLoadMB = mb(GPU.peakMemory)
    let snapshot = GPU.snapshot()
    log(String(format: "[load] %.1fs · active %d MB · cache %d MB · peak %d MB", run.loadSeconds, mb(snapshot.activeMemory), mb(snapshot.cacheMemory), mb(GPU.peakMemory)))

    for (index, imageURL) in config.imageURLs.enumerated() {
        let call = await analyze(container: container, imageURLs: [imageURL], config: config, label: "single-\(index + 1)")
        summaryLines(call).forEach(log)
        run.calls.append(call)
    }

    if config.multi, config.imageURLs.count > 1 {
        let call = await analyze(container: container, imageURLs: config.imageURLs, config: config, label: "multi-\(config.imageURLs.count)")
        summaryLines(call).forEach(log)
        run.calls.append(call)
    }
    return run
}

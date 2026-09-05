// craft-probe — a real Gemma generation, headless, for the Crafted Text path.
//
// `lapse craft` deliberately does NOT link MLX: that is what lets the parser
// and layout run in CI on any machine. This is the other half — the piece
// that needs the weights — kept in the spike package which already carries
// the vendored, patched mlx-swift-lm. Together they make the whole path
// drivable from a shell:
//
//   lapse craft --prompt split --brief "Visit Prague this summer" \
//     | craft-probe --stats > reply.json
//   lapse craft --response reply.json --json
//
// Text in, text out. No image, no app, no simulator.
//
// BUILD WITH XCODEBUILD, never `swift build` — SPM does not compile MLX's
// .metal sources and the binary dies with "Failed to load the default
// metallib". See ../README.md.
//
// The tokenizer bridge below is duplicated from SpikeCore.swift on purpose:
// SwiftPM cannot share a file between two targets, and the spike's own
// target is pinned evidence for docs/ai/phase0-findings.md — better a few
// duplicated lines here than a refactor of that.

import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import Tokenizers

// MARK: - Tokenizer bridge (see note above)

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

// MARK: - Arguments

func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func die(_ message: String) -> Never {
    note("craft-probe: \(message)")
    exit(1)
}

let usage = """
craft-probe — one text generation from a local MLX model.

USAGE:
  craft-probe [options]            Prompt on stdin, generation on stdout.

OPTIONS:
  --prompt-file PATH   Read the prompt from a file instead of stdin ("-" = stdin)
  --prompt TEXT        The prompt inline
  --snapshot DIR       Model snapshot (default: the Hugging Face cache entry
                       for mlx-community/gemma-4-e2b-it-4bit, which is the
                       same directory SceneAnalyser loads)
  --max-tokens N       Default 320 — what CraftedTextService asks for
  --temperature T      Default 0.7 — likewise
  --framing MODE       auto (default) | manual
                       auto   — ChatSession builds a Chat.Message and the
                                processor applies the model's OWN chat
                                template. This is what the app does.
                       manual — additionally wrap the prompt in Gemma's
                                <start_of_turn> framing before handing it to
                                ChatSession, i.e. template it twice. Kept so
                                the difference can be measured rather than
                                assumed.
  --timeout SECONDS    Give up and exit 75 (default 300)
  --stats              Timing and token counts on stderr
  --repeat N           Run the same prompt N times (fresh session each time),
                       separated by a NUL byte on stdout
"""

var promptFile: String?
var inlinePrompt: String?
var snapshotArg: String?
var maxTokens = 320
var temperature: Float = 0.7
var framing = "auto"
var timeout: Double = 300
var wantsStats = false
var repeatCount = 1

var iterator = CommandLine.arguments.dropFirst().makeIterator()
while let flag = iterator.next() {
    switch flag {
    case "--prompt-file": promptFile = iterator.next()
    case "--prompt": inlinePrompt = iterator.next()
    case "--snapshot": snapshotArg = iterator.next()
    case "--max-tokens": maxTokens = Int(iterator.next() ?? "") ?? maxTokens
    case "--temperature": temperature = Float(iterator.next() ?? "") ?? temperature
    case "--framing": framing = iterator.next() ?? framing
    case "--timeout": timeout = Double(iterator.next() ?? "") ?? timeout
    case "--stats": wantsStats = true
    case "--repeat": repeatCount = Int(iterator.next() ?? "") ?? 1
    case "-h", "--help": print(usage); exit(0)
    default: die("unknown flag \(flag)")
    }
}
guard ["auto", "manual"].contains(framing) else {
    die("--framing expects auto | manual")
}

// MARK: - The prompt

let basePrompt: String
if let inlinePrompt {
    basePrompt = inlinePrompt
} else if let promptFile, promptFile != "-" {
    guard let text = try? String(contentsOfFile: promptFile, encoding: .utf8) else {
        die("could not read \(promptFile)")
    }
    basePrompt = text
} else {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    basePrompt = String(data: data, encoding: .utf8) ?? ""
}
guard !basePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    die("no prompt (pipe one in, or pass --prompt)")
}

/// Gemma's turn framing, applied by hand for `--framing manual`.
func manuallyFramed(_ prompt: String) -> String {
    "<start_of_turn>user\n\(prompt)<end_of_turn>\n<start_of_turn>model\n"
}

// MARK: - The snapshot

/// The same lookup `SceneAnalyser.cachedSnapshotDirectory()` does — the
/// Python-compatible Hub layout `HubClient` writes into — so the probe and
/// the app load the same bytes.
func cachedSnapshot(repo: String) -> URL? {
    let folder = "models--" + repo.replacingOccurrences(of: "/", with: "--")
    let home = ProcessInfo.processInfo.environment["HF_HOME"].map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache/huggingface")
    let snapshots = home.appendingPathComponent("hub/\(folder)/snapshots")
    let entries = (try? FileManager.default.contentsOfDirectory(
        at: snapshots, includingPropertiesForKeys: nil)) ?? []
    return entries.sorted { $0.path < $1.path }.first {
        FileManager.default.fileExists(atPath: $0.appendingPathComponent("config.json").path)
    }
}

let snapshot: URL
if let snapshotArg {
    snapshot = URL(fileURLWithPath: snapshotArg)
} else if let found = cachedSnapshot(repo: "mlx-community/gemma-4-e2b-it-4bit") {
    snapshot = found
} else {
    die("no snapshot found — pass --snapshot <dir>")
}
guard FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("config.json").path) else {
    die("no config.json in \(snapshot.path) — the snapshot is incomplete")
}

// MARK: - Run

func megabytes(_ bytes: Int) -> Int { bytes / (1024 * 1024) }

note("[probe] snapshot \(snapshot.lastPathComponent) · framing \(framing) "
    + "· maxTokens \(maxTokens) · temp \(temperature)")

let loadStart = Date()
let container: ModelContainer
do {
    container = try await VLMModelFactory.shared.loadContainer(
        from: snapshot, using: TransformersTokenizerLoader())
} catch {
    die("load failed: \(error)")
}
let loadSeconds = Date().timeIntervalSince(loadStart)
if wantsStats {
    note(String(format: "[probe] loaded in %.1fs · peak %d MB",
                loadSeconds, megabytes(GPU.peakMemory)))
}

for index in 0..<max(repeatCount, 1) {
    let prompt = framing == "manual" ? manuallyFramed(basePrompt) : basePrompt
    // A fresh session per run: the KV cache is per-session, and a
    // second brief must not be answered in the first one's context.
    let session = ChatSession(
        container,
        generateParameters: GenerateParameters(
            maxTokens: maxTokens, temperature: temperature))

    let start = Date()
    var text = ""
    var firstToken: Double?
    var info: GenerateCompletionInfo?

    let work = Task { () -> String in
        for try await generation in session.streamDetails(to: prompt) {
            if Task.isCancelled { break }
            switch generation {
            case .chunk(let chunk):
                if firstToken == nil { firstToken = Date().timeIntervalSince(start) }
                text += chunk
            case .info(let value):
                info = value
            default:
                break
            }
        }
        return text
    }
    // A local model that wanders can run for minutes; the app has a
    // person watching a spinner, CI has nobody.
    let watchdog = Task {
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        if !Task.isCancelled { work.cancel() }
    }
    do {
        _ = try await work.value
    } catch {
        watchdog.cancel()
        die("generation failed: \(error)")
    }
    watchdog.cancel()

    if text.isEmpty {
        note("[probe] timed out after \(Int(timeout))s with no output")
        exit(75)
    }
    if wantsStats {
        let wall = Date().timeIntervalSince(start)
        var line = String(format: "[probe] run %d · %.1fs wall", index + 1, wall)
        if let firstToken { line += String(format: " · ttft %.2fs", firstToken) }
        if let info {
            line += String(
                format: " · %d prompt + %d generated · %.1f tok/s · stop %@",
                info.promptTokenCount, info.generationTokenCount,
                info.tokensPerSecond, String(describing: info.stopReason))
        }
        note(line)
    }
    FileHandle.standardOutput.write(Data(text.utf8))
    if repeatCount > 1 && index < repeatCount - 1 {
        FileHandle.standardOutput.write(Data([0]))
    }
}
exit(0)

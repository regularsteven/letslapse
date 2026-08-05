// vlm-spike — LetsLapse Phase 0 verification harness (throwaway; NOT part of the app target).
// CLI entry point; the shared logic lives in SpikeCore.swift (also compiled into the iOS
// harness app). Results land in LetsLapse/docs/ai/phase0-findings.md.
//
// Usage:
//   .build/xcode/Build/Products/Release/vlm-spike --model mlx-community/gemma-4-e2b-it-4bit \
//     --image TestImages/IMG_0003.JPG [--image …] [--multi] \
//     --place "Prague" --light "dusk" --prompt-file Prompts/scene-prompt.txt \
//     --report reports/run.json
//
// NOTE: build via xcodebuild (see README) — plain `swift build` produces no Metal kernels.

import Foundation

var model = ""
var images: [String] = []
var multi = false
var place = "Prague"
var light = "dusk"
var maxTokens = 256
var resize = 1024.0
var promptFile: String?
var reportPath: String?
var localDir: String?

var it = CommandLine.arguments.dropFirst().makeIterator()
while let flag = it.next() {
    switch flag {
    case "--model": model = it.next() ?? ""
    case "--image": if let v = it.next() { images.append(v) }
    case "--multi": multi = true
    case "--place": place = it.next() ?? place
    case "--light": light = it.next() ?? light
    case "--max-tokens": maxTokens = Int(it.next() ?? "") ?? maxTokens
    case "--resize": resize = Double(it.next() ?? "") ?? resize
    case "--prompt-file": promptFile = it.next()
    case "--report": reportPath = it.next()
    case "--local-dir": localDir = it.next()
    default:
        FileHandle.standardError.write("unknown flag: \(flag)\n".data(using: .utf8)!)
        exit(2)
    }
}
guard !model.isEmpty, !images.isEmpty else {
    FileHandle.standardError.write("usage: vlm-spike --model <repo> --image <path> [...]\n".data(using: .utf8)!)
    exit(2)
}

let config = SpikeConfig(
    model: model,
    imageURLs: images.map { URL(fileURLWithPath: $0) },
    multi: multi,
    place: place,
    light: light,
    maxTokens: maxTokens,
    resize: resize,
    promptTemplate: promptFile.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) },
    localModelDirectory: localDir.map { URL(fileURLWithPath: $0) })

print("vlm-spike — model \(model)")
print("images: \(images.joined(separator: ", "))")

let run = await runSpike(config: config) { print($0) }

if let reportPath {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let url = URL(fileURLWithPath: reportPath)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? encoder.encode(run).write(to: url)
    print("[report] \(reportPath)")
}

if run.loadError != nil { exit(1) }
print("DONE")
exit(0)

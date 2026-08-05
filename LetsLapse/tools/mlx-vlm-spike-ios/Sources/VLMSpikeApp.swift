// Phase 0 on-device harness. Reuses SpikeCore.swift from the macOS CLI harness.
// Downloads the model over the phone's connection on first run (3.6 GB for the
// 4-bit candidate) — keep the app foregrounded; the idle timer is disabled.

import MLX
import SwiftUI

@main
struct VLMSpikeApp: App {
    var body: some Scene {
        WindowGroup { SpikeView() }
    }
}

struct SpikeView: View {
    @State private var log = "vlm-spike (iOS)\nTap a model to run the full scenario set.\n"
    @State private var running = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(log)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .id("log-end")
            }
            .onChange(of: log) { proxy.scrollTo("log-end", anchor: .bottom) }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                runButton("Gemma 4 E2B 4-bit", model: "mlx-community/gemma-4-e2b-it-4bit")
                runButton("TurboQuant 2-bit", model: "majentik/gemma-4-E2B-TurboQuant-MLX-2bit")
            }
            .padding()
            .background(.thinMaterial)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            // No Increased Memory Limit entitlement on this build: keep the MLX buffer cache
            // minimal so inference peak stays as close to the weights floor as possible.
            GPU.set(cacheLimit: 32 * 1024 * 1024)
            // Hands-free mode for USB-driven runs: when the 4-bit snapshot was pushed into
            // Documents/models/, start the scenario suite immediately — devicectl can launch
            // the app but cannot tap buttons.
            let fourBit = "mlx-community/gemma-4-e2b-it-4bit"
            if !running, localSnapshotExists(for: fourBit) {
                append("[auto] local snapshot found — starting run")
                Task { await run(model: fourBit) }
            }
        }
    }

    private func localSnapshotExists(for model: String) -> Bool {
        let slug = model.split(separator: "/").last.map(String.init) ?? "model"
        guard
            let dir = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("models/\(slug)", isDirectory: true)
        else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path)
    }

    private func runButton(_ title: String, model: String) -> some View {
        Button(running ? "Running…" : title) {
            Task { await run(model: model) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(running)
        .frame(maxWidth: .infinity)
    }

    private func append(_ line: String) {
        log += line + "\n"
        print(line)  // mirrored to stdout so `devicectl … launch --console` streams progress
    }

    private func run(model: String) async {
        running = true
        defer { running = false }

        guard
            let waterfallGold = Bundle.main.url(forResource: "IMG_0003", withExtension: "JPG", subdirectory: "TestImages"),
            let waterfallDusk = Bundle.main.url(forResource: "IMG_0005", withExtension: "JPG", subdirectory: "TestImages"),
            let closeUpWater = Bundle.main.url(forResource: "IMG_0004", withExtension: "JPG", subdirectory: "TestImages"),
            let foliage = Bundle.main.url(forResource: "IMG_0002", withExtension: "JPG", subdirectory: "TestImages")
        else {
            append("ERROR: bundled TestImages missing")
            return
        }
        let promptTemplate = Bundle.main.url(forResource: "scene-prompt", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

        append("=== \(model) ===")
        append("device model memory: \(ProcessInfo.processInfo.physicalMemory / 1_048_576) MB physical")

        let scenarios: [(String, [URL], Bool, String, String)] = [
            ("wf-gold", [waterfallGold], false, "Skógar", "golden hour"),
            ("wf-dusk", [waterfallDusk], false, "Skógar", "dusk"),
            ("noplace", [foliage], false, "", "day"),
            ("multi", [waterfallGold, closeUpWater, waterfallDusk], true, "Skógar", "day to dusk"),
        ]

        // A snapshot pushed over USB into Documents/models/<repo-slug>/ is used
        // directly; otherwise the model downloads from the hub on-device.
        let repoSlug = model.split(separator: "/").last.map(String.init) ?? "model"
        let localModelDirectory = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("models/\(repoSlug)", isDirectory: true)

        var reports: [RunReport] = []
        for (slug, images, multi, place, light) in scenarios {
            let config = SpikeConfig(
                model: model,
                imageURLs: images,
                multi: multi,
                place: place,
                light: light,
                maxTokens: 256,
                // 512 on device (vs 1024 on the Mac): vision activations are the movable part
                // of the memory peak; without the entitlement 1024 px dies at the default
                // ceiling (signal 9 straight after load). Findings record the difference.
                resize: 512,
                promptTemplate: promptTemplate,
                localModelDirectory: localModelDirectory)
            let report = await runSpike(config: config) { line in
                Task { @MainActor in append(line) }
            }
            reports.append(report)
        }

        // Persist reports to Documents for retrieval via `devicectl device copy from`.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
            let data = try? encoder.encode(reports)
        {
            let slug = model.split(separator: "/").last.map(String.init) ?? "model"
            let url = docs.appendingPathComponent("spike-\(slug).json")
            try? data.write(to: url)
            append("[report] \(url.path)")
        }
        append("=== DONE \(model) ===")
    }
}

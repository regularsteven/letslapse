import Foundation
import LetsLapseKit

// The published shape of a running Ladder shoot, and the run's own log.
// The hook itself lives in `CameraController` (MARK: Light Ladder); this file
// holds what the HUD reads and what the bench pulls.

extension CameraController {
    /// What a Ladder run is on, republished every window. Everything the
    /// running HUD draws — the rail, the toast, the third readout line — and
    /// nothing it doesn't.
    struct LadderState: Equatable {
        var ladderName: String
        var rungIndex: Int
        /// Brightest first, for the rail and the toast's glyph.
        var rungNames: [String]
        /// Each rung's EV span inside the drawing window (16 … −2), brightest
        /// first — the rail's bar heights.
        var spans: [Double]
        /// The selector's 3-window average; nil before the first window.
        var smoothedEV: Double?
        /// The pacing actually applied this window, governor included.
        var intervalSeconds: Double
        var blendFrames: Int
        /// `Dusk · every 2 s · blend 3 → 2, thermal` — the readout's third line.
        var readoutLine: String
        /// Increments on every rung change; the toast keys on it.
        var changeCount: Int
        /// The rung below (darker) and the EV that enters it.
        var nextRungName: String?
        var nextRungThresholdEV: Double?
        /// The rung above (brighter).
        var previousRungName: String?

        var rungName: String { rungNames.indices.contains(rungIndex) ? rungNames[rungIndex] : "" }
    }
}

/// One NDJSON line per window under `Logs/ladder-<run>.jsonl` — beside the
/// experiment logs the bench already pulls — so a run's rung history travels
/// without the project: window, smoothed EV, the rung, the pacing asked and
/// applied, and what the governor yielded. `docs/light-ladder.md` §4.7.
final class LadderWindowWriter {
    private let url: URL
    private var handle: FileHandle?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    init(runStartedAt: Date) {
        let directory = StorageRoot.logsURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: runStartedAt)
            .replacingOccurrences(of: ":", with: "-")
        url = directory.appendingPathComponent("ladder-\(stamp).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    private struct Header: Encodable {
        var kind = "ladder"
        var ladderID: String
        var ladderName: String
        var rungs: [Rung]
        var openingRung: Int
        var sceneEV: Double?
        var pipeline: String
        var startedAt: Date
    }

    private struct Line: Encodable {
        var window: Int
        var at: Date
        var sceneEV: Double?
        var rung: Int
        var name: String
        var everyAsked: Double
        var everyApplied: Double
        var blendAsked: Int
        var blendApplied: Int
        var yieldedBy: String?
        var changed: Bool
    }

    func writeHeader(ladder: LightLadder, rungIndex: Int, sceneEV: Double?, pipeline: String) {
        write(Header(
            ladderID: ladder.id.uuidString, ladderName: ladder.name, rungs: ladder.rungs,
            openingRung: rungIndex, sceneEV: sceneEV, pipeline: pipeline, startedAt: Date()))
    }

    func append(window: Int, rungIndex: Int, rung: Rung, sceneEV: Double?,
                pacing: LightLadderPacing, changed: Bool) {
        let yielded: String?
        switch pacing.yield {
        case .depth: yielded = "depth"
        case .pace: yielded = "pace"
        case nil: yielded = nil
        }
        write(Line(
            window: window, at: Date(), sceneEV: sceneEV, rung: rungIndex, name: rung.name,
            everyAsked: rung.intervalSeconds, everyApplied: pacing.intervalSeconds,
            blendAsked: rung.blendFrames, blendApplied: pacing.blendFrames,
            yieldedBy: yielded, changed: changed))
    }

    private func write<T: Encodable>(_ value: T) {
        guard let handle, var data = try? encoder.encode(value) else { return }
        data.append(0x0A)
        try? handle.write(contentsOf: data)
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}

import Foundation
import LetsLapseKit

// The app's own score sheet for the shape detectors (2026-09-12). There is no
// ground truth inside the app; the person's verdicts are the truth. Every
// time a detection mode runs on a picture the sheet records what each engine
// proposed, and then what the person did: Add is a hit for every engine that
// proposed the shape, leaving a shape un-added is a false alarm for every
// engine that proposed it, and a shape the person added that an engine which
// ran did NOT propose is that engine's miss. Shapes are merged across engines
// FIRST (`ShapeFinder.merge`), so one object found by three engines is one
// candidate with three proposers and one verdict — an engine is never marked
// wrong because another engine's copy of the same shape was the one accepted;
// it proposed the same thing, so it is marked right. Append-only NDJSON in the
// library root; the Find shapes sheet summarises it, and it is the raw
// material for a later label set (a verdict is a label with a picture).

struct ShapeFeedbackEvent: Codable, Sendable {
    enum Verdict: String, Codable, Sendable {
        /// An engine ran on a picture (carries its time and count).
        case ran
        /// An engine proposed this candidate (carries how many engines did).
        case proposed
        case accepted, rejected, missed
        /// The person took a verdict back (undo): the candidate is open again.
        case pending
    }
    var at: Date
    var project: UUID
    var run: UUID
    var candidate: UUID?
    var engine: String
    var search: String
    var verdict: Verdict
    var kind: String?
    var family: String?
    var diameterPx: Double?
    var confidence: Float?
    var foundBy: Int?
    var milliseconds: Int?
    var shapes: Int?
}

final class ShapeDetectorFeedback: @unchecked Sendable {
    static let shared = ShapeDetectorFeedback()
    static let fileName = "ShapeDetectorFeedback.ndjson"

    private let queue = DispatchQueue(label: "com.regularsteven.letslapse.shapes.feedback")
    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    var url: URL { StorageRoot.current.appendingPathComponent(Self.fileName) }

    // MARK: - Writing

    func record(_ events: [ShapeFeedbackEvent]) {
        guard !events.isEmpty else { return }
        let url = self.url
        queue.async { [encoder] in
            var data = Data()
            for e in events {
                guard let line = try? encoder.encode(e) else { continue }
                data.append(line); data.append(0x0A)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// A pass has run: one `ran` event per engine, one `proposed` event per
    /// candidate per engine that found it, and an `accepted` for every engine
    /// that found a shape the register already held (agreement with a shape a
    /// person kept is a hit).
    func recordPass(_ pass: ShapeFinder.Pass, project: UUID, listed: (DetectedShape) -> Bool) {
        let now = Date()
        var events: [ShapeFeedbackEvent] = []
        let search = pass.mode.search.token
        for run in pass.engines {
            events.append(ShapeFeedbackEvent(at: now, project: project, run: pass.runID, candidate: nil, engine: run.engine.rawValue,
                                             search: search, verdict: .ran, milliseconds: run.milliseconds, shapes: run.failed ? nil : run.shapes))
        }
        for found in pass.found {
            let already = listed(found.shape)
            for engine in found.foundBy {
                events.append(event(now, project: project, pass: pass, found: found, engine: engine, verdict: .proposed))
                if already { events.append(event(now, project: project, pass: pass, found: found, engine: engine, verdict: .accepted)) }
            }
        }
        record(events)
    }

    /// The person's verdict on one candidate: accepted → every proposer is
    /// right and every engine that ran without proposing it missed; rejected
    /// → every proposer raised a false alarm; pending (an undo) → every
    /// engine's earlier verdict on it is withdrawn.
    func recordVerdict(_ verdict: ShapeFeedbackEvent.Verdict, for found: ShapeFinder.Found, in pass: ShapeFinder.Pass, project: UUID) {
        let now = Date()
        var events: [ShapeFeedbackEvent] = []
        for engine in found.foundBy {
            events.append(event(now, project: project, pass: pass, found: found, engine: engine, verdict: verdict))
        }
        if verdict == .accepted || verdict == .pending {
            for run in pass.engines where !run.failed && !found.foundBy.contains(run.engine) {
                events.append(event(now, project: project, pass: pass, found: found, engine: run.engine,
                                    verdict: verdict == .accepted ? .missed : .pending))
            }
        }
        record(events)
    }

    private func event(_ at: Date, project: UUID, pass: ShapeFinder.Pass, found: ShapeFinder.Found,
                       engine: ShapeDetectionMode.Engine, verdict: ShapeFeedbackEvent.Verdict) -> ShapeFeedbackEvent {
        ShapeFeedbackEvent(at: at, project: project, run: pass.runID, candidate: found.id, engine: engine.rawValue,
                           search: pass.mode.search.token, verdict: verdict, kind: found.shape.kind.rawValue,
                           family: found.shape.family.rawValue, diameterPx: found.shape.nativeDiameterPx,
                           confidence: found.confidences[engine], foundBy: found.foundBy.count)
    }

    func clear() {
        let url = self.url
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Reading

    struct Score: Identifiable, Equatable {
        var engine: ShapeDetectionMode.Engine
        var searches: Set<String>
        var runs: Int
        var proposed: Int
        /// Proposals at least one other engine made too (Use All runs).
        var agreed: Int
        var accepted: Int
        var rejected: Int
        var missed: Int
        var medianMs: Int?
        var id: String { engine.rawValue }
        var precision: Double? { accepted + rejected > 0 ? Double(accepted) / Double(accepted + rejected) : nil }
        var recall: Double? { accepted + missed > 0 ? Double(accepted) / Double(accepted + missed) : nil }
    }

    func events() -> [ShapeFeedbackEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(ShapeFeedbackEvent.self, from: $0) }
    }

    /// One row per engine. Verdicts resolve per (run, candidate, engine): the
    /// last one written wins, and a `pending` (an undo) counts as none.
    func summary() -> [Score] {
        let all = events()
        guard !all.isEmpty else { return [] }
        struct Key: Hashable { var run: UUID; var candidate: UUID?; var engine: String }
        var runs: [String: Set<UUID>] = [:]
        var ms: [String: [Int]] = [:]
        var searches: [String: Set<String>] = [:]
        var proposed: [Key: Int] = [:]
        var verdict: [Key: ShapeFeedbackEvent.Verdict] = [:]
        for e in all {
            searches[e.engine, default: []].insert(e.search)
            switch e.verdict {
            case .ran:
                runs[e.engine, default: []].insert(e.run)
                if let m = e.milliseconds { ms[e.engine, default: []].append(m) }
            case .proposed:
                proposed[Key(run: e.run, candidate: e.candidate, engine: e.engine)] = e.foundBy ?? 1
            case .accepted, .rejected, .missed, .pending:
                verdict[Key(run: e.run, candidate: e.candidate, engine: e.engine)] = e.verdict
            }
        }
        var out: [Score] = []
        for engine in ShapeDetectionMode.Engine.allCases where engine != .all {
            let id = engine.rawValue
            let mine = proposed.filter { $0.key.engine == id }
            let verdicts = verdict.filter { $0.key.engine == id }
            let sorted = (ms[id] ?? []).sorted()
            let median = sorted.isEmpty ? nil : sorted[sorted.count / 2]
            let score = Score(engine: engine, searches: searches[id] ?? [], runs: runs[id]?.count ?? 0,
                              proposed: mine.count, agreed: mine.values.filter { $0 >= 2 }.count,
                              accepted: verdicts.values.filter { $0 == .accepted }.count,
                              rejected: verdicts.values.filter { $0 == .rejected }.count,
                              missed: verdicts.values.filter { $0 == .missed }.count, medianMs: median)
            if score.runs > 0 || score.proposed > 0 || !verdicts.isEmpty { out.append(score) }
        }
        return out
    }
}

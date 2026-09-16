import CoreLocation
import Foundation
import LetsLapseKit

/// Auto rename & tag's engine (2026-09-16): **analysis is cached, generation is not.**
///
/// Two stages, and the split is the load-bearing part:
///
/// - **Stage A — analysis.** Expensive. Runs once per asset, ever: the model reads the frame that
///   already backs the project's Gallery thumbnail and the raw reading is written beside the
///   project as a `SceneAnalysisRecord`, keyed by `assetID + sourceFrameID + schemaVersion`. A
///   changed thumbnail or a bumped schema invalidates; nothing else does.
/// - **Stage B — generation.** Cheap. Reads the record and produces a title and a tag set — the
///   Vision mapping or the language model's own words, then the suggestions reconciled against
///   the library's vocabulary (`SceneTagReconciler`). Re-runnable at no meaningful cost, so a
///   person who tags today and renames next month pays for one vision pass, not two.
///
/// Nothing runs on its own: analysis happens only when a person invokes the action, and the cache
/// is what stops the second invocation costing what the first one did. The engine is written so a
/// background scheduler could drive `analysis(for:)` later without restructuring — none ships.
///
/// Concurrency: analysis runs off the main actor, bounded to two at a time; Gemma runs strictly
/// serially regardless (the actor behind it is reentrant across its own suspension points, and two
/// generations at once is 5.6 GB the phone does not have). Cancelling a caller cancels its wait;
/// a record already written stays written.
@MainActor
final class AutoRenameEngine: ObservableObject {
    static let shared = AutoRenameEngine()

    // MARK: Instrumentation

    /// Every Stage A run this process has made — the number the acceptance check reads: re-running
    /// on the same selection must leave it where it was. Logged too, as
    /// `[autorename] analysis <id> frame=<frameID> engine=<engine>`.
    private(set) var analysisRuns = 0
    /// Notified on every Stage A run, for a harness that wants to count them.
    var onAnalysisStarted: ((UUID) -> Void)?

    // MARK: Types

    /// The capture's own facts — read live from the project each time, never cached to disk: they
    /// are free, and a stored copy could only drift.
    struct Facts: Equatable, Sendable {
        var place: String?
        /// The light word for the capture's clock ("dusk", "day to dusk").
        var light: String?
    }

    /// Stage B's answer for one project.
    struct Suggestion: Sendable {
        /// Empty when the engine writes no title (Vision) — which means keep the existing name.
        var title: String
        /// The tags to add, already reconciled: an existing tag as stored, or a new one as it
        /// would be stored. Tags the project already carries are left out.
        var tags: [SceneTagReconciler.Resolution]
        /// The engine's nouns for what is in frame — kept for search, never shown as chips.
        var elements: [String]
        var engine: SceneAnalysisRecord.Engine
        /// Whether Stage A was served from the record on disk.
        var fromCache: Bool
    }

    enum Failure: LocalizedError {
        case noFrame
        case unreadable

        var errorDescription: String? {
            switch self {
            case .noFrame: return "This project has no frame to look at."
            case .unreadable: return "Couldn't read this one."
            }
        }
    }

    private let limiter = AsyncLimiter(permits: 2)
    private let gemmaGate = AsyncLimiter(permits: 1)
    /// Place names for this process's life: a reverse geocode per row is a network round trip
    /// Apple rate-limits, and the fix never moves.
    private var facts: [UUID: Facts] = [:]

    // MARK: Engine selection

    /// Which engine a run uses: the installed language model when the person has it selected and
    /// it is on disk, Apple Vision otherwise. Not a cascade — one engine per run, recorded on the
    /// record it produces. Settings › AI Models' "Use the installed model for better results" is
    /// what flips this.
    static func engine(models: ModelManager = .shared) -> SceneAnalysisRecord.Engine {
        guard let active = models.activeModel, !active.isBuiltIn, models.isReady else { return .vision }
        return .gemma
    }

    // MARK: The frame

    /// The frame Stage A looks at — the one behind the project's Gallery tile — and its identity
    /// for the record: the path relative to the project folder, `@<seconds>` for a movie frame.
    func frame(for capture: AppModel.CaptureProject, model: AppModel) -> (frame: SceneFrameSampler.Frame, id: String)? {
        guard let url = model.thumbnailURL(for: capture) else { return nil }
        let folder = model.projectFolderURL(for: capture).standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        let relative = path.hasPrefix(folder) ? String(path.dropFirst(folder.count)) : url.lastPathComponent
        if model.mediaKind(for: capture) == .video {
            let seconds = Self.movieFrameSeconds
            return (.movie(url, seconds: seconds), "\(relative)@\(seconds)")
        }
        return (.still(url), relative)
    }

    /// The tile's own instant — `ProjectThumbnailGenerator.videoThumbnail` takes 0.2 s.
    static let movieFrameSeconds = 0.2

    // MARK: Facts

    func facts(for capture: AppModel.CaptureProject, model: AppModel) async -> Facts {
        if let known = facts[capture.id] { return known }
        let light = SceneContext.light(from: capture.createdAt, duration: capture.sourceDurationSeconds ?? 0)
        let locationFile = model.sourceClipURLs(for: capture).first ?? model.sourceFrameURLs(for: capture).first
        let place = await SceneContext.place(for: AutoNameController.location(of: locationFile))
        let read = Facts(place: place, light: light)
        facts[capture.id] = read
        return read
    }

    // MARK: Stage A

    /// The project's analysis: the record on disk when it is current, else one run of the model,
    /// written on the way out. Throws `Failure.noFrame` for a project with nothing to look at, and
    /// whatever the engine threw for a frame it could not read.
    func analysis(for capture: AppModel.CaptureProject, model: AppModel) async throws -> SceneAnalysisRecord {
        guard let (frame, frameID) = frame(for: capture, model: model) else { throw Failure.noFrame }
        let folder = model.projectFolderURL(for: capture)
        let id = capture.id

        if let cached = await Task.detached(priority: .userInitiated, operation: {
            SceneAnalysisRecord.current(inProjectFolder: folder, assetID: id, sourceFrameID: frameID)
        }).value {
            return cached
        }

        let engine = Self.engine()
        try await limiter.acquire()
        do {
            let record = try await run(engine, frame: frame, frameID: frameID, capture: capture, model: model)
            await limiter.release()
            return record
        } catch {
            await limiter.release()
            throw error
        }
    }

    /// One pass of `engine` over `frame`, inside the limiter's permit.
    private func run(
        _ engine: SceneAnalysisRecord.Engine, frame: SceneFrameSampler.Frame, frameID: String,
        capture: AppModel.CaptureProject, model: AppModel
    ) async throws -> SceneAnalysisRecord {
        try Task.checkCancellation()
        let id = capture.id
        let folder = model.projectFolderURL(for: capture)
        analysisRuns += 1
        onAnalysisStarted?(id)
        LLog("[autorename] analysis \(id.uuidString.prefix(8)) frame=\(frameID) engine=\(engine.rawValue)")

        let sample = try await SceneFrameSampler.sample(frame: frame)
        defer { SceneFrameSampler.cleanUp(sample) }
        guard let url = sample.frameURLs.first else { throw Failure.unreadable }

        let record: SceneAnalysisRecord
        switch engine {
        case .vision:
            let observed = try await Task.detached(priority: .userInitiated) {
                try VisionSceneAnalyzer.observe(url)
            }.value
            record = SceneAnalysisRecord(
                assetID: id, sourceFrameID: frameID, engine: .vision,
                labels: observed.identifiers.map { .init(identifier: $0.identifier, confidence: Double($0.confidence)) },
                hasText: observed.hasText, faceCount: observed.faceCount)
        case .gemma:
            // Strictly one generation at a time, whatever the limiter allows.
            try await gemmaGate.acquire()
            do {
                // The prompt wants the place and light words; they are read live, as the chips are.
                let facts = await facts(for: capture, model: model)
                let result = try await MLXSceneAnalyzer.shared.analyze(
                    SceneAnalysisRequest(imageURLs: [url], place: facts.place, light: facts.light))
                await gemmaGate.release()
                let labels = (result.subjectTags + result.elements).map {
                    SceneAnalysisRecord.Label(identifier: $0, confidence: 1)
                }
                record = SceneAnalysisRecord(
                    assetID: id, sourceFrameID: frameID, engine: .gemma, labels: labels,
                    sceneText: result.title.isEmpty ? nil : result.title)
            } catch {
                await gemmaGate.release()
                throw error
            }
        }

        // Written whether or not the caller is still waiting: the pass is paid for.
        await Task.detached(priority: .utility) {
            do { try record.write(inProjectFolder: folder) }
            catch { LLog("[autorename] could not write the record for \(id.uuidString.prefix(8)): \(error)") }
        }.value
        return record
    }

    // MARK: Stage B

    /// What the record says, in the app's own terms: the title (empty for Vision), the taxonomy
    /// tags, the elements — before reconciliation. Pure, so a cached record and a live pass agree.
    nonisolated static func generate(_ record: SceneAnalysisRecord, light: String?) -> (title: String, tags: [String], elements: [String]) {
        switch record.engine {
        case .vision:
            let observed = VisionSceneAnalyzer.FrameObservations(
                identifiers: record.labels.map { (identifier: $0.identifier, confidence: Float($0.confidence)) },
                hasText: record.hasText, faceCount: record.faceCount)
            let result = VisionSceneAnalyzer.assemble(from: observed, contextLight: light)
            return ("", result.subjectTags, result.elements)
        case .gemma:
            let identifiers = record.labels.map(\.identifier)
            return (record.sceneText ?? "",
                    identifiers.filter { SceneMetadata.taxonomy.contains($0) },
                    identifiers.filter { !SceneMetadata.taxonomy.contains($0) })
        }
    }

    /// How many of the engine's elements are offered as tags beside the taxonomy ones: enough for
    /// "Urban · Architecture · Waterfront", not enough to mint a vocabulary per row.
    static let elementTagCandidates = 3

    /// Stage B for one project: the suggestion, reconciled against the library's vocabulary and
    /// minus the tags the project already carries.
    func suggestion(for capture: AppModel.CaptureProject, model: AppModel, facts: Facts) async throws -> Suggestion {
        let wasCached = await isCached(capture, model: model)
        let record = try await analysis(for: capture, model: model)
        let generated = Self.generate(record, light: facts.light)
        let existing = SceneMetadata.orderedTaxonomy + model.libraryTags
        let applied = model.resolvedKeywords(for: capture)
        let candidates = generated.tags + generated.elements.prefix(Self.elementTagCandidates)
        return Suggestion(
            title: generated.title.trimmingCharacters(in: .whitespacesAndNewlines),
            tags: SceneTagReconciler.reconcile(candidates, existing: existing, applied: applied),
            elements: generated.elements,
            engine: record.engine,
            fromCache: wasCached)
    }

    /// Whether Stage A would be served from disk right now.
    func isCached(_ capture: AppModel.CaptureProject, model: AppModel) async -> Bool {
        guard let (_, frameID) = frame(for: capture, model: model) else { return false }
        let folder = model.projectFolderURL(for: capture)
        let id = capture.id
        return await Task.detached(priority: .userInitiated) {
            SceneAnalysisRecord.current(inProjectFolder: folder, assetID: id, sourceFrameID: frameID) != nil
        }.value
    }
}

// MARK: - A counting semaphore for tasks

/// Bounds how many callers are inside `withPermit` at once. Waiters queue in arrival order; a
/// waiter whose task is cancelled leaves the queue with `CancellationError`.
actor AsyncLimiter {
    private var available: Int
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(permits: Int) {
        available = max(1, permits)
    }

    func acquire() async throws {
        try Task.checkCancellation()
        if available > 0 {
            available -= 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // The handler can run before this line (a cancel that lands while the actor hop
                // was pending finds no waiter to drop); so a task already cancelled never joins.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.drop(id) }
        }
    }

    func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().continuation.resume()
        } else {
            available += 1
        }
    }

    private func drop(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

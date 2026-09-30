import Foundation
import LetsLapseKit

// MARK: - Blend jobs that outlive the app
//
// Until 2026-09-30 a blend was a `Task` and ~25 values copied into it: send
// the app to the background (iOS refuses GPU work there, and a phone left to
// auto-lock backgrounds it), quit it, or lose it to a crash, and the run was
// gone — nothing on disk said what it was making or how far it had got.
//
// A job is now a folder, `Projects/<id>/.jobs/blend-<job id>/`, holding:
//
// - `job.json` — this record: the Adjust recipe the run was started with
//   (enough to rebuild it exactly), and a checkpoint per blend PASS;
// - one folder per pass (`main`, or `clip-N` / `piece-N` for a shoot blended
//   segment by segment) holding the finished pieces the Kit's resumable
//   engines write (`BlendSegments.swift`);
// - a finished pass's output, kept here rather than in `tmp/` (which iOS may
//   purge and Clear cache empties), so a resume skips the pass outright.
//
// The tail passes (reframe, crop, grade, slicing) are short re-encodes of the
// finished clip and simply run again. `.jobs/` is hidden: never carried by an
// archive or a transfer, never counted in a project's storage, and excluded
// from backup.

/// Why a job is not running.
enum BlendJobHold: String, Codable {
    /// Someone pressed Pause.
    case person
    /// The app left the foreground — iOS allows no GPU work there. Resumes by
    /// itself when the app comes back.
    case background
    /// The app quit, or was killed, mid-run: found at the next launch.
    case interrupted
}

/// The Adjust screen's recipe as the run started with it — the raw settings,
/// not what they compile to, so a resume rebuilds the run through exactly the
/// code that built it the first time.
struct BlendJobRecipe: Codable, Equatable {
    var constantWindow: Int
    var photoBlendDepth: Int
    var outputFPS: Int
    var linearLight: Bool
    var useRamp: Bool
    var rampStart: Int
    var rampEnd: Int
    var curve: String
    var trimVideoEnds: Bool
    var trimHeadTailSeconds: Double
    var blendSourceCodec: String?
    var warp: WarpTimeline?
    var reframe: ReframeTrack?
    /// The canvas the person CHOSE (nil = as shot) — not the effective one a
    /// finished blend records, which would read back as a choice.
    var blendCanvasRatio: String?
    var blendCanvasOffset: Double
    var exportShortEdge: Int?
    var timeSlice: TimeSliceSettings?
    var timeSliceVariations: TimeSliceVariationPlan?
    /// The Create menu's format override for this run ("hevc10" / "h264").
    var blendProfile: String?
    var excludedFrameIndices: [Int]
    var applyStabilisation: Bool
}

/// A pass's output once it finished — enough to hand it to the tail passes
/// again without re-blending.
struct BlendJobPassOutput: Codable, Equatable {
    var fileName: String
    /// The recipe key the pass was made under — reused only under the same
    /// one: a stills pass made before the project's look changed is not the
    /// pass the job would make now.
    var recipeKey: String?
    var isImage: Bool
    var summary: String
    var inputFrames: Int?
    var outputFrames: Int?
    var width: Int?
    var height: Int?
    var geometryBaked: Bool
}

struct BlendJobPass: Codable, Equatable {
    var checkpoint: BlendCheckpoint?
    var output: BlendJobPassOutput?
}

struct BlendJobRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var captureID: UUID
    /// The project's title when the job started, for the offer's sentence.
    var projectName: String
    var createdAt: Date
    var updatedAt: Date
    /// nil while running.
    var hold: BlendJobHold?
    var recipe: BlendJobRecipe
    var passes: [String: BlendJobPass]
    /// Where the whole run's bar stood when it last moved.
    var fraction: Double
    var framesDone: Int?
    var framesTotal: Int?
    /// The launch that last ran it. A record saying "running" under any other
    /// launch's token is a job that launch never finished.
    var launchToken: UUID?
    /// The recipe key (`AppModel.blendJobLookKey`) when it last ran — what
    /// tells a paused job's card whether the project has changed since, so
    /// the job would have to start again.
    var recipeKey: String?
}

/// The job's folder and record on disk.
enum BlendJobFiles {
    static let jobsFolderName = ".jobs"
    static let folderPrefix = "blend-"
    static let recordName = "job.json"

    static func folder(projectFolder: URL, jobID: UUID) -> URL {
        projectFolder
            .appendingPathComponent(jobsFolderName, isDirectory: true)
            .appendingPathComponent(folderPrefix + jobID.uuidString, isDirectory: true)
    }

    static func load(folder: URL) -> BlendJobRecord? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(recordName)) else { return nil }
        return try? decoder.decode(BlendJobRecord.self, from: data)
    }

    /// Atomic: the record is either the old one or the new one, never half
    /// of each — it is the only account of the pieces.
    static func save(_ record: BlendJobRecord, folder: URL) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: folder.path) {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            // Scratch that can be rebuilt from the project: never backed up.
            var jobs = folder.deletingLastPathComponent()
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? jobs.setResourceValues(values)
        }
        try encoder.encode(record).write(to: folder.appendingPathComponent(recordName), options: .atomic)
    }

    /// Parks a job — the launch offer's Later: it stops being "interrupted"
    /// and waits on its project, like one paused with Resume Later.
    static func park(folder: URL) {
        guard var record = load(folder: folder) else { return }
        record.hold = .person
        record.updatedAt = Date()
        try? save(record, folder: folder)
    }

    /// Every blend job under a projects root, newest first. A folder whose
    /// record can't be read is left alone — never deleted on a guess.
    static func findAll(projectsRoot: URL) -> [(record: BlendJobRecord, folder: URL)] {
        let fileManager = FileManager.default
        guard let projects = try? fileManager.contentsOfDirectory(atPath: projectsRoot.path) else { return [] }
        var found: [(BlendJobRecord, URL)] = []
        for name in projects where UUID(uuidString: name) != nil {
            let jobs = projectsRoot.appendingPathComponent(name).appendingPathComponent(jobsFolderName)
            guard let entries = try? fileManager.contentsOfDirectory(atPath: jobs.path) else { continue }
            for entry in entries where entry.hasPrefix(folderPrefix) {
                let folder = jobs.appendingPathComponent(entry, isDirectory: true)
                if let record = load(folder: folder) { found.append((record, folder)) }
            }
        }
        return found.sorted { $0.0.updatedAt > $1.0.updatedAt }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// A job while this launch runs it: the record, its folder, and the control
/// the engines answer between frames. Checkpoints arrive on the engines'
/// threads and are written before the engine goes on, so the record on disk
/// never trails the pieces by more than the piece in flight.
final class BlendJobRun: @unchecked Sendable {
    let folder: URL
    let control = BlendRunControl()
    /// The part of every pass key the engines can't see (the look, the
    /// overlays, the framing lock) — see `AppModel.blendJobRecipeKey`.
    let recipeKey: String
    /// Roughly how much work goes into one piece: what a kill can lose.
    let segmentSeconds: TimeInterval
    /// Called (on the engine's thread) after each checkpoint is written, so
    /// the owner can note the whole run's bar beside it — a job a kill ends
    /// has no pause to record how far it got. Set before the run starts.
    var onCheckpointSaved: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var current: BlendJobRecord
    /// Why a pause was asked for, so the pause the engine throws back is
    /// recorded as that — and an error thrown while it was pending (the GPU
    /// refusing work in the background) reads as the same pause.
    private var requestedHold: BlendJobHold?
    /// Set once the folder is gone: a write that arrives later (a checkpoint
    /// callback still in flight) must not bring the job back.
    private var discarded = false

    init(record: BlendJobRecord, folder: URL, recipeKey: String, segmentSeconds: TimeInterval) {
        self.current = record
        self.folder = folder
        self.recipeKey = recipeKey
        self.segmentSeconds = segmentSeconds
    }

    var record: BlendJobRecord {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    var pendingHold: BlendJobHold? {
        lock.lock(); defer { lock.unlock() }
        return requestedHold
    }

    /// Changes the record and writes it, in one step. The write happens
    /// under the lock too: two writers (a checkpoint from the engine, a
    /// progress note from the main actor) must land in the order they
    /// changed the record, or the older one could be the file left on disk.
    func update(_ change: (inout BlendJobRecord) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !discarded else { return }
        change(&current)
        current.updatedAt = Date()
        do {
            try BlendJobFiles.save(current, folder: folder)
        } catch {
            LLog("blend job \(current.id.uuidString.prefix(8)): record not saved — \(error.localizedDescription)")
        }
    }

    func requestPause(_ hold: BlendJobHold) {
        lock.lock()
        if requestedHold == nil { requestedHold = hold }
        lock.unlock()
        control.requestPause()
    }

    /// A Cancel after a Pause: the stop that follows is a discard, not a hold.
    func clearPendingHold() {
        lock.lock()
        requestedHold = nil
        lock.unlock()
    }

    /// The pieces' folder and resume point for one pass.
    func segmentation(forPass key: String) -> BlendSegmentation {
        let directory = folder.appendingPathComponent(key, isDirectory: true)
        let resume = record.passes[key]?.checkpoint
        return BlendSegmentation(
            directory: directory,
            recipeKey: recipeKey,
            resume: resume,
            control: control,
            targetSegmentSeconds: segmentSeconds,
            onCheckpoint: { [weak self] checkpoint in
                self?.update { record in
                    record.passes[key, default: BlendJobPass()].checkpoint = checkpoint
                }
                self?.onCheckpointSaved?()
            })
    }

    /// A pass that already finished under this run's recipe key, with its
    /// output still on disk.
    func finishedPass(_ key: String) -> (output: BlendJobPassOutput, url: URL)? {
        guard let output = record.passes[key]?.output, output.recipeKey == recipeKey else { return nil }
        let url = folder.appendingPathComponent(output.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (output, url)
    }

    /// Moves a finished pass's output from `tmp/` into the job and records
    /// it; the pass's pieces are no longer needed once it has. Returns where
    /// the output now lives.
    func keep(_ url: URL, as output: BlendJobPassOutput, forPass key: String) throws -> URL {
        var output = output
        output.recipeKey = recipeKey
        let destination = folder.appendingPathComponent(output.fileName)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: url, to: destination)
        update { record in
            record.passes[key, default: BlendJobPass()].output = output
        }
        try? fileManager.removeItem(at: folder.appendingPathComponent(key, isDirectory: true))
        return destination
    }

    /// The job is over — finished or cancelled: its folder goes.
    func discard() {
        lock.lock()
        discarded = true
        lock.unlock()
        try? FileManager.default.removeItem(at: folder)
    }
}

/// What a screen needs to show a job it isn't running: the offer at launch,
/// the project's paused row.
struct BlendJobSummary: Identifiable, Equatable {
    var id: UUID
    var captureID: UUID
    var projectName: String
    var hold: BlendJobHold
    var fraction: Double
    var framesDone: Int?
    var framesTotal: Int?
    var updatedAt: Date
    var folder: URL
    var recipeKey: String?
    var stabilised: Bool

    init(record: BlendJobRecord, folder: URL) {
        id = record.id
        captureID = record.captureID
        projectName = record.projectName
        hold = record.hold ?? .interrupted
        fraction = record.fraction
        framesDone = record.framesDone
        framesTotal = record.framesTotal
        updatedAt = record.updatedAt
        self.folder = folder
        recipeKey = record.recipeKey
        stabilised = record.recipe.applyStabilisation
    }

    /// Whether the last close interrupted it (the launch offer's jobs), as
    /// opposed to someone parking it.
    var wasInterrupted: Bool { hold != .person }
}

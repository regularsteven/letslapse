import Foundation
import AVFoundation
import CoreVideo
import CryptoKit

// MARK: - Resumable blends
//
// A blend used to be one `AVAssetWriter` writing one file that only became a
// movie when the last frame was in: background the app (iOS forbids GPU work
// there), let the phone lock, quit, or crash, and the whole run was lost — the
// half-written file had no index, and nothing had recorded how far it got.
//
// A resumable blend writes its output as a run of short, finished movies
// ("pieces", `BlendSegment`) — each closed and renamed into place whenever
// about `targetSegmentSeconds` of work has gone into it — and reports a
// `BlendCheckpoint` after every one. Output frame k depends only on the input
// frames its window covers, the options, and k itself (the dither is seeded
// with k; the accumulator is reset per window), so a pass restarted at the
// frame after a piece reproduces exactly what an unbroken run would have
// written. At the end the pieces are joined, without re-encoding, into the
// file the caller asked for. Losing work means losing the piece in flight —
// seconds, never the run.

/// How a running blend is asked to stop, keep its work, or close the piece it
/// is writing. The app asks from any thread; the engine answers between output
/// frames.
public final class BlendRunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var pauseRequested = false
    private var checkpointRequested = false
    private var cancelRequested = false

    public init() {}

    /// Stop after the frame being made, keep everything finished — the piece
    /// in flight is closed and kept — and throw `LapseError.paused`. A pass
    /// that reaches its last frame first simply finishes.
    public func requestPause() {
        lock.lock(); pauseRequested = true; lock.unlock()
    }

    /// Close the piece in flight after the frame being made, and carry on:
    /// a checkpoint without a stop. The app asks when it is about to lose the
    /// foreground, so a background that follows costs almost nothing.
    public func requestCheckpoint() {
        lock.lock(); checkpointRequested = true; lock.unlock()
    }

    /// Stop now. The piece in flight is thrown away; finished pieces stay on
    /// disk for whoever owns the folder to keep or delete.
    public func cancel() {
        lock.lock(); cancelRequested = true; lock.unlock()
    }

    public var isPauseRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return pauseRequested
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelRequested
    }

    /// True once per `requestCheckpoint()`.
    func takeCheckpointRequest() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let requested = checkpointRequested
        checkpointRequested = false
        return requested
    }
}

/// A `CMTime` that survives JSON: value and timescale, which is all a
/// presentation time read off a sample carries.
public struct BlendCheckpointTime: Codable, Equatable, Sendable {
    public var value: Int64
    public var timescale: Int32

    public init(_ time: CMTime) {
        value = time.value
        timescale = time.timescale
    }

    public var time: CMTime { CMTime(value: value, timescale: timescale) }
}

/// One finished piece of a resumable blend's output: a whole, playable movie
/// holding output frames `firstOutputFrame ..< firstOutputFrame + outputFrames`.
public struct BlendSegment: Codable, Equatable, Sendable {
    public var fileName: String
    public var firstOutputFrame: Int
    public var outputFrames: Int
    public var firstInputFrame: Int
    public var inputFrames: Int

    public init(fileName: String, firstOutputFrame: Int, outputFrames: Int, firstInputFrame: Int, inputFrames: Int) {
        self.fileName = fileName
        self.firstOutputFrame = firstOutputFrame
        self.outputFrames = outputFrames
        self.firstInputFrame = firstInputFrame
        self.inputFrames = inputFrames
    }
}

/// Where a resumable blend got to: the pieces it finished and the exact point
/// the next one starts. Written by the engine after every piece; handed back
/// to pick the pass up.
public struct BlendCheckpoint: Codable, Equatable, Sendable {
    /// The pass this belongs to — a fingerprint of its inputs, schedule and
    /// encode (`BlendSegmentation.recipeKey` folded in). A checkpoint only
    /// resumes the pass that wrote it; any other pass starts afresh.
    public var passKey: String
    public var segments: [BlendSegment]
    /// The output frame the next piece starts with.
    public var nextOutputFrame: Int
    /// Input frames consumed by the finished pieces — the index of the next
    /// input frame.
    public var consumedInputFrames: Int
    /// Video only: the presentation time of that next input frame, where the
    /// reader seeks on resume. Nil for stills, whose inputs are a list.
    public var resumeInputTime: BlendCheckpointTime?
    public var width: Int
    public var height: Int
    /// What the pieces were encoded as ("h264", "hevc", "prores", "jpeg"):
    /// every piece of a pass must share it, so a stills blend that fell back
    /// from HEVC to H.264 stays on H.264 when it resumes.
    public var codec: String
    /// How far through the pass this is, 0…1, for a paused job's readout.
    public var fraction: Double

    public init(
        passKey: String, segments: [BlendSegment], nextOutputFrame: Int,
        consumedInputFrames: Int, resumeInputTime: BlendCheckpointTime?,
        width: Int, height: Int, codec: String, fraction: Double
    ) {
        self.passKey = passKey
        self.segments = segments
        self.nextOutputFrame = nextOutputFrame
        self.consumedInputFrames = consumedInputFrames
        self.resumeInputTime = resumeInputTime
        self.width = width
        self.height = height
        self.codec = codec
        self.fraction = fraction
    }

    /// Output frames already finished.
    public var outputFramesDone: Int {
        segments.reduce(0) { $0 + $1.outputFrames }
    }
}

/// Asks an engine for a resumable run.
public struct BlendSegmentation: Sendable {
    /// Where the pieces live. The pass owns it: files in it that the resumed
    /// checkpoint doesn't name are removed when the pass starts.
    public var directory: URL
    /// What the engine can't see for itself but its frames depend on — the
    /// app's grade, overlays, framing lock — as a stable string. Folded into
    /// the pass key, so a change to any of it restarts the pass rather than
    /// joining pieces made two different ways.
    public var recipeKey: String
    /// The checkpoint to pick up from, or nil for a fresh pass.
    public var resume: BlendCheckpoint?
    public var control: BlendRunControl
    /// Roughly how much work goes into one piece, in wall-clock seconds —
    /// the most a kill can lose.
    public var targetSegmentSeconds: TimeInterval
    /// Called on the engine's thread after each finished piece. Persist it:
    /// it is the only record of the pieces.
    public var onCheckpoint: @Sendable (BlendCheckpoint) -> Void

    public init(
        directory: URL,
        recipeKey: String = "",
        resume: BlendCheckpoint? = nil,
        control: BlendRunControl = BlendRunControl(),
        targetSegmentSeconds: TimeInterval = 10,
        onCheckpoint: @escaping @Sendable (BlendCheckpoint) -> Void = { _ in }
    ) {
        self.directory = directory
        self.recipeKey = recipeKey
        self.resume = resume
        self.control = control
        self.targetSegmentSeconds = targetSegmentSeconds
        self.onCheckpoint = onCheckpoint
    }
}

enum BlendSegments {
    /// The pass key: SHA-256 over the engine's own description of the pass
    /// and the caller's recipe key.
    static func passKey(engine: String, recipeKey: String) -> String {
        let digest = SHA256.hash(data: Data("\(engine)\n\(recipeKey)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A short stable hash of a window schedule or a list of times, for an
    /// engine description.
    static func digest<T>(_ values: [T]) -> String {
        let text = values.map { "\($0)" }.joined(separator: ",")
        return SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// An input file's identity for a pass key: its name, size and
    /// modification time — enough to notice a replaced source.
    static func fileIdentity(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? -1
        let modified = values?.contentModificationDate.map { Int($0.timeIntervalSince1970) } ?? -1
        return "\(url.lastPathComponent):\(size):\(modified)"
    }

    /// The checkpoint worth resuming from, or nil to start afresh. A
    /// checkpoint only counts for its own pass, and only if every piece it
    /// names is still on disk, in order, frame for frame contiguous — a piece
    /// is renamed into place only once its writer has finished, so being
    /// there means being whole. Anything short of that restarts the pass: a
    /// resume must never join pieces that don't line up.
    static func validResume(_ checkpoint: BlendCheckpoint?, passKey: String, directory: URL) -> BlendCheckpoint? {
        guard let checkpoint, checkpoint.passKey == passKey,
              checkpoint.nextOutputFrame > 0, !checkpoint.segments.isEmpty else { return nil }
        var output = 0
        var input = 0
        for segment in checkpoint.segments {
            guard segment.firstOutputFrame == output, segment.firstInputFrame == input,
                  segment.outputFrames > 0,
                  FileManager.default.fileExists(atPath: directory.appendingPathComponent(segment.fileName).path)
            else { return nil }
            output += segment.outputFrames
            input += segment.inputFrames
        }
        guard output == checkpoint.nextOutputFrame, input == checkpoint.consumedInputFrames else { return nil }
        return checkpoint
    }

    /// Clears the pass's folder of everything a resume doesn't use: stale
    /// pieces from another pass, and the half-written piece a kill left.
    static func prepare(directory: URL, keeping checkpoint: BlendCheckpoint?) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let kept = Set(checkpoint?.segments.map(\.fileName) ?? [])
        let contents = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in contents where name.hasPrefix(pieceStem) && !kept.contains(name) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    static let pieceStem = "piece-"

    static func pieceName(firstOutputFrame: Int, fileExtension: String) -> String {
        String(format: "\(pieceStem)%07d.%@", firstOutputFrame, fileExtension)
    }

    static func partialName(firstOutputFrame: Int, fileExtension: String) -> String {
        String(format: "\(pieceStem)%07d.partial.%@", firstOutputFrame, fileExtension)
    }

    static func codecName(_ codec: AVVideoCodecType) -> String {
        switch codec {
        case .hevc: return "hevc"
        case .h264: return "h264"
        case .jpeg: return "jpeg"
        default: return "prores"
        }
    }
}

// MARK: - The writer

/// The engines' writer: one movie straight to the output (no segmentation —
/// exactly the writer the engines always had), or a run of pieces joined at
/// the end. The engine asks it for each frame's buffer pool (which opens a
/// piece when none is open), appends, and after each frame asks whether the
/// piece should close.
final class SegmentedMovieWriter {
    struct Endpoint {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
    }

    private struct OpenPiece {
        let endpoint: Endpoint
        let partialURL: URL
        let firstOutputFrame: Int
        let firstInputFrame: Int
        var outputFrames = 0
        let openedAt: Date
    }

    let output: URL
    let segmentation: BlendSegmentation?
    private let fileType: AVFileType
    private let fileExtension: String
    private let transform: CGAffineTransform
    /// Builds a configured writer for one file — input attached, NOT yet
    /// started: the piece's timescale has to be set before `startWriting()`.
    private let makeEndpoint: (URL) throws -> Endpoint
    private(set) var segments: [BlendSegment]
    private var open: OpenPiece?

    init(
        output: URL,
        fileType: AVFileType,
        transform: CGAffineTransform = .identity,
        segmentation: BlendSegmentation?,
        resumed: BlendCheckpoint?,
        makeEndpoint: @escaping (URL) throws -> Endpoint
    ) {
        self.output = output
        self.fileType = fileType
        self.fileExtension = fileType == .mov ? "mov" : "mp4"
        self.transform = transform
        self.segmentation = segmentation
        self.segments = resumed?.segments ?? []
        self.makeEndpoint = makeEndpoint
    }

    var isSegmented: Bool { segmentation != nil }

    /// The pool output frame `outputFrame` is made in — opening a piece at
    /// `time` if none is open. The first piece of a pass starts its session
    /// at zero, as the single file always did, so a capture-clock layout that
    /// begins after zero keeps its lead-in; every later piece starts at its
    /// own first frame.
    func pool(forOutputFrame outputFrame: Int, firstInputFrame: Int, at time: CMTime) throws -> CVPixelBufferPool {
        if open == nil {
            let target: URL
            if segmentation != nil {
                target = segmentation!.directory.appendingPathComponent(
                    BlendSegments.partialName(firstOutputFrame: outputFrame, fileExtension: fileExtension))
            } else {
                target = output
            }
            try? FileManager.default.removeItem(at: target)
            let endpoint = try makeEndpoint(target)
            if segmentation != nil {
                // Frame-exact edits: the default movie timescale (600) would
                // round each piece's edges to 1/600 s.
                endpoint.writer.movieTimeScale = 60000
            }
            guard endpoint.writer.startWriting() else {
                try? FileManager.default.removeItem(at: target)
                throw LapseError.writerFailed(
                    writerFailureDescription(endpoint.writer.error, fallback: "could not start encoding"))
            }
            endpoint.writer.startSession(atSourceTime: outputFrame == 0 ? .zero : time)
            open = OpenPiece(
                endpoint: endpoint, partialURL: target, firstOutputFrame: outputFrame,
                firstInputFrame: firstInputFrame, openedAt: Date())
        }
        guard let pool = open!.endpoint.adaptor.pixelBufferPool else {
            throw LapseError.writerFailed(
                "no pixel buffer pool (writer status \(open!.endpoint.writer.status.rawValue))")
        }
        return pool
    }

    /// Appends the frame whose pool was just asked for.
    func append(_ buffer: CVPixelBuffer, at time: CMTime) throws {
        guard let endpoint = open?.endpoint else {
            throw LapseError.writerFailed("no open writer to append to")
        }
        while !endpoint.input.isReadyForMoreMediaData {
            if endpoint.writer.status == .failed {
                throw LapseError.writerFailed(writerFailureDescription(endpoint.writer.error, fallback: "encoder failed"))
            }
            usleep(2000)
        }
        guard endpoint.adaptor.append(buffer, withPresentationTime: time) else {
            throw LapseError.writerFailed(writerFailureDescription(endpoint.writer.error, fallback: "frame append failed"))
        }
        open!.outputFrames += 1
    }

    /// Whether the piece in flight should close after the frame just
    /// appended: it has had its share of work, or the app asked.
    func pieceIsDue() -> Bool {
        guard let segmentation, let open, open.outputFrames > 0 else { return false }
        let asked = segmentation.control.takeCheckpointRequest()
        return asked || Date().timeIntervalSince(open.openedAt) >= segmentation.targetSegmentSeconds
    }

    var hasOpenFrames: Bool { (open?.outputFrames ?? 0) > 0 }

    /// Closes the piece in flight. `endTime` is the next output frame's time,
    /// so the piece's last frame lasts exactly as long as it does in an
    /// unbroken file; nil (the pass's last piece) leaves the ending to the
    /// writer, as the single file always did.
    @discardableResult
    func closePiece(endTime: CMTime?, consumedInputFrames: Int) throws -> BlendSegment? {
        guard let piece = open else { return nil }
        open = nil
        let endpoint = piece.endpoint
        endpoint.input.markAsFinished()
        if let endTime {
            endpoint.writer.endSession(atSourceTime: endTime)
        }
        let finished = DispatchSemaphore(value: 0)
        endpoint.writer.finishWriting { finished.signal() }
        finished.wait()
        guard endpoint.writer.status == .completed else {
            try? FileManager.default.removeItem(at: piece.partialURL)
            throw LapseError.writerFailed(writerFailureDescription(endpoint.writer.error, fallback: "could not finalize file"))
        }
        guard let segmentation else { return nil }
        let name = BlendSegments.pieceName(firstOutputFrame: piece.firstOutputFrame, fileExtension: fileExtension)
        let finalURL = segmentation.directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: finalURL)
        // The rename is the commit: a piece is either all there under its
        // own name or not there at all.
        try FileManager.default.moveItem(at: piece.partialURL, to: finalURL)
        let segment = BlendSegment(
            fileName: name,
            firstOutputFrame: piece.firstOutputFrame,
            outputFrames: piece.outputFrames,
            firstInputFrame: piece.firstInputFrame,
            inputFrames: consumedInputFrames - piece.firstInputFrame)
        segments.append(segment)
        return segment
    }

    /// Throws the piece in flight away — a cancel, or a failure mid-piece.
    func abandon() {
        guard let piece = open else { return }
        open = nil
        if piece.endpoint.writer.status == .writing {
            piece.endpoint.writer.cancelWriting()
        }
        if segmentation != nil {
            try? FileManager.default.removeItem(at: piece.partialURL)
        }
    }

    /// Ends the pass: closes the last piece and, when segmented, joins every
    /// piece into `output` without re-encoding.
    func finish(consumedInputFrames: Int) throws {
        try closePiece(endTime: nil, consumedInputFrames: consumedInputFrames)
        guard let segmentation else { return }
        let urls = segments.map { segmentation.directory.appendingPathComponent($0.fileName) }
        try SegmentJoiner.join(urls, to: output, fileType: fileType, transform: transform)
    }
}

// MARK: - Joining

/// Lays finished pieces end to end in one movie, samples copied as they are.
enum SegmentJoiner {
    /// Synchronous, for the engines' own threads: the join itself is async
    /// AVFoundation work, run on a detached task and waited for here. The
    /// engines call this off the main thread (their work queue, or a
    /// detached `.utility` task) at the very end of a pass.
    static func join(_ urls: [URL], to output: URL, fileType: AVFileType, transform: CGAffineTransform) throws {
        guard !urls.isEmpty else { throw LapseError.noInputFrames }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: output)
        // One piece is already the movie. Copied rather than moved: the
        // pieces belong to the job until the job says it is done with them.
        if urls.count == 1 {
            try fileManager.copyItem(at: urls[0], to: output)
            return
        }
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .utility) {
            do {
                try await joinAsync(urls, to: output, fileType: fileType, transform: transform)
            } catch {
                box.error = error
            }
            done.signal()
        }
        done.wait()
        if let error = box.error { throw error }
    }

    static func joinAsync(_ urls: [URL], to output: URL, fileType: AVFileType, transform: CGAffineTransform) async throws {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw LapseError.writerFailed("could not make a track to join the pieces")
        }
        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let source = try await asset.loadTracks(withMediaType: .video).first else {
                throw LapseError.noVideoTrack(url)
            }
            let range = try await source.load(.timeRange)
            guard range.duration > .zero else {
                throw LapseError.readerFailed("\(url.lastPathComponent) holds no frames")
            }
            try track.insertTimeRange(range, of: source, at: cursor)
            cursor = cursor + range.duration
        }
        track.preferredTransform = transform
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw LapseError.writerFailed("no passthrough export session to join the pieces")
        }
        export.outputURL = output
        export.outputFileType = fileType
        let session = ExportBox(export)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.session.exportAsynchronously {
                if session.session.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: LapseError.writerFailed(
                        writerFailureDescription(session.session.error, fallback: "joining the pieces failed")))
                }
            }
        }
    }

    private final class ResultBox: @unchecked Sendable {
        var error: Error?
    }

    private final class ExportBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }
}

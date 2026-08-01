import AVFoundation
import Foundation

/// Renders a collection to one video: each entry trimmed to its in/out points,
/// cropped and scaled onto the canvas, butt-joined in timeline order, exported
/// at the canvas ratio's maximum resolution. One controller per export run,
/// owned by the screen that started it.
///
/// The phases mirror the app's Processing pattern — explicit, event-driven,
/// each ticking exactly once. A single `AVAssetExportSession` genuinely does
/// decode → transform → encode in one pass, so the per-clip detail comes from
/// where the session's head *is* (its progress mapped into the timeline), not
/// from invented stage thresholds.
@MainActor
final class CollectionExportController: ObservableObject {
    enum Phase: Equatable {
        case preparing
        case rendering(clip: Int, of: Int)
        case combining(clips: Int)
        case saving
    }

    enum State: Equatable {
        case idle
        case exporting
        case done(URL)
        case failed(String)
        case cancelled
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusLine: String = "Getting started…"

    private let model: AppModel
    let collectionID: UUID

    private var session: AVAssetExportSession?
    private var pollTimer: Timer?
    private var exportTask: Task<Void, Never>?
    private var startedAt: Date?
    /// Cumulative end time (seconds) of each clip on the output timeline.
    private var clipBoundaries: [Double] = []
    private var totalSeconds: Double = 0
    private var clipCount = 0

    init(model: AppModel, collectionID: UUID) {
        self.model = model
        self.collectionID = collectionID
    }

    func start() {
        guard state == .idle || state == .cancelled else { return }
        guard let collection = model.collection(withID: collectionID),
              !collection.entries.isEmpty, collection.ratio != nil else {
            state = .failed("This collection has no clips to export.")
            return
        }
        // The kept render is still exactly what this recipe would produce —
        // exporting again is instant until clips, trims or crops change.
        if let cached = model.validCachedRender(for: collection) {
            state = .done(cached)
            return
        }
        state = .exporting
        phase = .preparing
        progress = 0
        statusLine = "Getting started…"
        startedAt = Date()
        clipCount = collection.entries.count
        exportTask = Task { await runExport(collection) }
    }

    func cancel() {
        exportTask?.cancel()
        session?.cancelExport()
        stopPolling()
        state = .cancelled
    }

    // MARK: - The run

    private func runExport(_ collection: LapseCollection) async {
        guard let ratio = collection.ratio else { return }
        do {
            let (composition, videoComposition) = try await buildComposition(collection, ratio: ratio)
            guard !Task.isCancelled else { return }

            guard let session = AVAssetExportSession(
                asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                throw ExportError.sessionUnavailable
            }
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("collection-export-\(UUID().uuidString).mp4")
            session.outputURL = scratch
            session.outputFileType = .mp4
            session.videoComposition = videoComposition
            self.session = session

            progress = 0.04
            phase = .rendering(clip: 1, of: clipCount)
            startPolling()

            await withCheckedContinuation { continuation in
                session.exportAsynchronously { continuation.resume() }
            }
            stopPolling()

            switch session.status {
            case .completed:
                phase = .saving
                progress = 0.98
                statusLine = "Almost done"
                let url = try finishExport(scratch: scratch, collection: collection)
                progress = 1
                state = .done(url)
            case .cancelled:
                try? FileManager.default.removeItem(at: scratch)
                state = .cancelled
            default:
                try? FileManager.default.removeItem(at: scratch)
                throw session.error ?? ExportError.exportFailed
            }
        } catch is CancellationError {
            state = .cancelled
        } catch {
            guard state == .exporting else { return }
            state = .failed(error.localizedDescription)
        }
    }

    /// One video track, one instruction per clip: trim by time range, then a
    /// per-segment transform that crops (resolved pan offset) and scales the
    /// clip onto the canvas.
    private func buildComposition(_ collection: LapseCollection, ratio: CanvasRatio)
        async throws -> (AVMutableComposition, AVMutableVideoComposition) {
        let renderSize = ratio.exportSize
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.sessionUnavailable
        }

        var cursor = CMTime.zero
        var instructions: [AVMutableVideoCompositionInstruction] = []
        clipBoundaries = []

        for entry in collection.entries {
            guard let url = model.blendMediaURL(for: entry.blendID) else {
                throw ExportError.missingClip
            }
            let asset = AVURLAsset(url: url)
            guard let assetTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw ExportError.missingClip
            }
            let duration = try await asset.load(.duration)
            let seconds = duration.seconds
            let start = CMTime(seconds: seconds * entry.inPoint, preferredTimescale: 600)
            let end = CMTime(seconds: seconds * entry.outPoint, preferredTimescale: 600)
            let range = CMTimeRange(start: start, end: end)
            guard range.duration.seconds > 0.01 else { continue }

            try track.insertTimeRange(range, of: assetTrack, at: cursor)

            let preferred = try await assetTrack.load(.preferredTransform)
            let natural = try await assetTrack.load(.naturalSize)
            let orientedRect = CGRect(origin: .zero, size: natural).applying(preferred)
            let orientedSize = CGSize(width: abs(orientedRect.width), height: abs(orientedRect.height))
            // Land the oriented picture at the origin before crop/scale math.
            let oriented = preferred.concatenating(
                CGAffineTransform(translationX: -orientedRect.minX, y: -orientedRect.minY))

            let transform: CGAffineTransform
            if let offset = model.resolvedCropOffset(entry: entry, in: collection),
               let box = CollectionMath.cropBox(clipSize: orientedSize, canvas: ratio, offset: offset) {
                // The kept rect fills the canvas exactly (it is canvas-shaped).
                let scale = renderSize.width / box.rect.width
                transform = oriented
                    .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    .concatenating(CGAffineTransform(
                        translationX: -box.rect.minX * scale, y: -box.rect.minY * scale))
            } else {
                // Matches the canvas (within tolerance): centred aspect-fill.
                let scale = max(renderSize.width / orientedSize.width,
                                renderSize.height / orientedSize.height)
                transform = oriented
                    .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    .concatenating(CGAffineTransform(
                        translationX: (renderSize.width - orientedSize.width * scale) / 2,
                        y: (renderSize.height - orientedSize.height * scale) / 2))
            }

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: range.duration)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(transform, at: cursor)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)

            cursor = CMTimeAdd(cursor, range.duration)
            clipBoundaries.append(cursor.seconds)
        }

        guard !instructions.isEmpty else { throw ExportError.missingClip }
        totalSeconds = cursor.seconds

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = instructions
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(
            value: 1, timescale: CMTimeScale(model.collectionExportFPS(collection)))
        return (composition, videoComposition)
    }

    /// The render moves in with its collection; the manifest remembers the
    /// recipe it satisfies so re-exports can skip the whole pipeline.
    private func finishExport(scratch: URL, collection: LapseCollection) throws -> URL {
        let folder = model.collectionRenderFolderURL(for: collection.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("render.mp4")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: scratch, to: destination)
        model.recordCollectionExport(
            collection.id, fileName: "render.mp4", recipe: model.collectionRecipe(collection))
        return destination
    }

    // MARK: - Progress

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollProgress() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollProgress() {
        guard let session, state == .exporting else { return }
        let p = Double(session.progress)
        progress = max(progress, 0.04 + p * 0.92)

        if p >= 0.995 {
            // The writer is finalizing the joined file.
            phase = .combining(clips: clipCount)
            statusLine = clipCount == 1 ? "Finishing up…" : "Combining \(clipCount) clips…"
            return
        }
        // Which clip the session's head is inside right now.
        let position = p * totalSeconds
        let index = clipBoundaries.firstIndex { position < $0 } ?? clipCount - 1
        phase = .rendering(clip: index + 1, of: clipCount)
        statusLine = etaLine(clip: index + 1)
    }

    private func etaLine(clip: Int) -> String {
        guard let startedAt, progress > 0.08 else { return "Getting started…" }
        let elapsed = Date().timeIntervalSince(startedAt)
        let remaining = max(2, elapsed * (1 - progress) / progress)
        let phrase: String
        if remaining < 8 {
            phrase = "Almost done"
        } else if remaining < 90 {
            phrase = "About \(Int((remaining / 5).rounded() * 5)) seconds left"
        } else {
            let minutes = Int((remaining / 60).rounded())
            phrase = "About \(minutes) minute\(minutes == 1 ? "" : "s") left"
        }
        return clipCount > 1 ? "\(phrase) · Clip \(clip) of \(clipCount)" : phrase
    }

    private enum ExportError: LocalizedError {
        case sessionUnavailable
        case missingClip
        case exportFailed

        var errorDescription: String? {
            switch self {
            case .sessionUnavailable: return "Couldn't start the export."
            case .missingClip: return "A clip in this collection is missing from the library."
            case .exportFailed: return "The export didn't finish."
            }
        }
    }
}

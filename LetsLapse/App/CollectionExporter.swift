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
    /// clip onto the canvas. Ken Burns collections take their own build —
    /// this plain path stays exactly what it always was.
    private func buildComposition(_ collection: LapseCollection, ratio: CanvasRatio)
        async throws -> (AVMutableComposition, AVMutableVideoComposition) {
        if collection.kenBurnsEnabled {
            return try await buildKenBurnsComposition(collection, ratio: ratio)
        }
        return try await buildPlainComposition(collection, ratio: ratio)
    }

    private func buildPlainComposition(_ collection: LapseCollection, ratio: CanvasRatio)
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

    // MARK: - Ken Burns build

    /// One clip's fully resolved place in a Ken Burns export: its source
    /// range, its span on the output timeline (retimed, fades overlapped),
    /// and the two crop framings the move animates between.
    private struct PlannedClip {
        /// The track is only usable while its asset lives — inserting from a
        /// track whose asset has deallocated fails with OSStatus -12780.
        let asset: AVURLAsset
        let assetTrack: AVAssetTrack
        let sourceRange: CMTimeRange
        let span: CMTimeRange
        let startTransform: CGAffineTransform
        let endTransform: CGAffineTransform
        let trackIndex: Int
    }

    /// Two alternating video tracks so neighbouring clips can overlap for the
    /// crossfade; every clip carries a transform ramp between its two Ken
    /// Burns framings. Consistent durations either rescale each clip's kept
    /// range to the target (auto speed) or take a target-length window from
    /// the clip's in point.
    private func buildKenBurnsComposition(_ collection: LapseCollection, ratio: CanvasRatio)
        async throws -> (AVMutableComposition, AVMutableVideoComposition) {
        guard let kenBurns = collection.kenBurns else {
            return try await buildPlainComposition(collection, ratio: ratio)
        }
        let renderSize = ratio.exportSize
        let scale600 = CMTimeScale(600)
        let target = Double(model.kenBurnsEffectiveClipSeconds(collection))

        var planned: [PlannedClip] = []
        var cursor = 0.0

        for (index, entry) in collection.entries.enumerated() {
            guard let url = model.blendMediaURL(for: entry.blendID) else {
                throw ExportError.missingClip
            }
            let asset = AVURLAsset(url: url)
            guard let assetTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw ExportError.missingClip
            }
            let full = try await asset.load(.duration).seconds

            let sourceStart: Double
            let sourceEnd: Double
            let outputSeconds: Double
            if kenBurns.consistentDurations, kenBurns.autoAdjustSpeed {
                // The whole kept range, sped up (only if required) to the target.
                sourceStart = full * entry.inPoint
                sourceEnd = full * entry.outPoint
                outputSeconds = min(target, sourceEnd - sourceStart)
            } else if kenBurns.consistentDurations {
                // A target-length window from the clip's in point, real speed.
                sourceStart = min(full * entry.inPoint, max(0, full - target))
                sourceEnd = min(full, sourceStart + target)
                outputSeconds = sourceEnd - sourceStart
            } else {
                sourceStart = full * entry.inPoint
                sourceEnd = full * entry.outPoint
                outputSeconds = sourceEnd - sourceStart
            }
            guard outputSeconds > 0.01 else { continue }

            let preferred = try await assetTrack.load(.preferredTransform)
            let natural = try await assetTrack.load(.naturalSize)
            let orientedRect = CGRect(origin: .zero, size: natural).applying(preferred)
            let orientedSize = CGSize(width: abs(orientedRect.width), height: abs(orientedRect.height))
            let oriented = preferred.concatenating(
                CGAffineTransform(translationX: -orientedRect.minX, y: -orientedRect.minY))

            // The crop box is the move's zoom-1 framing — for a clip that
            // matches the canvas it is simply the whole picture.
            let offset = model.resolvedCropOffset(entry: entry, in: collection) ?? 0.5
            guard let base = CollectionMath.cropBox(
                clipSize: orientedSize, canvas: ratio, offset: offset) else {
                throw ExportError.missingClip
            }
            let move = entry.kenBurns ?? .bestEffort(forClipIndex: index)
            let startRect = CollectionMath.kenBurnsRect(
                base: base.rect, zoom: move.startZoom,
                anchorX: move.startAnchorX, anchorY: move.startAnchorY)
            let endRect = CollectionMath.kenBurnsRect(
                base: base.rect, zoom: move.endZoom,
                anchorX: move.endAnchorX, anchorY: move.endAnchorY)

            var fade = 0.0
            if kenBurns.fadeTransition, let previous = planned.last {
                fade = model.kenBurnsFadeSeconds(
                    outgoing: previous.span.duration.seconds, incoming: outputSeconds)
            }
            let spanStart = max(0, cursor - fade)
            planned.append(PlannedClip(
                asset: asset,
                assetTrack: assetTrack,
                sourceRange: CMTimeRange(
                    start: CMTime(seconds: sourceStart, preferredTimescale: scale600),
                    end: CMTime(seconds: sourceEnd, preferredTimescale: scale600)),
                span: CMTimeRange(
                    start: CMTime(seconds: spanStart, preferredTimescale: scale600),
                    duration: CMTime(seconds: outputSeconds, preferredTimescale: scale600)),
                startTransform: canvasTransform(oriented: oriented, rect: startRect, renderWidth: renderSize.width),
                endTransform: canvasTransform(oriented: oriented, rect: endRect, renderWidth: renderSize.width),
                trackIndex: planned.count % 2))
            cursor = spanStart + outputSeconds
        }
        guard !planned.isEmpty else { throw ExportError.missingClip }

        let composition = AVMutableComposition()
        var tracks: [AVMutableCompositionTrack] = []
        for _ in 0..<2 {
            guard let track = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw ExportError.sessionUnavailable
            }
            tracks.append(track)
        }
        var trackEnds: [CMTime] = [.zero, .zero]
        for clip in planned {
            let track = tracks[clip.trackIndex]
            // Explicit gap up to the clip's start — alternating tracks are
            // mostly holes, and an implicit gap is not worth relying on.
            if clip.span.start > trackEnds[clip.trackIndex] {
                track.insertEmptyTimeRange(CMTimeRange(
                    start: trackEnds[clip.trackIndex], end: clip.span.start))
            }
            try track.insertTimeRange(clip.sourceRange, of: clip.assetTrack, at: clip.span.start)
            if abs(clip.sourceRange.duration.seconds - clip.span.duration.seconds) > 0.01 {
                track.scaleTimeRange(
                    CMTimeRange(start: clip.span.start, duration: clip.sourceRange.duration),
                    toDuration: clip.span.duration)
            }
            trackEnds[clip.trackIndex] = clip.span.end
        }

        // Instructions tile the output: solo stretches and (with fades) the
        // overlaps, cut at every clip boundary. Each segment re-derives its
        // slice of the clip's whole-span transform ramp, so motion is
        // continuous across the cuts; the earlier clip sits on top of an
        // overlap and fades out over the one arriving underneath.
        var boundaries: [Double] = []
        for clip in planned {
            boundaries.append(clip.span.start.seconds)
            boundaries.append(clip.span.end.seconds)
        }
        boundaries = boundaries.sorted().reduce(into: []) { result, time in
            if result.last.map({ time - $0 > 0.0005 }) ?? true { result.append(time) }
        }

        var instructions: [AVMutableVideoCompositionInstruction] = []
        for (start, end) in zip(boundaries, boundaries.dropFirst()) {
            let segment = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: scale600),
                end: CMTime(seconds: end, preferredTimescale: scale600))
            let covering = planned
                .filter { $0.span.start.seconds <= start + 0.0005 && $0.span.end.seconds >= end - 0.0005 }
                .sorted { $0.span.start < $1.span.start }
            guard !covering.isEmpty else { continue }

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = segment
            var layers: [AVMutableVideoCompositionLayerInstruction] = []
            for (position, clip) in covering.enumerated() {
                let layer = segmentLayer(for: clip, track: tracks[clip.trackIndex], segment: segment)
                if covering.count > 1, position == 0 {
                    layer.setOpacityRamp(
                        fromStartOpacity: 1, toEndOpacity: 0, timeRange: segment)
                }
                layers.append(layer)
            }
            instruction.layerInstructions = layers
            instructions.append(instruction)
        }
        guard !instructions.isEmpty else { throw ExportError.missingClip }

        clipBoundaries = planned.map { $0.span.end.seconds }
        totalSeconds = planned.last?.span.end.seconds ?? 0

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = instructions
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(
            value: 1, timescale: CMTimeScale(model.collectionExportFPS(collection)))
        return (composition, videoComposition)
    }

    /// Maps a source-space crop rect onto the canvas: orient, scale so the
    /// rect fills the render width (it is canvas-shaped, so height follows),
    /// then land the rect's corner on the origin.
    private func canvasTransform(
        oriented: CGAffineTransform, rect: CGRect, renderWidth: CGFloat
    ) -> CGAffineTransform {
        let scale = renderWidth / rect.width
        return oriented
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: -rect.minX * scale, y: -rect.minY * scale))
    }

    /// The slice of a clip's start→end transform ramp that falls inside one
    /// instruction segment. AVFoundation's ramps interpolate the matrix
    /// linearly, so lerping the endpoints ourselves keeps every segment's
    /// motion exactly on the clip's one line.
    private func segmentLayer(
        for clip: PlannedClip, track: AVCompositionTrack, segment: CMTimeRange
    ) -> AVMutableVideoCompositionLayerInstruction {
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let clipSeconds = clip.span.duration.seconds
        let f0 = clipSeconds > 0
            ? min(1, max(0, (segment.start.seconds - clip.span.start.seconds) / clipSeconds)) : 0
        let f1 = clipSeconds > 0
            ? min(1, max(0, (segment.end.seconds - clip.span.start.seconds) / clipSeconds)) : 1
        let from = lerpTransform(clip.startTransform, clip.endTransform, CGFloat(f0))
        let to = lerpTransform(clip.startTransform, clip.endTransform, CGFloat(f1))
        if from == to {
            layer.setTransform(from, at: segment.start)
        } else {
            layer.setTransformRamp(fromStart: from, toEnd: to, timeRange: segment)
        }
        return layer
    }

    private func lerpTransform(
        _ a: CGAffineTransform, _ b: CGAffineTransform, _ t: CGFloat
    ) -> CGAffineTransform {
        CGAffineTransform(
            a: a.a + (b.a - a.a) * t, b: a.b + (b.b - a.b) * t,
            c: a.c + (b.c - a.c) * t, d: a.d + (b.d - a.d) * t,
            tx: a.tx + (b.tx - a.tx) * t, ty: a.ty + (b.ty - a.ty) * t)
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

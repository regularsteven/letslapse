import AVFoundation
import CoreMedia
import LetsLapseKit

/// The one reader→writer export behind the tail passes over a finished blend —
/// the punch-in reframe, the canvas crop and the standalone grade bake. It
/// replaces `AVAssetExportSession(presetName: .highestQuality)` there: the
/// preset chose its own bitrate and wrote no colour tags, so the tail passes
/// were the last video writers in the app outside the shared
/// `VideoEncodePolicy`.
///
/// With a composition the video is rendered through it — the composition owns
/// geometry and orientation, so the writer keeps an identity transform.
/// Without one the frames come straight off the track (the policy's dimensions
/// must then be the track's natural size) and the source's
/// `preferredTransform` is carried across. Audio passes through untouched.
/// Cancelling the surrounding task stops the pumps, discards the partial file
/// and throws `CancellationError`.
enum CompositionExporter {
    /// The blocking pump parks a thread on `DispatchGroup.wait()`; a dedicated
    /// queue keeps that thread out of the concurrency pool. Serial is enough —
    /// the tail passes run one at a time.
    private static let queue = DispatchQueue(
        label: "com.letslapse.composition-export", qos: .userInitiated)

    /// Writes `asset` to `outputURL` through `policy`. `progress` (0…1) is by
    /// decoded frame against the clip's estimated frame count, reported from
    /// the pump's queue.
    ///
    /// Any `AVAsset` — the tail passes hand over a file, the stitch hands over
    /// the `AVMutableComposition` it just laid its pieces into. That second
    /// caller is why this is not `AVURLAsset`: the stitch used to run through
    /// `AVAssetExportSession(presetName: .highestQuality)`, which is a device
    /// capability budget rather than a passthrough and silently retimes what it
    /// cannot afford (see `stitchVideos`).
    static func export(
        asset: AVAsset,
        composition: AVVideoComposition?,
        to outputURL: URL,
        fileType: AVFileType,
        policy: VideoEncodePolicy,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportFailure("the clip has no video track")
        }
        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        // What the sound is, for the writer: a passthrough into anything but
        // a QuickTime movie needs the source's format said up front.
        let soundTrack: AVAssetTrack? = audioTrack ?? nil
        let audioFormat: CMFormatDescription? = try? await soundTrack?.load(.formatDescriptions).first
        let preferred = try await videoTrack.load(.preferredTransform)
        let duration = try await asset.load(.duration).seconds
        // Progress denominator only — a frame more or fewer just parks the bar
        // a hair short of full until the writer finalises.
        let estimatedFrames = max(1, Int((duration * policy.fps).rounded()))

        let state = PumpState()
        do {
            try Task.checkCancellation()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    queue.async {
                        do {
                            try run(
                                asset: asset,
                                videoTrack: videoTrack,
                                audioTrack: audioTrack ?? nil,
                                audioFormat: audioFormat,
                                composition: composition,
                                transform: composition == nil ? preferred : .identity,
                                outputURL: outputURL,
                                fileType: fileType,
                                policy: policy,
                                estimatedFrames: estimatedFrames,
                                state: state,
                                progress: progress)
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } onCancel: {
                state.cancel()
            }
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    /// Blocking reader→writer pump, `AppModel.runConversion`'s shape: the
    /// media pumps run on their own queues, so the `DispatchGroup.wait()` here
    /// is safe — this only ever runs on `queue`.
    private static func run(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        audioTrack: AVAssetTrack?,
        audioFormat: CMFormatDescription?,
        composition: AVVideoComposition?,
        transform: CGAffineTransform,
        outputURL: URL,
        fileType: AVFileType,
        policy: VideoEncodePolicy,
        estimatedFrames: Int,
        state: PumpState,
        progress: (@Sendable (Double) -> Void)?
    ) throws {
        try? FileManager.default.removeItem(at: outputURL)

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        } catch {
            throw ExportFailure(error.localizedDescription)
        }

        // Half-float frames for a Main10 encode so the encoder quantises to
        // 10-bit itself; BGRA everywhere else — the decode-side twin of the
        // policy's adaptor attributes.
        let pixelFormat: OSType = policy.profile == .hevcMain10
            ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA
        let videoOutput: AVAssetReaderOutput
        if let composition {
            let compositionOutput = AVAssetReaderVideoCompositionOutput(
                videoTracks: [videoTrack],
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat])
            compositionOutput.videoComposition = composition
            videoOutput = compositionOutput
        } else {
            videoOutput = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat])
        }
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw ExportFailure("cannot read the video track")
        }
        reader.add(videoOutput)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: policy.videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else {
            throw ExportFailure("cannot write the video track")
        }
        writer.add(videoInput)
        writer.shouldOptimizeForNetworkUse = true

        // The sound goes with the picture — never dropped without a line.
        // Passthrough where the container carries the source's codec as a
        // player expects it: nil settings on both ends copies the samples
        // verbatim, with the source's format as the writer's hint (every
        // container but a QuickTime movie requires one before it will take
        // a passthrough at all — until 2026-11-06 none was given, so an
        // .mp4 took no sound from any source, and said nothing). An .mp4
        // takes AAC that way and nothing else: a camera's PCM (Sony's XAVC S
        // writes 16-bit big-endian) can be muxed into one, but a browser
        // will not play it, and an .mp4 is what goes downstream. Anything
        // else is decoded and written as AAC.
        var audioPair: (output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)?
        if let audioTrack {
            let source = audioFormat.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            let passesThrough = fileType != .mp4 || source?.mFormatID == kAudioFormatMPEG4AAC
            if passesThrough {
                let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
                output.alwaysCopiesSampleData = false
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
                input.expectsMediaDataInRealTime = false
                if reader.canAdd(output), writer.canAdd(input) {
                    reader.add(output)
                    writer.add(input)
                    audioPair = (output, input)
                }
            }
            if audioPair == nil {
                let channels = min(max(Int(source?.mChannelsPerFrame ?? 2), 1), 2)
                // AAC-LC's rates; a camera's 48 kHz stays 48 kHz.
                let rate = source.map { $0.mSampleRate == 44_100 ? 44_100.0 : 48_000.0 } ?? 48_000
                let decoded = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                    AVSampleRateKey: rate,
                    AVNumberOfChannelsKey: channels,
                ])
                decoded.alwaysCopiesSampleData = false
                let encoded = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: rate,
                    AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: channels == 1 ? 128_000 : 256_000,
                ])
                encoded.expectsMediaDataInRealTime = false
                if reader.canAdd(decoded), writer.canAdd(encoded) {
                    reader.add(decoded)
                    writer.add(encoded)
                    audioPair = (decoded, encoded)
                    LLog("export: \(outputURL.lastPathComponent) — sound written as AAC (\(channels) ch, \(Int(rate)) Hz): the source's own codec does not go into this container as a player expects it")
                } else {
                    LLog("export: ALARM \(outputURL.lastPathComponent) — the source has sound and neither a passthrough nor an AAC encode of it could be set up; the copy is silent")
                }
            }
        }

        guard reader.startReading() else {
            throw ExportFailure(reader.error?.localizedDescription ?? "could not start reading")
        }
        guard writer.startWriting() else {
            throw ExportFailure(writer.error?.localizedDescription ?? "could not start writing")
        }
        writer.startSession(atSourceTime: .zero)

        // Composition frames are the CI pipeline's own render — definitionally
        // the policy's colour. Attachments matching the stream tags mean the
        // encoder performs no colour conversion, only RGB→YCbCr. Track-output
        // frames keep whatever the source declared.
        let tagBuffers = composition != nil

        let group = DispatchGroup()
        group.enter()
        videoInput.requestMediaDataWhenReady(
            on: DispatchQueue(label: "com.letslapse.composition-export.video")) {
            while videoInput.isReadyForMoreMediaData {
                if state.isCancelled {
                    reader.cancelReading()
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                guard let sample = videoOutput.copyNextSampleBuffer() else {
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                if tagBuffers, let buffer = CMSampleBufferGetImageBuffer(sample) {
                    policy.tagColor(buffer)
                }
                if !videoInput.append(sample) {
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                if let progress {
                    // Whole percents only, so the MainActor isn't hopped to
                    // per frame.
                    let percent = state.advanceFrame(estimatedFrames: estimatedFrames)
                    if let percent { progress(Double(percent) / 100) }
                }
            }
        }

        if let audioPair {
            group.enter()
            audioPair.input.requestMediaDataWhenReady(
                on: DispatchQueue(label: "com.letslapse.composition-export.audio")) {
                while audioPair.input.isReadyForMoreMediaData {
                    if state.isCancelled {
                        audioPair.input.markAsFinished()
                        group.leave()
                        return
                    }
                    guard let sample = audioPair.output.copyNextSampleBuffer(),
                          audioPair.input.append(sample) else {
                        audioPair.input.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }

        group.wait()

        if state.isCancelled {
            writer.cancelWriting()
            throw CancellationError()
        }
        if reader.status == .reading { reader.cancelReading() }
        if reader.status == .failed {
            throw ExportFailure(reader.error?.localizedDescription ?? "reading failed")
        }

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw ExportFailure(writer.error?.localizedDescription ?? "could not finalize the file")
        }
    }

    /// The cancel flag and progress counters, shared with the pump queues.
    /// `@unchecked Sendable`: the lock guards everything, and the counters are
    /// only advanced from the single video-pump queue anyway.
    private final class PumpState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var framesWritten = 0
        private var lastReportedPercent = -1

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
        }

        /// Counts one appended frame; returns the new whole percent when it
        /// changed, nil while it hasn't.
        func advanceFrame(estimatedFrames: Int) -> Int? {
            lock.lock(); defer { lock.unlock() }
            framesWritten += 1
            let percent = min(100, framesWritten * 100 / max(1, estimatedFrames))
            guard percent != lastReportedPercent else { return nil }
            lastReportedPercent = percent
            return percent
        }
    }

    /// What went wrong, in words the pass-specific errors wrap for the user.
    struct ExportFailure: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }
}

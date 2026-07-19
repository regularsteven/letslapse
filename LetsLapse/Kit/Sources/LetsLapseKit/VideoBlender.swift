import Foundation
import AVFoundation
import CoreVideo
import Metal

public enum OutputCodec: String, CaseIterable, Sendable {
    case h264
    case hevc
    case prores
    case jpeg

    var avCodec: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        case .prores: return .proRes422
        case .jpeg: return .jpeg
        }
    }

    public var fileType: AVFileType {
        switch self {
        case .h264, .hevc: return .mp4
        case .prores, .jpeg: return .mov
        }
    }

    public var preferredExtension: String {
        fileType == .mp4 ? "mp4" : "mov"
    }
}

public struct VideoBlendOptions: Sendable {
    /// How many input frames feed each output frame, across the clip.
    public var ramp: BlendRamp
    /// Frame rate of the written file. With a ramp starting at window 1 on
    /// high-fps source, the head of the clip plays back as slow motion.
    public var outputFPS: Double
    public var codec: OutputCodec
    /// Average in linear light (physically correct long-exposure look) rather
    /// than in gamma-encoded values.
    public var linearLight: Bool

    public init(ramp: BlendRamp, outputFPS: Double = 30, codec: OutputCodec = .h264, linearLight: Bool = true) {
        self.ramp = ramp
        self.outputFPS = outputFPS
        self.codec = codec
        self.linearLight = linearLight
    }
}

public struct VideoBlendResult: Sendable {
    public let outputURL: URL
    public let inputFrames: Int
    public let outputFrames: Int
    public let outputDuration: Double
    public let width: Int
    public let height: Int
}

/// Blends a moving, variable-sized window of input frames into each output
/// frame: constant window = motion-blurred timelapse; ramped window =
/// slow-mo → hyperlapse speed ramp. Decode streams off disk, accumulation
/// runs on the GPU, so memory stays flat regardless of clip length.
public final class VideoBlender: @unchecked Sendable {
    private let core: BlendCore
    private let workQueue = DispatchQueue(label: "com.letslapse.videoblender", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false

    public init(core: BlendCore) {
        self.core = core
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func blend(
        input: URL,
        to output: URL,
        options: VideoBlendOptions,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> VideoBlendResult {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw LapseError.noVideoTrack(input)
        }
        let (nominalFPS, transform) = try await track.load(.nominalFrameRate, .preferredTransform)
        let duration = try await asset.load(.duration)
        let sourceFPS = nominalFPS > 0 ? Double(nominalFPS) : 30
        let estimatedFrames = max(1, Int((duration.seconds * sourceFPS).rounded()))

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                workQueue.async {
                    do {
                        let result = try self.run(
                            asset: asset, track: track, transform: transform,
                            estimatedFrames: estimatedFrames,
                            output: output, options: options, progress: progress)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    // MARK: - Pipeline

    private func run(
        asset: AVURLAsset,
        track: AVAssetTrack,
        transform: CGAffineTransform,
        estimatedFrames: Int,
        output: URL,
        options: VideoBlendOptions,
        progress: (@Sendable (Double) -> Void)?
    ) throws -> VideoBlendResult {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw LapseError.readerFailed(error.localizedDescription)
        }
        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw LapseError.readerFailed("cannot attach track output")
        }
        reader.add(readerOutput)
        guard reader.startReading() else {
            throw LapseError.readerFailed(reader.error?.localizedDescription ?? "could not start decoding")
        }

        var pendingBuffer: CVPixelBuffer?
        func nextPixelBuffer() throws -> CVPixelBuffer? {
            if let buffer = pendingBuffer {
                pendingBuffer = nil
                return buffer
            }
            while true {
                guard let sample = readerOutput.copyNextSampleBuffer() else {
                    if reader.status == .failed {
                        throw LapseError.readerFailed(reader.error?.localizedDescription ?? "decode error")
                    }
                    return nil
                }
                if let buffer = CMSampleBufferGetImageBuffer(sample) {
                    return buffer
                }
            }
        }

        // Peek the first frame for the true buffer dimensions before
        // configuring the writer.
        guard let firstBuffer = try nextPixelBuffer() else {
            reader.cancelReading()
            throw LapseError.noInputFrames
        }
        pendingBuffer = firstBuffer
        let width = CVPixelBufferGetWidth(firstBuffer)
        let height = CVPixelBufferGetHeight(firstBuffer)

        try? FileManager.default.removeItem(at: output)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: output, fileType: options.codec.fileType)
        } catch {
            throw LapseError.writerFailed(error.localizedDescription)
        }
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: options.codec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        if options.codec == .jpeg {
            videoSettings[AVVideoCompressionPropertiesKey] = [AVVideoQualityKey: 0.95]
        }
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false
        writerInput.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
        guard writer.canAdd(writerInput) else {
            throw LapseError.writerFailed("cannot attach video input")
        }
        writer.add(writerInput)
        guard writer.startWriting() else {
            throw LapseError.writerFailed(writer.error?.localizedDescription ?? "could not start encoding")
        }
        writer.startSession(atSourceTime: .zero)

        defer {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
        }

        let accumulator = FrameAccumulator(core: core)
        let schedule = WindowSchedule.make(totalInputFrames: estimatedFrames, ramp: options.ramp)
        let srgb = options.linearLight
        // Bounds how many decoded frames wait on the GPU at once, which keeps
        // peak memory flat even with 50-frame windows on 4K input.
        let inFlight = DispatchSemaphore(value: 3)

        var scheduleIndex = 0
        var inputFrames = 0
        var outputFrames = 0
        var endOfInput = false

        while !endOfInput {
            if isCancelled { throw LapseError.cancelled }

            // If the input outlives the frame-count estimate (VFR clips),
            // keep going with the final window size.
            let window = scheduleIndex < schedule.count
                ? schedule[scheduleIndex]
                : (schedule.last ?? options.ramp.window(atProgress: 1))
            scheduleIndex += 1

            var framesInWindow = 0
            for _ in 0..<window {
                guard let pixelBuffer = try nextPixelBuffer() else {
                    endOfInput = true
                    break
                }
                let (texture, holder) = try core.makeTexture(from: pixelBuffer, srgb: srgb)
                guard let commandBuffer = core.commandQueue.makeCommandBuffer() else {
                    throw LapseError.gpuSetupFailed("could not create a command buffer")
                }
                if framesInWindow == 0 {
                    try accumulator.reset(width: width, height: height, commandBuffer: commandBuffer)
                }
                try accumulator.accumulate(texture, commandBuffer: commandBuffer)
                inFlight.wait()
                commandBuffer.addCompletedHandler { _ in
                    // Keeps the decoded buffer alive until the GPU has read it.
                    _ = holder
                    _ = pixelBuffer
                    inFlight.signal()
                }
                commandBuffer.commit()
                framesInWindow += 1
                inputFrames += 1
                if inputFrames % 10 == 0 {
                    progress?(min(0.99, Double(inputFrames) / Double(max(estimatedFrames, inputFrames))))
                }
            }
            guard framesInWindow > 0 else { break }

            guard let pool = adaptor.pixelBufferPool else {
                throw LapseError.writerFailed("no pixel buffer pool (writer status \(writer.status.rawValue))")
            }
            var outBuffer: CVPixelBuffer?
            let poolStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outBuffer)
            guard poolStatus == kCVReturnSuccess, let outBuffer else {
                throw LapseError.writerFailed("output buffer allocation failed (\(poolStatus))")
            }
            let (destination, destinationHolder) = try core.makeTexture(from: outBuffer, srgb: srgb)
            guard let commandBuffer = core.commandQueue.makeCommandBuffer() else {
                throw LapseError.gpuSetupFailed("could not create a command buffer")
            }
            try accumulator.finalize(into: destination, commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if let error = commandBuffer.error {
                throw LapseError.gpuSetupFailed("GPU error: \(error.localizedDescription)")
            }
            _ = destinationHolder

            while !writerInput.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw LapseError.writerFailed(writer.error?.localizedDescription ?? "encoder failed")
                }
                usleep(2000)
            }
            let time = CMTime(
                value: Int64((Double(outputFrames) / options.outputFPS * 60000).rounded()),
                timescale: 60000)
            guard adaptor.append(outBuffer, withPresentationTime: time) else {
                throw LapseError.writerFailed(writer.error?.localizedDescription ?? "frame append failed")
            }
            outputFrames += 1
            core.flushTextureCache()
        }

        guard outputFrames > 0 else { throw LapseError.noInputFrames }

        writerInput.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw LapseError.writerFailed(writer.error?.localizedDescription ?? "could not finalize file")
        }
        progress?(1.0)

        return VideoBlendResult(
            outputURL: output,
            inputFrames: inputFrames,
            outputFrames: outputFrames,
            outputDuration: Double(outputFrames) / options.outputFPS,
            width: width,
            height: height)
    }
}

import Foundation
import AVFoundation
import CoreVideo
import Metal

public enum OutputCodec: String, CaseIterable, Sendable {
    case h264
    case hevc
    case prores
    case jpeg

    public var avCodec: AVVideoCodecType {
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
    /// Number of seconds to skip at both the head and tail of the source.
    public var trimHeadTailSeconds: Double
    /// An explicit per-output-frame window schedule (consecutive input-frame
    /// counts). When set it replaces the schedule derived from `ramp`, letting
    /// a caller compile an arbitrary speed curve — piecewise stretches with
    /// eased seams — into one blend pass. Input that outlives the schedule
    /// keeps blending at the last window, exactly like the ramp path.
    public var customWindows: [Int]?

    public init(
        ramp: BlendRamp,
        outputFPS: Double = 30,
        codec: OutputCodec = .h264,
        linearLight: Bool = true,
        trimHeadTailSeconds: Double = 0,
        customWindows: [Int]? = nil
    ) {
        self.ramp = ramp
        self.outputFPS = outputFPS
        self.codec = codec
        self.linearLight = linearLight
        self.trimHeadTailSeconds = trimHeadTailSeconds
        self.customWindows = customWindows
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
        let trim = max(0, options.trimHeadTailSeconds)
        let sourceDuration = duration.seconds
        guard sourceDuration.isFinite, trim * 2 < sourceDuration else {
            throw LapseError.readerFailed("trim would remove the entire clip")
        }
        let workingDuration = max(0, sourceDuration - (trim * 2))
        let estimatedFrames = max(1, Int((workingDuration * sourceFPS).rounded()))
        let timeRange: CMTimeRange? = trim > 0
            ? CMTimeRange(
                start: CMTime(seconds: trim, preferredTimescale: 600),
                duration: CMTime(seconds: workingDuration, preferredTimescale: 600)
            )
            : nil

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                workQueue.async {
                    do {
                        let result = try self.run(
                            asset: asset, track: track, transform: transform,
                            timeRange: timeRange,
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

    /// Decodes a single frame with no pixel-format request to see what the
    /// decoder natively produces, and returns the plain biplanar format to ask
    /// for when — and only when — that native layout is 4:2:0 (both chroma
    /// dimensions half of luma). Returns nil for anything else, including any
    /// failure, so the caller falls back to BGRA.
    private static func nativeBiplanar420Format(asset: AVURLAsset, track: AVAssetTrack) -> OSType? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        // Settings WITHOUT a pixel-format key: that is what makes the reader
        // decode into the decoder's own layout. Passing nil instead would vend
        // compressed samples, which carry no image buffer at all.
        let probe = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferMetalCompatibilityKey as String: true])
        probe.alwaysCopiesSampleData = false
        guard reader.canAdd(probe) else { return nil }
        reader.add(probe)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }

        var buffer: CVPixelBuffer?
        // Bounded: one decoded frame answers the question, and a clip that
        // somehow yields none must not turn the probe into a full scan.
        for _ in 0..<8 {
            guard let sample = probe.copyNextSampleBuffer() else { break }
            if let image = CMSampleBufferGetImageBuffer(sample) { buffer = image; break }
        }
        guard let buffer, CVPixelBufferGetPlaneCount(buffer) == 2 else { return nil }
        let lumaWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        guard chromaWidth * 2 == lumaWidth, chromaHeight * 2 == lumaHeight else { return nil }

        // The decoded buffer's own format is the authority on depth. The
        // container extension is only a backup: H.264 written by AVAssetWriter
        // carries no BitsPerComponent at all, and trusting it alone would push
        // every such clip onto the slow path.
        let containerBits = (track.formatDescriptions as? [CMFormatDescription] ?? []).compactMap {
            CMFormatDescriptionGetExtension(
                $0, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int
        }.max()
        guard let depth = VideoBlender.depth(ofNative: CVPixelBufferGetPixelFormatType(buffer))
                ?? containerBits else { return nil }
        if depth <= 8 { return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange }
        if depth <= 10 { return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange }
        return nil
    }

    /// Bit depth of a 4:2:0 biplanar pixel format, including the
    /// lossless/lossy compressed variants the decoder hands back natively on
    /// Apple silicon. nil for anything that is not 4:2:0 biplanar.
    private static func depth(ofNative format: OSType) -> Int? {
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange:
            return 8
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange,
             kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange,
             kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange:
            return 10
        default:
            return nil
        }
    }

    // MARK: - Pipeline

    private func run(
        asset: AVURLAsset,
        track: AVAssetTrack,
        transform: CGAffineTransform,
        timeRange: CMTimeRange?,
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
        if let timeRange {
            reader.timeRange = timeRange
        }
        // Ask the decoder for its own 4:2:0 biplanar output rather than
        // 32BGRA. That conversion — not the decode — is what bounds this
        // pipeline: the same 12 MP HEVC clip decodes at 481 fps natively and
        // 212 fps to BGRA on one thread.
        //
        // Only sources the decoder already produces as 4:2:0 qualify. Asking a
        // 4:2:2 source (ProRes, some imports) for 4:2:0 would make VideoToolbox
        // throw away half the chroma, so those keep the BGRA path, which is
        // lossless for them. The test is the native plane SHAPE rather than the
        // codec, because the decoder's native formats include Apple's
        // lossless-compressed variants that no fourCC allow-list would cover.
        // LL_BLEND_BGRA forces the original conversion path. It is the escape
        // hatch if the native-YUV read ever misbehaves on a device, and the
        // A/B lever these two paths were verified against.
        let readerPixelFormat = ProcessInfo.processInfo.environment["LL_BLEND_BGRA"] != nil
            ? nil
            : VideoBlender.nativeBiplanar420Format(asset: asset, track: track)
        let debugTiming = ProcessInfo.processInfo.environment["LL_BLEND_DEBUG"] != nil
        let blendStarted = Date()
        if debugTiming {
            let name = readerPixelFormat.map { format in
                String(bytes: (0..<4).map { UInt8((format >> (24 - $0 * 8)) & 0xff) }, encoding: .ascii) ?? "?"
            } ?? "32BGRA (fallback)"
            FileHandle.standardError.write(Data("  [blend reads \(name)]\n".utf8))
        }
        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                readerPixelFormat ?? kCVPixelFormatType_32BGRA,
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
        // nil whenever the decoder handed back something other than 8-bit
        // biplanar 4:2:0 — the BGRA path then runs exactly as before.
        let yuvParams = BlendCore.yuvParams(for: firstBuffer, toLinear: options.linearLight)

        try? FileManager.default.removeItem(at: output)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: output, fileType: options.codec.fileType)
        } catch {
            throw LapseError.writerFailed(error.localizedDescription)
        }
        let videoSettings: [String: Any]
        switch options.codec {
        case .h264, .hevc:
            let policy = VideoEncodePolicy(
                profile: options.codec == .hevc ? .hevcMain10 : .h264High8Bit,
                width: width, height: height, fps: options.outputFPS)
            videoSettings = policy.videoSettings
        case .prores:
            videoSettings = [
                AVVideoCodecKey: options.codec.avCodec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: VideoEncodePolicy.colorProperties,
            ]
        case .jpeg:
            videoSettings = [
                AVVideoCodecKey: options.codec.avCodec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.95],
            ]
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
        let schedule = options.customWindows.map { $0.map { max(1, $0) } }
            ?? WindowSchedule.make(totalInputFrames: estimatedFrames, ramp: options.ramp)
        let srgb = options.linearLight
        // One half-float mean texture, reused per output frame — the average
        // stays at full precision until `encodeGamma` quantizes it, dithered.
        let meanTexture = try core.makeMeanTexture(width: width, height: height)
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
                let holder: Any
                let commandBufferOrNil = core.commandQueue.makeCommandBuffer()
                guard let commandBuffer = commandBufferOrNil else {
                    throw LapseError.gpuSetupFailed("could not create a command buffer")
                }
                if let yuvParams {
                    let planes = try core.makeYUVTextures(from: pixelBuffer)
                    holder = planes.holders
                    if framesInWindow == 0 {
                        try accumulator.reset(width: width, height: height, commandBuffer: commandBuffer)
                    }
                    try accumulator.accumulateYUV(
                        luma: planes.luma, chroma: planes.chroma,
                        params: yuvParams, commandBuffer: commandBuffer)
                } else {
                    let (texture, textureHolder) = try core.makeTexture(from: pixelBuffer, srgb: srgb)
                    holder = textureHolder
                    if framesInWindow == 0 {
                        try accumulator.reset(width: width, height: height, commandBuffer: commandBuffer)
                    }
                    try accumulator.accumulate(texture, commandBuffer: commandBuffer)
                }
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
            // Non-sRGB view: `encodeGamma` applies the transfer curve itself.
            let (destination, destinationHolder) = try core.makeTexture(from: outBuffer, srgb: false)
            guard let commandBuffer = core.commandQueue.makeCommandBuffer() else {
                throw LapseError.gpuSetupFailed("could not create a command buffer")
            }
            try accumulator.finalizeMean(into: meanTexture, commandBuffer: commandBuffer)
            try core.encodeGamma(
                from: meanTexture, to: destination,
                ditherLSB: 1.0 / 255.0, frameIndex: outputFrames, applySRGB: srgb,
                commandBuffer: commandBuffer)
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
            if options.codec == .h264 || options.codec == .hevc || options.codec == .prores {
                VideoEncodePolicy.tagColor(outBuffer)
            }
            guard adaptor.append(outBuffer, withPresentationTime: time) else {
                throw LapseError.writerFailed(writer.error?.localizedDescription ?? "frame append failed")
            }
            outputFrames += 1
            core.flushTextureCache()
        }

        guard outputFrames > 0 else { throw LapseError.noInputFrames }

        if debugTiming {
            let elapsed = Date().timeIntervalSince(blendStarted)
            FileHandle.standardError.write(Data(String(
                format: "  [blend %d frames in %.1fs = %.0f fps in, %d out]\n",
                inputFrames, elapsed, Double(inputFrames) / max(elapsed, 0.001), outputFrames).utf8))
        }

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

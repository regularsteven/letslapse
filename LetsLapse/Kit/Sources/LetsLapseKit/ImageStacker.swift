import Foundation
import CoreGraphics
import ImageIO
import Metal
import AVFoundation
import CoreVideo
import UniformTypeIdentifiers

/// The outcome of `ImageStacker.stackSequence` — how many frames were written
/// and at what pixel size.
public struct StackSequenceResult: Sendable {
    public let outputFrames: Int
    public let width: Int
    public let height: Int
}

/// Averages a set of same-sized still images into one — a synthetic long
/// exposure with the noise knocked down by roughly sqrt(N).
public final class ImageStacker {
    private let core: BlendCore

    public init(core: BlendCore) {
        self.core = core
    }

    /// Stacks images loaded lazily from disk, one at a time, so memory stays
    /// bounded no matter how many frames go in. With `linearLight` (default)
    /// frames are linearized before averaging, matching how a real long
    /// exposure integrates light.
    ///
    /// `loadFrame` replaces the built-in decode, so a caller can put each frame
    /// through its own pass — the app hands in a loader that bakes the project's
    /// colour grade — while the streaming and memory behaviour stays the same.
    /// It must return frames at the size `loadImage(at:)` would, since the first
    /// one sizes the stack.
    public func stack(
        imageURLs: [URL],
        linearLight: Bool = true,
        loadFrame: ((URL) throws -> CGImage)? = nil,
        progress: ((Double) -> Void)? = nil
    ) throws -> CGImage {
        try stackImages(count: imageURLs.count, linearLight: linearLight, progress: progress) { index in
            let url = imageURLs[index]
            return try loadFrame?(url) ?? ImageStacker.loadImage(at: url)
        }
    }

    public func stack(images: [CGImage], linearLight: Bool = true, progress: ((Double) -> Void)? = nil) throws -> CGImage {
        try stackImages(count: images.count, linearLight: linearLight, progress: progress) { images[$0] }
    }

    /// Deep sibling of `stack(imageURLs:)`: same streaming accumulation, but
    /// the finalize keeps its precision — `finalizeMean` into half-float, then
    /// one undithered `encodeGamma` quantization to 16 bits per component. The
    /// blended frame leaves here carrying the sub-8-bit detail the window mean
    /// earned, so a caller writing scratch PNGs between blend and encode never
    /// quantizes to 8 bits along the way.
    public func stackDeep(
        imageURLs: [URL],
        linearLight: Bool = true,
        progress: ((Double) -> Void)? = nil
    ) throws -> CGImage {
        let (accumulator, width, height) = try accumulateImages(
            count: imageURLs.count, linearLight: linearLight, progress: progress
        ) { try ImageStacker.loadImage(at: imageURLs[$0]) }

        let meanTexture = try core.makeMeanTexture(width: width, height: height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .private
        guard let destination = core.device.makeTexture(descriptor: descriptor) else {
            throw LapseError.textureCreationFailed("\(width)x\(height) deep stack destination")
        }
        guard let commandBuffer = core.commandQueue.makeCommandBuffer() else {
            throw LapseError.gpuSetupFailed("could not create a command buffer")
        }
        try accumulator.finalizeMean(into: meanTexture, commandBuffer: commandBuffer)
        // The transfer curve is applied in-kernel (rgba16Unorm has no sRGB
        // view); at 16 bits the quantization step sits below visibility, so
        // no dither.
        try core.encodeGamma(
            from: meanTexture, to: destination,
            ditherLSB: 0, frameIndex: 0, applySRGB: linearLight,
            commandBuffer: commandBuffer)
        let result = try readDeepImage(from: destination, commandBuffer: commandBuffer)
        progress?(1.0)
        return result
    }

    private func stackImages(count: Int, linearLight: Bool, progress: ((Double) -> Void)?, imageAt: (Int) throws -> CGImage) throws -> CGImage {
        let (accumulator, width, height) = try accumulateImages(
            count: count, linearLight: linearLight, progress: progress, imageAt: imageAt)

        let destinationFormat: MTLPixelFormat = linearLight ? .bgra8Unorm_srgb : .bgra8Unorm
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: destinationFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .private
        guard let destination = core.device.makeTexture(descriptor: descriptor) else {
            throw LapseError.textureCreationFailed("\(width)x\(height) stack destination")
        }
        guard let commandBuffer = core.commandQueue.makeCommandBuffer() else {
            throw LapseError.gpuSetupFailed("could not create a command buffer")
        }
        try accumulator.finalize(into: destination, commandBuffer: commandBuffer)
        let result = try readImage(from: destination, commandBuffer: commandBuffer)
        progress?(1.0)
        return result
    }

    /// The shared front half of every still stack: streams `count` frames
    /// through a fresh accumulator one at a time, sizing the stack from the
    /// first. The finalize — 8-bit legacy or deep — is the caller's.
    private func accumulateImages(
        count: Int,
        linearLight: Bool,
        progress: ((Double) -> Void)?,
        imageAt: (Int) throws -> CGImage
    ) throws -> (accumulator: FrameAccumulator, width: Int, height: Int) {
        guard count > 0 else { throw LapseError.noInputFrames }
        let accumulator = FrameAccumulator(core: core)
        var width = 0
        var height = 0

        for index in 0..<count {
            try autoreleasepool {
                let image = try imageAt(index)
                if index == 0 {
                    width = image.width
                    height = image.height
                }
                guard image.width == width, image.height == height else {
                    throw LapseError.sizeMismatch(
                        expectedWidth: width, expectedHeight: height,
                        actualWidth: image.width, actualHeight: image.height)
                }
                let texture = try uploadTexture(for: image, srgb: linearLight)
                guard let commandBuffer = core.commandQueue.makeCommandBuffer() else {
                    throw LapseError.gpuSetupFailed("could not create a command buffer")
                }
                if index == 0 {
                    try accumulator.reset(width: width, height: height, commandBuffer: commandBuffer)
                }
                try accumulator.accumulate(texture, commandBuffer: commandBuffer)
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                if let error = commandBuffer.error {
                    throw LapseError.gpuSetupFailed("GPU error: \(error.localizedDescription)")
                }
            }
            progress?(Double(index + 1) / Double(count + 1))
        }
        return (accumulator, width, height)
    }

    // MARK: - Sequence (variable-blend timelapse)

    /// Produces a blended timelapse video from a sequence of still images.
    /// Each output frame is the average of a window of consecutive input
    /// stills, laid out by `ramp`: a flat window gives an evenly motion-blurred
    /// timelapse, while a window of 1 gives a straight timelapse with no
    /// stacking. Images are streamed off disk one at a time, so memory stays
    /// bounded no matter how many go in. Returns the written file's frame count
    /// and pixel dimensions.
    ///
    /// `loadFrame` replaces the built-in decode for every frame, which is how the
    /// app bakes a project's colour grade into a timelapse: each still is graded
    /// on its way to the accumulator, so the written video carries the grade and
    /// the originals on disk stay untouched. Frames must come back at the size
    /// `loadImage(at:)` would give — the first one sizes the writer, and a
    /// mismatch below throws rather than writing a corrupt file.
    ///
    /// `frameTimes` — elapsed capture seconds, one per entry in `imageURLs` —
    /// switches the output from "every frame is 1/fps long" to a layout that
    /// follows the real capture clock (see `FrameTimeMapping`). Pass it for a
    /// shoot whose spacing varies; leave it nil and the constant-fps layout
    /// runs exactly as before. When it is nil the stacker looks for a
    /// `frames.timestamps` sidecar beside the stills and uses that if it
    /// describes this exact set of frames.
    /// Wall-clock layout, if this shoot recorded one: one presentation time
    /// per output frame, taken at the first still of each window — the moment
    /// that window's exposure begins. A sidecar that doesn't describe exactly
    /// these frames (a filtered blend, a foreign directory) is ignored rather
    /// than guessed at — the caller can always hand the times in explicitly.
    private func windowPresentationTimes(
        imageURLs: [URL],
        frameTimes: [Double]?,
        schedule: [Int],
        outputFPS: Double
    ) -> [Double]? {
        let capturedTimes: [Double]? = {
            if let frameTimes, frameTimes.count == imageURLs.count { return frameTimes }
            guard frameTimes == nil,
                  let sidecar = FrameTimestamps.load(besideFrames: imageURLs),
                  sidecar.entries.count == imageURLs.count
            else { return nil }
            return sidecar.elapsedSeconds
        }()
        return capturedTimes.flatMap { times in
            var starts: [Double] = []
            var index = 0
            for window in schedule {
                guard times.indices.contains(index) else { return nil }
                starts.append(times[index])
                index += window
            }
            return FrameTimeMapping.presentationSeconds(
                frameTimes: starts, outputFPS: outputFPS)
        }
    }

    /// The window schedule a render runs: the caller's compiled windows when
    /// given — validated to consume exactly the input frames, because a
    /// schedule compiled against a different frame list would silently
    /// mis-window everything after the first drift — else the ramp's own.
    private func resolvedSchedule(
        imageURLs: [URL], ramp: BlendRamp, customWindows: [Int]?
    ) throws -> [Int] {
        guard let customWindows else {
            return WindowSchedule.make(totalInputFrames: imageURLs.count, ramp: ramp)
        }
        guard customWindows.allSatisfy({ $0 >= 1 }),
              customWindows.reduce(0, +) == imageURLs.count else {
            throw LapseError.writerFailed("window schedule doesn't match the input frames")
        }
        return customWindows
    }

    public func stackSequence(
        imageURLs: [URL],
        ramp: BlendRamp,
        outputFPS: Double,
        linearLight: Bool = true,
        outputURL: URL,
        frameTimes: [Double]? = nil,
        customWindows: [Int]? = nil,
        customWindowTimes: [Double]? = nil,
        loadFrame: ((URL) throws -> CGImage)? = nil,
        progress: ((Double) -> Void)? = nil
    ) throws -> StackSequenceResult {
        guard imageURLs.count >= 2 else {
            throw LapseError.writerFailed("a timelapse needs at least two photos")
        }
        let schedule = try resolvedSchedule(
            imageURLs: imageURLs, ramp: ramp, customWindows: customWindows)
        guard !schedule.isEmpty else { throw LapseError.noInputFrames }

        // A compiled schedule owns its pacing outright: its times when it
        // brought them, the constant layout when it didn't. The sidecar must
        // not re-stretch an authored warp — that's what the compiler's
        // per-stretch layout already accounted for.
        let windowStartTimes = customWindows != nil
            ? customWindowTimes
            : windowPresentationTimes(
                imageURLs: imageURLs, frameTimes: frameTimes, schedule: schedule, outputFPS: outputFPS)

        let load: (URL) throws -> CGImage = { url in
            try loadFrame?(url) ?? ImageStacker.loadImage(at: url)
        }

        // Size the writer from the first still (orientation already baked in).
        let firstImage = try load(imageURLs[0])
        let width = firstImage.width
        let height = firstImage.height

        try? FileManager.default.removeItem(at: outputURL)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw LapseError.writerFailed(error.localizedDescription)
        }
        let encodePolicy = VideoEncodePolicy(
            profile: .h264High8Bit, width: width, height: height, fps: outputFPS)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: encodePolicy.videoSettings)
        writerInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: encodePolicy.pixelBufferAttributes)
        guard writer.canAdd(writerInput) else {
            throw LapseError.writerFailed("cannot attach video input")
        }
        writer.add(writerInput)
        guard writer.startWriting() else {
            throw LapseError.writerFailed(writer.error?.localizedDescription ?? "could not start encoding")
        }
        writer.startSession(atSourceTime: .zero)

        defer {
            if writer.status == .writing { writer.cancelWriting() }
        }

        let accumulator = FrameAccumulator(core: core)
        let srgb = linearLight
        // One half-float mean texture, reused per output frame: the average
        // stays at full precision until `encodeGamma` quantizes it — with
        // dither — as it lands in the writer's buffer.
        let meanTexture = try core.makeMeanTexture(width: width, height: height)
        var inputIndex = 0
        var outputFrames = 0

        for window in schedule {
            // Average this window's stills into the accumulator.
            for offset in 0..<window {
                let index = inputIndex + offset
                try autoreleasepool {
                    let image = index == 0 ? firstImage : try load(imageURLs[index])
                    guard image.width == width, image.height == height else {
                        throw LapseError.sizeMismatch(
                            expectedWidth: width, expectedHeight: height,
                            actualWidth: image.width, actualHeight: image.height)
                    }
                    let texture = try uploadTexture(for: image, srgb: srgb)
                    guard let commandBuffer = core.commandQueue.makeCommandBuffer() else {
                        throw LapseError.gpuSetupFailed("could not create a command buffer")
                    }
                    if offset == 0 {
                        try accumulator.reset(width: width, height: height, commandBuffer: commandBuffer)
                    }
                    try accumulator.accumulate(texture, commandBuffer: commandBuffer)
                    commandBuffer.commit()
                    commandBuffer.waitUntilCompleted()
                    if let error = commandBuffer.error {
                        throw LapseError.gpuSetupFailed("GPU error: \(error.localizedDescription)")
                    }
                }
            }
            inputIndex += window

            // Finalize the window into a pooled pixel buffer and append it.
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
            // Wall-clock timing where the shoot recorded it, the constant
            // frame-index layout otherwise.
            let seconds = windowStartTimes.flatMap { $0.indices.contains(outputFrames) ? $0[outputFrames] : nil }
                ?? Double(outputFrames) / outputFPS
            let time = CMTime(value: Int64((seconds * 60000).rounded()), timescale: 60000)
            VideoEncodePolicy.tagColor(outBuffer)
            guard adaptor.append(outBuffer, withPresentationTime: time) else {
                throw LapseError.writerFailed(writer.error?.localizedDescription ?? "frame append failed")
            }
            outputFrames += 1
            core.flushTextureCache()
            progress?(min(0.99, Double(inputIndex) / Double(imageURLs.count)))
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

        return StackSequenceResult(outputFrames: outputFrames, width: width, height: height)
    }

    /// The tone-engine era `stackSequence`: frames arrive as scene-linear
    /// Display P3 half-float textures from `decodeLinear` — no 8-bit hop
    /// anywhere — the window mean is graded once per OUTPUT frame by
    /// `outputGrade`, and the writer is configured by `profile`: dithered
    /// 8-bit H.264 (gamut-converted to BT.709) or true 10-bit HEVC fed
    /// half-float Display P3. If the Main10 writer refuses to start, the
    /// blend falls back to H.264 automatically rather than failing.
    public func stackSequenceLinear(
        imageURLs: [URL],
        ramp: BlendRamp,
        outputFPS: Double,
        outputURL: URL,
        frameTimes: [Double]? = nil,
        customWindows: [Int]? = nil,
        customWindowTimes: [Double]? = nil,
        profile: VideoEncodePolicy.Profile = .h264High8Bit,
        decodeLinear: (URL) throws -> MTLTexture,
        /// The grade, applied once per OUTPUT frame after the average. The
        /// third argument is where that frame sits in the SOURCE, 0…1 — the
        /// centre of the window it was averaged from — so a grade that changes
        /// across the shoot knows which moment it is grading. A grade that
        /// doesn't change can ignore it.
        outputGrade: ((MTLTexture, MTLCommandBuffer, Double) throws -> MTLTexture)? = nil,
        progress: ((Double) -> Void)? = nil
    ) throws -> StackSequenceResult {
        guard imageURLs.count >= 2 else {
            throw LapseError.writerFailed("a timelapse needs at least two photos")
        }
        let schedule = try resolvedSchedule(
            imageURLs: imageURLs, ramp: ramp, customWindows: customWindows)
        guard !schedule.isEmpty else { throw LapseError.noInputFrames }
        // Same rule as `stackSequence`: a compiled schedule owns its pacing.
        let windowStartTimes = customWindows != nil
            ? customWindowTimes
            : windowPresentationTimes(
                imageURLs: imageURLs, frameTimes: frameTimes, schedule: schedule, outputFPS: outputFPS)

        let firstTexture = try decodeLinear(imageURLs[0])
        let width = firstTexture.width
        let height = firstTexture.height

        try? FileManager.default.removeItem(at: outputURL)
        func makeWriter(_ policy: VideoEncodePolicy) throws
            -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor) {
            let writer: AVAssetWriter
            do {
                writer = try AVAssetWriter(outputURL: outputURL, fileType: policy.fileType)
            } catch {
                throw LapseError.writerFailed(error.localizedDescription)
            }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: policy.videoSettings)
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input, sourcePixelBufferAttributes: policy.pixelBufferAttributes)
            guard writer.canAdd(input) else {
                throw LapseError.writerFailed("cannot attach video input")
            }
            writer.add(input)
            guard writer.startWriting() else {
                throw LapseError.writerFailed(writer.error?.localizedDescription ?? "could not start encoding")
            }
            return (writer, input, adaptor)
        }

        var policy = VideoEncodePolicy(profile: profile, width: width, height: height, fps: outputFPS)
        let writer: AVAssetWriter
        let writerInput: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        do {
            (writer, writerInput, adaptor) = try makeWriter(policy)
        } catch where profile == .hevcMain10 {
            // The compatibility floor: every supported device encodes H.264.
            policy = policy.fallbackToH264()
            try? FileManager.default.removeItem(at: outputURL)
            (writer, writerInput, adaptor) = try makeWriter(policy)
        }
        writer.startSession(atSourceTime: .zero)
        defer {
            if writer.status == .writing { writer.cancelWriting() }
        }

        let accumulator = FrameAccumulator(core: core)
        let meanTexture = try core.makeMeanTexture(width: width, height: height)
        let gamut = policy.gamutMatrixFromDisplayP3
        let ditherLSB: Float = policy.profile == .h264High8Bit ? 1.0 / 255.0 : 0
        var inputIndex = 0
        var outputFrames = 0

        for window in schedule {
            for offset in 0..<window {
                let index = inputIndex + offset
                try autoreleasepool {
                    let texture = index == 0 ? firstTexture : try decodeLinear(imageURLs[index])
                    guard texture.width == width, texture.height == height else {
                        throw LapseError.sizeMismatch(
                            expectedWidth: width, expectedHeight: height,
                            actualWidth: texture.width, actualHeight: texture.height)
                    }
                    guard let commandBuffer = core.commandQueue.makeCommandBuffer() else {
                        throw LapseError.gpuSetupFailed("could not create a command buffer")
                    }
                    if offset == 0 {
                        try accumulator.reset(width: width, height: height, commandBuffer: commandBuffer)
                    }
                    try accumulator.accumulate(texture, commandBuffer: commandBuffer)
                    commandBuffer.commit()
                    commandBuffer.waitUntilCompleted()
                    if let error = commandBuffer.error {
                        throw LapseError.gpuSetupFailed("GPU error: \(error.localizedDescription)")
                    }
                }
            }
            inputIndex += window

            guard let pool = adaptor.pixelBufferPool else {
                throw LapseError.writerFailed("no pixel buffer pool (writer status \(writer.status.rawValue))")
            }
            var outBuffer: CVPixelBuffer?
            let poolStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outBuffer)
            guard poolStatus == kCVReturnSuccess, let outBuffer else {
                throw LapseError.writerFailed("output buffer allocation failed (\(poolStatus))")
            }
            let (destination, destinationHolder) = try core.makeTexture(from: outBuffer, srgb: false)
            guard let commandBuffer = core.commandQueue.makeCommandBuffer() else {
                throw LapseError.gpuSetupFailed("could not create a command buffer")
            }
            try accumulator.finalizeMean(into: meanTexture, commandBuffer: commandBuffer)
            // The middle of the window this frame averaged, as a fraction of
            // the whole sequence: the moment the output frame actually shows.
            let sourcePosition = imageURLs.count > 1
                ? min(max(Double(inputIndex - window / 2) / Double(imageURLs.count - 1), 0), 1)
                : 0
            let graded = try outputGrade?(meanTexture, commandBuffer, sourcePosition) ?? meanTexture
            try core.encodeGamma(
                from: graded, to: destination,
                ditherLSB: ditherLSB, frameIndex: outputFrames, applySRGB: true,
                gamut: gamut, commandBuffer: commandBuffer)
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
            let seconds = windowStartTimes.flatMap { $0.indices.contains(outputFrames) ? $0[outputFrames] : nil }
                ?? Double(outputFrames) / outputFPS
            let time = CMTime(value: Int64((seconds * 60000).rounded()), timescale: 60000)
            policy.tagColor(outBuffer)
            guard adaptor.append(outBuffer, withPresentationTime: time) else {
                throw LapseError.writerFailed(writer.error?.localizedDescription ?? "frame append failed")
            }
            outputFrames += 1
            core.flushTextureCache()
            progress?(min(0.99, Double(inputIndex) / Double(imageURLs.count)))
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

        return StackSequenceResult(outputFrames: outputFrames, width: width, height: height)
    }

    // MARK: - CPU <-> GPU transfer

    private func uploadTexture(for image: CGImage, srgb: Bool) throws -> MTLTexture {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw LapseError.gpuSetupFailed("sRGB color space unavailable")
        }
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        try pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: colorSpace, bitmapInfo: bitmapInfo) else {
                throw LapseError.gpuSetupFailed("could not create a bitmap context")
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: srgb ? .bgra8Unorm_srgb : .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = core.device.makeTexture(descriptor: descriptor) else {
            throw LapseError.textureCreationFailed("\(width)x\(height) image upload")
        }
        pixels.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: raw.baseAddress!, bytesPerRow: bytesPerRow)
        }
        return texture
    }

    /// Encodes a blit of `texture` into a shared buffer on `commandBuffer`
    /// (which must already hold the finalize dispatch), runs it, and wraps the
    /// bytes as a CGImage. Blit-to-buffer readback works on every GPU family,
    /// unlike reading shared textures.
    private func readImage(from texture: MTLTexture, commandBuffer: MTLCommandBuffer) throws -> CGImage {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        guard let buffer = core.device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared) else {
            throw LapseError.gpuSetupFailed("could not allocate readback buffer")
        }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw LapseError.gpuSetupFailed("could not encode readback blit")
        }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer, destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw LapseError.gpuSetupFailed("GPU error: \(error.localizedDescription)")
        }

        let data = Data(bytes: buffer.contents(), count: bytesPerRow * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent) else {
            throw LapseError.imageEncodeFailed("could not wrap GPU output as an image")
        }
        return image
    }

    /// The 16-bit sibling of `readImage`: blits an rgba16Unorm texture — 8
    /// bytes per pixel — into a shared buffer and wraps it as a 16-bpc CGImage
    /// (RGBA, host-endian components), which CGImageDestination carries into a
    /// 16-bit PNG verbatim. Round-trip behaviour is pinned by `StackerTests`.
    private func readDeepImage(from texture: MTLTexture, commandBuffer: MTLCommandBuffer) throws -> CGImage {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 8
        guard let buffer = core.device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared) else {
            throw LapseError.gpuSetupFailed("could not allocate readback buffer")
        }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw LapseError.gpuSetupFailed("could not encode readback blit")
        }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer, destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw LapseError.gpuSetupFailed("GPU error: \(error.localizedDescription)")
        }

        let data = Data(bytes: buffer.contents(), count: bytesPerRow * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width, height: height,
                bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent) else {
            throw LapseError.imageEncodeFailed("could not wrap GPU output as a deep image")
        }
        return image
    }

    /// Loads an image with its EXIF orientation baked in, so portrait shots
    /// stack upright. For RAW files the thumbnail API stops at the embedded
    /// preview (a few hundred pixels), so when the primary image is larger
    /// than what came back, fall through to a full decode — rendering a DNG
    /// project from its preview JPEGs was how blended raws looked unblended.
    /// Public so the app's own full-size loads stay orientation-correct too.
    public static func loadImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw LapseError.imageLoadFailed(url)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 20000,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)

        var primaryLongSide = 0
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
            let height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
            primaryLongSide = max(width, height)
        }
        if let thumbnail, max(thumbnail.width, thumbnail.height) >= primaryLongSide {
            return thumbnail
        }
        if let full = CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) {
            // Full decode skips the thumbnail path's WithTransform, so bake
            // the EXIF orientation in here.
            var orientation = 1
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let value = properties[kCGImagePropertyOrientation] as? UInt32 {
                orientation = Int(value)
            }
            return Self.oriented(full, exifOrientation: orientation)
        }
        if let thumbnail {
            return thumbnail
        }
        throw LapseError.imageLoadFailed(url)
    }

    /// Bakes an EXIF orientation (1–8) into the pixels. Exact behaviour is
    /// pinned by `OrientationTests`.
    static func oriented(_ image: CGImage, exifOrientation: Int) -> CGImage {
        guard exifOrientation > 1, exifOrientation <= 8 else { return image }
        let width = image.width
        let height = image.height
        let swapsAxes = exifOrientation >= 5
        let outWidth = swapsAxes ? height : width
        let outHeight = swapsAxes ? width : height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: outWidth, height: outHeight,
                bitsPerComponent: 8, bytesPerRow: outWidth * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return image
        }
        context.interpolationQuality = .none
        var transform = CGAffineTransform.identity
        switch exifOrientation {
        case 2:
            transform = transform.translatedBy(x: CGFloat(width), y: 0).scaledBy(x: -1, y: 1)
        case 3:
            transform = transform.translatedBy(x: CGFloat(width), y: CGFloat(height)).rotated(by: .pi)
        case 4:
            transform = transform.translatedBy(x: 0, y: CGFloat(height)).scaledBy(x: 1, y: -1)
        case 5:
            transform = transform.translatedBy(x: 0, y: CGFloat(width)).rotated(by: -.pi / 2)
            transform = transform.translatedBy(x: CGFloat(width), y: 0).scaledBy(x: -1, y: 1)
        case 6:
            transform = transform.translatedBy(x: 0, y: CGFloat(width)).rotated(by: -.pi / 2)
        case 7:
            transform = transform.translatedBy(x: CGFloat(height), y: 0).rotated(by: .pi / 2)
            transform = transform.translatedBy(x: CGFloat(width), y: 0).scaledBy(x: -1, y: 1)
        case 8:
            transform = transform.translatedBy(x: CGFloat(height), y: 0).rotated(by: .pi / 2)
        default:
            break
        }
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { return image }
        return result
    }
}

// MARK: - Export

public enum ImageFormat: String, CaseIterable, Sendable {
    case png
    case jpeg
    case heic

    public var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        }
    }

    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        }
    }

    public static func infer(from url: URL) -> ImageFormat? {
        switch url.pathExtension.lowercased() {
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "heic", "heif": return .heic
        default: return nil
        }
    }
}

public enum ImageExporter {
    public static func write(
        _ image: CGImage,
        to url: URL,
        format: ImageFormat,
        quality: Double = 0.95,
        metadata: [CFString: Any]? = nil
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw LapseError.imageEncodeFailed("could not create \(format.rawValue) destination")
        }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        for (key, value) in metadata ?? [:] {
            properties[key] = value
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw LapseError.imageEncodeFailed("could not write \(url.lastPathComponent)")
        }
    }

    /// The metadata worth carrying from a source photo into an image derived
    /// from it: the EXIF block (capture time, exposure), the GPS fix, and the
    /// TIFF camera identity — minus orientation, which a derived image has
    /// already baked into its pixels (`loadImage` applies the transform).
    public static func carryoverMetadata(from url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        var metadata: [CFString: Any] = [:]
        if let exif = properties[kCGImagePropertyExifDictionary] {
            metadata[kCGImagePropertyExifDictionary] = exif
        }
        if let gps = properties[kCGImagePropertyGPSDictionary] {
            metadata[kCGImagePropertyGPSDictionary] = gps
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation)
            metadata[kCGImagePropertyTIFFDictionary] = tiff
        }
        return metadata.isEmpty ? nil : metadata
    }
}

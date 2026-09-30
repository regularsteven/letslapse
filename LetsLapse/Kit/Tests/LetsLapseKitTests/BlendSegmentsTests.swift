import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LetsLapseKit

/// Resumable blends (`BlendSegments.swift`): a run written as pieces, paused,
/// killed and picked up again must come out as the run that was never
/// interrupted. The video tests encode ProRes — intra-only, so every frame
/// encodes on its own and a piece boundary cannot change a single pixel —
/// and compare decoded frames exactly. The stills paths only write H.264 /
/// HEVC, whose frames depend on their neighbours, so those compare frame
/// counts and times exactly and pixels within a codec's tolerance.
final class BlendSegmentsTests: XCTestCase {
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("letslapse-segments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    // MARK: - Video

    private let proRes = VideoBlendOptions(ramp: .constant(10), outputFPS: 30, codec: .prores, linearLight: true)

    private func source(frames: Int = 150) throws -> URL {
        let url = work.appendingPathComponent("source-\(frames).mov")
        if !FileManager.default.fileExists(atPath: url.path) {
            // The sweeping box: every window averages a different stretch of
            // its path, so a frame from the wrong window cannot pass for the
            // right one.
            try VideoSynthesizer.makeVideo(at: url, frames: frames, width: 160, height: 120, fps: 30, pattern: .box)
        }
        return url
    }

    private func unbroken(_ options: VideoBlendOptions, frames: Int = 150) async throws -> URL {
        let output = work.appendingPathComponent("unbroken-\(UUID().uuidString).mov")
        _ = try await VideoBlender(core: try makeCore()).blend(input: try source(frames: frames), to: output, options: options)
        return output
    }

    func testAPieceAfterEveryFrameJoinsBackIntoTheSameFile() async throws {
        let reference = try await unbroken(proRes)
        let pieces = work.appendingPathComponent("pieces")
        let store = CheckpointStore()
        let output = work.appendingPathComponent("joined.mov")
        let result = try await VideoBlender(core: try makeCore()).blend(
            input: try source(), to: output, options: proRes,
            segmentation: BlendSegmentation(
                directory: pieces, recipeKey: "recipe", targetSegmentSeconds: 0,
                onCheckpoint: store.save))

        XCTAssertEqual(result.outputFrames, 15)
        XCTAssertEqual(result.inputFrames, 150)
        // A piece closes after every frame but the last, which is the finish.
        XCTAssertEqual(store.all.count, 14)
        XCTAssertEqual(store.all.last?.segments.count, 14)
        let expected = try await decodedFrames(of: reference)
        let actual = try await decodedFrames(of: output)
        XCTAssertEqual(actual.count, expected.count)
        XCTAssertEqual(actual.map(\.time), expected.map(\.time))
        XCTAssertEqual(actual.map(\.hash), expected.map(\.hash), "a piece boundary changed a pixel")
    }

    func testPauseThenResumeMatchesAnUnbrokenRun() async throws {
        let reference = try await unbroken(proRes)
        let pieces = work.appendingPathComponent("pieces")
        let control = BlendRunControl()
        let store = CheckpointStore()
        do {
            _ = try await VideoBlender(core: try makeCore()).blend(
                input: try source(), to: work.appendingPathComponent("never.mov"), options: proRes,
                segmentation: BlendSegmentation(
                    directory: pieces, recipeKey: "recipe", control: control, targetSegmentSeconds: 0,
                    onCheckpoint: { checkpoint in
                        store.save(checkpoint)
                        if checkpoint.nextOutputFrame >= 5 { control.requestPause() }
                    }))
            XCTFail("the run should have paused")
        } catch LapseError.paused {}
        let checkpoint = try XCTUnwrap(store.all.last)
        XCTAssertEqual(checkpoint.nextOutputFrame, 6, "the pause closes the frame being made, then stops")
        XCTAssertEqual(checkpoint.consumedInputFrames, 60)
        XCTAssertNotNil(checkpoint.resumeInputTime)
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("never.mov").path))

        // What a kill mid-piece leaves behind: a half-written piece. The
        // resume must neither use it nor leave it.
        let debris = pieces.appendingPathComponent("piece-0000006.partial.mov")
        try Data("half a movie".utf8).write(to: debris)

        let output = work.appendingPathComponent("resumed.mov")
        let result = try await VideoBlender(core: try makeCore()).blend(
            input: try source(), to: output, options: proRes,
            segmentation: BlendSegmentation(
                directory: pieces, recipeKey: "recipe", resume: checkpoint, targetSegmentSeconds: 0))
        // Straight to the recorded frame in an H.264 source — not a decode
        // from the top, which on a phone costs as long as the work skipped.
        XCTAssertEqual(result.resume, .seek)
        XCTAssertEqual(result.outputFrames, 15)
        XCTAssertEqual(result.inputFrames, 150)
        XCTAssertFalse(FileManager.default.fileExists(atPath: debris.path))
        let expected = try await decodedFrames(of: reference)
        let actual = try await decodedFrames(of: output)
        XCTAssertEqual(actual.map(\.time), expected.map(\.time))
        XCTAssertEqual(actual.map(\.hash), expected.map(\.hash))
    }

    func testResumingTwiceFromTheSameCheckpointIsHarmless() async throws {
        let reference = try await unbroken(proRes)
        let pieces = work.appendingPathComponent("pieces")
        let first = try await pausedRun(pieces: pieces, pauseAt: 3, recipeKey: "recipe")
        // Resumed, paused again further on…
        let second = try await pausedRun(pieces: pieces, pauseAt: 9, recipeKey: "recipe", resume: first)
        XCTAssertGreaterThan(second.nextOutputFrame, first.nextOutputFrame)
        // …then the OLDER checkpoint handed back (a resume that ran twice, or
        // a record written before the last one landed): still exact.
        let output = work.appendingPathComponent("again.mov")
        _ = try await VideoBlender(core: try makeCore()).blend(
            input: try source(), to: output, options: proRes,
            segmentation: BlendSegmentation(directory: pieces, recipeKey: "recipe", resume: first))
        let expected = try await decodedFrames(of: reference)
        let actual = try await decodedFrames(of: output)
        XCTAssertEqual(actual.map(\.hash), expected.map(\.hash))
        XCTAssertEqual(actual.map(\.time), expected.map(\.time))
    }

    func testACheckpointFromAnotherRecipeStartsAfresh() async throws {
        let reference = try await unbroken(proRes)
        let pieces = work.appendingPathComponent("pieces")
        let stale = try await pausedRun(pieces: pieces, pauseAt: 4, recipeKey: "old grade")
        let store = CheckpointStore()
        let output = work.appendingPathComponent("fresh.mov")
        let result = try await VideoBlender(core: try makeCore()).blend(
            input: try source(), to: output, options: proRes,
            segmentation: BlendSegmentation(
                directory: pieces, recipeKey: "new grade", resume: stale, targetSegmentSeconds: 0,
                onCheckpoint: store.save))
        XCTAssertEqual(result.resume, .restarted)
        // Started from frame 0: the first piece it reports is its own.
        XCTAssertEqual(store.all.first?.segments.first?.firstOutputFrame, 0)
        XCTAssertEqual(store.all.first?.nextOutputFrame, 1)
        let expected = try await decodedFrames(of: reference)
        let actual = try await decodedFrames(of: output)
        XCTAssertEqual(actual.map(\.hash), expected.map(\.hash))
    }

    func testAMissingPieceStartsAfresh() async throws {
        let reference = try await unbroken(proRes)
        let pieces = work.appendingPathComponent("pieces")
        let checkpoint = try await pausedRun(pieces: pieces, pauseAt: 6, recipeKey: "recipe")
        let doomed = try XCTUnwrap(checkpoint.segments.dropFirst(2).first)
        try FileManager.default.removeItem(at: pieces.appendingPathComponent(doomed.fileName))
        XCTAssertNil(BlendSegments.validResume(checkpoint, passKey: checkpoint.passKey, directory: pieces))
        let output = work.appendingPathComponent("rebuilt.mov")
        _ = try await VideoBlender(core: try makeCore()).blend(
            input: try source(), to: output, options: proRes,
            segmentation: BlendSegmentation(directory: pieces, recipeKey: "recipe", resume: checkpoint))
        let expected = try await decodedFrames(of: reference)
        let actual = try await decodedFrames(of: output)
        XCTAssertEqual(actual.map(\.hash), expected.map(\.hash))
    }

    func testCancelKeepsFinishedPiecesAndNothingHalfWritten() async throws {
        let pieces = work.appendingPathComponent("pieces")
        let control = BlendRunControl()
        do {
            _ = try await VideoBlender(core: try makeCore()).blend(
                input: try source(), to: work.appendingPathComponent("cancelled.mov"), options: proRes,
                segmentation: BlendSegmentation(
                    directory: pieces, control: control, targetSegmentSeconds: 0,
                    onCheckpoint: { checkpoint in
                        if checkpoint.nextOutputFrame >= 4 { control.cancel() }
                    }))
            XCTFail("the run should have been cancelled")
        } catch LapseError.cancelled {}
        let names = try FileManager.default.contentsOfDirectory(atPath: pieces.path)
        XCTAssertFalse(names.contains { $0.contains(".partial.") }, "\(names)")
        XCTAssertEqual(names.count, 4)
    }

    func testARampedAndTrimmedH264RunResumesFrameForFrame() async throws {
        // The real app's shape: H.264, a ramped schedule, the ends trimmed.
        // H.264 frames depend on their neighbours, so pixels are compared
        // within a codec's tolerance; counts and times exactly.
        let options = VideoBlendOptions(
            ramp: BlendRamp(startWindow: 2, endWindow: 12, curve: .easeInOut),
            outputFPS: 25, codec: .h264, linearLight: true, trimHeadTailSeconds: 0.5)
        let reference = try await unbroken(options, frames: 180)
        let pieces = work.appendingPathComponent("pieces")
        let control = BlendRunControl()
        let store = CheckpointStore()
        do {
            _ = try await VideoBlender(core: try makeCore()).blend(
                input: try source(frames: 180), to: work.appendingPathComponent("never.mp4"), options: options,
                segmentation: BlendSegmentation(
                    directory: pieces, control: control, targetSegmentSeconds: 0,
                    onCheckpoint: { checkpoint in
                        store.save(checkpoint)
                        if checkpoint.nextOutputFrame >= 7 { control.requestPause() }
                    }))
            XCTFail("the run should have paused")
        } catch LapseError.paused {}
        let output = work.appendingPathComponent("resumed.mp4")
        let result = try await VideoBlender(core: try makeCore()).blend(
            input: try source(frames: 180), to: output, options: options,
            segmentation: BlendSegmentation(directory: pieces, resume: try XCTUnwrap(store.all.last)))
        XCTAssertEqual(result.resume, .seek, "the seek missed on a trimmed source")
        let expected = try await decodedFrames(of: reference)
        let actual = try await decodedFrames(of: output)
        XCTAssertEqual(actual.count, expected.count)
        XCTAssertEqual(actual.map(\.time), expected.map(\.time))
        for (index, (a, e)) in zip(actual, expected).enumerated() {
            XCTAssertEqual(a.mean, e.mean, accuracy: 2.0, "frame \(index)")
            XCTAssertEqual(a.boxCentre, e.boxCentre, accuracy: 2.0, "frame \(index): the box moved")
        }
    }

    func testHEVCTenBitPiecesJoinAndResume() async throws {
        // The app's other output format: HEVC Main10 pieces must join by
        // passthrough exactly as H.264 ones do.
        let options = VideoBlendOptions(ramp: .constant(6), outputFPS: 30, codec: .hevc, linearLight: true)
        let reference = try await unbroken(options)
        let pieces = work.appendingPathComponent("hevc-pieces")
        let control = BlendRunControl()
        let store = CheckpointStore()
        do {
            _ = try await VideoBlender(core: try makeCore()).blend(
                input: try source(), to: work.appendingPathComponent("never.mp4"), options: options,
                segmentation: BlendSegmentation(
                    directory: pieces, control: control, targetSegmentSeconds: 0,
                    onCheckpoint: { checkpoint in
                        store.save(checkpoint)
                        if checkpoint.nextOutputFrame >= 9 { control.requestPause() }
                    }))
            XCTFail("the run should have paused")
        } catch LapseError.paused {}
        XCTAssertEqual(store.all.last?.codec, "hevc")
        let output = work.appendingPathComponent("hevc-resumed.mp4")
        let result = try await VideoBlender(core: try makeCore()).blend(
            input: try source(), to: output, options: options,
            segmentation: BlendSegmentation(directory: pieces, resume: try XCTUnwrap(store.all.last)))
        XCTAssertEqual(result.resume, .seek)
        let expected = try await decodedFrames(of: reference)
        let actual = try await decodedFrames(of: output)
        XCTAssertEqual(actual.count, 25)
        XCTAssertEqual(actual.map(\.time), expected.map(\.time))
        for (index, (a, e)) in zip(actual, expected).enumerated() {
            XCTAssertEqual(a.mean, e.mean, accuracy: 2.0, "frame \(index)")
            XCTAssertEqual(a.boxCentre, e.boxCentre, accuracy: 2.0, "frame \(index)")
        }
    }

    func testTheLinearStillsPathJoinsTenBitHEVC() throws {
        let urls = try stills(count: 36)
        let stacker = ImageStacker(core: try makeCore())
        let decode: (URL) throws -> MTLTexture = { url in
            try stacker.makeInputTexture(ImageStacker.loadImage(at: url), srgb: true)
        }
        let reference = work.appendingPathComponent("hevc-stills-reference.mp4")
        _ = try stacker.stackSequenceLinear(
            imageURLs: urls, ramp: .constant(2), outputFPS: 30, outputURL: reference,
            profile: .hevcMain10, decodeLinear: decode)
        let output = work.appendingPathComponent("hevc-stills-pieces.mp4")
        _ = try stacker.stackSequenceLinear(
            imageURLs: urls, ramp: .constant(2), outputFPS: 30, outputURL: output,
            profile: .hevcMain10, decodeLinear: decode,
            segmentation: BlendSegmentation(
                directory: work.appendingPathComponent("hevc-stills"), targetSegmentSeconds: 0))
        try assertSameClip(output, reference)
    }

    private func pausedRun(
        pieces: URL, pauseAt frame: Int, recipeKey: String, resume: BlendCheckpoint? = nil
    ) async throws -> BlendCheckpoint {
        let control = BlendRunControl()
        let store = CheckpointStore()
        do {
            _ = try await VideoBlender(core: try makeCore()).blend(
                input: try source(), to: work.appendingPathComponent("paused-\(UUID().uuidString).mov"),
                options: proRes,
                segmentation: BlendSegmentation(
                    directory: pieces, recipeKey: recipeKey, resume: resume, control: control,
                    targetSegmentSeconds: 0,
                    onCheckpoint: { checkpoint in
                        store.save(checkpoint)
                        if checkpoint.nextOutputFrame >= frame { control.requestPause() }
                    }))
            XCTFail("the run should have paused")
        } catch LapseError.paused {}
        return try XCTUnwrap(store.all.last)
    }

    // MARK: - Stills

    private func stills(count: Int) throws -> [URL] {
        let folder = work.appendingPathComponent("stills-\(count)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let width = 96, height = 64
        return try (0..<count).map { index in
            // A bright bar that walks across a dark field, one column per
            // still, so a mis-windowed frame lands its bar somewhere else.
            var values = [UInt8](repeating: 24, count: width * height)
            let column = index % width
            for y in 0..<height {
                for x in column..<min(width, column + 6) { values[y * width + x] = 230 }
            }
            let url = folder.appendingPathComponent(String(format: "frame-%04d.png", index))
            try writePNG(makeGrayImage(width: width, height: height, values: values), to: url)
            return url
        }
    }

    func testStillsPauseAndResumeKeepFramesAndTimes() throws {
        let urls = try stills(count: 60)
        let stacker = ImageStacker(core: try makeCore())
        let reference = work.appendingPathComponent("stills-reference.mp4")
        _ = try stacker.stackSequence(
            imageURLs: urls, ramp: .constant(4), outputFPS: 25, outputURL: reference)

        let pieces = work.appendingPathComponent("stills-pieces")
        let control = BlendRunControl()
        let store = CheckpointStore()
        do {
            _ = try stacker.stackSequence(
                imageURLs: urls, ramp: .constant(4), outputFPS: 25,
                outputURL: work.appendingPathComponent("never.mp4"),
                segmentation: BlendSegmentation(
                    directory: pieces, recipeKey: "look", control: control, targetSegmentSeconds: 0,
                    onCheckpoint: { checkpoint in
                        store.save(checkpoint)
                        if checkpoint.nextOutputFrame >= 6 { control.requestPause() }
                    }))
            XCTFail("the run should have paused")
        } catch LapseError.paused {}
        let checkpoint = try XCTUnwrap(store.all.last)
        XCTAssertEqual(checkpoint.nextOutputFrame, 7)
        XCTAssertEqual(checkpoint.consumedInputFrames, 28)
        XCTAssertNil(checkpoint.resumeInputTime)

        let output = work.appendingPathComponent("stills-resumed.mp4")
        let result = try ImageStacker(core: try makeCore()).stackSequence(
            imageURLs: urls, ramp: .constant(4), outputFPS: 25, outputURL: output,
            segmentation: BlendSegmentation(directory: pieces, recipeKey: "look", resume: checkpoint))
        XCTAssertEqual(result.outputFrames, 15)
        try assertSameClip(output, reference)
    }

    func testTheLinearStillsPathResumesToo() throws {
        let urls = try stills(count: 48)
        let stacker = ImageStacker(core: try makeCore())
        let decode: (URL) throws -> MTLTexture = { url in
            try stacker.makeInputTexture(ImageStacker.loadImage(at: url), srgb: true)
        }
        let reference = work.appendingPathComponent("linear-reference.mp4")
        _ = try stacker.stackSequenceLinear(
            imageURLs: urls, ramp: .constant(3), outputFPS: 30, outputURL: reference, decodeLinear: decode)

        let pieces = work.appendingPathComponent("linear-pieces")
        let control = BlendRunControl()
        let store = CheckpointStore()
        do {
            _ = try stacker.stackSequenceLinear(
                imageURLs: urls, ramp: .constant(3), outputFPS: 30,
                outputURL: work.appendingPathComponent("never.mp4"), decodeLinear: decode,
                segmentation: BlendSegmentation(
                    directory: pieces, control: control, targetSegmentSeconds: 0,
                    onCheckpoint: { checkpoint in
                        store.save(checkpoint)
                        if checkpoint.nextOutputFrame >= 5 { control.requestPause() }
                    }))
            XCTFail("the run should have paused")
        } catch LapseError.paused {}
        let output = work.appendingPathComponent("linear-resumed.mp4")
        _ = try stacker.stackSequenceLinear(
            imageURLs: urls, ramp: .constant(3), outputFPS: 30, outputURL: output, decodeLinear: decode,
            segmentation: BlendSegmentation(directory: pieces, resume: try XCTUnwrap(store.all.last)))
        try assertSameClip(output, reference)
    }

    func testCancelStopsAStillsBlend() throws {
        let urls = try stills(count: 40)
        let control = BlendRunControl()
        control.cancel()
        XCTAssertThrowsError(try ImageStacker(core: try makeCore()).stackSequence(
            imageURLs: urls, ramp: .constant(4), outputFPS: 25,
            outputURL: work.appendingPathComponent("never.mp4"),
            segmentation: BlendSegmentation(directory: work.appendingPathComponent("p"), control: control))
        ) { error in
            guard case LapseError.cancelled = error else { return XCTFail("\(error)") }
        }
    }

    private func assertSameClip(_ actualURL: URL, _ expectedURL: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = try decodedFramesSync(of: expectedURL)
        let actual = try decodedFramesSync(of: actualURL)
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        XCTAssertEqual(actual.map(\.time), expected.map(\.time), file: file, line: line)
        for (index, (a, e)) in zip(actual, expected).enumerated() {
            XCTAssertEqual(a.mean, e.mean, accuracy: 2.0, "frame \(index)", file: file, line: line)
            XCTAssertEqual(a.boxCentre, e.boxCentre, accuracy: 1.5, "frame \(index): the bar moved", file: file, line: line)
        }
    }

    // MARK: - Decoding

    struct DecodedFrame {
        var time: CMTime
        /// FNV-1a over every pixel's colour bytes — equal only for identical frames.
        var hash: UInt64
        /// Mean byte value, for lossy comparisons.
        var mean: Double
        /// The brightness-weighted mean column: where the moving shape sits.
        var boxCentre: Double
    }

    private func decodedFrames(of url: URL) async throws -> [DecodedFrame] {
        try decodedFramesSync(of: url)
    }

    private func decodedFramesSync(of url: URL) throws -> [DecodedFrame] {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try blocking { try await asset.loadTracks(withMediaType: .video) }
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frames: [DecodedFrame] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            var hash: UInt64 = 0xcbf29ce484222325
            var total = 0.0
            var weighted = 0.0
            var weight = 0.0
            for y in 0..<height {
                let row = base + y * rowBytes
                for x in 0..<width {
                    for channel in 0..<3 {
                        hash = (hash ^ UInt64(row[x * 4 + channel])) &* 0x100000001b3
                    }
                    let value = Double(row[x * 4 + 1])
                    total += value
                    weighted += value * Double(x)
                    weight += value
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            frames.append(DecodedFrame(
                time: CMSampleBufferGetPresentationTimeStamp(sample),
                hash: hash,
                mean: total / Double(width * height),
                boxCentre: weight > 0 ? weighted / weight : 0))
        }
        XCTAssertEqual(reader.status, .completed)
        return frames
    }

    private func blocking<T>(_ operation: @escaping () async throws -> T) throws -> T {
        let box = BlockingBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await operation()) } catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }

    private final class BlockingBox<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw LapseError.imageEncodeFailed("png destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw LapseError.imageEncodeFailed("png finalize") }
    }
}

/// Collects checkpoints from the engine's thread.
final class CheckpointStore: @unchecked Sendable {
    private let lock = NSLock()
    private var checkpoints: [BlendCheckpoint] = []

    func save(_ checkpoint: BlendCheckpoint) {
        lock.lock()
        checkpoints.append(checkpoint)
        lock.unlock()
    }

    var all: [BlendCheckpoint] {
        lock.lock()
        defer { lock.unlock() }
        return checkpoints
    }
}

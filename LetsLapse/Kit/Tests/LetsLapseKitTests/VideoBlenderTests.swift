import XCTest
import AVFoundation
@testable import LetsLapseKit

final class VideoBlenderTests: XCTestCase {
    private var workDirectory: URL!

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("letslapse-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    func testConstantWindowBlendFrameCountAndValues() async throws {
        let core = try makeCore()
        let input = workDirectory.appendingPathComponent("in.mov")
        try VideoSynthesizer.makeVideo(at: input, frames: 60, width: 320, height: 240, fps: 30, pattern: .ramp)

        let blender = VideoBlender(core: core)
        let output = workDirectory.appendingPathComponent("out.mp4")
        let options = VideoBlendOptions(ramp: .constant(10), outputFPS: 30, codec: .h264, linearLight: true)
        let result = try await blender.blend(input: input, to: output, options: options)

        XCTAssertEqual(result.inputFrames, 60)
        XCTAssertEqual(result.outputFrames, 6)
        XCTAssertEqual(result.outputDuration, 0.2, accuracy: 0.001)
        XCTAssertEqual(result.width, 320)
        XCTAssertEqual(result.height, 240)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

        // First output frame should be the linear-light average of input
        // frames 0–9. Tolerance covers H.264 round-trips and the small
        // BT.709-vs-sRGB transfer difference.
        let expectedLinear = (0..<10)
            .map { srgbToLinear(VideoSynthesizer.rampLevel(frame: $0, of: 60)) }
            .reduce(0, +) / 10
        let expected = linearToSRGB(expectedLinear)
        let actual = try await firstFrameMeanGray(of: output)
        XCTAssertEqual(actual, expected, accuracy: 0.06,
            "first blended frame gray \(actual), expected ≈\(expected)")
    }

    func testRampedBlendMatchesSchedule() async throws {
        let core = try makeCore()
        let input = workDirectory.appendingPathComponent("in.mov")
        try VideoSynthesizer.makeVideo(at: input, frames: 120, width: 160, height: 120, fps: 30, pattern: .box)

        let ramp = BlendRamp(startWindow: 1, endWindow: 20, curve: .easeInOut)
        let expectedSchedule = WindowSchedule.make(totalInputFrames: 120, ramp: ramp)

        let blender = VideoBlender(core: core)
        let output = workDirectory.appendingPathComponent("out.mp4")
        let options = VideoBlendOptions(ramp: ramp, outputFPS: 30, codec: .h264, linearLight: true)
        let collector = ProgressCollector()
        let result = try await blender.blend(input: input, to: output, options: options) { fraction in
            collector.record(fraction)
        }
        let reportedProgress = collector.values

        XCTAssertEqual(result.inputFrames, 120)
        XCTAssertEqual(result.outputFrames, expectedSchedule.count)
        XCTAssertEqual(reportedProgress.last, 1.0)
        XCTAssertEqual(reportedProgress, reportedProgress.sorted(), "progress should be monotonic")
    }

    func testTrimHeadAndTailBeforeBlending() async throws {
        let core = try makeCore()
        let input = workDirectory.appendingPathComponent("trim-source.mov")
        try VideoSynthesizer.makeVideo(at: input, frames: 90, width: 160, height: 120, fps: 30, pattern: .ramp)

        let blender = VideoBlender(core: core)
        let output = workDirectory.appendingPathComponent("trimmed.mp4")
        let options = VideoBlendOptions(
            ramp: .constant(10),
            outputFPS: 30,
            codec: .h264,
            linearLight: true,
            trimHeadTailSeconds: 1
        )
        let result = try await blender.blend(input: input, to: output, options: options)

        XCTAssertEqual(result.inputFrames, 30)
        XCTAssertEqual(result.outputFrames, 3)
        XCTAssertEqual(result.outputDuration, 0.1, accuracy: 0.001)
    }

    func testMissingVideoTrackThrows() async throws {
        let core = try makeCore()
        let bogus = workDirectory.appendingPathComponent("nothing.mp4")
        try Data("not a movie".utf8).write(to: bogus)
        let blender = VideoBlender(core: core)
        let options = VideoBlendOptions(ramp: .constant(5))
        do {
            _ = try await blender.blend(
                input: bogus, to: workDirectory.appendingPathComponent("out.mp4"), options: options)
            XCTFail("expected an error for a non-video input")
        } catch {
            // Any LapseError / AVFoundation error is acceptable here.
        }
    }

    /// Decodes the first frame of a video and returns its mean gray (0–1).
    private func firstFrameMeanGray(of url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        defer { reader.cancelReading() }
        let sample = try XCTUnwrap(output.copyNextSampleBuffer())
        let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        var total = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let pixel = base + y * bytesPerRow + x * 4
                total += (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / 3
            }
        }
        return total / Double(width * height) / 255
    }
}

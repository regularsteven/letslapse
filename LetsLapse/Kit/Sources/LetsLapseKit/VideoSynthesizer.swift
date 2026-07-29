import Foundation
import AVFoundation
import CoreVideo

/// Renders simple synthetic clips — used by the test suite and the CLI's
/// `synth` command to exercise the blend pipeline without camera footage.
public enum VideoSynthesizer {
    public enum Pattern: String, CaseIterable, Sendable {
        /// Solid gray ramping dark → light across the clip. Good for verifying
        /// averages numerically.
        case ramp
        /// White box sweeping left → right. Good for eyeballing motion blur.
        case box
    }

    public static func makeVideo(
        at url: URL,
        frames: Int = 120,
        width: Int = 320,
        height: Int = 240,
        fps: Double = 30,
        pattern: Pattern = .ramp,
        fileType: AVFileType = .mov
    ) throws {
        guard frames > 0 else { throw LapseError.noInputFrames }
        try? FileManager.default.removeItem(at: url)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        } catch {
            throw LapseError.writerFailed(error.localizedDescription)
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        guard writer.startWriting() else {
            throw LapseError.writerFailed(writer.error?.localizedDescription ?? "could not start")
        }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw LapseError.writerFailed(writer.error?.localizedDescription ?? "encoder failed")
                }
                usleep(1000)
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw LapseError.writerFailed("no pixel buffer pool")
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
            guard let buffer else {
                throw LapseError.writerFailed("buffer allocation failed")
            }
            fill(buffer, frame: frame, of: frames, pattern: pattern)
            let time = CMTime(value: Int64((Double(frame) / fps * 60000).rounded()), timescale: 60000)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw LapseError.writerFailed(writer.error?.localizedDescription ?? "frame append failed")
            }
        }

        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw LapseError.writerFailed(writer.error?.localizedDescription ?? "could not finalize file")
        }
    }

    /// Gray level (0–1, sRGB-encoded) of the `ramp` pattern at a given frame.
    /// Exposed so tests can compute expected blend results.
    public static func rampLevel(frame: Int, of total: Int) -> Double {
        let t = total > 1 ? Double(frame) / Double(total - 1) : 0
        return 0.1 + 0.8 * t
    }

    private static func fill(_ buffer: CVPixelBuffer, frame: Int, of total: Int, pattern: Pattern) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        switch pattern {
        case .ramp:
            let value = UInt8((rampLevel(frame: frame, of: total) * 255).rounded())
            for y in 0..<height {
                let row = bytes + y * bytesPerRow
                for x in 0..<width {
                    row[x * 4 + 0] = value
                    row[x * 4 + 1] = value
                    row[x * 4 + 2] = value
                    row[x * 4 + 3] = 255
                }
            }
        case .box:
            let t = total > 1 ? Double(frame) / Double(total - 1) : 0
            let boxWidth = max(4, width / 10)
            let boxX = Int(t * Double(width - boxWidth))
            for y in 0..<height {
                let row = bytes + y * bytesPerRow
                for x in 0..<width {
                    let inBox = x >= boxX && x < boxX + boxWidth
                    let value: UInt8 = inBox ? 255 : 20
                    row[x * 4 + 0] = value
                    row[x * 4 + 1] = value
                    row[x * 4 + 2] = value
                    row[x * 4 + 3] = 255
                }
            }
        }
    }
}

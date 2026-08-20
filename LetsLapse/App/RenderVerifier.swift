import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import os

/// Reads a finished render back off disk and checks it against what the job
/// believed it was writing.
///
/// Every number the app shows about a blended clip — "600 frames out", "50 fps",
/// the clip length on the version row — used to be arithmetic. The blend engine
/// computed a schedule, the schedule said 600 frames, and that figure was copied
/// into the manifest and repeated on every screen. Nothing ever opened the file.
///
/// So when a tail stage quietly retimed the clip, the app had no way to notice.
/// Project B0E3269D shipped two clips of 150 frames at 12.5 fps under a
/// "11998 frames in → 600 frames out · 50 fps" label: `AVAssetExportSession`'s
/// `.highestQuality` preset had thrown away three of every four blended frames
/// to fit a device budget, and every surface in the app kept reporting the
/// intended figures. A render that loses frames is a failed render — this is
/// what makes it say so.
enum RenderVerifier {
    private static let log = Logger(
        subsystem: "com.regularsteven.letslapse", category: "render-verify")

    /// What the file on disk actually contains.
    struct Measurement: Sendable {
        /// Real coded frames, summed from the sample buffers' sample counts.
        /// Counting `copyNextSampleBuffer()` calls is NOT the same number — the
        /// reader vends zero-sample marker buffers too, which over-counts and
        /// would make a tolerance check quietly meaningless.
        var frameCount: Int
        var duration: Double
        /// The track's own declared rate.
        var nominalFPS: Double
        /// Display-oriented pixel size — the shape a player shows, with the
        /// track's `preferredTransform` applied.
        var displayWidth: Int
        var displayHeight: Int

        /// Frames divided by seconds: the rate the file really plays at,
        /// independent of what the track declares.
        var measuredFPS: Double {
            guard duration > 0.0001, frameCount > 0 else { return 0 }
            return Double(frameCount) / duration
        }
    }

    /// Probes `url` without decoding a single frame.
    ///
    /// `AVAssetReaderSampleReferenceOutput` hands back sample buffers carrying
    /// timing and file offsets but no media data, so a 12-second 4K clip costs
    /// a table walk rather than a decode. A track output over compressed
    /// samples is the fallback for anything that won't vend references.
    static func measure(_ url: URL) async throws -> Measurement {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VerifyError.unreadable("the file has no video track")
        }
        let duration = try await asset.load(.duration).seconds
        let nominal = (try? await track.load(.nominalFrameRate)).map(Double.init) ?? 0
        let natural = (try? await track.load(.naturalSize)) ?? .zero
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let oriented = CGRect(origin: .zero, size: natural)
            .applying(transform).standardized.size

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw VerifyError.unreadable(error.localizedDescription)
        }
        let output: AVAssetReaderOutput
        let reference = AVAssetReaderSampleReferenceOutput(track: track)
        if reader.canAdd(reference) {
            output = reference
        } else {
            let compressed = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(compressed) else {
                throw VerifyError.unreadable("the video track could not be read")
            }
            output = compressed
        }
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw VerifyError.unreadable(
                reader.error?.localizedDescription ?? "the file could not be opened")
        }
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            // Sum the samples, and do NOT floor each buffer at one: the reader
            // vends a handful of zero-sample marker buffers per track (measured:
            // exactly 4, on both a synthetic clip and a real blend), so flooring
            // over-counts and flattering the count is the one thing a check like
            // this must never do. Summing matches `ffprobe -count_frames`.
            frames += CMSampleBufferGetNumSamples(sample)
        }
        if reader.status == .failed {
            throw VerifyError.unreadable(
                reader.error?.localizedDescription ?? "the file could not be read to the end")
        }

        return Measurement(
            frameCount: frames,
            duration: duration.isFinite ? duration : 0,
            nominalFPS: nominal,
            displayWidth: max(0, Int(abs(oriented.width).rounded())),
            displayHeight: max(0, Int(abs(oriented.height).rounded())))
    }

    /// Frame-count slack. A whole-frame rounding difference at the tail of a
    /// clip is ordinary; losing a percent of the render is not. Two frames
    /// covers short clips, where 1% rounds to nothing.
    private static func frameTolerance(_ expected: Int) -> Int {
        max(2, Int((Double(expected) * 0.01).rounded(.up)))
    }

    /// Rate slack, relative. Wide enough for a container that rounds its
    /// timescale, far too tight for the halvings a capability-capped export
    /// preset performs.
    private static let fpsTolerance = 0.02

    /// Measures `url` and throws unless it matches what the job intended.
    ///
    /// Returns the measurement on success so the caller can record what is
    /// actually on disk rather than what it planned — the manifest should
    /// describe the file, not the intention.
    @discardableResult
    static func verify(
        _ url: URL,
        expectedFrames: Int?,
        expectedFPS: Double,
        stage: String
    ) async throws -> Measurement {
        let measured = try await measure(url)

        guard measured.frameCount > 0 else {
            throw VerifyError.empty(stage: stage)
        }

        if expectedFPS > 0, measured.measuredFPS > 0 {
            let drift = abs(measured.measuredFPS - expectedFPS) / expectedFPS
            if drift > fpsTolerance {
                throw VerifyError.rateMismatch(
                    stage: stage,
                    expectedFPS: expectedFPS,
                    actualFPS: measured.measuredFPS,
                    frames: measured.frameCount,
                    duration: measured.duration)
            }
        }

        if let expectedFrames, expectedFrames > 0 {
            let drift = abs(measured.frameCount - expectedFrames)
            if drift > frameTolerance(expectedFrames) {
                throw VerifyError.frameCountMismatch(
                    stage: stage,
                    expected: expectedFrames,
                    actual: measured.frameCount,
                    fps: measured.measuredFPS)
            }
            if drift > 0 {
                // Inside tolerance, but worth a breadcrumb: a render that is
                // routinely a frame or two out is a rounding bug waiting to
                // grow into the one above.
                log.notice("""
                    \(stage, privacy: .public): expected \(expectedFrames) frames, \
                    file has \(measured.frameCount) — within tolerance.
                    """)
            }
        }
        return measured
    }

    enum VerifyError: LocalizedError {
        case unreadable(String)
        case empty(stage: String)
        case frameCountMismatch(stage: String, expected: Int, actual: Int, fps: Double)
        case rateMismatch(
            stage: String, expectedFPS: Double, actualFPS: Double,
            frames: Int, duration: Double)

        var errorDescription: String? {
            switch self {
            case .unreadable(let reason):
                return "The finished clip couldn't be checked: \(reason)"
            case .empty(let stage):
                return "The finished clip has no frames (after \(stage)). Nothing was saved."
            case .frameCountMismatch(let stage, let expected, let actual, let fps):
                let lost = expected - actual
                let detail = lost > 0
                    ? "\(lost) of \(expected) blended frames are missing"
                    : "it has \(actual - expected) frames more than the \(expected) blended"
                return """
                    The render finished but the file doesn't match it: \(detail) \
                    (\(actual) frames at \(Self.rate(fps)) after \(stage)). \
                    Nothing was saved — please report this.
                    """
            case .rateMismatch(let stage, let expectedFPS, let actualFPS, let frames, let duration):
                return """
                    The render finished at \(Self.rate(actualFPS)) instead of \
                    \(Self.rate(expectedFPS)) — \(frames) frames over \
                    \(String(format: "%.1f", duration))s after \(stage). \
                    Nothing was saved — please report this.
                    """
            }
        }

        private static func rate(_ fps: Double) -> String {
            let rounded = (fps * 100).rounded() / 100
            return rounded == rounded.rounded()
                ? "\(Int(rounded)) fps"
                : String(format: "%.2f fps", rounded)
        }
    }
}

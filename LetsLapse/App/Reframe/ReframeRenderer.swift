import AVFoundation
import CoreGraphics
import Foundation

enum ReframeError: LocalizedError {
    case notImplemented
    case noVideoTrack
    case emptyTimeline
    case cannotWrite(URL)

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "Reframe rendering isn't wired up yet — the edit is saved, but there's nothing to write it with."
        case .noVideoTrack:
            return "That clip has no video track to reframe."
        case .emptyTimeline:
            return "Add at least one keyframe before creating the clip."
        case .cannotWrite(let url):
            return "Couldn't write the clip to \(url.lastPathComponent)."
        }
    }
}

/// Writes a reframed clip: the source read once, each frame cropped to the
/// window `ReframeEngine` reports for its own timestamp, retimed by the same
/// curve, and written out at the ratio's render size.
///
/// An actor because a render owns a reader and a writer for its whole life and
/// nothing else may touch them — the UI only ever sees `progress`.
actor ReframeRenderer {
    /// The plan a render works from — resolved up front so the frame loop
    /// never has to ask the asset anything.
    struct Plan {
        var sourceSize: CGSize
        var outputSize: CGSize
        var sourceDuration: Double
        var outputDuration: Double
        var frameRate: Int
        var keys: [PunchKeyframe]
        var ratio: ReframeRatio

        /// The crop for a given source time, in source pixels.
        func crop(at t: Double) -> ScaledCrop {
            ReframeEngine.crop(at: t, keys: keys, ratio: ratio, sourceSize: sourceSize)
        }
    }

    func render(
        asset: AVAsset,
        keys: [PunchKeyframe],
        ratio: ReframeRatio,
        outputURL: URL,
        progress: @Sendable (Double) -> Void
    ) async throws {
        let plan = try await plan(for: asset, keys: keys, ratio: ratio)
        progress(0)

        // TODO: the frame loop.
        //   1. AVAssetReader + AVAssetReaderTrackOutput on the video track,
        //      kCVPixelFormatType_32BGRA (or the source's native format).
        //   2. AVAssetWriter + AVAssetWriterInput at `plan.outputSize`, with an
        //      AVAssetWriterInputPixelBufferAdaptor.
        //   3. For each output frame n: outTime = n / plan.frameRate; invert
        //      `ReframeEngine.outputTime` to find the source time it wants,
        //      pull the sample at or after it, and draw it through the
        //      CGAffineTransform below into the writer's pixel buffer.
        //   4. Blend depth (`interp().bl`) averages the neighbouring source
        //      frames into the written one — the same rolling window the
        //      existing blend path uses.
        //   5. progress(Double(n) / totalFrames) each frame; finishWriting().
        _ = plan.crop(at: 0)
        _ = Self.cropTransform(crop: plan.crop(at: 0), outputSize: plan.outputSize)
        throw ReframeError.notImplemented
    }

    /// Convenience for callers that only have a file.
    func render(
        url: URL,
        keys: [PunchKeyframe],
        ratio: ReframeRatio,
        outputURL: URL,
        progress: @Sendable (Double) -> Void
    ) async throws {
        try await render(
            asset: AVURLAsset(url: url), keys: keys, ratio: ratio,
            outputURL: outputURL, progress: progress)
    }

    // MARK: - Plan

    func plan(for asset: AVAsset, keys: [PunchKeyframe], ratio: ReframeRatio) async throws -> Plan {
        guard !keys.isEmpty else { throw ReframeError.emptyTimeline }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ReframeError.noVideoTrack
        }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displayed = natural.applying(transform)
        let sourceSize = CGSize(width: abs(displayed.width), height: abs(displayed.height))
        let duration = try await asset.load(.duration).seconds
        let nominal = try await track.load(.nominalFrameRate)

        return Plan(
            sourceSize: sourceSize,
            outputSize: ratio.renderSize,
            sourceDuration: duration.isFinite ? duration : 0,
            outputDuration: ReframeEngine.outputDuration(
                keys: keys, sourceDuration: duration.isFinite ? duration : 0),
            frameRate: nominal > 0 ? Int(nominal.rounded()) : 30,
            keys: keys,
            ratio: ratio)
    }

    /// Source pixels → output pixels for one frame: translate the crop's
    /// origin to zero, then scale it up to fill the output.
    static func cropTransform(crop: ScaledCrop, outputSize: CGSize) -> CGAffineTransform {
        guard crop.w > 0, crop.h > 0 else { return .identity }
        let scale = Double(outputSize.width) / crop.w
        return CGAffineTransform(translationX: -crop.x, y: -crop.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
    }
}

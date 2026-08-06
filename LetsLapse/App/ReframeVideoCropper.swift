import AVFoundation
import CoreImage
import CoreGraphics

/// Bakes the punch-in reframe into a finished blend: one composition pass
/// over the (short) output clip, the way the grade bake works, but with a
/// per-frame crop instead of a per-frame colour chain.
///
/// The crop is evaluated at each output frame's *source* moment — handed in
/// as the compiled warp's frame map — so the punch stays welded to the same
/// scene time however the speed curve stretches the clock around it. Frames
/// are cropped from the full-resolution blend and scaled (Lanczos) to one
/// constant render size: the canvas-shaped base crop at source pixel scale,
/// so the wide stretches keep every pixel and only the punch itself
/// magnifies.
enum ReframeVideoCropper {
    /// GPU-backed and thread-safe; the composition handler runs on
    /// AVFoundation's own queues.
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// The constant output size for a reframed clip: the canvas-shaped crop at
    /// zoom 1 over `displaySize`, even-rounded for the encoder.
    static func renderSize(displaySize: CGSize, aspect: Double) -> CGSize? {
        let base = ReframeMath.baseCrop(aspect: aspect, sourceSize: displaySize)
        guard base.width > 1, base.height > 1 else { return nil }
        return CGSize(
            width: CGFloat(max(2, Int(base.width.rounded()) & ~1)),
            height: CGFloat(max(2, Int(base.height.rounded()) & ~1)))
    }

    /// One crop rect per output frame, in display-oriented pixels of
    /// `sourceSize` — the space the keys were authored in.
    static func rects(
        track: ReframeTrack,
        aspect: Double,
        sourceSize: CGSize,
        warp: WarpTimeline,
        frameSourceTimes: [Double]
    ) -> [CGRect] {
        frameSourceTimes.map { time in
            track.crop(
                atSource: time, aspect: aspect, sourceSize: sourceSize,
                outputTime: warp.outputTime(atSource:))
        }
    }

    /// Writes a copy of `sourceURL` with the reframe baked in and returns the
    /// new file's URL and pixel size — in the temporary directory, under a
    /// `LetsLapse-` name, the caller owns it.
    ///
    /// `sourceSize` is the capture's display-oriented size (the keys' space);
    /// the pass rescales if the blend intermediate landed at another scale.
    static func croppedCopy(
        of sourceURL: URL,
        track: ReframeTrack,
        aspect: Double,
        sourceSize: CGSize,
        warp: WarpTimeline,
        frameSourceTimes: [Double],
        outputFPS: Int,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> (url: URL, renderSize: CGSize) {
        guard !track.isEmpty, !frameSourceTimes.isEmpty else {
            throw ReframeCropError.exportFailed("the reframe has no keyframes")
        }
        let asset = AVURLAsset(url: sourceURL)
        guard let assetTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ReframeCropError.exportFailed("the clip has no video track")
        }
        let preferred = try await assetTrack.load(.preferredTransform)
        let natural = try await assetTrack.load(.naturalSize)
        let orientedRect = CGRect(origin: .zero, size: natural).applying(preferred)
        let clipSize = CGSize(width: abs(orientedRect.width), height: abs(orientedRect.height))
        guard clipSize.width > 0, clipSize.height > 0,
              sourceSize.width > 0, sourceSize.height > 0 else {
            throw ReframeCropError.exportFailed("the clip's size couldn't be read")
        }

        // The keys live in the capture's pixel space; the blend intermediate
        // is normally the same scale, but a mismatch just rescales the rects.
        let scale = Double(clipSize.width) / Double(sourceSize.width)
        let scaledSource = CGSize(
            width: sourceSize.width * CGFloat(scale), height: sourceSize.height * CGFloat(scale))
        guard let renderSize = renderSize(displaySize: scaledSource, aspect: aspect) else {
            throw ReframeCropError.exportFailed("the render size collapsed")
        }

        let frameRects = rects(
            track: track, aspect: aspect, sourceSize: sourceSize,
            warp: warp, frameSourceTimes: frameSourceTimes
        ).map { $0.applying(CGAffineTransform(scaleX: scale, y: scale)) }

        let outFps = Double(max(1, outputFPS))
        let composition = AVMutableVideoComposition(asset: asset) { request in
            let index = Int((request.compositionTime.seconds * outFps).rounded())
            let rect = frameRects[min(max(0, index), frameRects.count - 1)]
            let extent = request.sourceImage.extent
            // The rects are top-left display coordinates; Core Image runs
            // bottom-left.
            let flipped = CGRect(
                x: rect.minX, y: extent.height - rect.maxY,
                width: max(1, rect.width), height: max(1, rect.height))
            let cropped = request.sourceImage.cropped(to: flipped)
                .transformed(by: CGAffineTransform(translationX: -flipped.minX, y: -flipped.minY))
            // Lanczos for the resample — the punch is a magnification, and
            // bilinear stair-steps exactly where the move should be silkiest.
            let scaled = cropped.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: renderSize.height / flipped.height,
                kCIInputAspectRatioKey: (renderSize.width / flipped.width)
                    / (renderSize.height / flipped.height),
            ])
            request.finish(
                with: scaled.cropped(to: CGRect(origin: .zero, size: renderSize)),
                context: context)
        }
        composition.renderSize = renderSize

        guard let export = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ReframeCropError.exportUnavailable
        }
        let isMP4 = sourceURL.pathExtension.lowercased() == "mp4"
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LetsLapse-reframed-\(UUID().uuidString).\(isMP4 ? "mp4" : "mov")")
        try? FileManager.default.removeItem(at: outputURL)
        export.videoComposition = composition
        export.outputURL = outputURL
        export.outputFileType = isMP4 ? .mp4 : .mov
        export.shouldOptimizeForNetworkUse = true

        let box = ExportBox(export)
        let poller: Task<Void, Never>? = progress.map { report in
            Task.detached {
                while !Task.isCancelled {
                    report(Double(box.session.progress))
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }
        defer { poller?.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    box.session.exportAsynchronously {
                        switch box.session.status {
                        case .completed:
                            continuation.resume()
                        case .cancelled:
                            continuation.resume(throwing: CancellationError())
                        default:
                            continuation.resume(throwing: ReframeCropError.exportFailed(
                                box.session.error?.localizedDescription ?? "the reframe pass didn't finish"))
                        }
                    }
                }
            } onCancel: {
                box.session.cancelExport()
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        return (outputURL, renderSize)
    }

    /// `AVAssetExportSession` isn't `Sendable`; boxing it keeps the compiler
    /// honest about the hop into the completion handler.
    private final class ExportBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }

    enum ReframeCropError: LocalizedError {
        case exportUnavailable
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .exportUnavailable:
                return "Couldn't start the punch-in reframe pass on this video."
            case .exportFailed(let reason):
                return "Couldn't bake the punch-in reframe: \(reason)"
            }
        }
    }
}

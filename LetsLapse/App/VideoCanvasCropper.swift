import AVFoundation
import CoreGraphics

/// Crops a finished blend to the canvas chosen on the Adjust screen — the same
/// centred `CollectionMath.cropBox` the preview draws, applied as one
/// composition pass over the (short) output clip, the way the grade bake works.
///
/// The render stays at source pixel scale: a 1080p 16:9 blend cropped to 9:16
/// lands at 608×1080, never upscaled to a nominal export size. Rotation is
/// inherent — the crop works on the clip's display-oriented picture via its
/// `preferredTransform`, so a metadata-rotated capture crops the way it looks.
enum VideoCanvasCropper {
    /// The kept pixels for `displaySize` on `canvas` (centred), even-rounded
    /// for the encoder. nil when the clip already matches the canvas.
    static func cropSize(displaySize: CGSize, canvas: CanvasRatio) -> CGSize? {
        guard displaySize.width > 0, displaySize.height > 0 else { return nil }
        guard abs(displaySize.width / displaySize.height - canvas.aspect) > 0.01 else { return nil }
        guard let box = CollectionMath.cropBox(clipSize: displaySize, canvas: canvas, offset: 0.5) else {
            return nil
        }
        return CGSize(
            width: CGFloat(max(2, Int(box.rect.width.rounded()) & ~1)),
            height: CGFloat(max(2, Int(box.rect.height.rounded()) & ~1)))
    }

    /// Writes a copy of `sourceURL` cropped to `canvas` — and, when
    /// `shortEdge` is set, scaled down to that resolution class (1080 →
    /// 1920×1080 / 1080×1920) — returning the new file's URL and pixel size:
    /// in the temporary directory, under a `LetsLapse-` name, the caller
    /// owns it. A clip that already matches the canvas at an acceptable size
    /// returns `sourceURL` with a nil size, so callers can invoke this
    /// unconditionally and tell the two apart.
    static func croppedCopy(
        of sourceURL: URL,
        canvas: CanvasRatio,
        shortEdge: Int? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> (url: URL, renderSize: CGSize?) {
        let asset = AVURLAsset(url: sourceURL)
        guard let assetTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw CropError.exportFailed("the clip has no video track")
        }
        let preferred = try await assetTrack.load(.preferredTransform)
        let natural = try await assetTrack.load(.naturalSize)
        let orientedRect = CGRect(origin: .zero, size: natural).applying(preferred)
        let orientedSize = CGSize(width: abs(orientedRect.width), height: abs(orientedRect.height))
        // The kept pixels: the centred canvas crop, or the whole frame when
        // the clip already matches — the pass still runs then if a size cap
        // asks for a downscale.
        let cropped = cropSize(displaySize: orientedSize, canvas: canvas)
        let keptSize = cropped ?? CGSize(
            width: CGFloat(max(2, Int(orientedSize.width.rounded()) & ~1)),
            height: CGFloat(max(2, Int(orientedSize.height.rounded()) & ~1)))
        let target = shortEdge.flatMap { ReframeVideoCropper.scaledDown(keptSize, shortEdge: $0) }
        guard cropped != nil || target != nil else { return (sourceURL, nil) }
        let renderSize = target ?? keptSize
        let boxRect = CollectionMath.cropBox(
            clipSize: orientedSize, canvas: canvas, offset: 0.5)?.rect
            ?? CGRect(origin: .zero, size: orientedSize)

        // Land the oriented picture at the origin, slide the kept rect to the
        // render origin — same transform chain as the collection export —
        // then scale once to the export size.
        let oriented = preferred.concatenating(
            CGAffineTransform(translationX: -orientedRect.minX, y: -orientedRect.minY))
        let exportScale = renderSize.width / max(1, keptSize.width)
        let transform = oriented
            .concatenating(CGAffineTransform(translationX: -boxRect.minX, y: -boxRect.minY))
            .concatenating(CGAffineTransform(scaleX: exportScale, y: exportScale))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: assetTrack)
        layer.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layer]

        let composition = AVMutableVideoComposition()
        composition.instructions = [instruction]
        composition.renderSize = renderSize
        let fps = try await assetTrack.load(.nominalFrameRate)
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps.rounded())))

        guard let export = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw CropError.exportUnavailable
        }
        let isMP4 = sourceURL.pathExtension.lowercased() == "mp4"
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LetsLapse-cropped-\(UUID().uuidString).\(isMP4 ? "mp4" : "mov")")
        try? FileManager.default.removeItem(at: outputURL)
        export.videoComposition = composition
        export.outputURL = outputURL
        export.outputFileType = isMP4 ? .mp4 : .mov
        export.shouldOptimizeForNetworkUse = true

        let box2 = ExportBox(export)
        let poller: Task<Void, Never>? = progress.map { report in
            Task.detached {
                while !Task.isCancelled {
                    report(Double(box2.session.progress))
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }
        defer { poller?.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    box2.session.exportAsynchronously {
                        switch box2.session.status {
                        case .completed:
                            continuation.resume()
                        case .cancelled:
                            continuation.resume(throwing: CancellationError())
                        default:
                            continuation.resume(throwing: CropError.exportFailed(
                                box2.session.error?.localizedDescription ?? "the crop pass didn't finish"))
                        }
                    }
                }
            } onCancel: {
                box2.session.cancelExport()
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

    enum CropError: LocalizedError {
        case exportUnavailable
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .exportUnavailable:
                return "Couldn't start the canvas crop pass on this video."
            case .exportFailed(let reason):
                return "Couldn't crop to the canvas: \(reason)"
            }
        }
    }
}

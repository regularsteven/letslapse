import AVFoundation
import CoreGraphics
import CoreImage
import LetsLapseKit

/// Crops a finished blend to the canvas chosen on the Adjust screen — the same
/// `CollectionMath.cropBox` the preview draws, applied as one composition pass
/// over the (short) output clip, the way the grade bake works. The box slides
/// along the source's free axis by `offset` (0…1, 0.5 = centred) — the guided
/// builder's frame pane drags it; every other caller keeps it centred.
///
/// The render stays at source pixel scale: a 1080p 16:9 blend cropped to 9:16
/// lands at 608×1080, never upscaled to a nominal export size. Rotation is
/// inherent — the crop works on the clip's display-oriented picture (the CI
/// composition applies the `preferredTransform` before the handler sees a
/// frame), so a metadata-rotated capture crops the way it looks.
enum VideoCanvasCropper {
    /// GPU-backed and thread-safe; the composition handler runs on
    /// AVFoundation's own queues.
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// The kept pixels for `displaySize` on `canvas`, even-rounded for the
    /// encoder. Size is offset-independent — only where the box sits moves —
    /// so this stays the one truth for every "crops to 2160×1214" label.
    /// nil when the clip already matches the canvas.
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
    /// unconditionally and tell the two apart — a nil size also means a
    /// `grade` was NOT baked.
    ///
    /// A non-identity `grade` rides the same pass — every frame is already
    /// decoded and re-encoded here, so folding the colour chain in saves the
    /// separate grade generation.
    static func croppedCopy(
        of sourceURL: URL,
        canvas: CanvasRatio,
        offset: Double = 0.5,
        shortEdge: Int? = nil,
        grade: PhotoGrade = .identity,
        gradeMap: GradeSourceMap = .direct,
        /// Forces the output size. Set when this pass is normalising one
        /// segment of a mixed-resolution ramp shoot to the size every other
        /// segment lands at, so the stitch can lay them end to end — see
        /// `ReframeVideoCropper.croppedCopy`'s override of the same name.
        renderSizeOverride: CGSize? = nil,
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
        let target = renderSizeOverride
            ?? shortEdge.flatMap { ReframeVideoCropper.scaledDown(keptSize, shortEdge: $0) }
        // An override that already matches the kept pixels asks for nothing:
        // let a base-resolution segment out untouched rather than paying a
        // full re-encode to arrive where it already is.
        let needsCrop = cropped != nil
        let needsScale = target != nil && target != keptSize
        // ...unless this pass is normalising a mixed-resolution shoot, where
        // matching SIZE is not enough — the pieces must also agree on how they
        // are oriented.
        //
        // This pass renders display-oriented, so it BAKES rotation and emits an
        // identity transform. A rotated segment let out untouched keeps its
        // landscape raster and its −90 tag instead, and `stitchVideos` gives
        // the whole track one transform — piece 0's. A portrait shoot therefore
        // came out with its base upright and its burst rotated 90° and
        // letterboxed, because the burst had already been baked upright and
        // then got rotated a second time (project A7B4726A, 2026-08-15).
        //
        // Gated on the override so the ordinary tail path is untouched: there,
        // one clip is the whole clip and skipping a pointless re-encode of an
        // already-correct portrait video is exactly right.
        let needsOrienting = renderSizeOverride != nil && !preferred.isIdentity
        guard needsCrop || needsScale || needsOrienting else { return (sourceURL, nil) }
        let renderSize = target ?? keptSize
        let boxRect = CollectionMath.cropBox(
            clipSize: orientedSize, canvas: canvas, offset: offset)?.rect
            ?? CGRect(origin: .zero, size: orientedSize)

        // The grade's chain, built once — the movie carries no as-shot
        // temperature tag, so white balance anchors at D65 like every video
        // grade (see `VideoGrader`). A grade that travels can't be built once:
        // it is rebuilt per frame, at the SOURCE moment `gradeMap` says that
        // frame came from, because this pass runs over a clip whose clock the
        // warp has already rewritten.
        let chain: ((CIImage) -> CIImage)? = grade.isIdentity || grade.isKeyframed
            ? nil : PhotoGrader.filterChain(grade, asShotKelvin: PhotoGrader.neutralKelvin)
        let keyframedGrade: PhotoGrade? = grade.isKeyframed ? grade : nil
        let gradedDuration = (try? await asset.load(.duration))?.seconds ?? 0
        let composition = AVMutableVideoComposition(asset: asset) { request in
            let extent = request.sourceImage.extent
            // The box is authored top-left on the display-oriented picture;
            // Core Image runs bottom-left.
            let flipped = CGRect(
                x: boxRect.minX, y: extent.height - boxRect.maxY,
                width: max(1, boxRect.width), height: max(1, boxRect.height))
            let croppedImage = request.sourceImage.cropped(to: flipped)
                .transformed(by: CGAffineTransform(translationX: -flipped.minX, y: -flipped.minY))
            // Lanczos, like the reframe pass — the layer-instruction transform
            // this replaces resampled bilinearly, so a downscaled crop landed
            // softer than a downscaled reframe of the same clip.
            let scaled = croppedImage.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: renderSize.height / flipped.height,
                kCIInputAspectRatioKey: (renderSize.width / flipped.width)
                    / (renderSize.height / flipped.height),
            ])
            let framed = scaled.cropped(to: CGRect(origin: .zero, size: renderSize))
            // Filters like the unsharp mask and the vignette grow the extent;
            // the frame has to come back the size the writer expects.
            var graded = chain.map { $0(framed).cropped(to: framed.extent) } ?? framed
            if let keyframedGrade {
                let position = gradeMap.position(
                    outputSeconds: request.compositionTime.seconds,
                    outputDuration: gradedDuration)
                let moment = PhotoGrader.filterChain(
                    keyframedGrade.frozen(at: position),
                    asShotKelvin: PhotoGrader.neutralKelvin)
                graded = moment(graded).cropped(to: framed.extent)
            }
            request.finish(with: graded, context: context)
        }
        composition.renderSize = renderSize

        let nominalFPS = (try? await assetTrack.load(.nominalFrameRate)) ?? 30
        let fps = nominalFPS > 0 ? Double(nominalFPS) : 30
        // The shared policy encodes the pass — deterministic bitrate and full
        // colour tags, where the export-session preset chose its own and
        // wrote none.
        let policy = VideoEncodePolicy(
            profile: .h264High8Bit,
            width: Int(renderSize.width), height: Int(renderSize.height), fps: fps)
        let isMP4 = sourceURL.pathExtension.lowercased() == "mp4"
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LetsLapse-cropped-\(UUID().uuidString).\(isMP4 ? "mp4" : "mov")")
        do {
            try await CompositionExporter.export(
                asset: asset, composition: composition, to: outputURL,
                fileType: isMP4 ? .mp4 : .mov, policy: policy, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CropError.exportFailed(error.localizedDescription)
        }
        return (outputURL, renderSize)
    }

    enum CropError: LocalizedError {
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .exportFailed(let reason):
                return "Couldn't crop to the canvas: \(reason)"
            }
        }
    }
}

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
///
/// The same pass also cuts the project's own **crop** — the Edit screen's
/// frame (`FrameCrop`, 2026-09-12) — and can run for that alone. The order is
/// level → project crop → canvas box → scale: the project crop was drawn over
/// the levelled picture, and the canvas is then the largest box of its shape
/// inside what the photographer kept, which is the one composition rule the
/// two crops have ("crop first, then the canvas on the cropped clip"). The
/// stills blend needs this pass for the crop alone: `ImageStacker` writes
/// every output frame into a pool at the source's size, so a crop that
/// changes the size cannot ride the per-frame bake and is cut here, over the
/// finished clip, exactly as the canvas is.
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
    /// `canvas` nil = no box: the pass still levels, cuts the project `crop`
    /// and scales to `shortEdge`, which is what a resolution cap over a
    /// project crop with no chosen canvas wants — the crop is the shape,
    /// and the "as shot" default must not re-cut it.
    ///
    /// A non-identity `grade` rides the same pass — every frame is already
    /// decoded and re-encoded here, so folding the colour chain in saves the
    /// separate grade generation.
    static func croppedCopy(
        of sourceURL: URL,
        canvas: CanvasRatio?,
        offset: Double = 0.5,
        shortEdge: Int? = nil,
        grade: PhotoGrade = .identity,
        gradeMap: GradeSourceMap = .direct,
        /// The project's fine rotation, applied to every frame BEFORE the
        /// canvas crop. Its own parameter (not `grade.rotationDegrees`) so the
        /// per-segment normalisation, which runs with an identity grade, can
        /// still level — and a level on its own is reason enough to run.
        rotationDegrees: Double = 0,
        /// The project's own crop — the Edit screen's frame, in the LEVELLED
        /// picture's unit square — cut after the level and before the canvas
        /// box is fitted. Its own parameter for the same reason as the
        /// rotation: the stills blend runs this pass with an identity grade
        /// (its colour is already baked per frame) and still has to cut. A
        /// full crop is a no-op, so callers can pass it unconditionally.
        crop: FrameCrop? = nil,
        /// The rate the job asked for. Stated by the caller rather than probed
        /// off `sourceURL`: this pass runs over an intermediate, and reading the
        /// clock back from it propagates whatever an upstream stage did to it
        /// instead of correcting it. nil falls back to the probe, for callers
        /// with no intended rate of their own.
        outputFPS: Double? = nil,
        /// Forces the output size. Set when this pass is normalising one
        /// segment of a mixed-resolution ramp shoot to the size every other
        /// segment lands at, so the stitch can lay them end to end — see
        /// `ReframeVideoCropper.croppedCopy`'s override of the same name.
        renderSizeOverride: CGSize? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> (url: URL, renderSize: CGSize?) {
        try await croppedCopy(
            of: sourceURL, canvas: canvas, offset: offset, shortEdge: shortEdge,
            grade: grade, gradeMap: gradeMap, rotationDegrees: rotationDegrees,
            crop: crop, outputFPS: outputFPS, renderSizeOverride: renderSizeOverride,
            profile: .h264High8Bit, progress: progress)
    }

    /// The project's crop alone: the Edit screen's frame cut from the
    /// LEVELLED clip, no canvas box, no scale — the stills blend's tail pass
    /// (see the type comment). Returns `sourceURL` with a nil size when the
    /// crop keeps the whole frame and nothing else asks for the pass.
    ///
    /// `profile` is the encode the clip was written with: a 10-bit HEVC
    /// stills blend stays 10-bit through its crop rather than landing as
    /// 8-bit H.264 the way the canvas pass (video sources, 8-bit) does.
    static func croppedCopy(
        of sourceURL: URL,
        crop: FrameCrop,
        grade: PhotoGrade = .identity,
        gradeMap: GradeSourceMap = .direct,
        rotationDegrees: Double = 0,
        outputFPS: Double? = nil,
        profile: VideoEncodePolicy.Profile = .h264High8Bit,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> (url: URL, renderSize: CGSize?) {
        try await croppedCopy(
            of: sourceURL, canvas: nil, offset: 0.5, shortEdge: nil,
            grade: grade, gradeMap: gradeMap, rotationDegrees: rotationDegrees,
            crop: crop, outputFPS: outputFPS, renderSizeOverride: nil,
            profile: profile, progress: progress)
    }

    /// The one body behind both entry points. `canvas` nil = no canvas box,
    /// only whatever the project crop, the level, the scale and the override
    /// ask for.
    private static func croppedCopy(
        of sourceURL: URL,
        canvas: CanvasRatio?,
        offset: Double,
        shortEdge: Int?,
        grade: PhotoGrade,
        gradeMap: GradeSourceMap,
        rotationDegrees: Double,
        crop: FrameCrop?,
        outputFPS: Double?,
        renderSizeOverride: CGSize?,
        profile: VideoEncodePolicy.Profile,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> (url: URL, renderSize: CGSize?) {
        let asset = AVURLAsset(url: sourceURL)
        guard let assetTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw CropError.exportFailed("the clip has no video track")
        }
        let preferred = try await assetTrack.load(.preferredTransform)
        let natural = try await assetTrack.load(.naturalSize)
        let orientedRect = CGRect(origin: .zero, size: natural).applying(preferred)
        let orientedSize = CGSize(width: abs(orientedRect.width), height: abs(orientedRect.height))
        // The project crop first. Its pixels are measured over the oriented
        // natural size, which is also the extent every request's frame
        // arrives at, so the rect the handler cuts (`FrameCrop.apply`) and
        // the size everything below is fitted to agree to the pixel.
        let projectCrop = crop.flatMap { $0.isFull ? nil : $0 }
        let framedSize = projectCrop?.outputSize(for: orientedSize) ?? orientedSize
        // The kept pixels: the centred canvas crop inside what the project
        // crop left, or the whole (project-cropped) frame when the clip
        // already matches — the pass still runs then if a size cap asks for a
        // downscale.
        let cropped = canvas.flatMap { cropSize(displaySize: framedSize, canvas: $0) }
        let keptSize = cropped ?? CGSize(
            width: CGFloat(max(2, Int(framedSize.width.rounded()) & ~1)),
            height: CGFloat(max(2, Int(framedSize.height.rounded()) & ~1)))
        let target = renderSizeOverride
            ?? shortEdge.flatMap { ReframeVideoCropper.scaledDown(keptSize, shortEdge: $0) }
        // An override that already matches the kept pixels asks for nothing:
        // let a base-resolution segment out untouched rather than paying a
        // full re-encode to arrive where it already is.
        let needsCrop = cropped != nil || projectCrop != nil
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
        let needsLevelling = FrameRotation.isActive(rotationDegrees) || grade.hasRotation
        guard needsCrop || needsScale || needsOrienting || needsLevelling else { return (sourceURL, nil) }
        let renderSize = target ?? keptSize
        // The canvas box, fitted inside the project-cropped frame.
        let boxRect = canvas.flatMap {
            CollectionMath.cropBox(clipSize: framedSize, canvas: $0, offset: offset)?.rect
        } ?? CGRect(origin: .zero, size: framedSize)

        // The grade's chain, built once — the movie carries no as-shot
        // temperature tag, so white balance anchors at D65 like every video
        // grade (see `VideoGrader`). A grade that travels can't be built once:
        // it is rebuilt per frame, at the SOURCE moment `gradeMap` says that
        // frame came from, because this pass runs over a clip whose clock the
        // warp has already rewritten. Colour only — a grade that is nothing
        // but geometry (a level, a crop) builds no chain, since this pass
        // applies its geometry itself.
        let chain: ((CIImage) -> CIImage)? = grade.isColorIdentity || grade.isKeyframed
            ? nil : PhotoGrader.filterChain(grade, asShotKelvin: PhotoGrader.neutralKelvin)
        let keyframedGrade: PhotoGrade? = grade.isKeyframed ? grade : nil
        let gradedDuration = (try? await asset.load(.duration))?.seconds ?? 0
        let composition = AVMutableVideoComposition(asset: asset) { request in
            // The level this frame gets: the grade's own moment when it
            // travels, else the constant handed in.
            let angle = keyframedGrade.map {
                $0.rotationDegrees(at: gradeMap.position(
                    outputSeconds: request.compositionTime.seconds,
                    outputDuration: gradedDuration))
            } ?? rotationDegrees
            let levelled = FrameRotation.rotated(request.sourceImage, degrees: angle)
            // The project crop, cut from the levelled frame and moved to the
            // origin, so the canvas box below is measured in its pixels.
            let kept = projectCrop.map { FrameCrop.apply($0, to: levelled) } ?? levelled
            let extent = kept.extent
            // The box is authored top-left on the display-oriented picture;
            // Core Image runs bottom-left.
            let flipped = CGRect(
                x: boxRect.minX, y: extent.height - boxRect.maxY,
                width: max(1, boxRect.width), height: max(1, boxRect.height))
            let croppedImage = kept.cropped(to: flipped)
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

        let fps: Double
        if let outputFPS, outputFPS > 0 {
            fps = outputFPS
        } else {
            let nominalFPS = (try? await assetTrack.load(.nominalFrameRate)) ?? 30
            fps = nominalFPS > 0 ? Double(nominalFPS) : 30
        }
        // The clip's clock, stated rather than inherited — see the twin comment
        // in `ReframeVideoCropper`. Without this the composition initializer
        // seeds `frameDuration` from the incoming asset, so a pass over an
        // already-retimed intermediate re-encodes the damage instead of the
        // rate the job asked for.
        composition.frameDuration = CMTime(
            value: 1, timescale: CMTimeScale(max(1, Int(fps.rounded()))))
        // The shared policy encodes the pass — deterministic bitrate and full
        // colour tags, where the export-session preset chose its own and
        // wrote none.
        let policy = VideoEncodePolicy(
            profile: profile,
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

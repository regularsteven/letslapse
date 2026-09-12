import AVFoundation
import CoreImage
import CoreGraphics
import LetsLapseKit

/// The video half of the grading system: the same `PhotoGrade` a still is
/// rendered through, applied to a movie.
///
/// Two jobs, both non-destructive — nothing here rewrites a capture in place:
///
/// - `gradedFrame` pulls one representative frame out of a clip and grades it,
///   which is what a video project's detail card shows as its live preview.
/// - `bakedCopy` writes a graded copy of a movie to a temporary file, for the
///   paths where a graded project's footage becomes a new file: a rendered
///   version, or an export to Photos.
///
/// The grade runs through `AVMutableVideoComposition`, so every frame is decoded,
/// put through the Core Image chain, and re-encoded. That means a baked copy is
/// a re-encode (ProRes lands as H.264, via the shared `VideoEncodePolicy`),
/// which is the accepted cost of baking a grade into video, and exactly what
/// `VideoFlatten` already does for Capture Flat on non-Log hardware.
///
/// This is the STANDALONE bake, for when no geometry pass runs — when the
/// blend chain also reframes or crops, the grade rides that pass instead (see
/// the croppers' `grade` parameter) and this file's chain is what they apply.
/// The chain itself stays the legacy CI one; moving video onto the GPU tone
/// engine is a flagged follow-up.
enum VideoGrader {
    /// GPU-backed and thread-safe; the composition handler runs on AVFoundation's
    /// own queues and the frame grab off the media work queue.
    private static let context: CIContext = {
        // As `PhotoGrader`: a graded movie may carry a LUT.
        LUTStore.installResolver()
        return CIContext(options: [.useSoftwareRenderer: false])
    }()

    /// A graded still from `url` for a preview, or nil when no frame could be
    /// read. `seconds` picks how far in to sample — a fraction of a second,
    /// matching the ungraded video thumbnail, so the two show the same moment.
    /// `maxDimension` bounds the decode the way the still grader's previews are
    /// bounded.
    static func gradedFrame(
        at url: URL,
        grade: PhotoGrade,
        seconds: Double = 0.2,
        maxDimension: CGFloat = 1400
    ) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        guard let frame = try? generator.copyCGImage(
            at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil) else {
            MediaWorkQueue.note(
                "grade frame grab failed for \(url.lastPathComponent)", isError: true)
            return nil
        }
        guard !grade.isIdentity else { return frame }
        // Levelled first, cropped second, graded third — the same order
        // `composition` bakes in, so the vignette sits on the frame that
        // ships. The crop was drawn over the LEVELLED picture, which is why
        // it follows the rotation.
        var source = FrameRotation.rotated(CIImage(cgImage: frame), degrees: grade.rotationDegrees)
        if let crop = grade.crop, !crop.isFull {
            source = FrameCrop.apply(crop, to: source)
        }
        // A card's one frame is the clip's opening moment, which is the moment
        // a keyframed grade answers for when it is only asked once.
        let output = filterChain(grade.frozen(at: 0))(source)
        guard output.extent.width > 0, output.extent.height > 0 else { return frame }
        // A failed render leaves the ungraded frame on screen rather than an
        // empty card.
        return context.createCGImage(output, from: output.extent) ?? frame
    }

    /// The composition that bakes `grade` into every frame of `asset`, or nil
    /// when the grade is a no-op — callers then export (or skip exporting)
    /// without one rather than paying for an identity pass.
    ///
    /// A **keyframed** grade needs two things this one doesn't: how long the
    /// clip runs, so a frame's time can be turned into a position, and — when
    /// the clip's clock is no longer the source's — the `map` that says which
    /// source moment each frame came from. Without a duration there is no
    /// position to grade at, so the grade freezes at the opening moment rather
    /// than guessing; that is a visible flattening, never a silent smear across
    /// the wrong frames.
    ///
    /// The project's **crop** is cut here too — after the level, because it
    /// was drawn over the levelled picture, and before the colour, so the
    /// vignette centres on the frame that ships (the still path grades first
    /// and cuts after; see `PhotoGrader.engineRender`). It is the OPENING
    /// moment's crop for every frame: a composition renders at one size, and
    /// the crop is static by decision — the timeline carries it whole, never
    /// eased — so no later moment can disagree. The composition comes back
    /// with `renderSize` already at the cropped size, measured over the size
    /// the initializer gave it: the track's DISPLAY-oriented natural size,
    /// which is also the extent every request's `sourceImage` arrives at
    /// (verified on a 90°-tagged clip, 2026-09-12), so the rect the handler
    /// cuts and the size the composition promised agree to the pixel. A
    /// player takes that size as is; `bakedCopy` keeps it.
    static func composition(
        for asset: AVAsset,
        grade: PhotoGrade,
        durationSeconds: Double? = nil,
        map: GradeSourceMap = .direct,
        /// Whether the crop is cut. The default is NOT to — the opposite of
        /// `PhotoGrader.render(cropped:)`, because a composition's usual home
        /// is a player: the video editor's, which is the editor's preview and
        /// keeps the whole levelled frame so the text layers drawn over it
        /// keep their coordinate space (spec decision 3 — the editor never
        /// resizes the picture for a crop; its Crop panel says "shown on
        /// export"). The surfaces that show the finished picture ask for the
        /// cut: `bakedCopy`, and the motion preview. A true with no crop is a
        /// no-op.
        cropped: Bool = false
    ) -> AVMutableVideoComposition? {
        // The project's level, applied to every frame before its colour: the
        // geometry keeps the frame's size, so the writer sees nothing new —
        // the crop is what changes the size, and `renderSize` says so below.
        let rotation = grade.rotationDegrees
        let crop = cropped ? grade.crop.flatMap { $0.isFull ? nil : $0 } : nil
        // Nothing to do — including a crop-only grade the caller asked to
        // leave uncut — is no composition, not a pass that renders every
        // frame through nothing.
        guard !grade.isColorIdentity || grade.hasRotation || crop != nil else { return nil }
        let composition: AVMutableVideoComposition
        if grade.isKeyframed, let duration = durationSeconds, duration > 0 {
            composition = AVMutableVideoComposition(asset: asset) { request in
                let position = map.position(
                    outputSeconds: request.compositionTime.seconds, outputDuration: duration)
                let moment = grade.frozen(at: position)
                let chain = filterChain(moment)
                let levelled = FrameRotation.rotated(
                    request.sourceImage, degrees: moment.rotationDegrees)
                let framed = crop.map { FrameCrop.apply($0, to: levelled) } ?? levelled
                let graded = chain(framed).cropped(to: framed.extent)
                request.finish(with: graded, context: context)
            }
        } else {
            let chain = filterChain(grade.frozen(at: 0))
            composition = AVMutableVideoComposition(asset: asset) { request in
                let levelled = FrameRotation.rotated(request.sourceImage, degrees: rotation)
                let framed = crop.map { FrameCrop.apply($0, to: levelled) } ?? levelled
                // Filters like the unsharp mask and the vignette grow the extent;
                // the frame has to come back the size the writer expects — the
                // cropped one, when there is a crop.
                let graded = chain(framed).cropped(to: framed.extent)
                request.finish(with: graded, context: context)
            }
        }
        if let crop {
            composition.renderSize = crop.outputSize(for: composition.renderSize)
        }
        return composition
    }

    /// Writes a copy of `sourceURL` with `grade` baked in and returns the new
    /// file's URL — in the temporary directory, under a `LetsLapse-` name so the
    /// cache sweep can reclaim it. The caller owns that file.
    ///
    /// An identity grade returns `sourceURL` unchanged, so callers can invoke
    /// this unconditionally; compare the result against what you passed in
    /// before deleting anything.
    static func bakedCopy(
        of sourceURL: URL,
        grade: PhotoGrade,
        map: GradeSourceMap = .direct,
        /// The rate the job asked for, when the caller has one. This is the
        /// render pipeline's third tail pass and carried the same defect as the
        /// two croppers: probing the clock off the incoming intermediate re-
        /// encodes whatever an upstream stage did to it. Export paths that are
        /// simply re-grading a file the user already has (Save to Photos) pass
        /// nil and keep the probe — there the source's own rate IS the intent.
        outputFPS: Double? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        // Only a keyframed grade needs the clip's length, and only that read is
        // worth the probe.
        let duration = grade.isKeyframed
            ? (try? await asset.load(.duration))?.seconds : nil
        guard let composition = composition(
            for: asset, grade: grade, durationSeconds: duration, map: map, cropped: true)
        else { return sourceURL }
        guard let assetTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw GradeError.exportFailed("the clip has no video track")
        }
        // The policy needs the clip's display-oriented shape and rate — probed
        // the way the croppers probe theirs. Even-rounded for the encoder;
        // the composition renders the matching size so a stray odd pixel is
        // cropped, not scaled.
        let preferred = try await assetTrack.load(.preferredTransform)
        let natural = try await assetTrack.load(.naturalSize)
        let orientedRect = CGRect(origin: .zero, size: natural).applying(preferred)
        let orientedWidth = max(2, Int(abs(orientedRect.width).rounded()) & ~1)
        let orientedHeight = max(2, Int(abs(orientedRect.height).rounded()) & ~1)
        guard orientedWidth > 2 || orientedHeight > 2 else {
            throw GradeError.exportFailed("the clip's size couldn't be read")
        }
        // With a crop the composition has already sized itself, off the same
        // oriented natural size its handler measures every frame against —
        // `pixelRect` keeps that even, so the encoder is happy — and that
        // size is kept rather than re-derived from the probe here, which
        // could round a crop edge two pixels away from the handler's on an
        // odd-sized source. The probe stands in only if the composition
        // could not read one.
        let oriented = CGSize(width: orientedWidth, height: orientedHeight)
        let rendered: CGSize
        if let crop = grade.crop, !crop.isFull {
            let sized = composition.renderSize
            rendered = sized.width >= 2 && sized.height >= 2 ? sized : crop.outputSize(for: oriented)
        } else {
            rendered = oriented
        }
        let width = Int(rendered.width)
        let height = Int(rendered.height)
        composition.renderSize = rendered
        let fps: Double
        if let outputFPS, outputFPS > 0 {
            fps = outputFPS
        } else {
            let nominalFPS = (try? await assetTrack.load(.nominalFrameRate)) ?? 30
            fps = nominalFPS > 0 ? Double(nominalFPS) : 30
        }
        // Stated, not inherited — the composition initializer would otherwise
        // seed the clock from the incoming asset.
        composition.frameDuration = CMTime(
            value: 1, timescale: CMTimeScale(max(1, Int(fps.rounded()))))
        // The shared policy encodes the pass — deterministic bitrate and full
        // colour tags, where the export-session preset chose its own and
        // wrote none. Video sources are 8-bit, so H.264 High is the profile.
        let policy = VideoEncodePolicy(
            profile: .h264High8Bit, width: width, height: height, fps: fps)

        // Keeps the container the source used, so an mp4 blend output stays an
        // mp4 and a captured .mov stays a .mov.
        let isMP4 = sourceURL.pathExtension.lowercased() == "mp4"
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LetsLapse-graded-\(UUID().uuidString).\(isMP4 ? "mp4" : "mov")")
        do {
            try await CompositionExporter.export(
                asset: asset, composition: composition, to: outputURL,
                fileType: isMP4 ? .mp4 : .mov, policy: policy, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GradeError.exportFailed(error.localizedDescription)
        }
        return outputURL
    }

    /// The Core Image chain for a grade, anchored at D65: a movie carries no
    /// as-shot temperature tag the way a DNG does, so the white-balance control
    /// is expressed relative to the sRGB white point the frames are encoded
    /// against — the same anchor a JPEG still gets. Colour only: the grade's
    /// rotation is geometry and every caller applies it before the crop it
    /// carries, never inside the chain.
    private static func filterChain(_ grade: PhotoGrade) -> (CIImage) -> CIImage {
        PhotoGrader.filterChain(grade, asShotKelvin: PhotoGrader.neutralKelvin)
    }

    enum GradeError: LocalizedError {
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .exportFailed(let reason):
                return "Couldn't apply the colour grade: \(reason)"
            }
        }
    }
}


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
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

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
        let source = CIImage(cgImage: frame)
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
    static func composition(
        for asset: AVAsset,
        grade: PhotoGrade,
        durationSeconds: Double? = nil,
        map: GradeSourceMap = .direct
    ) -> AVMutableVideoComposition? {
        guard !grade.isIdentity else { return nil }
        guard grade.isKeyframed, let duration = durationSeconds, duration > 0 else {
            let chain = filterChain(grade.frozen(at: 0))
            return AVMutableVideoComposition(asset: asset) { request in
                // Filters like the unsharp mask and the vignette grow the extent;
                // the frame has to come back the size the writer expects.
                let graded = chain(request.sourceImage).cropped(to: request.sourceImage.extent)
                request.finish(with: graded, context: context)
            }
        }
        return AVMutableVideoComposition(asset: asset) { request in
            let position = map.position(
                outputSeconds: request.compositionTime.seconds, outputDuration: duration)
            let chain = filterChain(grade.frozen(at: position))
            let graded = chain(request.sourceImage).cropped(to: request.sourceImage.extent)
            request.finish(with: graded, context: context)
        }
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
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        // Only a keyframed grade needs the clip's length, and only that read is
        // worth the probe.
        let duration = grade.isKeyframed
            ? (try? await asset.load(.duration))?.seconds : nil
        guard let composition = composition(
            for: asset, grade: grade, durationSeconds: duration, map: map) else { return sourceURL }
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
        let width = max(2, Int(abs(orientedRect.width).rounded()) & ~1)
        let height = max(2, Int(abs(orientedRect.height).rounded()) & ~1)
        guard width > 2 || height > 2 else {
            throw GradeError.exportFailed("the clip's size couldn't be read")
        }
        composition.renderSize = CGSize(width: width, height: height)
        let nominalFPS = (try? await assetTrack.load(.nominalFrameRate)) ?? 30
        let fps = nominalFPS > 0 ? Double(nominalFPS) : 30
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
    /// against — the same anchor a JPEG still gets.
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

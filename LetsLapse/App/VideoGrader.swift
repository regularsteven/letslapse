import AVFoundation
import CoreImage
import CoreGraphics

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
/// a re-encode (ProRes lands as H.264/HEVC — `AVAssetExportPresetHighestQuality`
/// picks), which is the accepted cost of baking a grade into video, and exactly
/// what `VideoFlatten` already does for Capture Flat on non-Log hardware.
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
        let output = filterChain(grade)(source)
        guard output.extent.width > 0, output.extent.height > 0 else { return frame }
        // A failed render leaves the ungraded frame on screen rather than an
        // empty card.
        return context.createCGImage(output, from: output.extent) ?? frame
    }

    /// The composition that bakes `grade` into every frame of `asset`, or nil
    /// when the grade is a no-op — callers then export (or skip exporting)
    /// without one rather than paying for an identity pass.
    static func composition(for asset: AVAsset, grade: PhotoGrade) -> AVMutableVideoComposition? {
        guard !grade.isIdentity else { return nil }
        let chain = filterChain(grade)
        return AVMutableVideoComposition(asset: asset) { request in
            // Filters like the unsharp mask and the vignette grow the extent;
            // the frame has to come back the size the writer expects.
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
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard let composition = composition(for: asset, grade: grade) else { return sourceURL }
        guard let export = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw GradeError.exportUnavailable
        }

        // Keeps the container the source used, so an mp4 blend output stays an
        // mp4 and a captured .mov stays a .mov.
        let isMP4 = sourceURL.pathExtension.lowercased() == "mp4"
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LetsLapse-graded-\(UUID().uuidString).\(isMP4 ? "mp4" : "mov")")
        try? FileManager.default.removeItem(at: outputURL)

        export.videoComposition = composition
        export.outputURL = outputURL
        export.outputFileType = isMP4 ? .mp4 : .mov
        export.shouldOptimizeForNetworkUse = true

        let box = ExportBox(export)
        // The bake is a whole-clip re-encode; polling its fraction is what
        // keeps the processing bar moving through the grade band.
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
                            continuation.resume(throwing: GradeError.exportFailed(
                                box.session.error?.localizedDescription ?? "the grade pass didn't finish"))
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
        return outputURL
    }

    /// The Core Image chain for a grade, anchored at D65: a movie carries no
    /// as-shot temperature tag the way a DNG does, so the white-balance control
    /// is expressed relative to the sRGB white point the frames are encoded
    /// against — the same anchor a JPEG still gets.
    private static func filterChain(_ grade: PhotoGrade) -> (CIImage) -> CIImage {
        PhotoGrader.filterChain(grade, asShotKelvin: PhotoGrader.neutralKelvin)
    }

    /// `AVAssetExportSession` isn't `Sendable`; boxing it keeps the compiler
    /// honest about the hop into the completion handler.
    private final class ExportBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }

    enum GradeError: LocalizedError {
        case exportUnavailable
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .exportUnavailable:
                return "Couldn't start the colour grade pass on this video."
            case .exportFailed(let reason):
                return "Couldn't apply the colour grade: \(reason)"
            }
        }
    }
}

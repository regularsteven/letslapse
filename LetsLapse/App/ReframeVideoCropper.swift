import AVFoundation
import CoreImage
import CoreGraphics
import LetsLapseKit
import os

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

    private static let log = Logger(subsystem: "com.regularsteven.letslapse", category: "reframe")

    /// The constant output size for a reframed clip: the canvas-shaped crop at
    /// zoom 1 over `displaySize`, even-rounded for the encoder.
    static func renderSize(displaySize: CGSize, aspect: Double) -> CGSize? {
        let base = ReframeMath.baseCrop(aspect: aspect, sourceSize: displaySize)
        guard base.width > 1, base.height > 1 else { return nil }
        return CGSize(
            width: CGFloat(max(2, Int(base.width.rounded()) & ~1)),
            height: CGFloat(max(2, Int(base.height.rounded()) & ~1)))
    }

    /// `size` scaled down to the `shortEdge` class — 1080 means 1920×1080 /
    /// 1080×1920 for 16:9 material, 1080×1080 for square: the SHORTER
    /// dimension lands on the class number, whatever the orientation.
    /// Even-rounded for the encoder; nil when the size already fits.
    static func scaledDown(_ size: CGSize, shortEdge: Int) -> CGSize? {
        let short = min(size.width, size.height)
        guard short > CGFloat(shortEdge) + 1 else { return nil }
        let factor = CGFloat(shortEdge) / short
        return CGSize(
            width: CGFloat(max(2, Int((size.width * factor).rounded()) & ~1)),
            height: CGFloat(max(2, Int((size.height * factor).rounded()) & ~1)))
    }

    /// One crop rect per output frame, in display-oriented pixels of
    /// `sourceSize` — the space the keys were authored in.
    ///
    /// Move spans are measured on the COMPILED clock, not the timeline's
    /// steady-speed approximation: output frame `i` plays at `i ÷ outFps`, so
    /// inverting `frameSourceTimes` (monotone) gives the exact source→clip
    /// map, seam eases and the frame-for-frame slow-motion floor included. A
    /// "~1s" move pill means one real second of the finished clip.
    static func rects(
        track: ReframeTrack,
        aspect: Double,
        sourceSize: CGSize,
        frameSourceTimes: [Double],
        outputFPS: Int
    ) -> [CGRect] {
        let outputTime = outputTimeMap(
            frameSourceTimes: frameSourceTimes, outputFPS: outputFPS)
        return frameSourceTimes.map { time in
            track.crop(
                atSource: time, aspect: aspect, sourceSize: sourceSize,
                outputTime: outputTime)
        }
    }

    /// Source seconds → clip seconds through the compiled frame map — the
    /// render's own clock. The guided builder's scrub preview evaluates its
    /// crops through this same map, so a previewed move and a rendered move
    /// can never disagree about where they sit on the viewer's clock.
    static func outputTimeMap(
        frameSourceTimes: [Double], outputFPS: Int
    ) -> (Double) -> Double {
        let outFps = Double(max(1, outputFPS))
        let times = frameSourceTimes
        return { s in
            guard let first = times.first, let last = times.last, times.count > 1 else { return 0 }
            if s <= first { return 0 }
            if s >= last { return Double(times.count - 1) / outFps }
            var lo = 0
            var hi = times.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if times[mid] >= s { hi = mid } else { lo = mid + 1 }
            }
            let t0 = times[lo - 1]
            let t1 = times[lo]
            let fraction = t1 > t0 ? (s - t0) / (t1 - t0) : 0
            return (Double(lo - 1) + fraction) / outFps
        }
    }

    /// Writes a copy of `sourceURL` with the reframe baked in and returns the
    /// new file's URL and pixel size — in the temporary directory, under a
    /// `LetsLapse-` name, the caller owns it.
    ///
    /// `sourceSize` is the capture's display-oriented size (the keys' space);
    /// the pass rescales if the blend intermediate landed at another scale.
    /// A non-identity `grade` rides the same pass — every frame is already
    /// decoded and re-encoded here, so folding the colour chain in saves the
    /// separate grade generation.
    static func croppedCopy(
        of sourceURL: URL,
        track: ReframeTrack,
        aspect: Double,
        sourceSize: CGSize,
        frameSourceTimes: [Double],
        outputFPS: Int,
        grade: PhotoGrade = .identity,
        gradeMap: GradeSourceMap = .direct,
        exportShortEdge: Int? = nil,
        /// Forces the output size instead of deriving it from `sourceURL`.
        ///
        /// Set when this pass runs **per segment** of a mixed-resolution ramp
        /// shoot, where the segments must all land at one size for the stitch
        /// to lay them end to end. Deriving it per segment would size the 4K
        /// burst's output off the burst — which is the one thing this must not
        /// do, because the extra pixels are meant to be spent on the crop, not
        /// on the output.
        renderSizeOverride: CGSize? = nil,
        /// Pre-computed crop rects, in `sourceSize` pixels, one per frame of
        /// THIS clip — still scaled by this clip's own `scale` below.
        ///
        /// Required when the pass runs per segment, because move spans are
        /// measured on the viewer's clock and `outputTimeMap` derives that
        /// clock from the array it is given: handed one segment's slice, it
        /// restarts the clip at zero for every segment and each one replays
        /// the whole punch. The rects must therefore be computed ONCE over the
        /// whole clip's frame map and sliced, never recomputed per segment.
        rectsOverride: [CGRect]? = nil,
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

        // The bake indexes rects by rendered frame number, so it is only
        // correct while the clip really has one frame per compiled map entry.
        // The blend truncates silently when a source file holds fewer frames
        // than its schedule budgeted (a burst that under-delivered its nominal
        // rate) — and from that point every lookup lands early: the punch
        // drifts, and late keys (the release to wide) are never reached. The
        // probed per-segment densities should make the counts agree; if they
        // ever disagree again, say so where a bug report can find it.
        let clipDuration = try await asset.load(.duration).seconds
        let clipFrames = Int((clipDuration * Double(max(1, outputFPS))).rounded())
        if abs(clipFrames - frameSourceTimes.count) > 1 {
            log.error("""
                Reframe frame map desynced: the compiled schedule has \
                \(frameSourceTimes.count) frames but the blended clip has \
                \(clipFrames) — the schedule was built on a source density the \
                files didn't deliver. Framing will mis-time from the first \
                short segment onward.
                """)
        }

        // The keys live in the capture's pixel space; the blend intermediate
        // is normally the same scale, but a mismatch just rescales the rects.
        let scale = Double(clipSize.width) / Double(sourceSize.width)
        let scaledSource = CGSize(
            width: sourceSize.width * CGFloat(scale), height: sourceSize.height * CGFloat(scale))
        guard let fullSize = renderSize(displaySize: scaledSource, aspect: aspect) else {
            throw ReframeCropError.exportFailed("the render size collapsed")
        }
        // An export cap resamples ONCE, straight from the kept pixels to the
        // target — a 2× punch on a 4K source lands pixel-sharp at 1080.
        //
        // `scale` above is what makes the override honest across a
        // mixed-resolution shoot: it is computed from the clip this call was
        // handed, so a 4K burst gets 2.0 and a 1080p base gets 1.0, the keys
        // land in each segment's own pixel space, and the crop → Lanczos →
        // renderSize chain below still resamples exactly once. The burst's
        // extra pixels are therefore spent on the crop and nowhere else.
        let renderSize = renderSizeOverride
            ?? exportShortEdge.flatMap { scaledDown(fullSize, shortEdge: $0) }
            ?? fullSize

        let frameRects = (rectsOverride ?? rects(
            track: track, aspect: aspect, sourceSize: sourceSize,
            frameSourceTimes: frameSourceTimes, outputFPS: outputFPS)
        ).map { $0.applying(CGAffineTransform(scaleX: scale, y: scale)) }

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
            let framed = scaled.cropped(to: CGRect(origin: .zero, size: renderSize))
            // Filters like the unsharp mask and the vignette grow the extent;
            // the frame has to come back the size the writer expects. Grading
            // after the scale keeps the vignette centred on the final frame.
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

        // The shared policy encodes the pass — deterministic bitrate and full
        // colour tags, where the export-session preset chose its own and
        // wrote none.
        let policy = VideoEncodePolicy(
            profile: .h264High8Bit,
            width: Int(renderSize.width), height: Int(renderSize.height), fps: outFps)
        let isMP4 = sourceURL.pathExtension.lowercased() == "mp4"
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LetsLapse-reframed-\(UUID().uuidString).\(isMP4 ? "mp4" : "mov")")
        do {
            try await CompositionExporter.export(
                asset: asset, composition: composition, to: outputURL,
                fileType: isMP4 ? .mp4 : .mov, policy: policy, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ReframeCropError.exportFailed(error.localizedDescription)
        }
        return (outputURL, renderSize)
    }

    enum ReframeCropError: LocalizedError {
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .exportFailed(let reason):
                return "Couldn't bake the punch-in reframe: \(reason)"
            }
        }
    }
}

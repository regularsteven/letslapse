import CoreGraphics
import CoreImage
import LetsLapseKit
import CoreVideo
import Foundation

/// The scene-aware compositing stage: base frame, overlay raster, and —
/// when a placement is chosen — the semantic mask that lets the photographed
/// scene occlude the overlay. Pure Core Image, `CIImage` in and out, so the
/// same call slots after the preview grade today and before an export encode
/// later, and a Metal kernel could replace the internals without the API
/// moving.
///
/// Knows nothing about text: the overlay arrives as pixels with alpha.
enum SceneAwareCompositor {

    /// Where a mask's pixels come from. Two kinds, and the difference runs
    /// all the way through: a **grid** is the segmentation model's (or a
    /// hand-supplied file's) sampled probabilities, which want thresholding,
    /// morphology, feathering and edge refinement before they can be trusted
    /// as a boundary — and which describe the SOURCE frame, so they turn with
    /// it. A **shape** is arithmetic: it resolves exactly at any size, needs
    /// none of that post-processing, and is authored on the levelled picture
    /// so it is already in output space.
    enum MaskSource {
        case grid(SceneMask)
        case shape(MaskShape, inverted: Bool)
    }

    /// The occlusion half of a composite: the mask of the region whose
    /// pixels are restored OVER the overlay. Sky placement restores non-sky;
    /// land placement restores sky. The caller picks the region; this stage
    /// just applies it.
    struct Occlusion {
        var mask: MaskSource
        var settings: SegmentationSettings
        /// The rotation the frame being composited has been levelled by; a
        /// grid mask is levelled to match on its way to frame space (a shape
        /// is already there). 0 = the frame is the source.
        var rotationDegrees: Double = 0
    }

    /// Every mask a composite might need, resolved before the loop starts.
    /// The segmentation model produces one analysis read two ways (sky and
    /// its complement); custom masks are files, keyed by their own id.
    ///
    /// A value type so it can cross into a detached render task alongside
    /// the overlays it serves.
    struct MaskSet: Sendable {
        var sky: SceneMask?
        var custom: [UUID: SceneMask] = [:]
        /// The project's drawn masks, by id. Parameters rather than pixels:
        /// a shape resolves to a gradient at whatever size the frame is, so
        /// unlike the other two there is nothing to decode or infer up front.
        var shapes: [UUID: MaskShape] = [:]

        static let empty = MaskSet()

        var isEmpty: Bool { sky == nil && custom.isEmpty && shapes.isEmpty }

        /// The mask of the region that composites back OVER a layer placed
        /// here — the occlusion half. Sky placement restores non-sky; land
        /// restores sky; a custom placement restores everything outside the
        /// named region. nil = nothing occludes (no placement, or the mask
        /// this placement names is missing).
        func restorationMask(for placement: OverlayPlacement) -> MaskSource? {
            switch placement {
            case .none:
                return nil
            case .sky:
                return sky.map { .grid($0.inverted()) }
            case .land:
                return sky.map(MaskSource.grid)
            case .custom(let id):
                return custom[id].map { .grid($0.inverted()) }
            case .customInverted(let id):
                return custom[id].map(MaskSource.grid)
            case .shape(let id):
                // What restores over a layer placed inside a shape is
                // everything outside it — the complement, same rule as the
                // grids above.
                return shapes[id].map { .shape($0, inverted: true) }
            case .shapeInverted(let id):
                return shapes[id].map { .shape($0, inverted: false) }
            }
        }

        /// The mask of the region ITSELF, for the debug tint — "what the
        /// analysis calls this region", not what occludes it.
        func regionMask(for placement: OverlayPlacement) -> MaskSource? {
            switch placement {
            case .none: return nil
            case .sky: return sky.map(MaskSource.grid)
            case .land: return sky.map { .grid($0.inverted()) }
            case .custom(let id): return custom[id].map(MaskSource.grid)
            case .customInverted(let id): return custom[id].map { .grid($0.inverted()) }
            case .shape(let id): return shapes[id].map { .shape($0, inverted: false) }
            case .shapeInverted(let id): return shapes[id].map { .shape($0, inverted: true) }
            }
        }
    }

    enum DebugMode {
        case none
        /// The post-processed restoration mask, tinted over the result.
        case mask
        /// The raw pre-threshold confidence grid as tint alpha — a sequence
        /// mask's vote fractions become visible.
        case confidence
    }

    /// One shared context: contexts own GPU caches, and per-call contexts
    /// rebuild them per call.
    ///
    /// A float working format because the guided filter carries signed,
    /// unbounded coefficients between stages — in an 8-bit intermediate `a`
    /// clips and `b` loses its sign, and the refinement quietly becomes a
    /// no-op.
    private static let context = CIContext(options: [
        .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false,
    ])

    // MARK: - Edge-aware refinement

    /// The guided filter's two stages (He et al.). Written as Core Image
    /// kernels rather than a Metal `.ci.metal` because that would need
    /// `-fcikernel` build flags this project does not otherwise carry; if a
    /// future OS drops the source-compiled path these return nil and
    /// refinement is skipped, which degrades to exactly today's behaviour.
    private static let coefficientKernel = CIColorKernel(source: """
    kernel vec4 gfCoeffs(__sample meanI, __sample meanP, __sample corrI, __sample corrIP, float eps) {
        float varI = corrI.r - meanI.r * meanI.r;
        float cov  = corrIP.r - meanI.r * meanP.r;
        float a = cov / (varI + eps);
        return vec4(a, meanP.r - a * meanI.r, 0.0, 1.0);
    }
    """)

    private static let applyKernel = CIColorKernel(source: """
    kernel vec4 gfApply(__sample ab, __sample guide) {
        float q = clamp(ab.r * guide.r + ab.g, 0.0, 1.0);
        return vec4(q, q, q, 1.0);
    }
    """)

    /// Radius as a fraction of the frame's long edge. Proportional, not
    /// absolute, so the 1100 px scrub render and the full-resolution export
    /// refine identically — the same reason overlay size is a fraction of
    /// the long edge.
    private static let refineRadiusFraction: Double = 0.032
    private static let refineEpsilon: Double = 0.001

    /// Pulls a mask's boundary onto the edges the PHOTOGRAPH actually has.
    ///
    /// The segmentation grid is 448² and its boundary is a smoothed,
    /// rounded-off version of the skyline — measured 2026-09-01, the mask's
    /// edge sat a mean 12.6 px from the nearest real image edge, and this
    /// brings it to 4.9. The model knows WHERE the sky is; the photograph
    /// knows exactly where it ENDS, and this is what marries the two. It is
    /// what Google's Sky Optimization ships for the same reason.
    ///
    /// Returns the input untouched when the kernels are unavailable.
    private static func edgeRefined(_ mask: CIImage, guide: CIImage) -> CIImage {
        guard let coefficientKernel, let applyKernel else { return mask }
        let extent = mask.extent
        guard extent.width >= 8, extent.height >= 8 else { return mask }
        let radius = max(extent.width, extent.height) * refineRadiusFraction

        let luminance = grayscale(guide.cropped(to: extent))
        let meanI = boxBlur(luminance, radius)
        let meanP = boxBlur(mask, radius)
        let corrI = boxBlur(multiply(luminance, luminance), radius)
        let corrIP = boxBlur(multiply(luminance, mask), radius)
        guard let coefficients = coefficientKernel.apply(
                extent: extent, arguments: [meanI, meanP, corrI, corrIP, refineEpsilon]),
              let refined = applyKernel.apply(
                extent: extent, arguments: [boxBlur(coefficients, radius), luminance])
        else { return mask }
        return refined.cropped(to: extent)
    }

    private static func boxBlur(_ image: CIImage, _ radius: Double) -> CIImage {
        guard let filter = CIFilter(name: "CIBoxBlur") else { return image }
        // Clamped for the same reason the feather is: sampling transparent
        // black past the extent drags the frame border toward zero.
        filter.setValue(image.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        return filter.outputImage?.cropped(to: image.extent) ?? image
    }

    private static func multiply(_ a: CIImage, _ b: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIMultiplyCompositing") else { return a }
        filter.setValue(a, forKey: kCIInputImageKey)
        filter.setValue(b, forKey: kCIInputBackgroundImageKey)
        return filter.outputImage ?? a
    }

    /// Rec.709 luma into every channel — the guided filter works on one
    /// channel, and a colour guide would need the 3×3 covariance variant.
    private static func grayscale(_ image: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIColorMatrix") else { return image }
        let luma = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(luma, forKey: "inputRVector")
        filter.setValue(luma, forKey: "inputGVector")
        filter.setValue(luma, forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        return filter.outputImage ?? image
    }

    static func composite(
        base: CIImage, overlay: CIImage?, occlusion: Occlusion?, debug: DebugMode = .none
    ) -> CIImage {
        var result = base
        if let overlay {
            let overlaid = overlay.composited(over: base).cropped(to: base.extent)
            if let occlusion,
               let restore = restorationMask(occlusion, extent: base.extent, guide: base) {
                // White restores the scene over the overlay; feathered grays
                // restore it partially — which is where the subtlety lives.
                result = blend(input: base, background: overlaid, mask: restore)
            } else {
                result = overlaid
            }
        }
        switch debug {
        case .none:
            return result
        case .mask:
            // The debug tint reads as "what the analysis calls this region",
            // so it skips the edge-bias erosion — that dial biases whichever
            // region RESTORES, and baking it into the tint would show a
            // different boundary than the segmentation actually produced.
            guard let occlusion,
                  let restore = restorationMask(
                    occlusion, extent: base.extent, guide: base, applyEdgeBias: false)
            else { return result }
            return tinted(result, mask: restore)
        case .confidence:
            // Only a grid has confidence to show: a shape's coverage is
            // exactly what the mask tint already draws.
            guard let occlusion else { return result }
            guard case .grid(let sceneMask) = occlusion.mask,
                  let raw = sceneMask.ciImage()?.transformed(
                    by: scaleTransform(from: sceneMask, to: base.extent))
            else { return composite(base: base, overlay: nil, occlusion: occlusion, debug: .mask) }
            let levelled = FrameRotation.rotated(
                raw.cropped(to: base.extent), degrees: occlusion.rotationDegrees)
            return tinted(result, mask: levelled)
        }
    }

    /// Renders a composite back to the `CGImage` the preview displays.
    static func renderCGImage(_ image: CIImage, colorSpace: CGColorSpace?) -> CGImage? {
        context.createCGImage(
            image, from: image.extent, format: .RGBA8,
            colorSpace: colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3))
    }

    // MARK: - Mask post-processing

    /// Threshold → open/close → conservative erosion → feather → clamp, all
    /// at grid resolution (cheap enough to run live while the dials move —
    /// the cache stores raw model grids only), then scaled to the frame.
    private static func restorationMask(
        _ occlusion: Occlusion, extent: CGRect, guide: CIImage?,
        applyEdgeBias: Bool = true
    ) -> CIImage? {
        // A drawn shape short-circuits the whole chain below. There is no
        // sampled boundary to clean up, no confidence to threshold and no
        // 448-grid coarseness to refine against the photograph — the
        // gradient IS the answer, at whatever size the frame happens to be.
        if case .shape(let shape, let inverted) = occlusion.mask {
            return MaskShapeRenderer.maskImage(shape, extent: extent, inverted: inverted)
        }
        guard case .grid(let sceneMask) = occlusion.mask,
              let grid = sceneMask.ciImage() else { return nil }
        let settings = occlusion.settings
        var mask = grid

        if let threshold = CIFilter(name: "CIColorThreshold") {
            threshold.setValue(mask, forKey: kCIInputImageKey)
            threshold.setValue(settings.threshold, forKey: "inputThreshold")
            mask = threshold.outputImage ?? mask
        }
        // Open (despeckle) then close (fill pinholes), fixed 2 px at grid
        // scale for the spike.
        mask = morphology(mask, filter: "CIMorphologyMinimum", radius: 2)
        mask = morphology(mask, filter: "CIMorphologyMaximum", radius: 2)
        mask = morphology(mask, filter: "CIMorphologyMaximum", radius: 2)
        mask = morphology(mask, filter: "CIMorphologyMinimum", radius: 2)
        // Bias the boundary. Positive erodes the RESTORING region — less
        // occlusion, type sits further over the scene. Negative dilates it —
        // more occlusion, type tucks further behind, which is what a spiky
        // skyline usually wants.
        if applyEdgeBias, abs(settings.edgeBias) > 0.01 {
            mask = morphology(
                mask,
                filter: settings.edgeBias > 0 ? "CIMorphologyMinimum" : "CIMorphologyMaximum",
                radius: abs(settings.edgeBias))
        }
        if settings.featherRadius > 0.01, let blur = CIFilter(name: "CIGaussianBlur") {
            // The clamp is load-bearing: without it the blur samples
            // transparent beyond the extent and the mask fades at the frame
            // borders — edge sky would leak over edge text.
            blur.setValue(mask.clampedToExtent(), forKey: kCIInputImageKey)
            blur.setValue(settings.featherRadius, forKey: kCIInputRadiusKey)
            mask = (blur.outputImage ?? mask).cropped(to: grid.extent)
        }
        if let clamp = CIFilter(name: "CIColorClamp") {
            clamp.setValue(mask, forKey: kCIInputImageKey)
            mask = clamp.outputImage ?? mask
        }
        // Scaled to the frame, then levelled the way the frame was — the
        // grid describes the source, and the frame under it has turned.
        let scaled = FrameRotation.rotated(
            mask.transformed(by: scaleTransform(from: sceneMask, to: extent))
                .cropped(to: extent),
            degrees: occlusion.rotationDegrees)
        // The refinement goes last, in FRAME space: its whole purpose is to
        // use boundary detail the 448 grid never carried, which only exists
        // at full resolution.
        guard let guide else { return scaled }
        return edgeRefined(scaled, guide: guide)
    }

    private static func scaleTransform(from mask: SceneMask, to extent: CGRect) -> CGAffineTransform {
        // MaskGeometry.stretch: the grid covers the frame's unit square, so
        // the map to frame space is a pure per-axis scale.
        CGAffineTransform(
            scaleX: extent.width / CGFloat(mask.width),
            y: extent.height / CGFloat(mask.height))
    }

    private static func morphology(_ image: CIImage, filter name: String, radius: Double) -> CIImage {
        guard let filter = CIFilter(name: name) else { return image }
        // Clamped for the same reason the feather is: a minimum filter
        // sampling transparent black past the extent erodes the whole frame
        // border to zero, and border sky then never restores over border
        // text.
        filter.setValue(image.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        return filter.outputImage?.cropped(to: image.extent) ?? image
    }

    private static func blend(input: CIImage, background: CIImage, mask: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIBlendWithMask") else { return background }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(background, forKey: kCIInputBackgroundImageKey)
        filter.setValue(mask, forKey: kCIInputMaskImageKey)
        return filter.outputImage?.cropped(to: background.extent) ?? background
    }

    // MARK: - Preview convenience

    /// The whole preview composite for one rendered frame: every overlay at
    /// its animation phase, scene occlusion where a placement is chosen, and
    /// the debug tint when the mask is being inspected. Returns `base`
    /// untouched (no re-encode) when there is nothing to draw.
    ///
    /// Callable from any queue: the mask lookup is the cache-only path, so
    /// this can never trigger inference — a drag or a scrub composites with
    /// whatever mask is already there.
    static func compositedPreview(
        base: CGImage,
        overlays: [SceneOverlay],
        maskGrades: [MaskGrade] = [],
        suppressing suppressed: Set<UUID>,
        position: Double,
        masks: MaskSet,
        settings: SegmentationSettings,
        debugRegion: OverlayPlacement?,
        /// The project's fine rotation, which `base` has ALREADY been
        /// levelled by (`PhotoGrader.render` does it). The masks are source
        /// grids, so they are levelled here to stay registered with it.
        rotationDegrees: Double = 0
    ) -> CGImage {
        guard let image = composited(
            base: CIImage(cgImage: base),
            frameSize: CGSize(width: base.width, height: base.height),
            overlays: overlays, maskGrades: maskGrades,
            suppressing: suppressed, position: position,
            masks: masks, settings: settings, debugRegion: debugRegion,
            editorPreview: true, rotationDegrees: rotationDegrees)
        else { return base }
        return renderCGImage(image, colorSpace: base.colorSpace) ?? base
    }

    /// The one compositing core — preview and export both come here, which
    /// is what makes "what the editor shows is what the export bakes" true
    /// for overlays, and now for masked grades too.
    ///
    /// **Masked grades run display-referred, and that is a decision.** The
    /// whole-picture grade is the tone engine's: linear decode, Metal kernel,
    /// display-referred out. A masked grade then runs `PhotoGrader.adjust` —
    /// the Core Image chain — over that finished picture. It is the coarser
    /// of the two paths, and it cannot recover a highlight the whole-picture
    /// grade has already clipped.
    ///
    /// It is used anyway because it is the only stage BOTH renderers share.
    /// A stills export blends many source frames into one output frame and
    /// hands it here; there is no seam earlier than this where a mask drawn
    /// on the OUTPUT frame could be applied at all. Running the engine a
    /// second time would give a better preview and a preview that no longer
    /// matched the export, which is the one thing this file exists to
    /// prevent. If masked grades ever want linear light, the engine needs a
    /// masked-recipe pass and both callers move to it together. Returns nil when there is nothing to draw (no overlays
    /// at this position, no debug tint), so callers can skip the re-encode.
    /// `editorPreview` turns on the two affordances that describe how the
    /// EDITOR draws rather than what the piece is: onion skin, and ghosting
    /// a hidden layer that has onion skin on. An export passes false and
    /// gets exactly the layers the viewer will see.
    static func composited(
        base: CIImage,
        frameSize: CGSize,
        overlays: [SceneOverlay],
        /// The grades applied inside a mask, in list order. They go on FIRST,
        /// before any text — they are part of the picture, and type placed in
        /// a graded region has to sit on the graded pixels.
        maskGrades: [MaskGrade] = [],
        /// The layers the EDITOR is carrying itself — a dragged layer and
        /// the followers travelling with it, drawn by SwiftUI proxies for the
        /// length of the gesture so they move at pointer rate. Empty for an
        /// export, which has nothing to drag.
        suppressing suppressed: Set<UUID>,
        position: Double,
        masks: MaskSet,
        settings: SegmentationSettings,
        debugRegion: OverlayPlacement?,
        editorPreview: Bool,
        /// The rotation `base` has already been levelled by. Overlays live in
        /// the levelled frame and need nothing; the masks are grids over the
        /// SOURCE frame and are levelled the same way so sky stays over sky.
        rotationDegrees: Double = 0,
        /// True to draw every layer at its resting layout regardless of
        /// `position` — the whole-shoot still, where a layer that has
        /// already exited is still part of the piece.
        settled: Bool = false
    ) -> CIImage? {
        var image = base
        var drewAnything = false
        for grade in maskGrades where grade.isActive {
            guard let source = masks.regionMask(for: grade.placement) else { continue }
            let occlusion = Occlusion(
                mask: source, settings: settings, rotationDegrees: rotationDegrees)
            // The guide is the picture, so a grade applied inside Sky stops at
            // the roofline the photograph actually has rather than at the 448
            // grid's rounded version of it — the same refinement text
            // occlusion gets, and for the same reason: a visible boundary.
            guard let selection = restorationMask(occlusion, extent: image.extent, guide: image)
            else { continue }
            let adjusted = PhotoGrader
                .adjust(image, grade.adjustments, asShotKelvin: PhotoGrader.neutralKelvin)
                .cropped(to: image.extent)
            image = blend(input: adjusted, background: image, mask: selection)
            drewAnything = true
        }
        // Layers are stored front-to-back (index 0 is frontmost), and each
        // composite paints OVER what came before — so the array is walked in
        // reverse and row 1 of the Text tab lands on top.
        for overlay in overlays.reversed() where !suppressed.contains(overlay.id) {
            let onion = editorPreview && overlay.onionSkin
            guard overlay.isVisible || onion else { continue }
            guard let spec = TextOverlayRasterizer.spec(
                    for: overlay, frameSize: frameSize, position: position,
                    ignoringAnimation: onion || settled),
                  let raster = TextOverlayRasterizer.render(spec) else { continue }
            var layer = CIImage(cgImage: raster)
            if !overlay.isVisible {
                // A hidden layer shown only by its onion skin reads as
                // scaffolding, not as the piece.
                layer = faded(layer, alpha: 0.34)
            }
            let occlusion = masks.restorationMask(for: overlay.placement)
                .map { Occlusion(mask: $0, settings: settings, rotationDegrees: rotationDegrees) }
            image = composite(base: image, overlay: layer, occlusion: occlusion)
            drewAnything = true
        }
        if let debugRegion, let mask = masks.regionMask(for: debugRegion) {
            // The debug tint shows what the analysis calls this region, after
            // the same post-processing the occlusion uses.
            image = composite(
                base: image, overlay: nil,
                occlusion: Occlusion(mask: mask, settings: settings, rotationDegrees: rotationDegrees),
                debug: .mask)
            drewAnything = true
        }
        return drewAnything ? image : nil
    }

    /// Scales a layer's alpha without touching its color — premultiplied
    /// input, so the RGB channels scale with it.
    private static func faded(_ image: CIImage, alpha: Double) -> CIImage {
        guard let filter = CIFilter(name: "CIColorMatrix") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha)), forKey: "inputAVector")
        return filter.outputImage ?? image
    }

    // MARK: - Export baking

    /// Bakes overlays onto one finished export frame — the closure body
    /// behind `ImageStacker`'s `overlayComposite` hook. The buffer arrives
    /// display-referred and color-tagged; the composite renders into a fresh
    /// buffer from the writer's own pool (never in place — Core Image's
    /// behavior when source and destination share memory is undefined).
    /// Returns nil when this frame needs nothing, so the original appends
    /// untouched at zero cost.
    static func bakeExportFrame(
        _ buffer: CVPixelBuffer,
        position: Double,
        pool: CVPixelBufferPool,
        overlays: [SceneOverlay],
        maskGrades: [MaskGrade] = [],
        masks: MaskSet,
        settings: SegmentationSettings,
        /// The project's fine rotation, levelled into the frame here — the
        /// stacker hands over the graded, colour-tagged output frame and this
        /// is the only place a stills blend turns it.
        rotationDegrees: Double = 0
    ) throws -> CVPixelBuffer? {
        // Self-draining: a frame's worth of Core Image temporaries is tens of
        // megabytes, and this is called from a render loop whose caller we
        // don't own (the Kit hook is public). The caller pools too; both is
        // cheap and neither alone is something to rely on.
        try autoreleasepool {
            try bakeExportFrameBody(
                buffer, position: position, pool: pool,
                overlays: overlays, maskGrades: maskGrades, masks: masks,
                settings: settings, rotationDegrees: rotationDegrees)
        }
    }

    private static func bakeExportFrameBody(
        _ buffer: CVPixelBuffer,
        position: Double,
        pool: CVPixelBufferPool,
        overlays: [SceneOverlay],
        maskGrades: [MaskGrade],
        masks: MaskSet,
        settings: SegmentationSettings,
        rotationDegrees: Double
    ) throws -> CVPixelBuffer? {
        let levelling = FrameRotation.isActive(rotationDegrees)
        let base = FrameRotation.rotated(CIImage(cvPixelBuffer: buffer), degrees: rotationDegrees)
        let composited = composited(
            base: base, frameSize: base.extent.size,
            overlays: overlays, maskGrades: maskGrades,
            suppressing: [], position: position,
            masks: masks, settings: settings, debugRegion: nil,
            editorPreview: false, rotationDegrees: rotationDegrees)
        // Nothing drawn and nothing levelled: the frame appends untouched.
        guard composited != nil || levelling else { return nil }
        let composite = composited ?? base
        var scratch: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &scratch)
        guard status == kCVReturnSuccess, let scratch else {
            throw NSError(
                domain: "SceneAwareCompositor", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "overlay buffer allocation failed (\(status))"])
        }
        // Round-trip in the buffer's own color identity: the writer tagged
        // it before this call, so read and write agree with the encoder.
        let space = CVBufferCopyAttachments(buffer, .shouldPropagate)
            .flatMap { CVImageBufferCreateColorSpaceFromAttachments($0)?.takeRetainedValue() }
            ?? CGColorSpace(name: CGColorSpace.displayP3)!
        context.render(composite, to: scratch, bounds: base.extent, colorSpace: space)
        return scratch
    }

    /// Bakes overlays into a single finished still (the long-exposure PNG).
    /// A stack folds the whole shoot into one frame, so every overlay
    /// renders at its resolved final state — every reveal complete, and no
    /// exit taken, since the still holds the whole shoot at once.
    /// Returns nil when there is nothing to draw.
    static func bakeStill(
        _ image: CGImage,
        overlays: [SceneOverlay],
        maskGrades: [MaskGrade] = [],
        masks: MaskSet,
        settings: SegmentationSettings,
        rotationDegrees: Double = 0
    ) -> CGImage? {
        let levelling = FrameRotation.isActive(rotationDegrees)
        let base = FrameRotation.rotated(CIImage(cgImage: image), degrees: rotationDegrees)
        let composited = composited(
            base: base,
            frameSize: CGSize(width: image.width, height: image.height),
            overlays: overlays, maskGrades: maskGrades,
            suppressing: [], position: 1,
            masks: masks, settings: settings, debugRegion: nil,
            editorPreview: false, rotationDegrees: rotationDegrees, settled: true)
        guard composited != nil || levelling else { return nil }
        return renderCGImage(composited ?? base, colorSpace: image.colorSpace)
    }

    /// The debug overlay: magenta through the mask, over the composite —
    /// the mask and its effect visible at once.
    private static func tinted(_ image: CIImage, mask: CIImage) -> CIImage {
        let tint = CIImage(color: CIColor(red: 0.85, green: 0, blue: 0.85, alpha: 0.55))
            .cropped(to: image.extent)
        let clear = CIImage(color: .clear).cropped(to: image.extent)
        let masked = blend(input: tint, background: clear, mask: mask)
        return masked.composited(over: image).cropped(to: image.extent)
    }
}

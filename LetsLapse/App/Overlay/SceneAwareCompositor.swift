import CoreGraphics
import CoreImage
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

    /// The occlusion half of a composite: the mask of the region whose
    /// pixels are restored OVER the overlay. Sky placement restores non-sky;
    /// land placement restores sky. The caller picks the region; this stage
    /// just applies it.
    struct Occlusion {
        var mask: SceneMask
        var settings: SegmentationSettings
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
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func composite(
        base: CIImage, overlay: CIImage?, occlusion: Occlusion?, debug: DebugMode = .none
    ) -> CIImage {
        var result = base
        if let overlay {
            let overlaid = overlay.composited(over: base).cropped(to: base.extent)
            if let occlusion, let restore = restorationMask(occlusion, extent: base.extent) {
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
            guard let occlusion,
                  let restore = restorationMask(occlusion, extent: base.extent)
            else { return result }
            return tinted(result, mask: restore)
        case .confidence:
            guard let occlusion,
                  let raw = occlusion.mask.ciImage()?.transformed(
                    by: scaleTransform(from: occlusion.mask, to: base.extent))
            else { return result }
            return tinted(result, mask: raw.cropped(to: base.extent))
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
    private static func restorationMask(_ occlusion: Occlusion, extent: CGRect) -> CIImage? {
        guard let grid = occlusion.mask.ciImage() else { return nil }
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
        // Conservative edges: erode the RESTORING region, so bias always
        // means less occlusion.
        if settings.edgeBias > 0.01 {
            mask = morphology(mask, filter: "CIMorphologyMinimum", radius: settings.edgeBias)
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
        return mask
            .transformed(by: scaleTransform(from: occlusion.mask, to: extent))
            .cropped(to: extent)
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
        filter.setValue(image, forKey: kCIInputImageKey)
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
        suppressing suppressed: UUID?,
        position: Double,
        skyMaskKey: String?,
        settings: SegmentationSettings,
        showMask: Bool
    ) -> CGImage {
        let frameSize = CGSize(width: base.width, height: base.height)
        let skyMask = skyMaskKey.flatMap {
            SceneMaskService.shared.cachedSkyMask(forKey: $0)
        }
        var image = CIImage(cgImage: base)
        var drewAnything = false
        for overlay in overlays where overlay.id != suppressed {
            guard let spec = TextOverlayRasterizer.spec(
                    for: overlay, frameSize: frameSize, position: position),
                  let raster = TextOverlayRasterizer.render(spec) else { continue }
            var occlusion: Occlusion?
            if let skyMask {
                switch overlay.placement {
                case .none:
                    break
                case .sky:
                    // Text in the sky: everything that is not sky restores
                    // over it.
                    occlusion = Occlusion(mask: skyMask.inverted(), settings: settings)
                case .land:
                    occlusion = Occlusion(mask: skyMask, settings: settings)
                }
            }
            image = composite(
                base: image, overlay: CIImage(cgImage: raster),
                occlusion: occlusion)
            drewAnything = true
        }
        if showMask, let skyMask {
            // The debug tint shows what the model calls sky, after the same
            // post-processing the occlusion uses.
            image = composite(
                base: image, overlay: nil,
                occlusion: Occlusion(mask: skyMask, settings: settings),
                debug: .mask)
            drewAnything = true
        }
        guard drewAnything else { return base }
        return renderCGImage(image, colorSpace: base.colorSpace) ?? base
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

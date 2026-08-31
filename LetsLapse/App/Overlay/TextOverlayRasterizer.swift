import CoreGraphics
import CoreImage
import CoreText
import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Rasterizes a text overlay into a frame-sized transparent image, one glyph
/// at a time so each character can carry its own animation state.
///
/// A pure function of its `Spec`: the raster of a finished animation (every
/// phase 1) is byte-identical to the raster of no animation at all, which is
/// the structural half of "the final layout is always the end state". Cached,
/// because a playback sweep asks for a raster per ladder step.
///
/// Spike scope on purpose: one system font, white, a single soft shadow for
/// contrast. No typography surface.
enum TextOverlayRasterizer {

    struct Spec: Equatable {
        var string: String
        /// Resolved against the ACTUAL render's long edge (2000 settled,
        /// 1100 scrub, full-res export) so geometry is scale-invariant.
        var fontSizePixels: CGFloat
        /// Anchor centre in pixels, top-left origin, in `frameSize` space.
        var center: CGPoint
        var frameSize: CGSize
        /// Raw 0…1 progress per grapheme cluster; empty = settled (all 1).
        var phases: [Double]
        /// nil = fade only; otherwise characters arrive from this direction.
        var direction: OverlayAnimation.Direction?

        /// Deterministic cache identity. Phases arrive quantized (the scrub
        /// ladder), so rounding here only guards float noise.
        var cacheKey: String {
            let phaseKey = phases.map { String(format: "%.3f", $0) }.joined(separator: ",")
            return [
                string, String(format: "%.1f", fontSizePixels),
                String(format: "%.1f,%.1f", center.x, center.y),
                String(format: "%.0fx%.0f", frameSize.width, frameSize.height),
                direction?.rawValue ?? "-", phaseKey,
            ].joined(separator: "|")
        }
    }

    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 24
        return cache
    }()

    /// How far a sliding character travels, in font-size units.
    private static let slideTravel: CGFloat = 0.6

    static func render(_ spec: Spec) -> CGImage? {
        guard !spec.string.isEmpty,
              spec.frameSize.width >= 1, spec.frameSize.height >= 1,
              spec.fontSizePixels >= 1 else { return nil }
        let key = spec.cacheKey as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = draw(spec) else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    /// The raster request for an overlay at one moment of the timeline, in
    /// one render's pixel space. nil = nothing to draw (empty text, or the
    /// reveal hasn't started).
    static func spec(
        for overlay: SceneOverlay, frameSize: CGSize, position: Double
    ) -> Spec? {
        guard case .text(let content) = overlay.content,
              !content.string.isEmpty else { return nil }
        var phases: [Double] = []
        var direction: OverlayAnimation.Direction?
        if let animation = overlay.animation {
            phases = animation.phases(at: position, characterCount: content.string.count)
            direction = animation.style == .characterSlide ? animation.direction : nil
            // Before its reveal the overlay simply isn't there.
            if phases.allSatisfy({ $0 <= 0 }) { return nil }
            // At or past the end the raster must equal the no-animation
            // raster — same cache entry, byte-identical pixels.
            if phases.allSatisfy({ $0 >= 1 }) {
                phases = []
                direction = nil
            }
        }
        let longEdge = max(frameSize.width, frameSize.height)
        return Spec(
            string: content.string,
            fontSizePixels: overlay.size * longEdge,
            center: CGPoint(
                x: overlay.centerX * frameSize.width,
                y: overlay.centerY * frameSize.height),
            frameSize: frameSize,
            phases: phases,
            direction: direction)
    }

    private static func draw(_ spec: Spec) -> CGImage? {
        let width = Int(spec.frameSize.width.rounded())
        let height = Int(spec.frameSize.height.rounded())
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // Layout once. CoreText shapes the whole line (ligatures, emoji,
        // fallback fonts); animation is applied per glyph at draw time.
        #if canImport(AppKit)
        let font = NSFont.systemFont(ofSize: spec.fontSizePixels, weight: .bold) as CTFont
        #else
        let font = UIFont.systemFont(ofSize: spec.fontSizePixels, weight: .bold) as CTFont
        #endif
        // Only the font matters to the layout; color is set per glyph at draw
        // time, because CTFontDrawGlyphs paints with the context's fill.
        let attributed = NSAttributedString(string: spec.string, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        // The context is CG-native (bottom-left origin): the anchor's screen
        // y flips once here, and every animation offset flips its own y when
        // it is applied — one flip per axis, in one place each.
        let cgCenterY = spec.frameSize.height - spec.center.y
        let lineOrigin = CGPoint(
            x: spec.center.x - lineWidth / 2,
            y: cgCenterY - (ascent - descent) / 2)

        // UTF-16 offset → grapheme-cluster ordinal, so a ligature or an emoji
        // animates as one unit — the same unit `String.count` counts.
        var clusterOfUTF16 = [Int](repeating: 0, count: spec.string.utf16.count + 1)
        var ordinal = 0
        var utf16Offset = 0
        for character in spec.string {
            let span = character.utf16.count
            for i in 0..<span { clusterOfUTF16[utf16Offset + i] = ordinal }
            utf16Offset += span
            ordinal += 1
        }
        if utf16Offset < clusterOfUTF16.count { clusterOfUTF16[utf16Offset] = max(0, ordinal - 1) }
        let clusterCount = ordinal

        func phase(forCluster cluster: Int) -> Double {
            guard !spec.phases.isEmpty else { return 1 }
            guard cluster < spec.phases.count else { return spec.phases.last ?? 1 }
            return ReframeTrack.ease(spec.phases[cluster])
        }

        // Screen-space arrival offset for an eased phase, flipped to CG space
        // at the point of use.
        func slideOffset(eased: Double) -> CGSize {
            guard let direction = spec.direction else { return .zero }
            let travel = slideTravel * spec.fontSizePixels * CGFloat(1 - eased)
            switch direction {
            case .top: return CGSize(width: 0, height: -travel)
            case .bottom: return CGSize(width: 0, height: travel)
            case .left: return CGSize(width: -travel, height: 0)
            case .right: return CGSize(width: travel, height: 0)
            }
        }

        let shadowBlur = spec.fontSizePixels * 0.06
        let runs = (CTLineGetGlyphRuns(line) as? [CTRun]) ?? []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
            // The run's own font, not the requested one — emoji and fallback
            // glyphs arrive in a different face and must be drawn with it.
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = (attributes[kCTFontAttributeName as String] as! CTFont)

            for i in 0..<count {
                let utf16Index = min(max(indices[i], 0), clusterOfUTF16.count - 1)
                let cluster = min(clusterOfUTF16[utf16Index], max(clusterCount - 1, 0))
                let eased = phase(forCluster: cluster)
                guard eased > 0.001 else { continue }
                let offset = slideOffset(eased: eased)
                var position = CGPoint(
                    x: lineOrigin.x + positions[i].x + offset.width,
                    y: lineOrigin.y + positions[i].y - offset.height)
                ctx.setShadow(
                    offset: .zero, blur: shadowBlur,
                    color: CGColor(gray: 0, alpha: 0.55 * eased))
                ctx.setFillColor(CGColor(gray: 1, alpha: eased))
                var glyph = glyphs[i]
                CTFontDrawGlyphs(runFont, &glyph, &position, 1, ctx)
            }
        }
        return ctx.makeImage()
    }
}

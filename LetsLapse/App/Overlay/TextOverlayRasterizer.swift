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
/// Two layout modes, both resolved here so preview and export cannot drift:
/// free text flows from the anchor, boxed text wraps inside the layer's box
/// and can be auto-fitted to it.
enum TextOverlayRasterizer {

    /// The reference frame auto-size solves in. Fitting against the ACTUAL
    /// render size would let a 1100 px scrub and a 2000 px settled render
    /// choose different steps — the type would visibly jump when the scrub
    /// landed. Solving at a fixed long edge and scaling the answer makes the
    /// chosen size a property of the layer, not of the render.
    private static let fitReferenceLongEdge: Double = 1000

    struct Spec: Equatable {
        var string: String
        var style: TextOverlayContent
        /// Resolved against the ACTUAL render's long edge (2000 settled,
        /// 1100 scrub, full-res export) so geometry is scale-invariant.
        var fontSizePixels: CGFloat
        /// Anchor centre in pixels, top-left origin, in `frameSize` space.
        var center: CGPoint
        var frameSize: CGSize
        /// Wrap width in pixels for boxed text; nil = free, one line per
        /// paragraph.
        var wrapWidth: CGFloat?
        /// Box height in pixels, for vertical centring; nil = free.
        var boxHeight: CGFloat?
        /// Raw 0…1 progress per grapheme cluster; empty = settled (all 1).
        var phases: [Double]
        /// nil = fade only; otherwise characters arrive from this direction.
        var direction: OverlayAnimation.Direction?

        /// Deterministic cache identity. Phases arrive quantized (the scrub
        /// ladder), so rounding here only guards float noise.
        var cacheKey: String {
            let phaseKey = phases.map { String(format: "%.3f", $0) }.joined(separator: ",")
            let styleKey = [
                style.fontFamily ?? "-",
                style.isBold ? "b" : "-", style.isItalic ? "i" : "-",
                style.isUnderlined ? "u" : "-", style.colorHex,
                style.alignment.rawValue,
                String(format: "%.2f,%.3f,%.3f",
                       style.kerning, style.lineHeight, style.paragraphSpacing),
            ].joined(separator: ",")
            return [
                string, styleKey, String(format: "%.1f", fontSizePixels),
                String(format: "%.1f,%.1f", center.x, center.y),
                String(format: "%.0fx%.0f", frameSize.width, frameSize.height),
                wrapWidth.map { String(format: "%.1f", $0) } ?? "-",
                boxHeight.map { String(format: "%.1f", $0) } ?? "-",
                direction?.rawValue ?? "-", phaseKey,
            ].joined(separator: "|")
        }
    }

    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 24
        // The costs passed to setObject are inert without a byte budget, and
        // a settled 2000 px raster is ~12 MB — 24 of them is jetsam bait.
        // Playback only ever needs the current step plus the settled raster.
        cache.totalCostLimit = 64 << 20
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

    // MARK: - Size resolution

    /// The size a layer actually renders at: its own `size`, or — in box
    /// mode with auto-size on — the largest step in `[minSize, maxSize]`
    /// whose wrapped layout still fits inside the box.
    ///
    /// Solves BOTH axes. Fitting width alone reports a fit for type that has
    /// wrapped its way straight out of the bottom of the box.
    static func resolvedSize(for overlay: SceneOverlay, aspect: Double) -> Double {
        guard overlay.mode == .box, overlay.autoSize,
              case .text(let style) = overlay.content, !style.string.isEmpty
        else { return overlay.size }

        let low = min(overlay.minSize, overlay.maxSize)
        let high = max(overlay.minSize, overlay.maxSize)
        // The reference frame: long edge fixed, short edge from the aspect.
        let ratio = aspect > 0 ? aspect : 1
        let frame = ratio >= 1
            ? CGSize(width: fitReferenceLongEdge, height: fitReferenceLongEdge / ratio)
            : CGSize(width: fitReferenceLongEdge * ratio, height: fitReferenceLongEdge)
        let boxW = CGFloat(overlay.boxWidth) * frame.width
        let boxH = CGFloat(overlay.boxHeight) * frame.height
        guard boxW > 1, boxH > 1 else { return low }

        // 24 bisection steps resolve far finer than a font size can render;
        // the prototype's 60-step linear scan was doing the same job with
        // more layouts.
        var lo = low, hi = high
        if fits(style: style, size: hi, frame: frame, boxW: boxW, boxH: boxH) { return hi }
        if !fits(style: style, size: lo, frame: frame, boxW: boxW, boxH: boxH) { return lo }
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if fits(style: style, size: mid, frame: frame, boxW: boxW, boxH: boxH) {
                lo = mid
            } else {
                hi = mid
            }
        }
        return lo
    }

    private static func fits(
        style: TextOverlayContent, size: Double, frame: CGSize,
        boxW: CGFloat, boxH: CGFloat
    ) -> Bool {
        let pixels = CGFloat(size) * max(frame.width, frame.height)
        guard pixels >= 1 else { return true }
        let layout = layoutLines(
            style: style, fontSizePixels: pixels, wrapWidth: boxW)
        // Width is enforced by the wrap in box mode, but a single
        // unbreakable word can still overrun it.
        return layout.height <= boxH && layout.maxLineWidth <= boxW + 0.5
    }

    /// The raster request for an overlay at one moment of the timeline, in
    /// one render's pixel space. nil = nothing to draw (empty text, or the
    /// reveal hasn't started).
    static func spec(
        for overlay: SceneOverlay, frameSize: CGSize, position: Double,
        ignoringAnimation: Bool = false
    ) -> Spec? {
        guard case .text(let content) = overlay.content,
              !content.string.isEmpty else { return nil }
        var phases: [Double] = []
        var direction: OverlayAnimation.Direction?
        if let animation = overlay.animation, !ignoringAnimation {
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
        let aspect = frameSize.height > 0 ? frameSize.width / frameSize.height : 1
        let size = resolvedSize(for: overlay, aspect: Double(aspect))
        return Spec(
            string: content.string,
            style: content,
            fontSizePixels: CGFloat(size) * longEdge,
            center: CGPoint(
                x: overlay.centerX * frameSize.width,
                y: overlay.centerY * frameSize.height),
            frameSize: frameSize,
            wrapWidth: overlay.mode == .box
                ? CGFloat(overlay.boxWidth) * frameSize.width : nil,
            boxHeight: overlay.mode == .box
                ? CGFloat(overlay.boxHeight) * frameSize.height : nil,
            phases: phases,
            direction: direction)
    }

    // MARK: - Layout

    /// One laid-out line, with the UTF-16 offset in the FULL string that its
    /// own indices are relative to — the bridge back to global grapheme
    /// clusters, which is what animation phases are indexed by.
    private struct LaidLine {
        var line: CTLine
        var utf16Offset: Int
        var width: CGFloat
        /// Baseline offset from the top of the block, positive downward.
        var baselineFromTop: CGFloat
    }

    private struct Layout {
        var lines: [LaidLine] = []
        var height: CGFloat = 0
        var maxLineWidth: CGFloat = 0
    }

    /// Breaks the text into drawable lines. Paragraphs split on newlines;
    /// inside a paragraph the typesetter wraps to `wrapWidth` when there is
    /// one. Line advance is `lineHeight × fontSize` — a multiple of the type
    /// size, not of the face's own leading, so the dial means the same thing
    /// whatever font is chosen.
    private static func layoutLines(
        style: TextOverlayContent, fontSizePixels: CGFloat, wrapWidth: CGFloat?
    ) -> Layout {
        let font = resolveFont(
            family: style.fontFamily, size: fontSizePixels,
            bold: style.isBold, italic: style.isItalic)
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if abs(style.kerning) > 0.0001 {
            // Kerning is stored as a fraction of the em × 100, so the dial's
            // effect scales with the type instead of vanishing at large sizes.
            attributes[.kern] = style.kerning * fontSizePixels / 100
        }

        var layout = Layout()
        let lineAdvance = fontSizePixels * CGFloat(max(style.lineHeight, 0.4))
        let paragraphGap = fontSizePixels * CGFloat(max(style.paragraphSpacing, 0))

        // Byte offsets, not character offsets: CTLine indices are UTF-16.
        var paragraphUTF16Start = 0
        var y: CGFloat = 0
        let paragraphs = style.string.components(separatedBy: "\n")

        for (index, paragraph) in paragraphs.enumerated() {
            if index > 0 { y += paragraphGap }
            let attributed = NSAttributedString(string: paragraph, attributes: attributes)
            if paragraph.isEmpty {
                // A blank line still occupies a line.
                y += lineAdvance
                paragraphUTF16Start += 1
                continue
            }
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            var start = 0
            let length = attributed.length
            while start < length {
                let count: Int
                if let wrapWidth, wrapWidth > 1 {
                    let suggested = CTTypesetterSuggestLineBreak(
                        typesetter, start, Double(wrapWidth))
                    // A single glyph wider than the box would otherwise
                    // return 0 and spin here forever.
                    count = max(suggested, 1)
                } else {
                    count = length - start
                }
                let line = CTTypesetterCreateLine(
                    typesetter, CFRange(location: start, length: count))
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                y += lineAdvance
                layout.lines.append(LaidLine(
                    line: line,
                    utf16Offset: paragraphUTF16Start + start,
                    width: width,
                    // The baseline sits within its own line box, offset from
                    // the top by the ascent share of the advance.
                    baselineFromTop: y - lineAdvance * 0.22))
                layout.maxLineWidth = max(layout.maxLineWidth, width)
                start += count
            }
            paragraphUTF16Start += length + 1  // + the newline itself
        }
        layout.height = y
        return layout
    }

    /// The font a style asks for, falling back to the system face when the
    /// named family is not installed — a project authored on a Mac with a
    /// custom font must still open on a phone that lacks it.
    private static func resolveFont(
        family: String?, size: CGFloat, bold: Bool, italic: Bool
    ) -> CTFont {
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }

        if let family, !family.isEmpty {
            let descriptor = CTFontDescriptorCreateWithAttributes([
                kCTFontFamilyNameAttribute: family,
            ] as CFDictionary)
            let base = CTFontCreateWithFontDescriptor(descriptor, size, nil)
            // CTFontCreateWithFontDescriptor never fails; it substitutes.
            // Comparing the family back is how we find out whether the ask
            // was honored — and if it was, traits apply on top of it.
            let resolved = CTFontCopyFamilyName(base) as String
            if resolved.compare(family, options: .caseInsensitive) == .orderedSame {
                if traits.isEmpty { return base }
                return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits)
                    ?? base
            }
        }
        #if canImport(AppKit)
        var systemFont = NSFont.systemFont(
            ofSize: size, weight: bold ? .bold : .regular) as CTFont
        #else
        var systemFont = UIFont.systemFont(
            ofSize: size, weight: bold ? .bold : .regular) as CTFont
        #endif
        if italic {
            systemFont = CTFontCreateCopyWithSymbolicTraits(
                systemFont, size, nil, .traitItalic, .traitItalic) ?? systemFont
        }
        return systemFont
    }

    /// `#RRGGBB` (or `#RRGGBBAA`) to a color. An unparsable string reads as
    /// white — the spike's color, and never an invisible layer.
    static func color(fromHex hex: String) -> CGColor {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8,
              let value = UInt64(text, radix: 16)
        else { return CGColor(red: 1, green: 1, blue: 1, alpha: 1) }
        let hasAlpha = text.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        return CGColor(red: r, green: g, blue: b, alpha: a)
    }

    // MARK: - Drawing

    private static func draw(_ spec: Spec) -> CGImage? {
        let width = Int(spec.frameSize.width.rounded())
        let height = Int(spec.frameSize.height.rounded())
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let layout = layoutLines(
            style: spec.style, fontSizePixels: spec.fontSizePixels,
            wrapWidth: spec.wrapWidth)
        guard !layout.lines.isEmpty else { return nil }

        // The block's top edge in screen space (top-left origin): free text
        // centres its own height on the anchor; boxed text centres inside the
        // box, which is itself centred on the anchor.
        let blockTop = spec.center.y - layout.height / 2
        // The horizontal frame alignment resolves against: the box's width in
        // box mode, the widest line in free mode.
        let alignmentWidth = spec.wrapWidth ?? layout.maxLineWidth
        let alignmentLeft = spec.center.x - alignmentWidth / 2

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
        let fillColor = color(fromHex: spec.style.colorHex)
        let underlineThickness = max(spec.fontSizePixels * 0.055, 1)
        let underlineDrop = spec.fontSizePixels * 0.13

        for laid in layout.lines {
            // Per-line horizontal placement inside the alignment frame.
            let lineX: CGFloat
            switch spec.style.alignment {
            case .left: lineX = alignmentLeft
            case .center: lineX = alignmentLeft + (alignmentWidth - laid.width) / 2
            case .right: lineX = alignmentLeft + (alignmentWidth - laid.width)
            }
            // The context is CG-native (bottom-left origin): the baseline's
            // screen y flips once here, and every animation offset flips its
            // own y when it is applied — one flip per axis, in one place each.
            let baselineY = spec.frameSize.height - (blockTop + laid.baselineFromTop)

            let runs = (CTLineGetGlyphRuns(laid.line) as? [CTRun]) ?? []
            for run in runs {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                var indices = [CFIndex](repeating: 0, count: count)
                var advances = [CGSize](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
                CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
                // The run's own font, not the requested one — emoji and
                // fallback glyphs arrive in a different face and must be
                // drawn with it.
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let runFont = (attributes[kCTFontAttributeName as String] as! CTFont)

                for i in 0..<count {
                    // Line-relative UTF-16 index back to the full string.
                    let globalUTF16 = min(
                        max(indices[i] + laid.utf16Offset, 0), clusterOfUTF16.count - 1)
                    let cluster = min(clusterOfUTF16[globalUTF16], max(clusterCount - 1, 0))
                    let eased = phase(forCluster: cluster)
                    guard eased > 0.001 else { continue }
                    let offset = slideOffset(eased: eased)
                    var position = CGPoint(
                        x: lineX + positions[i].x + offset.width,
                        y: baselineY + positions[i].y - offset.height)
                    ctx.setShadow(
                        offset: .zero, blur: shadowBlur,
                        color: CGColor(gray: 0, alpha: 0.55 * eased))
                    ctx.setFillColor(fillColor.copy(alpha: CGFloat(eased)) ?? fillColor)
                    var glyph = glyphs[i]
                    CTFontDrawGlyphs(runFont, &glyph, &position, 1, ctx)

                    if spec.style.isUnderlined, advances[i].width > 0 {
                        // Drawn per glyph so the rule reveals with its own
                        // character rather than appearing whole on frame one.
                        ctx.fill(CGRect(
                            x: position.x, y: position.y - underlineDrop,
                            width: advances[i].width, height: underlineThickness))
                    }
                }
            }
        }
        return ctx.makeImage()
    }
}

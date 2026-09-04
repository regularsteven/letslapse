import LetsLapseKit
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
/// at a time so each reveal unit — the whole element, a word, a character —
/// can carry its own animation state.
///
/// A pure function of its `Spec`: the raster of a finished reveal (every
/// phase 1) is byte-identical to the raster of no animation at all, which is
/// the structural half of "the final layout is always the end state". Cached,
/// because a playback sweep asks for a raster per ladder step.
///
/// Two layout modes, both resolved here so preview and export cannot drift:
/// free text flows from the anchor, boxed text wraps inside the layer's box
/// and can be auto-fitted to it. The copy is a list of styled runs; each run
/// sets its own weight, colour and underline over the layer's.
enum TextOverlayRasterizer {

    /// The reference frame auto-size solves in. Fitting against the ACTUAL
    /// render size would let a 1100 px scrub and a 2000 px settled render
    /// choose different steps — the type would visibly jump when the scrub
    /// landed. Solving at a fixed long edge and scaling the answer makes the
    /// chosen size a property of the layer, not of the render.
    private static let fitReferenceLongEdge: Double = 1000

    /// The part of a spec that moves: which units are mid-reveal, how far,
    /// and in which style. nil = settled.
    struct Motion: Equatable {
        var unit: OverlayReveal.Unit
        var style: OverlayReveal.Style
        var direction: OverlayAnimation.Direction
        /// Raw 0…1 progress per unit. Easing is applied here, at draw time.
        var phases: [Double]
        /// A reveal OUT reads its progress backwards: 1 = gone.
        var isExit: Bool

        var cacheKey: String {
            let phaseKey = phases.map { String(format: "%.3f", $0) }.joined(separator: ",")
            return "\(unit.rawValue)/\(style.rawValue)/\(direction.rawValue)/\(isExit ? "out" : "in")/\(phaseKey)"
        }
    }

    struct Spec: Equatable {
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
        /// nil = the resting layout, exactly.
        var motion: Motion?
        /// The block's turn about its anchor, degrees, positive clockwise on
        /// screen. 0 for the vast majority of layers.
        var rotationDegrees: Double = 0

        var string: String { style.string }

        /// Deterministic cache identity. Phases arrive quantized (the scrub
        /// ladder), so rounding here only guards float noise.
        var cacheKey: String {
            let runKey = style.runs.map { "\($0.text)\u{1}\($0.styleKey)" }.joined(separator: "\u{2}")
            let styleKey = [
                style.fontFamily ?? "-",
                style.isBold ? "b" : "-", style.isItalic ? "i" : "-",
                style.isUnderlined ? "u" : "-", style.colorHex,
                style.alignment.rawValue,
                String(format: "%.2f,%.3f,%.3f",
                       style.kerning, style.lineHeight, style.paragraphSpacing),
            ].joined(separator: ",")
            return [
                runKey, styleKey, String(format: "%.1f", fontSizePixels),
                String(format: "%.1f,%.1f", center.x, center.y),
                String(format: "%.0fx%.0f", frameSize.width, frameSize.height),
                wrapWidth.map { String(format: "%.1f", $0) } ?? "-",
                boxHeight.map { String(format: "%.1f", $0) } ?? "-",
                motion?.cacheKey ?? "settled",
                String(format: "%.2f", rotationDegrees),
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

    /// The Core Image context the blur style renders through. One, shared:
    /// contexts own GPU caches. Thread-safe, so the export's detached render
    /// and the editor's work queue can both use it.
    private static let blurContext = CIContext(options: [.cacheIntermediates: false])

    /// How far a sliding unit travels, in font-size units.
    private static let slideTravel: CGFloat = 0.6
    /// How far a bouncing unit drops in from, in font-size units.
    private static let bounceTravel: CGFloat = 0.9
    /// The blur style's radius at progress 0, in font-size units. The
    /// design's 10 px was measured on a 660 px-wide mock; a fraction of the
    /// em keeps it the same softness at 4000 px.
    private static let blurRadius: CGFloat = 0.22

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
    /// one render's pixel space. nil = nothing to draw (empty text, before
    /// the reveal, after the exit).
    static func spec(
        for overlay: SceneOverlay, frameSize: CGSize, position: Double,
        ignoringAnimation: Bool = false
    ) -> Spec? {
        guard case .text(let content) = overlay.content,
              !content.string.isEmpty else { return nil }
        var motion: Motion?
        if !ignoringAnimation {
            switch overlay.effectiveAnimation.moment(at: position, content: content) {
            case .hidden:
                return nil
            case .settled:
                // At or past the end the raster must equal the no-animation
                // raster — same cache entry, byte-identical pixels.
                motion = nil
            case .revealing(let reveal, let phases):
                guard let style = reveal.style else { break }
                motion = Motion(
                    unit: reveal.unit, style: style, direction: reveal.direction,
                    phases: phases, isExit: false)
            case .exiting(let exit, let phases):
                guard let style = exit.style else { break }
                motion = Motion(
                    unit: exit.unit, style: style, direction: exit.direction,
                    phases: phases, isExit: true)
            }
        }
        let longEdge = max(frameSize.width, frameSize.height)
        let aspect = frameSize.height > 0 ? frameSize.width / frameSize.height : 1
        let size = resolvedSize(for: overlay, aspect: Double(aspect))
        return Spec(
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
            motion: motion,
            rotationDegrees: overlay.rotationDegrees)
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

    /// Our own attribute keys, read back off each `CTRun`. Core Text would
    /// draw an underline attribute itself under `CTLineDraw`; we draw glyphs
    /// one at a time, so the rule is ours to place — which is what lets it
    /// reveal with its own character.
    private static let underlineKey = NSAttributedString.Key("LLOverlayUnderline")
    private static let colorKey = NSAttributedString.Key("LLOverlayColor")

    /// The whole copy as one attributed string: the layer's font, kerning
    /// and colour, with each run's own weight, colour and underline over
    /// them. Built once per layout and sliced per paragraph.
    private static func attributedCopy(
        style: TextOverlayContent, fontSizePixels: CGFloat
    ) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        var fonts: [Bool: CTFont] = [:]
        for run in style.runs where !run.text.isEmpty {
            let bold = style.resolvedBold(run)
            let font: CTFont
            if let cached = fonts[bold] {
                font = cached
            } else {
                font = resolveFont(
                    family: style.fontFamily, size: fontSizePixels,
                    bold: bold, italic: style.isItalic)
                fonts[bold] = font
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                colorKey: style.resolvedColorHex(run),
                underlineKey: style.resolvedUnderline(run),
            ]
            if abs(style.kerning) > 0.0001 {
                // Kerning is stored as a fraction of the em × 100, so the
                // dial's effect scales with the type instead of vanishing at
                // large sizes.
                attributes[.kern] = style.kerning * fontSizePixels / 100
            }
            out.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return out
    }

    /// Breaks the text into drawable lines. Paragraphs split on newlines;
    /// inside a paragraph the typesetter wraps to `wrapWidth` when there is
    /// one. Line advance is `lineHeight × fontSize` — a multiple of the type
    /// size, not of the face's own leading, so the dial means the same thing
    /// whatever font is chosen.
    private static func layoutLines(
        style: TextOverlayContent, fontSizePixels: CGFloat, wrapWidth: CGFloat?
    ) -> Layout {
        let copy = attributedCopy(style: style, fontSizePixels: fontSizePixels)
        var layout = Layout()
        let lineAdvance = fontSizePixels * CGFloat(max(style.lineHeight, 0.4))
        let paragraphGap = fontSizePixels * CGFloat(max(style.paragraphSpacing, 0))

        // Byte offsets, not character offsets: CTLine indices are UTF-16.
        let whole = copy.string as NSString
        var paragraphUTF16Start = 0
        var y: CGFloat = 0
        var index = 0
        while paragraphUTF16Start <= whole.length {
            let newline = whole.range(
                of: "\n", options: [],
                range: NSRange(location: paragraphUTF16Start, length: whole.length - paragraphUTF16Start))
            let paragraphEnd = newline.location == NSNotFound ? whole.length : newline.location
            let length = paragraphEnd - paragraphUTF16Start
            if index > 0 { y += paragraphGap }
            if length == 0 {
                // A blank line still occupies a line.
                y += lineAdvance
            } else {
                let attributed = copy.attributedSubstring(
                    from: NSRange(location: paragraphUTF16Start, length: length))
                let typesetter = CTTypesetterCreateWithAttributedString(attributed)
                var start = 0
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
                        // The baseline sits within its own line box, offset
                        // from the top by the ascent share of the advance.
                        baselineFromTop: y - lineAdvance * 0.22))
                    layout.maxLineWidth = max(layout.maxLineWidth, width)
                    start += count
                }
            }
            index += 1
            if newline.location == NSNotFound { break }
            paragraphUTF16Start = paragraphEnd + 1  // + the newline itself
        }
        layout.height = y
        return layout
    }

    /// The font a style asks for, falling back to the system face when the
    /// named family is not installed — a project authored on a Mac with a
    /// custom font must still open on a phone that lacks it. Families
    /// imported into the project are registered with the font manager by
    /// `OverlayFontStore` before any render, so they resolve here like any
    /// installed face.
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

    // MARK: - Easing

    /// Ease-out-back, c = 1.70158: overshoots its target and settles — the
    /// Bounce and Pop styles' curve.
    static func easeOutBack(_ t: Double) -> Double {
        let c = 1.70158, d = c + 1
        let u = min(max(t, 0), 1) - 1
        return 1 + d * u * u * u + c * u * u
    }

    /// The unit's on-screen progress for a raw phase: the house cubic for
    /// most styles, raw for the two that ease themselves, and read backwards
    /// for an exit.
    private static func progress(_ raw: Double, motion: Motion) -> Double {
        let eased = motion.style.usesBackEase ? min(max(raw, 0), 1) : ReframeTrack.ease(raw)
        return motion.isExit ? 1 - eased : eased
    }

    // MARK: - Drawing

    /// One glyph, placed: where it sits at rest (CG coordinates, bottom-left
    /// origin) and which unit and run it belongs to.
    private struct PlacedGlyph {
        var glyph: CGGlyph
        var font: CTFont
        var position: CGPoint
        var advance: CGFloat
        var ascent: CGFloat
        var descent: CGFloat
        var color: CGColor
        var underlined: Bool
        var unit: Int
    }

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

        // Cluster → reveal unit. Settled rasters put everything in unit 0.
        let unitOfCluster: [Int] = spec.motion.map { spec.style.unitIndices(for: $0.unit).ofCluster }
            ?? Array(repeating: 0, count: clusterCount)

        // The layer's own turn: one CTM rotation about the anchor, applied
        // before any glyph is placed, so the lines, their animation offsets
        // and their underlines all turn together as one block. The context
        // is y-up, so a clockwise-on-screen angle is a negative CG angle.
        if abs(spec.rotationDegrees) > 0.005 {
            let anchor = CGPoint(x: spec.center.x, y: spec.frameSize.height - spec.center.y)
            ctx.translateBy(x: anchor.x, y: anchor.y)
            ctx.rotate(by: CGFloat(-spec.rotationDegrees * .pi / 180))
            ctx.translateBy(x: -anchor.x, y: -anchor.y)
        }

        // Place every glyph at rest first; the motion pass then draws them
        // unit by unit with the unit's transform.
        var placed: [PlacedGlyph] = []
        var colors: [String: CGColor] = [:]
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
                let hex = attributes[colorKey.rawValue] as? String ?? spec.style.colorHex
                let color: CGColor
                if let cached = colors[hex] {
                    color = cached
                } else {
                    color = self.color(fromHex: hex)
                    colors[hex] = color
                }
                let underlined = attributes[underlineKey.rawValue] as? Bool ?? spec.style.isUnderlined
                let ascent = CTFontGetAscent(runFont)
                let descent = CTFontGetDescent(runFont)

                for i in 0..<count {
                    // Line-relative UTF-16 index back to the full string.
                    let globalUTF16 = min(
                        max(indices[i] + laid.utf16Offset, 0), clusterOfUTF16.count - 1)
                    let cluster = min(clusterOfUTF16[globalUTF16], max(clusterCount - 1, 0))
                    let unit = cluster < unitOfCluster.count ? unitOfCluster[cluster] : 0
                    placed.append(PlacedGlyph(
                        glyph: glyphs[i], font: runFont,
                        position: CGPoint(x: lineX + positions[i].x, y: baselineY + positions[i].y),
                        advance: advances[i].width, ascent: ascent, descent: descent,
                        color: color, underlined: underlined, unit: unit))
                }
            }
        }
        guard !placed.isEmpty else { return nil }

        let shadowBlur = spec.fontSizePixels * 0.06
        let underlineThickness = max(spec.fontSizePixels * 0.055, 1)
        let underlineDrop = spec.fontSizePixels * 0.13

        /// Draws glyphs at `offset` from their rest with `alpha`.
        func drawGlyphs(_ glyphs: [PlacedGlyph], into context: CGContext,
                        offset: CGSize, alpha: CGFloat) {
            for item in glyphs {
                context.setShadow(
                    offset: .zero, blur: shadowBlur,
                    color: CGColor(gray: 0, alpha: 0.55 * alpha))
                context.setFillColor(item.color.copy(alpha: alpha) ?? item.color)
                var glyph = item.glyph
                var position = CGPoint(
                    x: item.position.x + offset.width, y: item.position.y - offset.height)
                CTFontDrawGlyphs(item.font, &glyph, &position, 1, context)
                if item.underlined, item.advance > 0 {
                    // Drawn per glyph so the rule reveals with its own
                    // character rather than appearing whole on frame one.
                    context.fill(CGRect(
                        x: position.x, y: position.y - underlineDrop,
                        width: item.advance, height: underlineThickness))
                }
            }
        }

        guard let motion = spec.motion else {
            drawGlyphs(placed, into: ctx, offset: .zero, alpha: 1)
            return ctx.makeImage()
        }

        // Group by unit, in order.
        var units: [[PlacedGlyph]] = []
        var unitIndex: [Int: Int] = [:]
        for item in placed {
            if let slot = unitIndex[item.unit] {
                units[slot].append(item)
            } else {
                unitIndex[item.unit] = units.count
                units.append([item])
            }
        }

        /// The ink box of a unit at rest, CG coordinates.
        func bounds(of glyphs: [PlacedGlyph]) -> CGRect {
            var minX = CGFloat.infinity, maxX = -CGFloat.infinity
            var minY = CGFloat.infinity, maxY = -CGFloat.infinity
            for item in glyphs {
                minX = min(minX, item.position.x)
                maxX = max(maxX, item.position.x + max(item.advance, 0))
                minY = min(minY, item.position.y - item.descent - underlineDrop)
                maxY = max(maxY, item.position.y + item.ascent)
            }
            return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
        }

        for glyphs in units {
            let unit = glyphs[0].unit
            let raw = unit < motion.phases.count ? motion.phases[unit] : (motion.phases.last ?? 1)
            let t = progress(raw, motion: motion)
            guard t > 0.001 else { continue }
            if t >= 0.999 {
                drawGlyphs(glyphs, into: ctx, offset: .zero, alpha: 1)
                continue
            }
            let em = spec.fontSizePixels
            ctx.saveGState()
            switch motion.style {
            case .fade:
                drawGlyphs(glyphs, into: ctx, offset: .zero, alpha: CGFloat(t))
            case .slide:
                let travel = slideTravel * em * CGFloat(1 - t)
                let offset: CGSize
                switch motion.direction {
                case .top: offset = CGSize(width: 0, height: -travel)
                case .bottom: offset = CGSize(width: 0, height: travel)
                case .left: offset = CGSize(width: -travel, height: 0)
                case .right: offset = CGSize(width: travel, height: 0)
                }
                drawGlyphs(glyphs, into: ctx, offset: offset, alpha: CGFloat(t))
            case .bounce:
                let back = easeOutBack(t)
                let drop = bounceTravel * em * CGFloat(1 - back)
                drawGlyphs(glyphs, into: ctx, offset: CGSize(width: 0, height: drop),
                           alpha: CGFloat(min(1, 3 * t)))
            case .pop:
                let scale = max(0.01, easeOutBack(t))
                let box = bounds(of: glyphs)
                // About the unit's baseline centre: the type grows out of the
                // spot it will stand on, not out of its own middle.
                let anchor = CGPoint(x: box.midX, y: glyphs[0].position.y)
                ctx.translateBy(x: anchor.x, y: anchor.y)
                ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                ctx.translateBy(x: -anchor.x, y: -anchor.y)
                drawGlyphs(glyphs, into: ctx, offset: .zero, alpha: CGFloat(min(1, 2 * t)))
            case .wipe:
                let box = bounds(of: glyphs)
                // Clip from the left, with headroom above and below so
                // ascenders and the shadow are not shaved.
                let reveal = CGRect(
                    x: box.minX - shadowBlur, y: box.minY - box.height * 0.2 - shadowBlur,
                    width: (box.width + shadowBlur) * CGFloat(t),
                    height: box.height * 1.4 + shadowBlur * 2)
                ctx.clip(to: reveal)
                drawGlyphs(glyphs, into: ctx, offset: .zero, alpha: 1)
            case .blur:
                let radius = blurRadius * em * CGFloat(1 - t)
                if radius < 0.5 {
                    drawGlyphs(glyphs, into: ctx, offset: .zero, alpha: CGFloat(t))
                } else if let image = blurred(glyphs, radius: radius, bounds: bounds(of: glyphs),
                                              shadowBlur: shadowBlur, draw: drawGlyphs) {
                    ctx.setAlpha(CGFloat(t))
                    ctx.draw(image.image, in: image.rect)
                }
            }
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    /// The Blur style: the unit drawn at full strength into its own small
    /// bitmap, softened through Core Image, handed back with the rect it
    /// goes in. Per unit rather than per glyph, so a word blurs as one shape.
    private static func blurred(
        _ glyphs: [PlacedGlyph], radius: CGFloat, bounds: CGRect, shadowBlur: CGFloat,
        draw: ([PlacedGlyph], CGContext, CGSize, CGFloat) -> Void
    ) -> (image: CGImage, rect: CGRect)? {
        let margin = (radius * 3 + shadowBlur * 2).rounded(.up)
        let rect = bounds.insetBy(dx: -margin, dy: -margin).integral
        let width = Int(rect.width), height = Int(rect.height)
        guard width > 0, height > 0, width * height < 40_000_000,
              let sub = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        sub.translateBy(x: -rect.minX, y: -rect.minY)
        draw(glyphs, sub, .zero, 1)
        guard let sharp = sub.makeImage() else { return nil }
        let input = CIImage(cgImage: sharp)
        let soft = input.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(radius))
            .cropped(to: input.extent)
        guard let out = blurContext.createCGImage(soft, from: input.extent) else { return nil }
        return (out, rect)
    }
}

import Foundation
import CoreGraphics
import CoreText

/// Tiled review sheets: 8×5 tiles, detections overlaid. Green = accepted ellipse,
/// cyan = accepted quad, red = rejected ellipse (thin), orange = rejected quad.
enum ContactSheet {
    static let cols = 8, rows = 5, tile = 320, caption = 30
    static var perSheet: Int { cols * rows }

    static func render(assets: [Asset], thumbs: [String: CGImage], records: [DetectionRecord], to url: URL) throws {
        let width = cols * tile, height = rows * (tile + caption)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: ImageLoader.srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Flip to a top-left origin so image geometry can be drawn directly.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        var byAsset: [String: [DetectionRecord]] = [:]
        for r in records { byAsset[r.anchor.assetID, default: []].append(r) }

        for (i, asset) in assets.enumerated() {
            let col = i % cols, row = i / cols
            let ox = CGFloat(col * tile), oy = CGFloat(row * (tile + caption))
            guard let thumb = thumbs[asset.id] else {
                drawText("\(asset.shortID) — no image", at: CGPoint(x: ox + 6, y: oy + 20), size: 13, ctx: ctx, colour: CGColor(srgbRed: 1, green: 0.4, blue: 0.4, alpha: 1))
                continue
            }
            let tw = CGFloat(thumb.width), th = CGFloat(thumb.height)
            let s = min(CGFloat(tile) / tw, CGFloat(tile) / th)
            let dw = tw * s, dh = th * s
            let dx = ox + (CGFloat(tile) - dw) / 2, dy = oy + (CGFloat(tile) - dh) / 2
            ctx.saveGState()
            // Draw the image un-flipped inside the flipped context.
            ctx.translateBy(x: dx, y: dy + dh)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .medium
            ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: dw, height: dh))
            ctx.restoreGState()

            let recs = byAsset[asset.id] ?? []
            // Only the informative near-misses: shapes that fitted but failed a gate.
            let informative: Set<String> = ["residual", "coverage", "obliquity", "too-small", "centre-outside"]
            let rejectedEllipses = recs.filter { !$0.accepted && $0.anchor.kind == .ellipse && informative.contains($0.rejection ?? "") }
                .sorted { ($0.fitResidual ?? 1) < ($1.fitResidual ?? 1) }.prefix(10)
            let rejectedQuads = recs.filter { !$0.accepted && $0.anchor.kind == .quad && $0.rejection == "too-small" }
            ctx.saveGState()
            ctx.clip(to: CGRect(x: dx, y: dy, width: dw, height: dh))
            for r in rejectedEllipses { drawAnchor(r.anchor, in: CGRect(x: dx, y: dy, width: dw, height: dh), ctx: ctx, colour: CGColor(srgbRed: 1, green: 0.25, blue: 0.25, alpha: 0.55), width: 1) }
            for r in rejectedQuads { drawAnchor(r.anchor, in: CGRect(x: dx, y: dy, width: dw, height: dh), ctx: ctx, colour: CGColor(srgbRed: 1, green: 0.6, blue: 0.1, alpha: 0.6), width: 1) }
            for r in recs where r.accepted {
                let colour = r.anchor.kind == .ellipse ? CGColor(srgbRed: 0.2, green: 1, blue: 0.3, alpha: 0.95) : CGColor(srgbRed: 0.2, green: 0.9, blue: 1, alpha: 0.95)
                drawAnchor(r.anchor, in: CGRect(x: dx, y: dy, width: dw, height: dh), ctx: ctx, colour: colour, width: 2.5)
            }
            ctx.restoreGState()
            let ne = recs.filter { $0.accepted && $0.anchor.kind == .ellipse }.count
            let nq = recs.filter { $0.accepted && $0.anchor.kind == .quad }.count
            let nr = recs.filter { !$0.accepted }.count
            let src: String = {
                switch asset.representativeSource {
                case .blendImage: return "blend"
                case .blendVideo: return "clip"
                case .renderedFrame: return "frame"
                case .rawDecode: return "RAW"
                }
            }()
            let text = "\(asset.shortID) · \(src) \(asset.nativeWidth)×\(asset.nativeHeight) · E\(ne) Q\(nq) ✗\(nr)"
            drawText(text, at: CGPoint(x: ox + 5, y: oy + CGFloat(tile) + 20), size: 12, ctx: ctx, colour: CGColor(gray: 0.9, alpha: 1))
            let mode = asset.mode.count > 40 ? String(asset.mode.prefix(40)) : asset.mode
            drawText(mode, at: CGPoint(x: ox + 5, y: oy + 14), size: 10, ctx: ctx, colour: CGColor(gray: 1, alpha: 0.85), shadow: true)
        }
        guard let img = ctx.makeImage() else { return }
        try ImageLoader.writePNG(img, to: url)
    }

    static func drawAnchor(_ a: ShapeAnchor, in rect: CGRect, ctx: CGContext, colour: CGColor, width: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(colour)
        ctx.setLineWidth(width)
        if let c = a.corners {
            let pts = c.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
            ctx.move(to: pts[0]); for p in pts.dropFirst() { ctx.addLine(to: p) }
            ctx.closePath(); ctx.strokePath()
            // Mark the top-left corner.
            ctx.setFillColor(colour)
            ctx.fillEllipse(in: CGRect(x: pts[0].x - 3, y: pts[0].y - 3, width: 6, height: 6))
        } else {
            let cx = rect.minX + a.centre.x * rect.width, cy = rect.minY + a.centre.y * rect.height
            let sa = a.majorAxis * rect.width / 2, sb = a.minorAxis * rect.width / 2
            ctx.translateBy(x: cx, y: cy)
            ctx.rotate(by: a.rotation)
            ctx.strokeEllipse(in: CGRect(x: -sa, y: -sb, width: 2 * sa, height: 2 * sb))
            ctx.move(to: CGPoint(x: -sa, y: 0)); ctx.addLine(to: CGPoint(x: sa, y: 0)); ctx.strokePath()
        }
        ctx.restoreGState()
    }

    static func drawText(_ s: String, at p: CGPoint, size: CGFloat, ctx: CGContext, colour: CGColor, shadow: Bool = false) {
        let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: colour]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs as [NSAttributedString.Key: Any]))
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: p.x, y: p.y)
        ctx.scaleBy(x: 1, y: -1)
        if shadow {
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: CGColor(gray: 0, alpha: 0.9))
        }
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

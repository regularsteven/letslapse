import CoreGraphics
import SwiftUI
import LetsLapseKit

/// The little ink-and-white tiles that stand for a mask everywhere it is
/// listed — the Editor tab's Masks card, the Add menu, the Masks tab's deck.
///
/// One picture of one idea: **white is the region this version selects.** A
/// shape draws its gradient, a custom mask draws its file, and Sky and Land
/// draw the segmentation when it has been computed and a stylised horizon
/// when it has not. An inverted version is the same tile with the two
/// swapped, which is exactly what "· inverted" means.
enum MaskThumbnails {

    private final class Box { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 64
        return cache
    }()

    /// Everything a tile needs that the views themselves cannot resolve: the
    /// project's files and whatever the segmenter has already produced. A
    /// value so it can be handed down through the panels without either of
    /// them holding the model.
    struct Sources {
        /// The cached sky analysis, or nil when it has not been run. Sky and
        /// Land fall back to a drawn horizon rather than blocking on it —
        /// inference for a 48×36 tile would be absurd.
        var skyMask: SceneMask?
        /// A custom mask's file, already decoded to a thumbnail.
        var customThumbnail: (UUID) -> CGImage?

        static let none = Sources(skyMask: nil, customThumbnail: { _ in nil })
    }

    static let ink = CGColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1)
    static let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

    /// The tile for one version of one mask, at `size` in points.
    static func image(
        for mask: ProjectMask, inverted: Bool, size: CGSize,
        sources: Sources, scale: CGFloat = 2
    ) -> CGImage? {
        let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)
        switch mask.kind {
        case .shape:
            guard let shape = mask.shape else { return nil }
            // Keyed on the geometry itself: a dragged handle must redraw the
            // tile, and nothing else should.
            let key = "s|\(mask.id)|\(inverted)|\(Int(pixelSize.width))|\(shapeToken(shape))" as NSString
            if let box = cache.object(forKey: key) { return box.image }
            guard let image = MaskShapeRenderer.thumbnail(
                shape, size: pixelSize, inverted: inverted) else { return nil }
            cache.setObject(Box(image), forKey: key)
            return image
        case .custom:
            guard let id = mask.ref.customMaskID,
                  let file = sources.customThumbnail(id) else { return nil }
            guard inverted else { return file }
            let key = "ci|\(id)|\(Int(pixelSize.width))" as NSString
            if let box = cache.object(forKey: key) { return box.image }
            guard let image = invertedCopy(of: file) else { return file }
            cache.setObject(Box(image), forKey: key)
            return image
        case .sky, .land:
            // Land is the sky analysis read the other way round, and an
            // inverted version flips it once more — two flips being none.
            let wantsSky = (mask.kind == .sky) != inverted
            if let sky = sources.skyMask {
                let grid = wantsSky ? sky : sky.inverted()
                let key = "g|\(wantsSky)|\(grid.width)x\(grid.height)|\(grid.provenance)" as NSString
                if let box = cache.object(forKey: key) { return box.image }
                guard let image = gridImage(grid) else { return nil }
                cache.setObject(Box(image), forKey: key)
                return image
            }
            let key = "h|\(wantsSky)|\(Int(pixelSize.width))x\(Int(pixelSize.height))" as NSString
            if let box = cache.object(forKey: key) { return box.image }
            guard let image = horizonImage(size: pixelSize, skyIsWhite: wantsSky) else { return nil }
            cache.setObject(Box(image), forKey: key)
            return image
        }
    }

    /// A shape's identity for the cache key — every number that changes what
    /// is drawn, and nothing that does not.
    private static func shapeToken(_ shape: MaskShape) -> String {
        switch shape.kind {
        case .linear:
            return String(format: "l%.4f,%.4f,%.4f,%.4f,%.3f",
                          shape.start.x, shape.start.y, shape.end.x, shape.end.y, shape.feather)
        case .radial:
            return String(format: "r%.4f,%.4f,%.4f,%.4f,%.2f,%.3f",
                          shape.center.x, shape.center.y, shape.radiusX, shape.radiusY,
                          shape.rotationDegrees, shape.feather)
        }
    }

    /// A segmentation grid as a tile: white where the region is, ink where it
    /// is not. Drawn at the grid's own resolution — it is 448² at most and
    /// the tile is 48 pt, so there is nothing to gain by scaling first.
    private static func gridImage(_ mask: SceneMask) -> CGImage? {
        guard mask.width > 0, mask.height > 0,
              let context = CGContext(
                data: nil, width: mask.width, height: mask.height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(ink)
        context.fill(CGRect(x: 0, y: 0, width: mask.width, height: mask.height))
        // Row-major with a top-left origin; CGContext is bottom-left, so the
        // rows are laid down in reverse.
        for y in 0..<mask.height {
            for x in 0..<mask.width where mask.pixels[y * mask.width + x] > 127 {
                context.setFillColor(white)
                context.fill(CGRect(x: x, y: mask.height - 1 - y, width: 1, height: 1))
            }
        }
        return context.makeImage()
    }

    /// The stand-in for Sky and Land before the model has run: a plain
    /// skyline, so the tile still says which half of the picture it means.
    /// Deliberately generic — it is a symbol, not a claim about this scene.
    private static func horizonImage(size: CGSize, skyIsWhite: Bool) -> CGImage? {
        let width = max(Int(size.width.rounded()), 1), height = max(Int(size.height.rounded()), 1)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(skyIsWhite ? ink : white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // A ragged roofline across the middle. In CGContext's bottom-left
        // space the sky is the TOP of the tile, so it is the taller half.
        let w = CGFloat(width), h = CGFloat(height)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: h * 0.55))
        let steps: [CGFloat] = [0.55, 0.5, 0.62, 0.58, 0.48, 0.56, 0.52, 0.6]
        for (index, level) in steps.enumerated() {
            let x = w * CGFloat(index + 1) / CGFloat(steps.count)
            path.addLine(to: CGPoint(x: x, y: h * level))
        }
        if skyIsWhite {
            path.addLine(to: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: 0, y: h))
        } else {
            path.addLine(to: CGPoint(x: w, y: 0))
            path.addLine(to: CGPoint(x: 0, y: 0))
        }
        path.closeSubpath()
        context.setFillColor(white)
        context.addPath(path)
        context.fillPath()
        return context.makeImage()
    }

    /// A custom mask's file with black and white swapped.
    private static func invertedCopy(of image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(white)
        context.fill(rect)
        context.setBlendMode(.difference)
        context.draw(image, in: rect)
        return context.makeImage()
    }
}

/// One mask tile, with the badges that say what it carries.
///
/// The badge vocabulary is the design's: `AUTO` for a region that
/// re-segments per seam, `⊘` for a version applied inverted, an amber dot for
/// a mask that carries a grade, and a wash over a grade that is switched off.
struct MaskTile: View {
    let mask: ProjectMask
    var inverted: Bool = false
    var size: CGSize
    var sources: MaskThumbnails.Sources
    /// Draw the `AUTO` chip. Off in the Add menu's tight 22×16 rows, where
    /// the group heading already says it.
    var showsAuto: Bool = true
    var isSelected: Bool = false
    /// A mask that carries a grade — the amber dot, deck only.
    var isGraded: Bool = false
    /// A grade switched off: the whole tile dims.
    var isDisabled: Bool = false
    var cornerRadius: CGFloat = 6
    var accent: Color = LL.accent

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            if let image = MaskThumbnails.image(
                for: mask, inverted: inverted, size: size,
                sources: sources, scale: max(displayScale, 1)) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LL.ink
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(alignment: .topLeading) {
            if showsAuto && mask.kind.isAuto {
                Text("AUTO")
                    .font(.system(size: 7.5, weight: .semibold))
                    .monospaced()
                    .foregroundStyle(LL.ink)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                    .padding(3)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if inverted {
                Image(systemName: "circle.slash")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(LL.amber)
                    .padding(3)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isGraded {
                Circle().fill(LL.amber).frame(width: 7, height: 7).padding(3)
            }
        }
        .overlay {
            if isDisabled {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(LL.screenBackground.opacity(0.55))
            }
        }
        .overlay {
            // A hairline under the selection ring: an inverted tile draws
            // white where it selects, and a mask that reaches its own edge
            // would otherwise dissolve into the white card with no bounds at
            // all (seen on the Mac, 2026-09-07).
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(isSelected ? accent : .clear, lineWidth: 2.5)
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [mask.name(inverted: inverted), mask.caption(inverted: inverted)]
        if isGraded { parts.append("graded") }
        if isDisabled { parts.append("off") }
        return parts.joined(separator: ", ")
    }
}

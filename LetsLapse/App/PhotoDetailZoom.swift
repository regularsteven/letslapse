import CoreGraphics
import SwiftUI

/// Pixel peeping in the photo editor: the zoom/pan state the preview is drawn
/// through, the scan that finds the most detailed part of a frame, and the two
/// chips that go over the picture.
///
/// The problem this exists for: the editor renders its preview to fit the
/// screen, and at fit scale a 12 MP frame is being shown at a fifth of its
/// resolution — so noise reduction and sharpening, which work on single pixels,
/// are invisible whatever they are set to. Grading them by eye means seeing the
/// pixels the export will write, which means zooming to them (`PhotoZoomBox`)
/// and, while a Detail slider is actually moving, having them on screen without
/// leaving the picture at all (`DetailLoupe`).

// MARK: - Zoom state

/// Where the picture is being looked at. `scale` is a multiple of fit-to-pane,
/// so 1 is the state every editor opens in and the number means the same thing
/// on every screen; `offset` is the pan, in points, from centred.
struct PhotoZoom: Equatable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero

    /// The scale and offset a live gesture is measured from. Held here rather
    /// than in a `@GestureState` so a pinch and a drag can overlap without
    /// either losing its anchor.
    var pinchBase: CGFloat?
    var panBase: CGSize?

    var isFitted: Bool { scale <= 1.0001 }

    static let fitted = PhotoZoom()
}

/// The layout arithmetic for one pass: how big the picture is drawn, what
/// counts as 1:1 here, and which part of the source is on screen.
///
/// 1:1 is one *source pixel per screen pixel* — actual pixels, not one pixel
/// per point. On a 3× phone that is three times smaller than "natural size"
/// would suggest, and it is the only definition under which what you are
/// judging is what the file holds.
struct PhotoZoomGeometry {
    /// The pane the picture is drawn into, in points.
    let container: CGSize
    /// The source's pixel dimensions, oriented as displayed.
    let source: CGSize
    let displayScale: CGFloat

    /// The picture at fit-to-pane, in points.
    var fit: CGSize {
        guard source.width > 0, source.height > 0,
              container.width > 0, container.height > 0 else { return container }
        let factor = min(container.width / source.width, container.height / source.height)
        return CGSize(width: source.width * factor, height: source.height * factor)
    }

    /// The `scale` at which one source pixel covers one screen pixel.
    ///
    /// Below 1 for a source with fewer pixels than the pane has — a small JPEG
    /// on a 3× phone is already past actual pixels the moment it is fitted.
    /// Left unclamped so the readout stays honest there; `hasPixelsToReveal`
    /// is what decides whether the 1:1 toggle has anything to offer.
    var oneToOne: CGFloat {
        let fitted = fit
        guard fitted.width > 0 else { return 1 }
        return (source.width / displayScale) / fitted.width
    }

    /// True when the source holds more pixels than the fitted view shows, so
    /// zooming to 1:1 reveals something rather than just magnifying.
    var hasPixelsToReveal: Bool { oneToOne > 1.001 }

    /// Zooming out past fit is never useful — the picture is already whole —
    /// so fit is the floor. The ceiling is the design's 8×, or 1:1 where a
    /// large picture on a small pane puts that further out.
    var maximumScale: CGFloat { max(8, oneToOne) }

    /// Where the 1:1 toggle jumps to. Fit is still the floor, so on a source
    /// with nothing to reveal this is fit — which is why the toggle hides
    /// itself there rather than pretending.
    var actualPixelScale: CGFloat { clamped(scale: oneToOne) }

    func clamped(scale: CGFloat) -> CGFloat {
        min(max(scale, 1), maximumScale)
    }

    /// Keeps the picture's edges from being dragged inside the pane: pan is
    /// only ever over what is off screen.
    func clamped(offset: CGSize, scale: CGFloat) -> CGSize {
        let drawn = drawnSize(scale: scale)
        let limitX = max(0, (drawn.width - container.width) / 2)
        let limitY = max(0, (drawn.height - container.height) / 2)
        return CGSize(
            width: min(max(offset.width, -limitX), limitX),
            height: min(max(offset.height, -limitY), limitY))
    }

    func drawnSize(scale: CGFloat) -> CGSize {
        CGSize(width: fit.width * scale, height: fit.height * scale)
    }

    /// Which part of the source is on screen, normalised with a top-left
    /// origin.
    func visibleRegion(scale: CGFloat, offset: CGSize) -> CGRect {
        let drawn = drawnSize(scale: scale)
        guard drawn.width > 0, drawn.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        func span(drawn: CGFloat, container: CGFloat, offset: CGFloat) -> (CGFloat, CGFloat) {
            let low = min(max(((drawn - container) / 2 - offset) / drawn, 0), 1)
            let high = min(max(((drawn + container) / 2 - offset) / drawn, 0), 1)
            return (low, max(high, low))
        }
        let (x0, x1) = span(drawn: drawn.width, container: container.width, offset: offset.width)
        let (y0, y1) = span(drawn: drawn.height, container: container.height, offset: offset.height)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The offset that centres `point` (normalised) in the pane at `scale`.
    func offsetCentring(_ point: CGPoint, scale: CGFloat) -> CGSize {
        let drawn = drawnSize(scale: scale)
        return clamped(
            offset: CGSize(
                width: (0.5 - point.x) * drawn.width,
                height: (0.5 - point.y) * drawn.height),
            scale: scale)
    }
}

// MARK: - Chips

/// The pixel-peep readout: "1:1" when the picture is at actual pixels, and the
/// percentage of them otherwise. Only worth showing once the picture has left
/// fit scale, which is the one state that needs no explaining.
struct PixelScaleBadge: View {
    let scale: CGFloat
    let oneToOne: CGFloat

    private var isOneToOne: Bool { abs(scale - oneToOne) / max(oneToOne, 0.001) < 0.02 }

    private var label: String {
        guard !isOneToOne else { return "1:1" }
        return "\(Int((scale / max(oneToOne, 0.001) * 100).rounded()))%"
    }

    var body: some View {
        Text(label)
            .font(.system(size: 11.5, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(isOneToOne ? Color.black : Color.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isOneToOne
                               ? AnyShapeStyle(LL.amber)
                               : AnyShapeStyle(Color.black.opacity(0.55))))
            .accessibilityLabel(isOneToOne ? "Actual pixels" : "\(label) of actual pixels")
    }
}

/// The detail loupe: a square of the frame at actual pixels, floated over the
/// picture while a Detail slider is moving.
///
/// It is deliberately not a magnifier that follows a finger — the finger is on
/// a slider at the other end of the screen. It sits still, over the busiest
/// part of the frame (`PhotoDetailFocus`), so what changes while you drag is
/// the noise and the edges rather than the framing.
struct DetailLoupe: View {
    let image: CGImage?
    /// The screen scale the patch was cut for, so it draws at actual pixels.
    let displayScale: CGFloat
    let side: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: displayScale)
                    .interpolation(.none)
                    .antialiased(false)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: side, height: side)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(LL.amber, lineWidth: 1.5))
        .overlay(alignment: .bottomLeading) {
            Text("Detail")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(8)
        }
        .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Where to point it

/// Finds the part of a frame worth looking at closely.
///
/// The loupe has to land somewhere before anybody has told it where, and the
/// middle of the frame is as often as not sky. So: sum the absolute Laplacian
/// — the second derivative of luma, which is what both fine detail and noise
/// look like — over a grid of tiles, and take the busiest one. Run once per
/// frame off the main actor; the answer is a point, and it costs one small
/// grayscale draw.
enum PhotoDetailFocus {
    /// The busiest tile's centre, normalised, or nil if the image can't be
    /// read. Kept away from the very edge so a loupe centred on it still has a
    /// full square of picture to show.
    static func busiestPoint(in image: CGImage, tiles: Int = 8) -> CGPoint? {
        let longEdge = 512
        let scale = min(1, CGFloat(longEdge) / CGFloat(max(image.width, image.height)))
        let width = max(Int((CGFloat(image.width) * scale).rounded()), tiles * 4)
        let height = max(Int((CGFloat(image.height) * scale).rounded()), tiles * 4)
        // Gamma-encoded rather than linear grey: noise is judged by eye, and
        // the eye's own weighting is what puts the shadows' grain on the same
        // footing as the highlights' detail.
        guard let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: space,
                bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)

        var energy = [Double](repeating: 0, count: tiles * tiles)
        for y in 1..<(height - 1) {
            let row = y * width
            let tileY = min(y * tiles / height, tiles - 1)
            for x in 1..<(width - 1) {
                let centre = Int(pixels[row + x]) * 4
                let neighbours = Int(pixels[row + x - 1]) + Int(pixels[row + x + 1])
                    + Int(pixels[row - width + x]) + Int(pixels[row + width + x])
                let laplacian = abs(centre - neighbours)
                energy[tileY * tiles + min(x * tiles / width, tiles - 1)] += Double(laplacian)
            }
        }
        guard let best = energy.indices.max(by: { energy[$0] < energy[$1] }),
              energy[best] > 0 else { return nil }
        let step = 1.0 / CGFloat(tiles)
        let point = CGPoint(
            x: (CGFloat(best % tiles) + 0.5) * step,
            y: (CGFloat(best / tiles) + 0.5) * step)
        return CGPoint(
            x: min(max(point.x, 0.15), 0.85),
            y: min(max(point.y, 0.15), 0.85))
    }
}

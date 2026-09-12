import CoreGraphics
import Foundation
#if canImport(CoreImage)
import CoreImage
#endif

/// A project's crop — the Edit screen's Crop panel, persisted as a rectangle
/// of the LEVELLED frame's unit square plus the aspect it was drawn under.
///
/// Normalized rather than in pixels, so one crop serves every render size the
/// same picture goes out at (the 240 px thumbnail, the fit preview, the 4032
/// px export) and survives a re-decode at a different scale. It is expressed
/// in the frame AFTER `FrameRotation` has levelled it, because that is the
/// picture the photographer drew the frame over: a straighten applied later
/// would otherwise move the crop off the thing it was framing.
///
/// **Orientation.** The normalized space has its origin at the TOP-LEFT and
/// y running DOWN — the space overlays, masks, text layers and detail patches
/// already live in, and the one `CGImage.cropping(to:)` uses. Core Image is
/// y-up, and `apply(_:to:)` for a `CIImage` owns that flip so no caller has
/// to. Points and rectangles here are never Core Image coordinates.
///
/// A crop is deliberately not a colour: the engine never sees it, presets do
/// not carry it, and the Original/Edited verdict ignores it — the same
/// treatment `PhotoAdjustments.rotationDegrees` gets, for the same reason: it
/// belongs to one photograph, not to a look.
public struct FrameCrop: Codable, Equatable, Hashable, Sendable {

    /// The aspect the frame is locked to. `original` and `custom` carry no
    /// ratio: the first means "the whole frame", the second "whatever the
    /// photographer dragged".
    public enum Aspect: String, Codable, CaseIterable, Sendable {
        case original, square, fourFive, sixteenNine, nineSixteen, custom

        /// Width ÷ height, in pixel terms; nil where the aspect is free.
        public var ratio: Double? {
            switch self {
            case .original, .custom: return nil
            case .square: return 1
            case .fourFive: return 4.0 / 5.0
            case .sixteenNine: return 16.0 / 9.0
            case .nineSixteen: return 9.0 / 16.0
            }
        }

        /// The chip's caption.
        public var label: String {
            switch self {
            case .original: return "Original"
            case .square: return "1:1"
            case .fourFive: return "4:5"
            case .sixteenNine: return "16:9"
            case .nineSixteen: return "9:16"
            case .custom: return "Custom"
            }
        }
    }

    /// Normalized 0…1 over the levelled frame, origin top-left, y down.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var aspect: Aspect

    public init(x: Double, y: Double, width: Double, height: Double, aspect: Aspect) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.aspect = aspect
    }

    /// The whole frame, uncropped.
    public static let full = FrameCrop(x: 0, y: 0, width: 1, height: 1, aspect: .original)

    /// The crop as a rect in the same normalized, top-left space.
    public var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// The smallest a crop may be on either side, as a fraction of the frame.
    /// A twentieth of the picture is already a thumbnail of it; below that a
    /// corner handle cannot be told from the frame it is on.
    public static let minimumSide: Double = 0.05

    /// True when the crop keeps the whole frame — within half a thousandth,
    /// so the sub-pixel noise a handle drag leaves behind still reads as
    /// "no crop" and `apply` returns the picture untouched.
    public var isFull: Bool {
        width >= 0.9995 && height >= 0.9995
    }

    // MARK: - Fitting and clamping

    /// The centred, largest rectangle of `aspect` that fits inside a frame of
    /// `frameAspect` (width ÷ height, in pixels). `.original` and `.custom`
    /// have no ratio to fit, so they come back as the full frame under that
    /// aspect.
    ///
    /// In the normalized square a crop of pixel ratio r has width/height =
    /// r ÷ frameAspect, so a crop wider than the frame fills the width and a
    /// narrower one fills the height.
    public static func fitted(_ aspect: Aspect, frameAspect: Double) -> FrameCrop {
        guard let ratio = aspect.ratio, frameAspect > 0, ratio > 0 else {
            return FrameCrop(x: 0, y: 0, width: 1, height: 1, aspect: aspect)
        }
        let normalizedRatio = ratio / frameAspect
        let width: Double
        let height: Double
        if normalizedRatio >= 1 {
            width = 1
            height = 1 / normalizedRatio
        } else {
            width = normalizedRatio
            height = 1
        }
        return FrameCrop(
            x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height, aspect: aspect)
    }

    /// This crop brought back inside the frame: at least `minimumSide` on
    /// each side, never past 0…1, and — when the aspect carries a ratio —
    /// with that ratio held exactly in frame terms, the width deciding and
    /// the height following. A drag that pushed a corner past the edge lands
    /// here, as does a stored crop from a frame of another shape.
    public func clamped(frameAspect: Double) -> FrameCrop {
        var out = self
        let minimum = Self.minimumSide
        if let ratio = aspect.ratio, frameAspect > 0, ratio > 0 {
            let normalizedRatio = ratio / frameAspect
            // The widest the crop can be and still fit, and the narrowest it
            // can be with both sides at least the minimum. On a frame so
            // extreme that the two disagree, fitting wins: a crop that fits is
            // a crop, a crop that spills is not.
            let widest = min(1, normalizedRatio)
            let narrowest = max(minimum, minimum * normalizedRatio)
            let width = narrowest <= widest
                ? min(max(self.width, narrowest), widest)
                : widest
            out.width = width
            out.height = width / normalizedRatio
        } else {
            out.width = min(max(width, minimum), 1)
            out.height = min(max(height, minimum), 1)
        }
        out.x = min(max(x, 0), 1 - out.width)
        out.y = min(max(y, 0), 1 - out.height)
        return out
    }

    // MARK: - Pixels

    /// The crop in the pixels of a `size` frame: integer, every edge on an
    /// even coordinate, at least 2 × 2, and inside the frame.
    ///
    /// Even because the crop feeds video as well as stills — a 4:2:0 encoder
    /// wants even dimensions, and an even origin keeps the chroma grid where
    /// it was so a cropped frame is not resampled in colour. Losing under a
    /// pixel on each side is invisible; a chroma shift across a whole clip is
    /// not.
    public func pixelRect(in size: CGSize) -> CGRect {
        func even(_ value: Double) -> Int { Int((value / 2).rounded()) * 2 }
        func evenFloor(_ value: Double) -> Int { Int((value / 2).rounded(.down)) * 2 }
        // The frame's own even floor is the most a crop can take, so an
        // odd-sized picture loses its last row and column here rather than
        // spilling past its edge.
        let frameWidth = max(evenFloor(Double(size.width)), 2)
        let frameHeight = max(evenFloor(Double(size.height)), 2)
        // A crop read from a damaged file is the whole frame, not a trap —
        // and "damaged" has to include the finite-but-absurd (a hand-edited
        // `x` of 1e300 survives decoding), because `Int(_:)` traps on a
        // Double past its range and every render of the project would go
        // down with it. Anything well outside the unit square is not a crop;
        // the hair of slack is for handle noise, which the min/max below
        // already absorb.
        let unit = -0.01...1.01
        guard [x, y, width, height].allSatisfy({ $0.isFinite && unit.contains($0) }) else {
            return CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight)
        }
        let cropWidth = min(max(even(width * Double(size.width)), 2), frameWidth)
        let cropHeight = min(max(even(height * Double(size.height)), 2), frameHeight)
        let originX = min(max(even(x * Double(size.width)), 0), frameWidth - cropWidth)
        let originY = min(max(even(y * Double(size.height)), 0), frameHeight - cropHeight)
        return CGRect(x: originX, y: originY, width: cropWidth, height: cropHeight)
    }

    /// The size a `size` frame leaves with after this crop — the frame itself
    /// when the crop is full, so an uncropped odd-sized picture is not quietly
    /// trimmed to even.
    public func outputSize(for size: CGSize) -> CGSize {
        isFull ? size : pixelRect(in: size).size
    }

    /// `image` cropped, in its own pixels (top-left origin, as `CGImage`
    /// counts). The image itself when the crop is full or the cut fails.
    public static func apply(_ crop: FrameCrop, to image: CGImage) -> CGImage {
        guard !crop.isFull else { return image }
        let rect = crop.pixelRect(in: CGSize(width: image.width, height: image.height))
        return image.cropping(to: rect) ?? image
    }

    #if canImport(CoreImage)
    /// `image` cropped and moved back to the origin, so the result's extent is
    /// `(0, 0, w, h)` — what a video composition's render size and a writer's
    /// pixel buffer expect. The crop is computed over the image's extent
    /// (which need not sit at zero) with a top-left origin, then flipped into
    /// Core Image's y-up space: the top edge of the crop is `extent.maxY −
    /// pixelRect.minY`. Unchanged when the crop is full, so callers can apply
    /// it unconditionally.
    public static func apply(_ crop: FrameCrop, to image: CIImage) -> CIImage {
        guard !crop.isFull else { return image }
        let extent = image.extent
        guard extent.width >= 2, extent.height >= 2, !extent.isInfinite else { return image }
        let rect = crop.pixelRect(in: extent.size)
        let ciRect = CGRect(
            x: extent.minX + rect.minX,
            y: extent.maxY - rect.maxY,
            width: rect.width,
            height: rect.height)
        return image
            .cropped(to: ciRect)
            .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))
    }
    #endif

    // MARK: - Cache key

    /// A short, stable string identifying this crop for cache keys —
    /// `c0.1000,0.2000,0.8000,0.6000:sixteenNine`. Four decimals: a
    /// ten-thousandth of a 4K frame is under half a pixel, so two crops that
    /// print the same render the same.
    public var cacheToken: String {
        String(format: "c%.4f,%.4f,%.4f,%.4f:", x, y, width, height) + aspect.rawValue
    }

    // MARK: - Point mapping

    /// Where a point of the FULL frame lands in the cropped picture. Both
    /// points are normalized 0…1 over their frame, top-left origin — the
    /// space overlays and text layers are stored in. A point in the
    /// cropped-away margin comes back outside 0…1, which is the honest
    /// answer: that spot is no longer in the picture.
    public func mapPointIn(_ p: CGPoint) -> CGPoint {
        guard width > 0, height > 0 else { return p }
        return CGPoint(x: (p.x - x) / width, y: (p.y - y) / height)
    }

    /// The inverse of `mapPointIn`: which point of the full frame a point of
    /// the cropped picture shows.
    public func mapPointOut(_ p: CGPoint) -> CGPoint {
        CGPoint(x: x + p.x * width, y: y + p.y * height)
    }
}

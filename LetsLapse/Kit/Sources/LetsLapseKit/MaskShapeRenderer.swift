import CoreGraphics
import CoreImage
import Foundation

/// Turns a `MaskShape`'s numbers into the grayscale image the compositor
/// selects with — white where the mask applies, black where it does not,
/// feathered between.
///
/// Core Image's own gradient generators rather than a kernel of our own: they
/// are infinite-extent and resolution-independent, which is the whole point
/// of a parametric mask, and the ramp they draw is exactly the one
/// `MaskShape.coverage(at:in:)` defines and the Kit's tests pin.
///
/// **Two coordinate flips live here, and only here.** `MaskShape` is stored
/// in the picture's own top-left space (0…1, y down), the way `SceneOverlay`
/// and `PhotoGrader.DetailPatch.region` are. Core Image works bottom-left
/// with y up. Every point crosses over in `ciPoint`, and the rotation
/// crosses with it — a turn that is clockwise on screen is anticlockwise once
/// y points the other way.
///
/// **No levelling.** Unlike the segmentation grid, a drawn shape is authored
/// on the picture the editor shows — which is already levelled — so it lives
/// in OUTPUT space and needs no rotation to stay registered, exactly like a
/// text layer.
///
/// In the Kit (moved from the app 2026-09-07) so the render bench can draw
/// the same selection the editor draws: `MaskedGradeStage` is the other half.
public enum MaskShapeRenderer {

    /// One shared context for the thumbnails. The composite path never comes
    /// through here: it keeps everything as `CIImage` until the frame is
    /// rendered once at the end.
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// The shape as a selection mask over `extent`. White selects.
    ///
    /// `inverted` swaps the two ends, which is what an inverted `MaskGrade`
    /// applies through — "outside this shape" rather than inside it.
    public static func maskImage(_ shape: MaskShape, extent: CGRect, inverted: Bool = false) -> CIImage? {
        let size = extent.size
        guard size.width > 0, size.height > 0 else { return nil }
        let selected = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        let unselected = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        let inside = inverted ? unselected : selected
        let outside = inverted ? selected : unselected
        let image: CIImage?
        switch shape.kind {
        case .linear:
            image = linearGradient(shape, size: size, inside: inside, outside: outside)
        case .radial:
            image = radialGradient(shape, size: size, inside: inside, outside: outside)
        }
        // Generators are infinite; the compositor blends against a frame.
        return image?.cropped(to: extent)
    }

    // MARK: - The two gradients

    private static func linearGradient(
        _ shape: MaskShape, size: CGSize, inside: CIColor, outside: CIColor
    ) -> CIImage? {
        guard let filter = CIFilter(name: "CILinearGradient") else { return nil }
        // The band the transition happens across: fully selected at `near`,
        // fully unselected at `far`, both on the start→end axis.
        let band = shape.linearFeatherPoints(in: size)
            // Feather 0 is a hard edge on the 50% line. A generator needs two
            // distinct points to have a direction at all, so the "band" is
            // half a point wide either side of the midpoint — under a pixel,
            // which reads as the step it is meant to be.
            ?? hardEdgeBand(shape, size: size)
        filter.setValue(CIVector(cgPoint: ciPoint(band.near, in: size)), forKey: "inputPoint0")
        filter.setValue(CIVector(cgPoint: ciPoint(band.far, in: size)), forKey: "inputPoint1")
        filter.setValue(inside, forKey: "inputColor0")
        filter.setValue(outside, forKey: "inputColor1")
        return filter.outputImage
    }

    /// The degenerate band a feather-0 linear mask needs: a sub-pixel step
    /// centred on the 50% line, pointing the way the shape does.
    private static func hardEdgeBand(
        _ shape: MaskShape, size: CGSize
    ) -> (near: CGPoint, far: CGPoint) {
        let mid = shape.linearMidpoint(in: size)
        let start = shape.startPoint(in: size), end = shape.endPoint(in: size)
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(hypot(dx, dy), .ulpOfOne)
        let step = CGPoint(x: dx / length * 0.5, y: dy / length * 0.5)
        return (CGPoint(x: mid.x - step.x, y: mid.y - step.y),
                CGPoint(x: mid.x + step.x, y: mid.y + step.y))
    }

    private static func radialGradient(
        _ shape: MaskShape, size: CGSize, inside: CIColor, outside: CIColor
    ) -> CIImage? {
        guard let filter = CIFilter(name: "CIRadialGradient") else { return nil }
        let radiusX = shape.radiusXPoints(in: size)
        let radiusY = shape.radiusYPoints(in: size)
        guard radiusX > 0, radiusY > 0 else { return nil }
        let feather = min(max(shape.feather, 0), 1)
        // Generated as a CIRCLE of the +x radius at the origin, then stretched
        // into the ellipse, turned, and moved into place. Doing it this way
        // round means the feather stays a constant fraction of the radius on
        // both axes — which is what "inside 1 − feather is fully selected"
        // says, and what a circle-and-squash gets right and an ellipse filter
        // would not.
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        // A hard edge still needs two radii: half a point inside the outline.
        let inner = feather > 0 ? radiusX * (1 - feather) : max(radiusX - 0.5, 0)
        filter.setValue(inner, forKey: "inputRadius0")
        filter.setValue(radiusX, forKey: "inputRadius1")
        filter.setValue(inside, forKey: "inputColor0")
        filter.setValue(outside, forKey: "inputColor1")
        guard let gradient = filter.outputImage else { return nil }
        let centre = ciPoint(shape.centerPoint(in: size), in: size)
        // Read right to left: squash to the ellipse, turn it, put it in place.
        // `.rotated`/`.scaledBy` prepend, so this is the order a point travels.
        let transform = CGAffineTransform(translationX: centre.x, y: centre.y)
            .rotated(by: -shape.rotationDegrees * .pi / 180)
            .scaledBy(x: 1, y: CGFloat(radiusY / radiusX))
        return gradient.transformed(by: transform)
    }

    /// A picture-space point (top-left origin) in Core Image's space.
    private static func ciPoint(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x, y: size.height - point.y)
    }

    // MARK: - Thumbnails

    /// The little ink-and-white tile the Masks card and the deck draw: the
    /// SELECTED region white on `LL.ink`, unselected in ink — "which pixels
    /// does this one touch", at a glance.
    ///
    /// The inverted tile needs no special case. An inverted grade selects
    /// outside the shape, `maskImage(inverted:)` is already white there, and
    /// painting white-where-selected then draws the brief's "white ground,
    /// ink region" on its own.
    ///
    /// Rendered rather than drawn in SwiftUI so a shape and a segmentation
    /// mask can sit side by side in the same strip looking like the same kind
    /// of thing.
    public static func thumbnail(_ shape: MaskShape, size: CGSize, inverted: Bool = false) -> CGImage? {
        let extent = CGRect(origin: .zero, size: size)
        let ink = CIImage(color: CIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1))
            .cropped(to: extent)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: extent)
        guard let mask = maskImage(shape, extent: extent, inverted: inverted),
              let blend = CIFilter(name: "CIBlendWithMask")
        else { return nil }
        blend.setValue(white, forKey: kCIInputImageKey)
        blend.setValue(ink, forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)
        guard let output = blend.outputImage else { return nil }
        return context.createCGImage(output, from: extent, format: .RGBA8,
                                     colorSpace: CGColorSpaceCreateDeviceRGB())
    }
}

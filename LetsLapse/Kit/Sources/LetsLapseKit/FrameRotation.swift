import Foundation
import CoreGraphics
#if canImport(CoreImage)
import CoreImage
#endif

/// A project's fine rotation — the Edit screen's straighten control, a few
/// degrees either way to level a horizon the tripod didn't.
///
/// The transform is one thing everywhere it is applied: rotate the frame
/// about its centre, crop to the largest rectangle of the ORIGINAL aspect
/// that still lies inside the rotated picture (so no corner is ever black),
/// and scale that crop back up to the original pixel size. Output geometry
/// is therefore identical to input geometry — same width, same height, same
/// aspect — which is what lets every downstream consumer (overlays, masks,
/// canvas crops, reframe keys, the writer's pixel-buffer pool) stay
/// untouched. The price is a resample and a loss of usable pixels that grows
/// with the angle (about 23% of each edge at the full 10° on 16:9), which is
/// the deliberate trade: the range exists to adjust a capture that was shot
/// close to level, not to rotate one that was shot sideways.
///
/// Sign convention: **positive degrees rotate the picture clockwise as
/// displayed** — the same direction SwiftUI's `rotationEffect` and Core
/// Graphics' top-left-origin coordinates read a positive angle. Core Image's
/// y-up space needs the opposite sign, and `ciTransform` owns that flip so no
/// caller has to remember it.
public enum FrameRotation {
    /// The slider's travel, in degrees. Symmetric, so the control rests in the
    /// middle like Exposure does.
    public static let range: ClosedRange<Double> = -10...10

    /// Below this the rotation is treated as none at all: no resample, no
    /// crop, the original pixels. A hundredth of a degree is a fraction of a
    /// pixel across a 4K frame.
    public static let epsilon: Double = 0.005

    /// A stored angle brought back inside the slider's range, with the
    /// sub-epsilon noise a slider tick can leave behind snapped to zero.
    public static func clamped(_ degrees: Double) -> Double {
        let bounded = min(max(degrees, range.lowerBound), range.upperBound)
        return abs(bounded) < epsilon ? 0 : bounded
    }

    /// True when `degrees` would change a pixel.
    public static func isActive(_ degrees: Double) -> Bool {
        abs(degrees) >= epsilon
    }

    /// The largest same-aspect rectangle that fits inside a `width × height`
    /// frame rotated by `degrees`, as a fraction of the frame's own size.
    /// 1 at zero degrees; 0.773 at ten degrees on 16:9.
    ///
    /// Derivation: the inscribed rectangle's corner, rotated back into the
    /// source, must stay inside the source. For a corner at (sW/2, sH/2)
    /// that gives `s ≤ W / (W·cos θ + H·sin θ)` on the x axis and
    /// `s ≤ H / (W·sin θ + H·cos θ)` on the y axis; the tighter one wins,
    /// which is always the short edge's.
    public static func inscribedScale(width: Double, height: Double, degrees: Double) -> Double {
        guard width > 0, height > 0, isActive(degrees) else { return 1 }
        let theta = abs(degrees) * .pi / 180
        let (c, s) = (cos(theta), sin(theta))
        let byWidth = width / (width * c + height * s)
        let byHeight = height / (width * s + height * c)
        return min(byWidth, byHeight, 1)
    }

    /// The crop `rotated(_:)` keeps, in the ROTATED frame's own pixels with a
    /// top-left origin: centred, same aspect as the frame, scaled by
    /// `inscribedScale`.
    public static func cropRect(in size: CGSize, degrees: Double) -> CGRect {
        let scale = inscribedScale(width: size.width, height: size.height, degrees: degrees)
        let cropped = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: (size.width - cropped.width) / 2, y: (size.height - cropped.height) / 2,
            width: cropped.width, height: cropped.height)
    }

    // MARK: - Point mapping

    /// Where a point of the ORIGINAL frame lands in the rotated-and-cropped
    /// output. Both points are normalized 0…1 over their frame, top-left
    /// origin — the space overlays and detail patches live in. Points that
    /// fall in the cropped-away margin come back outside 0…1, which is the
    /// honest answer: that pixel is no longer in the picture.
    public static func sourceToOutput(
        _ point: CGPoint, width: Double, height: Double, degrees: Double
    ) -> CGPoint {
        guard isActive(degrees), width > 0, height > 0 else { return point }
        let scale = inscribedScale(width: width, height: height, degrees: degrees)
        let theta = degrees * .pi / 180
        let (c, s) = (cos(theta), sin(theta))
        // Centre the frame, rotate in y-down pixel space (clockwise for a
        // positive angle), then express against the crop's own size.
        let u = (point.x - 0.5) * width
        let v = (point.y - 0.5) * height
        let ru = u * c - v * s
        let rv = u * s + v * c
        return CGPoint(
            x: ru / (width * scale) + 0.5,
            y: rv / (height * scale) + 0.5)
    }

    /// The inverse of `sourceToOutput`: which point of the original frame a
    /// point of the output shows.
    public static func outputToSource(
        _ point: CGPoint, width: Double, height: Double, degrees: Double
    ) -> CGPoint {
        guard isActive(degrees), width > 0, height > 0 else { return point }
        let scale = inscribedScale(width: width, height: height, degrees: degrees)
        let theta = -degrees * .pi / 180
        let (c, s) = (cos(theta), sin(theta))
        let ru = (point.x - 0.5) * width * scale
        let rv = (point.y - 0.5) * height * scale
        let u = ru * c - rv * s
        let v = ru * s + rv * c
        return CGPoint(x: u / width + 0.5, y: v / height + 0.5)
    }

    /// Re-expresses a point pinned to the SCENE from one rotation's output
    /// space to another's — what keeps a text layer on the same rock when the
    /// horizon is levelled after the text was placed.
    public static func remap(
        _ point: CGPoint, width: Double, height: Double, from old: Double, to new: Double
    ) -> CGPoint {
        let source = outputToSource(point, width: width, height: height, degrees: old)
        return sourceToOutput(source, width: width, height: height, degrees: new)
    }

    /// How much a scene-pinned length grows going from one rotation to
    /// another: the crop-in zooms the picture, so anything attached to it
    /// zooms too. 1 when nothing changes.
    public static func lengthScale(width: Double, height: Double, from old: Double, to new: Double) -> Double {
        let before = inscribedScale(width: width, height: height, degrees: old)
        let after = inscribedScale(width: width, height: height, degrees: new)
        guard after > 0 else { return 1 }
        return before / after
    }

    // MARK: - Core Image

    #if canImport(CoreImage)
    /// The whole transform as one Core Image graph over `image`, whose
    /// extent must be the frame (origin at zero). The result has exactly the
    /// same extent. Unchanged when the angle is inactive, so callers can
    /// apply it unconditionally.
    ///
    /// Rotation about the centre, Lanczos back up to size: one resample,
    /// the same kernel the reframe and canvas croppers already use, so a
    /// rotated blend is filtered the way every other geometry pass is.
    public static func rotated(_ image: CIImage, degrees: Double) -> CIImage {
        guard isActive(degrees) else { return image }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = inscribedScale(width: extent.width, height: extent.height, degrees: degrees)
        guard scale > 0 else { return image }
        let center = CGPoint(x: extent.midX, y: extent.midY)
        // Core Image is y-up: a positive CGAffineTransform angle turns
        // counter-clockwise on screen, and this API promises clockwise.
        let spin = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: CGFloat(-degrees * .pi / 180))
            .translatedBy(x: -center.x, y: -center.y)
        // Sample beyond the source edge with the edge itself rather than
        // transparent black: the crop below never reaches those pixels, but
        // the Lanczos kernel's support does, and a transparent fringe would
        // darken the outermost row of the output.
        let rotated = image.clampedToExtent().transformed(by: spin)
        // The crop is snapped INWARD to whole pixels. Core Image's clamp
        // replicates the edge of an image's integral extent, so a crop with a
        // fractional origin leaves a sliver of transparency between the true
        // edge and the replicated one — which the resample then blends into
        // the output's outer row (alpha 148 at the corner pixel, measured).
        // Losing under a pixel on each side is invisible; the fringe is not.
        let raw = CGRect(
            x: center.x - extent.width * scale / 2,
            y: center.y - extent.height * scale / 2,
            width: extent.width * scale,
            height: extent.height * scale)
        let crop = CGRect(
            x: raw.minX.rounded(.up), y: raw.minY.rounded(.up),
            width: raw.maxX.rounded(.down) - raw.minX.rounded(.up),
            height: raw.maxY.rounded(.down) - raw.minY.rounded(.up))
        guard crop.width >= 2, crop.height >= 2 else { return image }
        // Cropped, then clamped again, so the resample below reads replicated
        // picture past the crop's edge rather than transparent black.
        let cropped = rotated.cropped(to: crop).clampedToExtent()
        // Per-axis, because the pixel snap above can leave the two axes a
        // fraction of a pixel apart in aspect; the output must be exactly
        // the input's size.
        let scaleX = extent.width / crop.width
        let scaleY = extent.height / crop.height
        let scaled: CIImage
        if let lanczos = CIFilter(name: "CILanczosScaleTransform") {
            lanczos.setValue(cropped, forKey: kCIInputImageKey)
            lanczos.setValue(scaleY, forKey: kCIInputScaleKey)
            lanczos.setValue(scaleX / scaleY, forKey: kCIInputAspectRatioKey)
            scaled = lanczos.outputImage
                ?? cropped.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        } else {
            scaled = cropped.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }
        // The resample scales about the origin, so the crop's corner lands at
        // (crop.origin × scale); bring it back to the frame's own origin —
        // exactly, by construction — and trim to the frame.
        let back = CGAffineTransform(
            translationX: extent.minX - crop.minX * scaleX,
            y: extent.minY - crop.minY * scaleY)
        return scaled.transformed(by: back).cropped(to: extent)
    }
    #endif
}

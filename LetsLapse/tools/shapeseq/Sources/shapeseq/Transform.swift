import Foundation
import CoreGraphics

enum RenderVariant: String, CaseIterable { case centred, aligned }
enum RotationMode: String { case major, none }

/// Source-pixel (y-down) → output-pixel (y-down) transforms for one anchor.
enum AnchorTransform {
    struct Frame { let width: Int; let height: Int; var rect: CGRect { CGRect(x: 0, y: 0, width: width, height: height) } }

    /// Scale applied to native pixels so the shape's major axis hits the target.
    static func scaleFactor(anchor: ShapeAnchor, native: (Int, Int), frame: Frame, targetFraction: Double) -> Double {
        let target = targetFraction * Double(frame.height)
        let majorPx = Double(anchor.majorAxis) * Double(native.0)
        return majorPx > 0 ? target / majorPx : 1
    }

    static func homography(anchor: ShapeAnchor, native: (Int, Int), frame: Frame, targetFraction: Double,
                           variant: RenderVariant, rotation: RotationMode, medianAspect: Double?) -> Homography? {
        let W = Double(native.0)
        let cx = Double(anchor.centre.x) * W, cy = Double(anchor.centre.y) * Double(native.1)
        let ox = Double(frame.width) / 2, oy = Double(frame.height) / 2
        let s = scaleFactor(anchor: anchor, native: native, frame: frame, targetFraction: targetFraction)
        let theta = Double(anchor.rotation)
        let toOrigin = Homography.translate(-cx, -cy)
        let toCentre = Homography.translate(ox, oy)
        let rot: Homography = {
            switch (anchor.kind, rotation) {
            case (.quad, _): return Homography.rotate(-theta)          // level the top edge
            case (.ellipse, .major): return Homography.rotate(-theta)  // major axis → horizontal
            case (.ellipse, .none): return .identity
            }
        }()
        switch (anchor.kind, variant) {
        case (.ellipse, .centred), (.quad, .centred):
            return toCentre * Homography.scale(s, s) * rot * toOrigin
        case (.ellipse, .aligned):
            // Stretch along the minor axis so the ellipse becomes a circle of radius a.
            let a = Double(anchor.majorAxis), b = Double(anchor.minorAxis)
            guard b > 0 else { return nil }
            let unskew = Homography.rotate(theta) * Homography.scale(1, a / b) * Homography.rotate(-theta)
            return toCentre * Homography.scale(s, s) * rot * unskew * toOrigin
        case (.quad, .aligned):
            guard let c = anchor.corners, c.count == 4 else { return nil }
            let src = c.map { CGPoint(x: Double($0.x) * W, y: Double($0.y) * Double(native.1)) }
            let target = targetFraction * Double(frame.height)
            let aspect = medianAspect ?? quadAspect(anchor)      // width / height
            let dw = aspect >= 1 ? target : target * aspect
            let dh = aspect >= 1 ? target / aspect : target
            let dst = [CGPoint(x: ox - dw / 2, y: oy - dh / 2), CGPoint(x: ox + dw / 2, y: oy - dh / 2),
                       CGPoint(x: ox + dw / 2, y: oy + dh / 2), CGPoint(x: ox - dw / 2, y: oy + dh / 2)]
            return Homography.from(src, to: dst)
        }
    }

    /// width / height of the quad as seen (top-edge mean over side mean).
    static func quadAspect(_ a: ShapeAnchor) -> Double {
        guard let c = a.corners, c.count == 4 else { return 1 }
        func d(_ p: CGPoint, _ q: CGPoint) -> Double { Double(hypot(p.x - q.x, p.y - q.y)) }
        let w = (d(c[0], c[1]) + d(c[3], c[2])) / 2
        let h = (d(c[0], c[3]) + d(c[1], c[2])) / 2
        return h > 0 ? w / h : 1
    }

    /// Fraction of the output frame covered by source pixels under `h` (0 if the
    /// projective transform sends a source corner behind the camera).
    static func coverage(_ h: Homography, native: (Int, Int), frame: Frame) -> Double {
        let W = Double(native.0), H = Double(native.1)
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: W, y: 0), CGPoint(x: W, y: H), CGPoint(x: 0, y: H)]
        for p in corners {
            let w = h.m[6] * Double(p.x) + h.m[7] * Double(p.y) + h.m[8]
            if w <= 1e-9 { return 0 }
        }
        return Polygon.coverage(of: corners.map { h.apply($0) }, in: frame.rect)
    }
}

import SwiftUI
import LetsLapseKit

/// The chrome for a register shape on the picture — the ellipse or rectangle
/// itself and the handles that edit it. Sits where `MaskShapeOverlay` sits,
/// inside `PhotoViewerView.picture` and registered over the drawn image, so
/// every coordinate here is picture points with a top-left origin.
///
/// An ellipse edits like a Radial mask: drag the centre to move it, the two
/// axis handles to size it, the stalk to turn it. A rectangle is four corner
/// handles plus the centre; with the Square lock on, a corner drag scales the
/// whole quad about the opposite corner so a square stays square.
struct RegisterShapeOverlay: View {
    @Binding var shape: DetectedShape
    /// Size of the drawn picture, in points.
    let drawn: CGSize
    /// The frame the register measures in (native pixels), for re-measuring on release.
    let native: CGSize
    var accent: Color = LL.amber
    var squareLock: Bool = false
    let onEditing: (Bool) -> Void
    let onHUD: (String?) -> Void

    private enum Grab: Equatable {
        case move
        case axisX, axisY, rotate
        case corner(Int)
    }

    @State private var grab: Grab?
    @State private var base: DetectedShape?

    private var handleSize: CGFloat { 22 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch shape.kind {
            case .ellipse: ellipseChrome
            case .quad: quadChrome
            }
        }
        .frame(width: drawn.width, height: drawn.height, alignment: .topLeading)
    }

    // MARK: - Geometry in points

    private var centrePt: CGPoint { CGPoint(x: shape.centre.x * drawn.width, y: shape.centre.y * drawn.height) }
    private var semiA: CGFloat { CGFloat(shape.majorAxis) * drawn.width / 2 }
    private var semiB: CGFloat { CGFloat(shape.minorAxis) * drawn.width / 2 }
    private var cornerPts: [CGPoint] {
        (shape.corners ?? []).map { CGPoint(x: $0.x * drawn.width, y: $0.y * drawn.height) }
    }

    private func onAxis(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
        let c = CGFloat(cos(shape.rotation)), s = CGFloat(sin(shape.rotation))
        return CGPoint(x: centrePt.x + dx * c - dy * s, y: centrePt.y + dx * s + dy * c)
    }

    // MARK: - Ellipse

    @ViewBuilder private var ellipseChrome: some View {
        let centre = centrePt
        let a = semiA, b = semiB
        let outline = Path(ellipseIn: CGRect(x: -a, y: -b, width: 2 * a, height: 2 * b))
            .applying(CGAffineTransform(translationX: centre.x, y: centre.y).rotated(by: shape.rotation))
        outline.stroke(Color.white, lineWidth: 1.4)
        outline.stroke(accent.opacity(0.9), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        // Axis ticks.
        Path { p in
            p.move(to: onAxis(-a, 0)); p.addLine(to: onAxis(a, 0))
            p.move(to: onAxis(0, -b)); p.addLine(to: onAxis(0, b))
        }
        .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        // Rotation stalk beyond the east handle.
        let knob = onAxis(a + 34, 0)
        Path { p in p.move(to: onAxis(a, 0)); p.addLine(to: knob) }
            .stroke(Color.white.opacity(0.7), lineWidth: 1)

        handle(at: centre, grab: .move, filled: true, glyph: "arrow.up.and.down.and.arrow.left.and.right")
        squareHandle(at: onAxis(a, 0), grab: .axisX)
        squareHandle(at: onAxis(0, -b), grab: .axisY)
        handle(at: knob, grab: .rotate, filled: false, glyph: "arrow.clockwise")
    }

    // MARK: - Quad

    @ViewBuilder private var quadChrome: some View {
        let pts = cornerPts
        if pts.count == 4 {
            let outline = Path { p in
                p.move(to: pts[0]); for q in pts.dropFirst() { p.addLine(to: q) }; p.closeSubpath()
            }
            outline.stroke(Color.white, lineWidth: 1.4)
            outline.stroke(accent.opacity(0.9), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            handle(at: centrePt, grab: .move, filled: true, glyph: "arrow.up.and.down.and.arrow.left.and.right")
            ForEach(0..<4, id: \.self) { i in
                squareHandle(at: pts[i], grab: .corner(i))
            }
        }
    }

    // MARK: - Handles

    private func handle(at point: CGPoint, grab target: Grab, filled: Bool, glyph: String? = nil) -> some View {
        ZStack {
            Circle()
                .fill(filled ? accent : Color.black.opacity(0.35))
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
            if let glyph {
                Image(systemName: glyph)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: handleSize, height: handleSize)
        .contentShape(Circle().scale(1.6))
        .position(point)
        .gesture(dragGesture(for: target))
    }

    private func squareHandle(at point: CGPoint, grab target: Grab) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(accent, lineWidth: 1.5))
            .frame(width: handleSize * 0.6, height: handleSize * 0.6)
            .contentShape(Rectangle().scale(2.2))
            .position(point)
            .gesture(dragGesture(for: target))
    }

    // MARK: - Gestures

    private func dragGesture(for target: Grab) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(MaskShapeOverlay.space))
            .onChanged { value in
                if grab == nil {
                    grab = target
                    base = shape
                    onEditing(true)
                }
                apply(target, at: value.location, translation: value.translation)
                onHUD(hudCaption())
            }
            .onEnded { _ in
                shape = shape.remeasured(frame: native)
                grab = nil
                base = nil
                onHUD(nil)
                onEditing(false)
            }
    }

    private func apply(_ target: Grab, at point: CGPoint, translation: CGSize) {
        guard let base, drawn.width > 0, drawn.height > 0 else { return }
        let W = drawn.width, H = drawn.height
        let baseCentre = CGPoint(x: base.centre.x * W, y: base.centre.y * H)
        switch target {
        case .move:
            let dx = translation.width / W, dy = translation.height / H
            shape.centre = clamp(CGPoint(x: base.centre.x + dx, y: base.centre.y + dy))
            if let c = base.corners {
                shape.corners = c.map { clamp(CGPoint(x: $0.x + dx, y: $0.y + dy)) }
            }
        case .axisX:
            let a = max(4, projected(point, from: baseCentre, angle: base.rotation).x.magnitude)
            shape.majorAxis = Double(2 * a / W)
        case .axisY:
            let b = max(4, projected(point, from: baseCentre, angle: base.rotation).y.magnitude)
            shape.minorAxis = Double(2 * b / W)
        case .rotate:
            let angle = atan2(Double(point.y - baseCentre.y), Double(point.x - baseCentre.x))
            shape.rotation = angle
        case .corner(let i):
            guard var c = base.corners, c.count == 4 else { return }
            let p = clamp(CGPoint(x: point.x / W, y: point.y / H))
            if squareLock {
                // Scale the whole quad about the opposite corner, along the diagonal.
                let opposite = c[(i + 2) % 4]
                let dBase = CGPoint(x: (c[i].x - opposite.x) * W, y: (c[i].y - opposite.y) * H)
                let dNow = CGPoint(x: (p.x - opposite.x) * W, y: (p.y - opposite.y) * H)
                let len = max(hypot(dBase.x, dBase.y), 1)
                let s = max(0.05, (dNow.x * dBase.x + dNow.y * dBase.y) / (len * len))
                c = c.map { clamp(CGPoint(x: opposite.x + ($0.x - opposite.x) * s, y: opposite.y + ($0.y - opposite.y) * s)) }
            } else {
                c[i] = p
            }
            shape.corners = c
            shape.centre = CGPoint(x: c.map(\.x).reduce(0, +) / 4, y: c.map(\.y).reduce(0, +) / 4)
        }
    }

    /// A point's offset from the centre, expressed along the shape's own axes.
    private func projected(_ point: CGPoint, from centre: CGPoint, angle: Double) -> CGPoint {
        let dx = point.x - centre.x, dy = point.y - centre.y
        let c = CGFloat(cos(angle)), s = CGFloat(sin(angle))
        return CGPoint(x: dx * c + dy * s, y: -dx * s + dy * c)
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
    }

    private func hudCaption() -> String {
        let px = Int(shape.majorAxis * Double(native.width))
        switch shape.kind {
        case .ellipse:
            return "\(shape.displayName) · \(px) px across · \(String(format: "%+.0f°", shape.rotation * 180 / .pi))"
        case .quad:
            let w = Int(shape.aspect >= 1 ? shape.majorAxis * Double(native.width) : shape.minorAxis * Double(native.width))
            let h = Int(shape.aspect >= 1 ? shape.minorAxis * Double(native.width) : shape.majorAxis * Double(native.width))
            return "\(shape.displayName) · \(w)×\(h) px"
        }
    }
}

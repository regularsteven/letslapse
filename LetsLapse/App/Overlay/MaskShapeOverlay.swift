import SwiftUI
import LetsLapseKit

/// The mask chrome drawn over the picture: a shape's handles, the drag that
/// creates one, and the HUD pill that reports what the gesture is doing.
///
/// It sits inside `PhotoViewerView.picture`, registered exactly over the
/// drawn image, so every coordinate here is in the picture's own points with
/// a top-left origin — the space `MaskShape` is defined in. The Kit owns the
/// geometry (`MaskShape.cardinalPoint`, `resized`, `rotated`); this file only
/// draws it and turns gestures into calls.
///
/// **The collision rule.** A drag on the picture means one of three things,
/// and never two at once: with a tool armed it draws a new mask; on a handle
/// it moves the shape (handles always win — a mask can be nudged mid-grade);
/// otherwise, with a slider label armed, it sets that value.
struct MaskShapeOverlay: View {
    /// The shape to draw handles for, and where to write edits back to.
    @Binding var shape: MaskShape
    /// Size of the drawn picture, in points.
    let drawn: CGSize
    var accent: Color = LL.accent
    /// True while the user is dragging, so the caller can suppress its own
    /// pan gesture and re-render at gesture rate.
    let onEditing: (Bool) -> Void
    /// A live caption for the HUD pill, or nil to clear it.
    let onHUD: (String?) -> Void

    /// What the current drag is moving. Captured on the first change of the
    /// gesture and held for its length — every edit is applied to this frozen
    /// base rather than accumulated, the discipline `OverlayDragState` and
    /// `BoxResizeBase` already set in this editor.
    private enum Grab: Equatable {
        case start, end, move
        case cardinal(MaskShape.Cardinal)
        case rotate
    }

    @State private var grab: Grab?
    @State private var base: MaskShape?

    private var handleSize: CGFloat { 22 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch shape.kind {
            case .linear: linearChrome
            case .radial: radialChrome
            }
        }
        .frame(width: drawn.width, height: drawn.height, alignment: .topLeading)
    }

    // MARK: - Linear

    @ViewBuilder private var linearChrome: some View {
        let start = shape.startPoint(in: drawn)
        let end = shape.endPoint(in: drawn)
        let mid = shape.linearMidpoint(in: drawn)
        let normal = shape.linearNormal(in: drawn)
        // Long enough to leave the picture from anywhere in it — the lines
        // are conceptually infinite.
        let reach = Double(drawn.width + drawn.height) * 1.5

        // The connector between the two points.
        Path { path in
            path.move(to: start)
            path.addLine(to: end)
        }
        .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        // The 50% line.
        rule(through: mid, normal: normal, reach: reach)
            .stroke(Color.white, lineWidth: 1.2)

        // The feather band.
        if let band = shape.linearFeatherPoints(in: drawn) {
            rule(through: band.near, normal: normal, reach: reach)
                .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            rule(through: band.far, normal: normal, reach: reach)
                .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }

        handle(at: start, grab: .start, filled: true)
        handle(at: end, grab: .end, filled: false)
    }

    private func rule(through point: CGPoint, normal: CGVector, reach: Double) -> Path {
        Path { path in
            path.move(to: CGPoint(x: point.x - normal.dx * reach, y: point.y - normal.dy * reach))
            path.addLine(to: CGPoint(x: point.x + normal.dx * reach, y: point.y + normal.dy * reach))
        }
    }

    // MARK: - Radial

    @ViewBuilder private var radialChrome: some View {
        let centre = shape.centerPoint(in: drawn)
        let rx = shape.radiusXPoints(in: drawn)
        let ry = shape.radiusYPoints(in: drawn)
        let collapsed = shape.handlesCollapse(in: drawn)

        // The outline. Drawn as an axis-aligned ellipse and then turned about
        // the centre, which is the same transform the mask itself uses.
        Ellipse()
            .fill(Color.white.opacity(0.001))
            .frame(width: rx * 2, height: ry * 2)
            .overlay(Ellipse().stroke(Color.white, lineWidth: 1.2))
            .rotationEffect(.degrees(shape.rotationDegrees))
            .position(centre)
            .gesture(dragGesture(for: .move))

        // The feather boundary.
        Ellipse()
            .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .frame(width: rx * 2 * max(0.05, 1 - shape.feather),
                   height: ry * 2 * max(0.05, 1 - shape.feather))
            .rotationEffect(.degrees(shape.rotationDegrees))
            .position(centre)
            .allowsHitTesting(false)

        // The rotation stalk and its handle.
        let east = shape.cardinalPoint(.east, in: drawn)
        let knob = shape.rotationHandlePoint(in: drawn)
        Path { path in
            path.move(to: east)
            path.addLine(to: knob)
        }
        .stroke(Color.white, lineWidth: 1)
        .allowsHitTesting(false)
        handle(at: knob, grab: .rotate, filled: false, glyph: "arrow.clockwise")

        if collapsed {
            Text("small mask · handles collapsed — zoom in to edit")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .position(x: centre.x, y: min(centre.y + ry + 18, drawn.height - 10))
                .allowsHitTesting(false)
        } else {
            ForEach(Array(MaskShape.Cardinal.allCases.enumerated()), id: \.offset) { _, cardinal in
                squareHandle(at: shape.cardinalPoint(cardinal, in: drawn), cardinal: cardinal)
            }
        }
    }

    // MARK: - Handles

    private func handle(
        at point: CGPoint, grab: Grab, filled: Bool, glyph: String? = nil
    ) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(accent, lineWidth: 1.5))
            .overlay {
                if filled {
                    Circle().fill(accent).frame(width: 5, height: 5)
                } else if let glyph {
                    Image(systemName: glyph)
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(accent)
                }
            }
            .frame(width: 14, height: 14)
            // A bigger invisible target than the drawn dot: 14 pt is right to
            // look at and small to hit, on a trackpad and hopeless on glass.
            .frame(width: handleSize, height: handleSize)
            .contentShape(Circle())
            .position(point)
            .gesture(dragGesture(for: grab))
    }

    private func squareHandle(at point: CGPoint, cardinal: MaskShape.Cardinal) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(accent, lineWidth: 1.5))
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(shape.rotationDegrees))
            .frame(width: handleSize, height: handleSize)
            .contentShape(Rectangle())
            .position(point)
            .gesture(dragGesture(for: .cardinal(cardinal)))
    }

    // MARK: - Gestures

    private func dragGesture(for target: Grab) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(MaskShapeOverlay.space))
            .onChanged { value in
                if grab != target {
                    grab = target
                    base = shape
                    onEditing(true)
                }
                apply(target, at: value.location, translation: value.translation)
                onHUD(hudCaption(for: target))
            }
            .onEnded { _ in
                grab = nil
                base = nil
                onEditing(false)
                onHUD(nil)
            }
    }

    private func apply(_ target: Grab, at point: CGPoint, translation: CGSize) {
        guard let base else { return }
        switch target {
        case .start:
            shape.start = normalized(point)
        case .end:
            shape.end = normalized(point)
        case .move:
            shape = base.moved(by: translation, in: drawn)
        case .cardinal(let cardinal):
            shape = base.resized(cardinal, to: point, in: drawn)
        case .rotate:
            shape = base.rotated(toward: point, in: drawn)
        }
    }

    /// A picture point as a stored fraction. Linear ends are deliberately
    /// left unclamped — the far end of a gradient often belongs off the
    /// picture — but a drag cannot put one arbitrarily far away either, so it
    /// is bounded to a frame's worth outside.
    private func normalized(_ point: CGPoint) -> CGPoint {
        guard drawn.width > 0, drawn.height > 0 else { return .zero }
        return CGPoint(x: min(max(point.x / drawn.width, -1), 2),
                       y: min(max(point.y / drawn.height, -1), 2))
    }

    private func hudCaption(for target: Grab) -> String {
        switch target {
        case .rotate:
            return String(format: "Rotation  %+.0f°", shape.rotationDegrees)
        default:
            return "\(shape.kind.displayName) · \(shape.sizeCaption(in: drawn))"
        }
    }

    /// The coordinate space the picture registers, so a drag that starts on a
    /// handle reports positions in the picture's own points however the pane
    /// is panned or zoomed.
    static let space = "LLMaskPicture"
}

/// The pill floated at the top of the picture while a mask gesture is
/// running — what is being drawn, moved or set, and to what.
struct MaskHUDPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(Color(red: 43 / 255, green: 43 / 255, blue: 46 / 255).opacity(0.9)))
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

/// The bottom hint that says what a drag on the picture will do right now.
/// Only on screen while something is armed — a tool, or a slider label — so
/// the mode is never a thing to remember.
struct MaskModeHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(LL.amber)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color(red: 43 / 255, green: 43 / 255, blue: 46 / 255).opacity(0.9)))
            .allowsHitTesting(false)
    }
}

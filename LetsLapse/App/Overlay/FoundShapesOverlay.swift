import SwiftUI
import LetsLapseKit

/// What "Find" just found, drawn over the picture as lines before anything
/// is added to the register (2026-09-12): every pending candidate as a thin
/// dashed outline, the ones already added as solid lines, rejected ones not
/// at all, and the hovered one — from the list in the rail or from the
/// picture itself — bold, with a tick / cross pill beside it that does what
/// the list's Add and Reject do. Sits in the same stack as
/// `RegisterShapeOverlay`, so coordinates are picture points with a top-left
/// origin.
///
/// The lines never take hits. Hover is worked out by the viewer from the
/// mouse position over the whole picture (`hoverTarget`): on macOS
/// `.onHover` tracks a view's frame, not its `contentShape`, so a stack of
/// picture-sized outline views always handed the hover to the last one
/// (found 2026-09-12 by Steven). Only the pill is hit-testable.
struct FoundShapesOverlay: View {
    let found: [ShapeFinder.Found]
    let added: Set<UUID>
    let rejected: Set<UUID>
    let hovered: UUID?
    /// Where the mouse touched the hovered outline, when the hover came from
    /// the picture: the pill sits right there, so accepting or rejecting is a
    /// short move that never has to leave the shape (2026-09-12, Steven:
    /// a pill above the bounding box was out of reach past other outlines).
    /// Nil when the hover came from the list.
    let hoverAnchor: CGPoint?
    /// Size of the drawn picture, in points.
    let drawn: CGSize
    let actions: ShapeFinder.FoundActions
    /// Whether the register already holds a candidate — such a one gets a
    /// "Listed" pill, not a tick that would add it twice.
    var isListed: (DetectedShape) -> Bool = { _ in false }
    var accent: Color = LL.amber

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(found.filter { !rejected.contains($0.id) }) { item in
                    let path = Self.outline(item.shape, drawn: drawn)
                    let isHovered = hovered == item.id
                    let isAdded = added.contains(item.id)
                    Group {
                        if isHovered {
                            path.stroke(accent.opacity(0.35), lineWidth: 9)
                        }
                        path.stroke(Color.black.opacity(isHovered ? 0.55 : 0.35), lineWidth: isHovered ? 5 : 3)
                        path.stroke(isAdded ? Color.white : accent,
                                    style: StrokeStyle(lineWidth: isHovered ? 2.6 : 1.4, dash: isAdded || isHovered ? [] : [6, 4]))
                    }
                }
            }
            .frame(width: drawn.width, height: drawn.height, alignment: .topLeading)
            .allowsHitTesting(false)
            if let id = hovered, let item = found.first(where: { $0.id == id }), !rejected.contains(id) {
                pill(for: item)
            }
        }
        .frame(width: drawn.width, height: drawn.height, alignment: .topLeading)
    }

    // MARK: - The tick / cross pill

    private func pill(for item: ShapeFinder.Found) -> some View {
        let rect = Self.pillRect(for: item.shape, anchor: hoverAnchor, drawn: drawn)
        let isAdded = added.contains(item.id)
        return HStack(spacing: 6) {
            if !isAdded && isListed(item.shape) {
                Label("Listed", systemImage: "checkmark.circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
            } else if isAdded {
                Label("Added", systemImage: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.leading, 4)
                pillButton("xmark", tint: Color(red: 0.85, green: 0.25, blue: 0.2), help: "Remove from the register") { actions.undo(item) }
            } else {
                pillButton("checkmark", tint: Color(red: 0.2, green: 0.6, blue: 0.3), help: "Add to the register") { actions.add(item) }
                pillButton("xmark", tint: Color(red: 0.85, green: 0.25, blue: 0.2), help: "Reject") { actions.reject(item) }
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.72), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.55), lineWidth: 0.8))
        .position(x: rect.midX, y: rect.midY)
    }

    private func pillButton(_ symbol: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(tint, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Geometry (shared with the viewer's hover handler)

    /// How far from a line the mouse may be and still hover it, in points.
    static let hoverTolerance: CGFloat = 10
    /// The pill's footprint, for keeping the hover alive while the mouse
    /// travels from the line to the buttons.
    static let pillSize = CGSize(width: 96, height: 32)

    static func outline(_ shape: DetectedShape, drawn: CGSize) -> Path {
        switch shape.kind {
        case .ellipse:
            let centre = CGPoint(x: shape.centre.x * drawn.width, y: shape.centre.y * drawn.height)
            let a = CGFloat(shape.majorAxis) * drawn.width / 2
            let b = CGFloat(shape.minorAxis) * drawn.width / 2
            return Path(ellipseIn: CGRect(x: -a, y: -b, width: 2 * a, height: 2 * b))
                .applying(CGAffineTransform(translationX: centre.x, y: centre.y).rotated(by: shape.rotation))
        case .quad:
            let pts = outlinePoints(shape, drawn: drawn)
            guard pts.count == 4 else { return Path() }
            return Path { p in
                p.move(to: pts[0]); for q in pts.dropFirst() { p.addLine(to: q) }; p.closeSubpath()
            }
        }
    }

    /// The outline as a closed polyline in picture points: 72 samples of an
    /// ellipse, a quad's four corners.
    static func outlinePoints(_ shape: DetectedShape, drawn: CGSize) -> [CGPoint] {
        switch shape.kind {
        case .ellipse:
            let centre = CGPoint(x: shape.centre.x * drawn.width, y: shape.centre.y * drawn.height)
            let a = CGFloat(shape.majorAxis) * drawn.width / 2
            let b = CGFloat(shape.minorAxis) * drawn.width / 2
            let c = CGFloat(cos(shape.rotation)), s = CGFloat(sin(shape.rotation))
            return (0..<72).map { i in
                let t = CGFloat(i) / 72 * 2 * .pi
                let x = a * cos(t), y = b * sin(t)
                return CGPoint(x: centre.x + x * c - y * s, y: centre.y + x * s + y * c)
            }
        case .quad:
            return (shape.corners ?? []).map { CGPoint(x: $0.x * drawn.width, y: $0.y * drawn.height) }
        }
    }

    /// Where the pill sits: just up and to the right of where the mouse
    /// touched the outline, else (a hover from the list) above the outline's
    /// top-right; always kept inside the picture.
    static func pillRect(for shape: DetectedShape, anchor: CGPoint?, drawn: CGSize) -> CGRect {
        var origin: CGPoint
        if let anchor {
            origin = CGPoint(x: anchor.x + 10, y: anchor.y - pillSize.height - 6)
        } else {
            let pts = outlinePoints(shape, drawn: drawn)
            let maxX = pts.map(\.x).max() ?? 0
            let minY = pts.map(\.y).min() ?? 0
            origin = CGPoint(x: maxX - pillSize.width + 10, y: minY - pillSize.height - 4)
        }
        origin.x = min(max(origin.x, 2), max(2, drawn.width - pillSize.width - 2))
        origin.y = min(max(origin.y, 2), max(2, drawn.height - pillSize.height - 2))
        return CGRect(origin: origin, size: pillSize)
    }

    /// The candidate under a point on the picture. The current one keeps the
    /// hover while the point is on its pill; otherwise the nearest outline
    /// within `hoverTolerance` takes it; otherwise the current one keeps it
    /// (a hover from the picture is sticky — it ends when another outline is
    /// hovered, the find changes, or the shape is rejected — so the mouse can
    /// leave the line for the pill without losing it).
    static func hoverTarget(at point: CGPoint, found: [ShapeFinder.Found], rejected: Set<UUID>,
                            current: UUID?, currentAnchor: CGPoint?, drawn: CGSize) -> UUID? {
        if let current, let item = found.first(where: { $0.id == current }), !rejected.contains(current),
           pillRect(for: item.shape, anchor: currentAnchor, drawn: drawn).insetBy(dx: -12, dy: -12).contains(point) {
            return current
        }
        var best: (id: UUID, distance: CGFloat)?
        for item in found where !rejected.contains(item.id) {
            let d = distance(from: point, toClosedPolyline: outlinePoints(item.shape, drawn: drawn))
            if d <= hoverTolerance, best == nil || d < best!.distance { best = (item.id, d) }
        }
        if let best { return best.id }
        if let current, !rejected.contains(current), found.contains(where: { $0.id == current }) { return current }
        return nil
    }

    static func distance(from p: CGPoint, toClosedPolyline pts: [CGPoint]) -> CGFloat {
        guard pts.count >= 2 else { return .infinity }
        var best = CGFloat.infinity
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
            let len2 = ab.x * ab.x + ab.y * ab.y
            let t = len2 > 0 ? max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / len2)) : 0
            let q = CGPoint(x: a.x + ab.x * t, y: a.y + ab.y * t)
            best = min(best, hypot(p.x - q.x, p.y - q.y))
        }
        return best
    }
}

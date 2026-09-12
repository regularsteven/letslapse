import SwiftUI
import LetsLapseKit
#if os(macOS)
import AppKit
#endif

// Mirrors the crop frame drawn over the picture on boards 2a / 5a / 3b
// (`crop`, `data-mode` handles) — spec §10 "Crop UI" and decision 3: the
// picture is never resized by the crop; the crop is a scrim and a frame over
// the full picture, so zoom, 1:1, text layers and masks keep their spaces.

/// The crop frame over the picture: a dimmed outside, a 1 pt frame, and —
/// while the Crop panel is open — thirds, corner handles and the gestures.
///
/// The overlay is laid over the picture with the picture's own on-screen
/// frame (`drawn`), so the crop's normalized rectangle maps to points by a
/// plain multiply and no coordinate space is invented. Panel open: a 55 %
/// scrim, handles, thirds hairlines; drag the body to move, drag a corner to
/// resize about the opposite corner, pinch to scale about the centre. Panel
/// closed: an 85 % scrim and the frame, nothing interactive, so the picture's
/// own gestures are untouched.
///
/// Every gesture freezes the crop it started from and applies ABSOLUTE
/// deltas to that base — the codebase idiom (`MediaResizeHandle`,
/// `GuidedFramingBox`): accumulating per-event deltas drifts under clamping
/// and doubles under a moving view. Locked aspects stay locked (`.original`
/// behaves as the frame's own ratio); `.custom` is free.
struct CropFrameOverlay: View {
    /// Normalized in the drawn picture — the levelled frame's unit square,
    /// origin top-left, y down.
    @Binding var crop: FrameCrop
    /// Drawn width ÷ height — what a locked aspect is measured against.
    var frameAspect: Double
    /// The picture's on-screen size; the overlay takes that same frame.
    var drawn: CGSize
    /// Panel open: 55 % scrim, handles, thirds, gestures. Closed: 85 % scrim
    /// + 1 pt frame, nothing interactive.
    var isEditing: Bool
    /// A drag or pinch owns the picture — the owner stands its pan / paging
    /// gestures down for the duration.
    var onEditing: (Bool) -> Void
    /// Gesture end — the moment to persist.
    var onChanged: () -> Void = {}

    /// The four handles, by the corner they sit on.
    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        /// Position on the crop in unit coordinates.
        var unit: CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: 0, y: 0)
            case .topRight: return CGPoint(x: 1, y: 0)
            case .bottomLeft: return CGPoint(x: 0, y: 1)
            case .bottomRight: return CGPoint(x: 1, y: 1)
            }
        }
    }

    /// What a drag does, classified at its first event and latched for the
    /// whole touch.
    enum DragMode: Equatable {
        case move
        case corner(Corner)
    }

    /// The crop at the drag's first event; every later event is applied to it.
    @State private var dragBase: FrameCrop?
    @State private var dragMode: DragMode?
    /// The crop at the pinch's first event.
    @State private var pinchBase: FrameCrop?
    /// Once a pinch joins the touch, the drag half is done for the whole
    /// touch — resuming it against a base the pinch has since scaled would
    /// apply a stale geometry (`GuidedFramingBox`'s pattern).
    @State private var dragSawPinch = false
    /// True between `onEditing(true)` and `onEditing(false)`, so two gestures
    /// overlapping produce one bracket, not two.
    @State private var owning = false
    @GestureState private var dragLive = false
    @GestureState private var pinchLive = false

    /// The corner handle's reach on each side of the corner: a 36 pt square.
    static let handleReach: CGFloat = 18
    /// The L-bracket's arm length.
    static let bracketArm: CGFloat = 18
    private static let space = "cropOverlay"

    /// The crop in the overlay's points.
    private var screenRect: CGRect {
        CGRect(
            x: crop.x * drawn.width, y: crop.y * drawn.height,
            width: crop.width * drawn.width, height: crop.height * drawn.height)
    }

    var body: some View {
        Group {
            if isEditing {
                editingBody
            } else if !crop.isFull {
                // A closed panel over an uncropped picture has nothing to
                // show — a frame around the picture's own edge would read as
                // a crop that is not there.
                restingBody
            }
        }
        .frame(width: drawn.width, height: drawn.height, alignment: .topLeading)
    }

    private var restingBody: some View {
        let rect = screenRect
        return ZStack(alignment: .topLeading) {
            scrim(around: rect, opacity: 0.85)
            frame(rect)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var editingBody: some View {
        let rect = screenRect
        return ZStack(alignment: .topLeading) {
            scrim(around: rect, opacity: 0.55)
            thirds(rect)
            frame(rect)
            brackets(rect)
            surface(rect)
        }
        .coordinateSpace(name: Self.space)
        .onChange(of: dragLive) { _, live in
            guard !live else { return }
            dragBase = nil
            dragMode = nil
            if !pinchLive {
                dragSawPinch = false
                endOwning()
            }
        }
        .onChange(of: pinchLive) { _, live in
            guard !live else { return }
            pinchBase = nil
            if !dragLive {
                dragSawPinch = false
                endOwning()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Crop frame")
        .accessibilityValue(crop.aspect.label)
        .modifier(CropFrameActions(nudge: nudge, scale: scale))
    }

    /// An accessibility step: the same geometry a drag or pinch applies,
    /// bracketed like one so the owner persists it.
    private func nudge(dx: Double, dy: Double) {
        crop = Self.moved(crop, dx: dx, dy: dy, frameAspect: frameAspect)
        onEditing(true)
        onEditing(false)
        onChanged()
    }

    private func scale(by magnification: Double) {
        crop = Self.scaled(crop, by: magnification, frameAspect: frameAspect)
        onEditing(true)
        onEditing(false)
        onChanged()
    }

    // MARK: - Layers

    /// Everything outside the crop dims — the frame shows exactly what will
    /// render.
    private func scrim(around rect: CGRect, opacity: Double) -> some View {
        Canvas { context, size in
            var mask = Path(CGRect(origin: .zero, size: size))
            mask.addRect(rect)
            context.fill(mask, with: .color(.black.opacity(opacity)), style: FillStyle(eoFill: true))
        }
        .frame(width: drawn.width, height: drawn.height)
        .allowsHitTesting(false)
    }

    private func frame(_ rect: CGRect) -> some View {
        Rectangle()
            .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
            .frame(width: max(2, rect.width), height: max(2, rect.height))
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
    }

    /// Rule-of-thirds hairlines inside the frame.
    private func thirds(_ rect: CGRect) -> some View {
        Path { path in
            for third in [1.0 / 3.0, 2.0 / 3.0] {
                let x = (rect.minX + rect.width * third).rounded() + 0.5
                let y = (rect.minY + rect.height * third).rounded() + 0.5
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.35), lineWidth: 1)
        .allowsHitTesting(false)
    }

    /// The four L-brackets, 3 pt white, arms along the frame's edges.
    private func brackets(_ rect: CGRect) -> some View {
        Path { path in
            let arm = Self.bracketArm
            for corner in Corner.allCases {
                let point = Self.point(of: corner, in: rect)
                // Arms run inward: toward +x on the left corners, −x on the
                // right; toward +y on the top corners, −y on the bottom.
                let dx: CGFloat = corner.unit.x == 0 ? arm : -arm
                let dy: CGFloat = corner.unit.y == 0 ? arm : -arm
                path.move(to: CGPoint(x: point.x, y: point.y + dy))
                path.addLine(to: point)
                path.addLine(to: CGPoint(x: point.x + dx, y: point.y))
            }
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .butt, lineJoin: .miter))
        .allowsHitTesting(false)
    }

    /// The touch surface: the crop plus the handles' reach on every side.
    /// Touches outside it fall through to the picture. Hit-testing lives here
    /// and the drag reads the overlay's named space, because this view moves
    /// with the crop it edits — measured locally, a drag would lose exactly
    /// the distance the frame travelled.
    private func surface(_ rect: CGRect) -> some View {
        let reach = Self.handleReach
        return Color.clear
            .frame(width: rect.width + 2 * reach, height: rect.height + 2 * reach)
            .contentShape(Rectangle())
            .offset(x: rect.minX - reach, y: rect.minY - reach)
            // HIGH priority for the same reason the XY pad's drag is: inside
            // `FullscreenMediaSheet`'s `.page` TabView a horizontal body or
            // corner drag is the pager's gesture too, and a plain drag would
            // let it take the page while the frame followed. The pinch stays
            // simultaneous — its own guards latch a touch to one job.
            .highPriorityGesture(dragGesture)
            .simultaneousGesture(pinchGesture)
            .modifier(CropPointerFeedback(rect: rect, classify: classify))
            // Pinned to the overlay's own size so a surface reaching past
            // the picture's edge overflows instead of widening the stack —
            // which would centre everything 18 pt off the picture.
            .frame(width: drawn.width, height: drawn.height, alignment: .topLeading)
    }

    private static func point(of corner: Corner, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + corner.unit.x * rect.width,
            y: rect.minY + corner.unit.y * rect.height)
    }

    // MARK: - Input

    /// One drag serves both jobs, classified at its first event: within a
    /// handle's reach it resizes against the opposite corner; inside the
    /// frame it moves. The mode is latched for the whole touch.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .updating($dragLive) { _, live, _ in live = true }
            .onChanged { value in
                guard drawn.width > 0, drawn.height > 0 else { return }
                guard pinchBase == nil, !dragSawPinch else { return }
                if dragBase == nil {
                    guard let mode = classify(value.startLocation, in: screenRect) else { return }
                    dragBase = crop
                    dragMode = mode
                    beginOwning()
                }
                guard let base = dragBase, let mode = dragMode else { return }
                let dx = Double(value.translation.width / drawn.width)
                let dy = Double(value.translation.height / drawn.height)
                switch mode {
                case .move:
                    crop = Self.moved(base, dx: dx, dy: dy, frameAspect: frameAspect)
                case .corner(let corner):
                    crop = Self.resized(
                        base, corner: corner, dx: dx, dy: dy, frameAspect: frameAspect)
                }
            }
    }

    /// Pinch scales the crop about its centre, ratio kept — the frame is
    /// always the visible truth, the gesture just drives it.
    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .updating($pinchLive) { _, live, _ in live = true }
            .onChanged { value in
                guard value.magnification.isFinite, value.magnification > 0 else { return }
                if pinchBase == nil {
                    pinchBase = crop
                    dragSawPinch = true
                    beginOwning()
                }
                guard let base = pinchBase else { return }
                crop = Self.scaled(base, by: Double(value.magnification), frameAspect: frameAspect)
            }
    }

    /// Which job a touch at `point` (overlay space) starts: the nearest
    /// corner within reach wins over the body, so a small crop's corners stay
    /// grabbable; nil outside both.
    func classify(_ point: CGPoint, in rect: CGRect) -> DragMode? {
        let reach = Self.handleReach
        var best: (Corner, CGFloat)?
        for corner in Corner.allCases {
            let handle = Self.point(of: corner, in: rect)
            let dx = abs(point.x - handle.x)
            let dy = abs(point.y - handle.y)
            guard dx <= reach, dy <= reach else { continue }
            let distance = hypot(dx, dy)
            if distance < (best?.1 ?? .infinity) { best = (corner, distance) }
        }
        if let best { return .corner(best.0) }
        return rect.contains(point) ? .move : nil
    }

    private func beginOwning() {
        guard !owning else { return }
        owning = true
        onEditing(true)
    }

    private func endOwning() {
        guard owning else { return }
        owning = false
        onEditing(false)
        onChanged()
    }

    // MARK: - Geometry (normalized)

    /// The ratio a locked aspect holds in the unit square: pixel ratio ÷
    /// frame aspect. `.original` holds the frame's own shape, which is 1
    /// here; `.custom` holds nothing.
    static func lockedRatio(of aspect: FrameCrop.Aspect, frameAspect: Double) -> Double? {
        switch aspect {
        case .original: return 1
        case .custom: return nil
        default:
            guard let ratio = aspect.ratio, frameAspect > 0 else { return nil }
            return ratio / frameAspect
        }
    }

    /// `base` shifted by a normalized delta, kept inside the frame.
    static func moved(_ base: FrameCrop, dx: Double, dy: Double, frameAspect: Double) -> FrameCrop {
        var next = base
        next.x = base.x + dx
        next.y = base.y + dy
        return next.clamped(frameAspect: frameAspect)
    }

    /// `base` with `corner` dragged by a normalized delta, the opposite
    /// corner fixed. The dragged corner stays on its own side of the anchor,
    /// no side drops under `FrameCrop.minimumSide`, and a locked ratio is
    /// held with the larger of the two implied sizes deciding — so the frame
    /// keeps up with a diagonal drag instead of lagging on the axis the
    /// finger favoured less.
    static func resized(
        _ base: FrameCrop, corner: Corner, dx: Double, dy: Double, frameAspect: Double
    ) -> FrameCrop {
        let unit = corner.unit
        let anchorX = unit.x == 0 ? base.x + base.width : base.x
        let anchorY = unit.y == 0 ? base.y + base.height : base.y
        let cornerX = (unit.x == 0 ? base.x : base.x + base.width) + dx
        let cornerY = (unit.y == 0 ? base.y : base.y + base.height) + dy
        var width = unit.x == 0 ? anchorX - cornerX : cornerX - anchorX
        var height = unit.y == 0 ? anchorY - cornerY : cornerY - anchorY
        // How far the crop can grow toward each edge with the anchor fixed.
        let roomX = unit.x == 0 ? anchorX : 1 - anchorX
        let roomY = unit.y == 0 ? anchorY : 1 - anchorY
        let minimum = FrameCrop.minimumSide
        if let ratio = lockedRatio(of: base.aspect, frameAspect: frameAspect), ratio > 0 {
            width = max(width, height * ratio)
            width = max(width, minimum, minimum * ratio)
            // Fitting wins over the floor, as in `FrameCrop.clamped`.
            width = min(width, roomX, roomY * ratio)
            height = width / ratio
        } else {
            width = min(max(width, minimum), roomX)
            height = min(max(height, minimum), roomY)
        }
        var next = base
        next.width = width
        next.height = height
        next.x = unit.x == 0 ? anchorX - width : anchorX
        next.y = unit.y == 0 ? anchorY - height : anchorY
        return next.clamped(frameAspect: frameAspect)
    }

    /// `base` scaled about its centre by `magnification`, clamped so neither
    /// side leaves 0…1 or drops under the minimum, then shifted back inside
    /// the frame if the centre sat near an edge.
    static func scaled(_ base: FrameCrop, by magnification: Double, frameAspect: Double) -> FrameCrop {
        guard base.width > 0, base.height > 0 else { return base }
        let minimum = FrameCrop.minimumSide
        var scale = magnification
        scale = min(scale, 1 / base.width, 1 / base.height)
        scale = max(scale, minimum / base.width, minimum / base.height)
        let width = base.width * scale
        let height = base.height * scale
        var next = base
        next.width = width
        next.height = height
        next.x = base.x + (base.width - width) / 2
        next.y = base.y + (base.height - height) / 2
        return next.clamped(frameAspect: frameAspect)
    }
}

/// VoiceOver can pick an aspect chip but cannot drag: the frame is nudged
/// and scaled through custom actions instead, by a twentieth of the picture
/// a step, and direct touch still drags it. Its own modifier so the editing
/// body's chain stays one the type-checker finishes.
private struct CropFrameActions: ViewModifier {
    var nudge: (Double, Double) -> Void
    var scale: (Double) -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityAddTraits(.allowsDirectInteraction)
            .accessibilityAction(named: "Move left") { nudge(-0.05, 0) }
            .accessibilityAction(named: "Move right") { nudge(0.05, 0) }
            .accessibilityAction(named: "Move up") { nudge(0, -0.05) }
            .accessibilityAction(named: "Move down") { nudge(0, 0.05) }
            .accessibilityAction(named: "Smaller") { scale(0.9) }
            .accessibilityAction(named: "Larger") { scale(1.1) }
    }
}

/// What the pointer says the frame will do: the same classification the drag
/// makes at its first event, so the cursor never promises a resize the drag
/// then reads as a move. Corners take the crosshair — AppKit has no public
/// diagonal resize cursor. Hover is read in the surface's local space, which
/// is the crop rect inset by the handles' reach.
private struct CropPointerFeedback: ViewModifier {
    var rect: CGRect
    var classify: (CGPoint, CGRect) -> CropFrameOverlay.DragMode?

    func body(content: Content) -> some View {
        #if os(macOS)
        content.onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                let reach = CropFrameOverlay.handleReach
                let point = CGPoint(
                    x: location.x + rect.minX - reach,
                    y: location.y + rect.minY - reach)
                switch classify(point, rect) {
                case .move: NSCursor.openHand.set()
                case .corner: NSCursor.crosshair.set()
                case nil: NSCursor.arrow.set()
                }
            case .ended:
                NSCursor.arrow.set()
            }
        }
        // Done / Revert with the pointer still over the frame tears the
        // surface down without an `.ended`, and the open hand would stay
        // over a picture that no longer drags.
        .onDisappear { NSCursor.arrow.set() }
        #else
        content
        #endif
    }
}

#if DEBUG
private struct CropFrameOverlayPreview: View {
    var isEditing: Bool
    @State private var crop = FrameCrop.fitted(.sixteenNine, frameAspect: 3.0 / 4.0)
    private let drawn = CGSize(width: 300, height: 400)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.orange, .purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(width: drawn.width, height: drawn.height)
            CropFrameOverlay(
                crop: $crop, frameAspect: 3.0 / 4.0, drawn: drawn, isEditing: isEditing,
                onEditing: { _ in }, onChanged: {})
        }
        .padding(30)
        .background(Color.black)
    }
}

#Preview("Crop · editing") {
    CropFrameOverlayPreview(isEditing: true)
}

#Preview("Crop · resting") {
    CropFrameOverlayPreview(isEditing: false)
}
#endif

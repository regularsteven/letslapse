#if os(watchOS) || os(macOS)
import SwiftUI

/// Deliberate friction for the two gestures that can't be taken back.
///
/// This is the generalised form of the old `SlideToStop`, and it keeps that
/// control's hard-won semantics exactly: the commit fires only when the thumb
/// is **released** past most of its travel, anything short springs back, and a
/// fired control re-arms after 0.8 s so a failed send can be retried without
/// leaving the screen.
///
/// What's new is the axis, and the axis is the whole point of the redesign.
/// Burst commits **up**, stop commits **down**; horizontal is left entirely to
/// tab paging. That separation is what makes a three-tab recording screen safe
/// to wear — a sideways brush can only ever change which page you're looking
/// at, and no amount of paging can start or end anything.
struct SlideToCommit: View {
    enum Direction {
        case up
        case down

        /// Where the bar rests before the drag. The bar always travels *away*
        /// from its home edge, so the pad reads as a slot the bar moves
        /// through rather than a button that happens to slide.
        var home: Alignment { self == .up ? .bottom : .top }

        var chevron: String { self == .up ? "chevron.up" : "chevron.down" }

        /// A drag toward the commit is positive travel, whichever way that is.
        func travel(from height: CGFloat) -> CGFloat { self == .up ? -height : height }
    }

    var direction: Direction
    var tint: Color
    /// The word on the bar — the thing that will happen.
    var title: String
    /// The instruction above/below it — how to make it happen.
    var hint: String
    var enabled: Bool
    var height: CGFloat = RemoteMetric.padHeight
    var onCommit: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var didFire = false
    /// Set once a drag has proved itself vertical. Without this a diagonal
    /// swipe could nudge the bar *and* page the tab; with it, whichever axis
    /// the gesture declares first owns the whole gesture.
    @State private var isTracking = false

    private let inset: CGFloat = 4
    private let commitFraction: CGFloat = 0.85

    var body: some View {
        GeometryReader { geometry in
            let barHeight = RemoteMetric.commitBarHeight
            let travel = max(1, geometry.size.height - barHeight - inset * 2)
            ZStack(alignment: direction.home) {
                RoundedRectangle(cornerRadius: RemoteMetric.padCorner, style: .continuous)
                    .fill(tint.opacity(0.10))
                RoundedRectangle(cornerRadius: RemoteMetric.padCorner, style: .continuous)
                    .strokeBorder(tint.opacity(0.42), lineWidth: 1)

                hintStack
                    // `fixedSize` vertically is load-bearing, not tidiness.
                    // Without it the stack is a flexible child of a ZStack
                    // that is already exactly as tall as the pad, and SwiftUI
                    // balances the overflow by squeezing the smallest child —
                    // the chevron — to zero height. It didn't fail to draw; it
                    // was drawn 0 pt tall, which looks identical and is much
                    // harder to find.
                    .fixedSize(horizontal: false, vertical: true)
                    // Centred in the space the bar does NOT occupy, rather
                    // than aligned to the pad's edge — at the pad's real
                    // height the edge-aligned version pushed the chevron out
                    // through the border.
                    .frame(height: max(0, geometry.size.height - barHeight - inset * 2))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: hintAlignment)
                    .opacity(hintOpacity(travel: travel))

                bar(height: barHeight)
                    .padding(inset)
                    .offset(y: direction == .up ? -dragOffset : dragOffset)
                    .gesture(dragGesture(travel: travel))
            }
        }
        .frame(height: height)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint(hint)
        .accessibilityAddTraits(.isButton)
        // VoiceOver can't slide. Without this the control would be unusable
        // with the screen curtain on — which is exactly when a no-look
        // control matters most.
        .accessibilityAction {
            guard enabled, !didFire else { return }
            fire(travel: 0)
        }
    }

    private var hintAlignment: Alignment {
        direction == .up ? .top : .bottom
    }

    private var hintStack: some View {
        VStack(spacing: 2) {
            if direction == .up {
                chevron
                hintLabel
            } else {
                hintLabel
                chevron
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var chevron: some View {
        Image(systemName: direction.chevron)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(tint)
            .frame(height: 10)
    }

    private var hintLabel: some View {
        Text(hint)
            .font(RemoteType.commit)
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func bar(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: RemoteMetric.rowCorner, style: .continuous)
            .fill(tint)
            .overlay(
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .kerning(0.5)
                    .foregroundStyle(barTextColour)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            )
            .frame(height: height)
    }

    /// The burst yellow needs black on it; the stop red needs white. Judged
    /// from the tint rather than passed in, so a caller can't get it wrong.
    private var barTextColour: Color {
        tint == RemoteTint.record ? .white : .black
    }

    private func dragGesture(travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard enabled, !didFire else { return }
                if !isTracking {
                    // Let the first few points decide the axis. A drag that
                    // declares itself horizontal is the tab pager's, and we
                    // never take it back for the rest of the gesture.
                    guard abs(value.translation.height) > abs(value.translation.width) else { return }
                    isTracking = true
                }
                let moved = direction.travel(from: value.translation.height)
                dragOffset = min(max(0, moved), travel)
            }
            .onEnded { _ in
                guard enabled, !didFire, isTracking else {
                    isTracking = false
                    return
                }
                isTracking = false
                if dragOffset >= travel * commitFraction {
                    fire(travel: travel)
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private func fire(travel: CGFloat) {
        didFire = true
        dragOffset = travel
        onCommit()
        // If the command failed and this control is still on screen, be ready
        // to try again rather than sitting latched at the far end.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            didFire = false
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                dragOffset = 0
            }
        }
    }

    /// The instruction fades out as the bar covers it — by two-thirds of the
    /// travel it's gone, so the pad is just the bar and the slot.
    private func hintOpacity(travel: CGFloat) -> Double {
        max(0, 1 - Double(dragOffset / (travel * 0.6)))
    }
}
#endif

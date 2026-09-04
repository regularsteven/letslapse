import LetsLapseKit
import SwiftUI

/// The lanes under the timeline strip: one band per text layer showing when
/// it is on screen, front layer on top. Read-mostly — the picker in the rail
/// is the authoring instrument ("Starts: At time · After layer"), and the
/// lanes are its visual mirror — but a band can be dragged to move a layer
/// in time, and trimmed at either end.
///
/// Drawn from the Claude Design pass *"Photo viewer text transitions"*
/// (Text Workflow · 1a, the chosen direction): 18pt lanes on the Mac, 15pt
/// on iPhone; a 12pt band whose darker heads mark the reveal in and out; a
/// dotted connector from a parent's reveal end to a linked child's band,
/// with a `⤷` disc at the child's start.
///
/// Owns no document state: every drag goes back through `onEdited`, the
/// same funnel the rail uses (`commit: false` for motion, `true` on release).
/// The owner resolves sequencing after each call.
struct OverlayLanesView: View {
    @Binding var document: OverlayDocument
    @Binding var selectedID: UUID?
    /// The playhead, 0…1 of the source.
    let position: Double
    /// Left inset before the track begins — `GradeTimelineView.leadInset`,
    /// so the bands sit exactly under the strip's own axis.
    let leadInset: CGFloat
    /// Right inset after the track — the frame-step discs and their gaps.
    let trailInset: CGFloat
    var compact: Bool = false
    var accent: Color = LL.accent
    let onEdited: (_ commit: Bool) -> Void
    /// Any drag stops playback, the way a scrub does.
    var onInteract: () -> Void = {}

    // MARK: Metrics — points, straight off the design.

    private var lanePitch: CGFloat { compact ? 18 : 15 }
    private var bandHeight: CGFloat { 12 }
    private var bandTop: CGFloat { compact ? 2 : 1 }
    private var gutterWidth: CGFloat { compact ? 26 : 36 }
    private var gutterGap: CGFloat { compact ? 4 : 4 }
    private var titleSize: CGFloat { 9 }
    /// Hit width of a trim handle — pointer-sized on the Mac, finger-sized
    /// on iPhone.
    private var handleHit: CGFloat { compact ? 8 : 22 }
    /// How many lanes show before the block scrolls.
    private var maxVisibleLanes: Int { compact ? 6 : 4 }
    /// Topmost lane's offset inside the block.
    private var blockTopPad: CGFloat { 2 }

    /// The block's own height, fixed from the layer count so the media above
    /// it never moves when a band is dragged.
    var height: CGFloat {
        let lanes = min(max(document.overlays.count, 1), maxVisibleLanes)
        return CGFloat(lanes) * lanePitch + blockTopPad + 2
    }

    /// A drag in progress: which band, which edge, and the animation it
    /// started from — the Ken Burns idiom of a frozen base plus a delta.
    private struct Drag {
        enum Kind { case move, start, end }
        var id: UUID
        var kind: Kind
        var base: OverlayAnimation
    }
    @State private var drag: Drag?

    var body: some View {
        GeometryReader { proxy in
            let trackWidth = max(1, proxy.size.width - leadInset - trailInset)
            let lanes = document.overlays.count
            ScrollView(.vertical, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(document.overlays.enumerated()), id: \.element.id) { index, layer in
                        lane(layer, index: index, trackWidth: trackWidth)
                    }
                    playhead(trackWidth: trackWidth, lanes: lanes)
                }
                .frame(width: proxy.size.width,
                       height: CGFloat(max(lanes, 1)) * lanePitch + blockTopPad + 2,
                       alignment: .topLeading)
            }
            .scrollDisabled(lanes <= maxVisibleLanes)
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Text layer lanes")
    }

    // MARK: - Lane

    @ViewBuilder private func lane(_ layer: SceneOverlay, index: Int, trackWidth: CGFloat) -> some View {
        let animation = layer.effectiveAnimation
        let span = animation.visibleSpan
        let top = blockTopPad + CGFloat(index) * lanePitch
        let selected = selectedID == layer.id
        let left = leadInset + trackWidth * CGFloat(span.lowerBound)
        let width = max(4, trackWidth * CGFloat(span.upperBound - span.lowerBound))
        let parent = animation.follows.flatMap { follow in
            document.overlays.first { $0.id == follow.layerID }
        }

        // Hairline through the lane's middle.
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(width: trackWidth, height: 1)
            .offset(x: leadInset, y: top + bandTop + bandHeight / 2)

        // Title in the gutter, right-aligned against the track.
        Text(layer.displayName)
            .font(.system(size: titleSize))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(.tertiary)
            .frame(width: gutterWidth, alignment: .trailing)
            .offset(x: leadInset - gutterWidth - gutterGap, y: top + bandTop - 1)
            .allowsHitTesting(false)

        // The dotted connector from the parent's reveal end.
        if let parent {
            let from = leadInset + trackWidth * CGFloat(min(max(parent.effectiveAnimation.reveal.end, 0), 1))
            let to = left
            if to > from + 1 {
                Path { path in
                    path.move(to: CGPoint(x: from, y: top + bandTop + bandHeight / 2))
                    path.addLine(to: CGPoint(x: to, y: top + bandTop + bandHeight / 2))
                }
                .stroke(accent, style: StrokeStyle(lineWidth: 2, dash: [2, 3]))
                .allowsHitTesting(false)
            }
        }

        band(layer, animation: animation, selected: selected, linked: parent != nil,
             trackWidth: trackWidth)
            .frame(width: width, height: bandHeight)
            .offset(x: left, y: top + bandTop)
    }

    @ViewBuilder private func band(
        _ layer: SceneOverlay, animation: OverlayAnimation, selected: Bool, linked: Bool,
        trackWidth: CGFloat
    ) -> some View {
        let span = animation.visibleSpan
        let total = max(span.upperBound - span.lowerBound, 0.0001)
        let inFraction = animation.reveal.style == nil ? 0 : min(animation.reveal.duration / total, 1)
        let outFraction = animation.exit.map { $0.style == nil ? 0 : min($0.duration / total, 1) } ?? 0
        ZStack(alignment: .leading) {
            GeometryReader { proxy in
                let w = proxy.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? accent : accent.opacity(0.42))
                    // Darker heads: the reveal in at the left, the reveal
                    // out at the right.
                    if inFraction > 0 {
                        UnevenRoundedRectangle(
                            topLeadingRadius: 6, bottomLeadingRadius: 6,
                            bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
                            .fill(Color.black.opacity(0.22))
                            .frame(width: max(2, w * CGFloat(inFraction)))
                    }
                    if outFraction > 0 {
                        UnevenRoundedRectangle(
                            topLeadingRadius: 0, bottomLeadingRadius: 0,
                            bottomTrailingRadius: 6, topTrailingRadius: 6, style: .continuous)
                            .fill(Color.black.opacity(0.22))
                            .frame(width: max(2, w * CGFloat(outFraction)))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(LL.cardBackground, lineWidth: 1.5)
                        .padding(-1.5)
                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                        .strokeBorder(accent, lineWidth: 1)
                        .padding(-2.5)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(layer, kind: .move, trackWidth: trackWidth))
            .onTapGesture { selectedID = layer.id }
            #if os(macOS)
            .onHover { inside in
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            #endif

            // Trim handles at both ends. The right one only means something
            // with an exit — without one the band runs to the end of the
            // shoot and there is nothing to trim.
            trimHandle
                .offset(x: -handleHit / 2)
                .gesture(dragGesture(layer, kind: .start, trackWidth: trackWidth))
                .accessibilityLabel("Trim reveal start")
            if animation.exit != nil {
                trimHandle
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .offset(x: handleHit / 2)
                    .gesture(dragGesture(layer, kind: .end, trackWidth: trackWidth))
                    .accessibilityLabel("Trim reveal out end")
            }

            if linked {
                // The link disc sits on the band's start.
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(accent)
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(LL.cardBackground))
                    .overlay(Circle().strokeBorder(accent.opacity(0.5), lineWidth: 1))
                    .offset(x: -7, y: -1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(layer.displayName) band")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var trimHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: handleHit, height: compact ? 16 : 24)
            .contentShape(Rectangle())
            #if os(macOS)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            #endif
    }

    private func playhead(trackWidth: CGFloat, lanes: Int) -> some View {
        Rectangle()
            .fill(LL.ink.opacity(0.55))
            .frame(width: 1, height: CGFloat(max(lanes, 1)) * lanePitch + blockTopPad)
            .offset(x: leadInset + trackWidth * CGFloat(min(max(position, 0), 1)), y: 0)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.15), value: position)
    }

    // MARK: - Dragging

    /// Body drag moves the whole layer in time (and breaks its link — a
    /// layer that has been placed by hand no longer follows); the left
    /// handle trims the reveal start; the right handle trims the exit end.
    private func dragGesture(_ layer: SceneOverlay, kind: Drag.Kind, trackWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard let index = document.overlays.firstIndex(where: { $0.id == layer.id })
                else { return }
                if drag?.id != layer.id || drag?.kind != kind {
                    onInteract()
                    selectedID = layer.id
                    // A layer with no animation yet materialises one so the
                    // band has something to move.
                    if document.overlays[index].animation == nil {
                        document.overlays[index].animation = .alwaysOn
                    }
                    drag = Drag(id: layer.id, kind: kind, base: document.overlays[index].effectiveAnimation)
                }
                guard let drag else { return }
                let dx = Double(value.translation.width / trackWidth)
                var next = drag.base
                switch kind {
                case .move:
                    next.shift(by: dx)
                    next.follows = nil
                case .start:
                    let start = min(max(drag.base.reveal.start + dx, 0),
                                    drag.base.reveal.end - OverlayReveal.minimumDuration)
                    next.reveal.start = max(0, start)
                    next.follows = nil
                case .end:
                    guard var exit = drag.base.exit else { break }
                    let duration = exit.duration
                    exit.end = min(max(drag.base.exit!.end + dx, exit.start + 0.01), 1)
                    exit.start = max(drag.base.reveal.end, exit.end - duration)
                    next.exit = exit
                }
                document.overlays[index].animation = next
                onEdited(false)
            }
            .onEnded { _ in
                drag = nil
                onEdited(true)
            }
    }
}

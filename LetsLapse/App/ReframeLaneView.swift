import SwiftUI

/// The reframe lane under the warp bar: one diamond per spatial keyframe and
/// a move pill per gap, drawn on the same output-proportional axis as the bar
/// above — so a punch move visibly lines up with (or deliberately misses) its
/// speed ramp. Keys are only ever made on purpose: nothing here auto-adds.
struct ReframeLaneView: View {
    @EnvironmentObject var model: AppModel
    @Binding var selectedKey: Int?
    @Binding var playhead: Double
    /// Bar-space mapping borrowed from the timeline, so both lanes agree.
    var position: (Double, CGFloat) -> CGFloat
    var timeAt: (CGFloat, CGFloat) -> Double
    var visibleStart: Double
    var visibleEnd: Double

    /// Which gap's move pill is open.
    @State private var openMove: Int?
    /// Key-drag grab offset in bar pixels; nil = not engaged (tap-through).
    @State private var keyDragBase: Double?

    private var track: ReframeTrack { model.activeReframe() }
    private static let laneHeight: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                lane(width: max(1, proxy.size.width))
            }
            .frame(height: Self.laneHeight)

            if let openMove, openMove < track.moves.count {
                movePopover(openMove)
                    .transition(.opacity)
            }

            keyLine
        }
    }

    // MARK: - Lane

    private func lane(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.secondary.opacity(0.28))
                .frame(height: 1)
                .frame(maxHeight: .infinity)

            movePills(width: width)
            diamonds(width: width)

            // The playhead, carried through from the bar above.
            if playhead >= visibleStart, playhead <= visibleEnd {
                Rectangle()
                    .fill(LL.accent)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .offset(x: position(playhead, width) - 1)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "reframeLane")
        .contentShape(Rectangle())
        .accessibilityLabel("Reframe keyframes")
    }

    private func diamonds(width: CGFloat) -> some View {
        ForEach(Array(track.keys.enumerated()), id: \.element.id) { index, key in
            let visible = key.t >= visibleStart && key.t <= visibleEnd
            if visible {
                diamond(index: index, key: key, width: width)
                    .position(
                        x: min(max(position(key.t, width), 8), width - 8),
                        y: Self.laneHeight / 2)
            }
        }
    }

    private func diamond(index: Int, key: ReframeTrack.Key, width: CGFloat) -> some View {
        let selected = index == selectedKey
        let punched = key.z > 1.02
        let side: CGFloat = selected ? 11 : 9
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(punched ? LL.amber : .white)
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(.black.opacity(0.3), lineWidth: 0.75))
            .frame(width: side, height: side)
            .rotationEffect(.degrees(45))
            .overlay {
                if selected {
                    Circle()
                        .strokeBorder(LL.accent, lineWidth: 2)
                        .frame(width: side + 11, height: side + 11)
                }
            }
            // 36pt touch target around an 11pt diamond.
            .frame(width: 36, height: Self.laneHeight)
            .contentShape(Rectangle())
            .gesture(keyGesture(index: index, width: width))
            .accessibilityLabel(
                "Keyframe \(index + 1), \(WarpTimeline.clock(key.t)), "
                + String(format: "%.1f× punch", key.z))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A touch that never crosses the slop is a tap (select + scrub there); a
    /// real drag slides the key in time, clamped at its neighbours, as one
    /// coalesced undo step.
    private func keyGesture(index: Int, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("reframeLane"))
            .onChanged { value in
                if keyDragBase == nil {
                    guard abs(value.translation.width) > 3 else { return }
                    guard track.keys.indices.contains(index) else { return }
                    keyDragBase = Double(value.location.x - position(track.keys[index].t, width))
                    WarpHaptics.engage()
                }
                guard let grab = keyDragBase else { return }
                let target = timeAt(value.location.x - CGFloat(grab), width)
                selectedKey = index
                openMove = nil
                model.updateReframe(coalescing: "reframe-key-time-\(index)") {
                    $0.setTime(target, forKey: index)
                }
                if track.keys.indices.contains(index) {
                    playhead = track.keys[index].t
                }
            }
            .onEnded { _ in
                let dragged = keyDragBase != nil
                keyDragBase = nil
                model.endWarpCoalescing()
                guard !dragged else { return }
                guard track.keys.indices.contains(index) else { return }
                selectedKey = index
                playhead = track.keys[index].t
                openMove = nil
                WarpHaptics.tick()
            }
    }

    /// One pill per gap between neighbouring keys, at the gap's midpoint —
    /// the spatial sibling of the seam pill. Hidden when the gap is too
    /// narrow to carry one.
    private func movePills(width: CGFloat) -> some View {
        ForEach(Array(track.moves.enumerated()), id: \.offset) { index, move in
            if track.keys.indices.contains(index + 1) {
                let x0 = position(track.keys[index].t, width)
                let x1 = position(track.keys[index + 1].t, width)
                if x1 - x0 > 58 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            openMove = openMove == index ? nil : index
                        }
                    } label: {
                        Text(pillLabel(move))
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(LL.amber)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(LL.ink, in: Capsule())
                            .frame(minWidth: 40, minHeight: Self.laneHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .position(x: (x0 + x1) / 2, y: Self.laneHeight / 2)
                    .accessibilityLabel("Move \(index + 1), \(pillLabel(move))")
                }
            }
        }
    }

    /// "ease" / "~1s ease" / "~2s thru"
    private func pillLabel(_ move: ReframeTrack.Move) -> String {
        move.span == .gap
            ? move.curve.label
            : "~\(move.span.label) \(move.curve.label)"
    }

    // MARK: - Move popover

    private func movePopover(_ index: Int) -> some View {
        let move = track.moves[index]
        return VStack(alignment: .leading, spacing: 8) {
            Text("MOVE INTO KEY \(index + 2)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .kerning(0.4)
            HStack(spacing: 6) {
                ForEach(ReframeTrack.Move.Span.allCases, id: \.self) { span in
                    let active = move.span == span
                    Button {
                        model.updateReframe {
                            var updated = $0.moves[index]
                            updated.span = span
                            $0.setMove(updated, at: index)
                        }
                    } label: {
                        Text(span.label)
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(active ? LL.amber : .primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                active ? LL.ink : LL.screenBackground,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                ForEach(ReframeTrack.Move.Curve.allCases, id: \.self) { curve in
                    let active = move.curve == curve
                    Button {
                        model.updateReframe {
                            var updated = $0.moves[index]
                            updated.curve = curve
                            $0.setMove(updated, at: index)
                        }
                    } label: {
                        Text(curve == .ease ? "Ease — a planned move" : "Thru — keeps tracking")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(active ? LL.amber : .primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                active ? LL.ink : LL.screenBackground,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(moveHint(move))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private func moveHint(_ move: ReframeTrack.Move) -> String {
        switch (move.span, move.curve) {
        case (.gap, .ease):
            return "The move fills the whole gap, easing out and settling in."
        case (.gap, .linear):
            return "The move fills the whole gap at a steady rate — for tracking a subject."
        case (_, .ease):
            return "Holds the earlier framing, then arrives over the last ~\(move.span.label) of viewer time."
        case (_, .linear):
            return "Holds, then moves steadily over the last ~\(move.span.label) of viewer time."
        }
    }

    // MARK: - Key line

    /// The selected key's facts and the explicit adds — the lane's only ways
    /// to make or remove a keyframe.
    private var keyLine: some View {
        HStack(spacing: 8) {
            if track.isEmpty {
                Text("Full frame — pinch the preview to punch in")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let index = selectedKey, track.keys.indices.contains(index) {
                let key = track.keys[index]
                Text(
                    "Key \(index + 1) of \(track.keys.count) · "
                    + "\(WarpTimeline.clock(key.t)) · "
                    + (key.z > 1.02 ? String(format: "%.1f× punch", key.z) : "full frame"))
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    model.updateReframe { $0.removeKey(at: index) }
                    selectedKey = track.keys.isEmpty
                        ? nil
                        : min(index, track.keys.count - 1)
                    WarpHaptics.tick()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 1, green: 0.23, blue: 0.19))
                        .contentShape(Rectangle().inset(by: -12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove keyframe \(index + 1)")
            } else {
                Text("\(track.keys.count) \(track.keys.count == 1 ? "key" : "keys") — tap one to edit")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if playheadOffKeys {
                Button {
                    addKeyAtPlayhead()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                        Text("Keyframe at \(WarpTimeline.clock(playhead))")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(LL.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(LL.screenBackground, in: Capsule())
                    .contentShape(Rectangle().inset(by: -8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(LL.screenBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var playheadOffKeys: Bool {
        !track.keys.contains { abs($0.t - playhead) < ReframeTrack.minimumKeySpacing }
    }

    /// The "+ Keyframe" path: the new key copies the framing on screen (the
    /// interpolated move, or the full frame on an empty lane), so adding a
    /// key never jumps the picture.
    private func addKeyAtPlayhead() {
        guard let size = model.sourceDisplaySize() else { return }
        let frame: (z: Double, cx: Double, cy: Double)
        if track.isEmpty {
            frame = (1, Double(size.width) / 2, Double(size.height) / 2)
        } else {
            let warp = model.activeWarp()
            frame = track.frame(atSource: playhead, outputTime: warp.outputTime(atSource:))
        }
        var newIndex = 0
        model.updateReframe {
            newIndex = $0.addKey(t: playhead, z: frame.z, cx: frame.cx, cy: frame.cy)
        }
        selectedKey = newIndex
        WarpHaptics.success()
    }
}

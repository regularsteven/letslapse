import SwiftUI

// Mirrors the Temp and Tint rows of board 6e (pads off) and `board-logic.js`
// `F.temp.track` / `F.tint.track` — spec §2 "Slider tracks in sliders mode".

/// A slider whose track is a gradient — the two white balance rows in
/// sliders mode, where the track itself says what the axis does (blue to
/// amber for Temp, green to magenta for Tint) and no accent fill is drawn
/// over it.
///
/// Only those two rows use it; every other row keeps the native `Slider`,
/// which already draws the design's plain track. It speaks the same
/// vocabulary as the native control — a value in a range, an editing bracket
/// on grab and release — so `PhotoAdjustmentsPanel` can hand either one the
/// same binding.
///
/// Touch-down puts the knob under the finger and the drag follows it. The
/// drag is HIGH priority for the same reason the pad's is: on iOS the editor
/// can be one page of a `.page` TabView (`FullscreenMediaSheet`, multi-frame
/// projects), and a plain drag on a horizontal slider is exactly the gesture
/// that pager wants to steal.
struct GradientTrackSlider: View {
    @Binding var value: Float
    var range: ClosedRange<Float>
    /// The track, leading to trailing.
    var colors: [Color]
    var style: XYPadStyle
    /// Grab / release, for the owner's persist-on-release.
    var onEditing: (Bool) -> Void = { _ in }
    var accessibilityLabel: String = ""
    var accessibilityValue: String = ""

    /// Flips false on cancel as well as end — the healer for a drag that dies
    /// without `onEnded`, the same guard `XYPad` keeps.
    @GestureState private var dragLive = false
    @State private var editing = false

    // MARK: - Metrics

    /// 26 pt white knob in a 30 pt row on the dark editors; the Mac's 20 pt
    /// bordered knob in a 24 pt row (3b).
    private var knobDiameter: CGFloat { style == .dark ? 26 : 20 }
    private var rowHeight: CGFloat { style == .dark ? 30 : 24 }
    private let trackHeight: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let travel = max(proxy.size.width - knobDiameter, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(height: trackHeight)
                    .frame(maxHeight: .infinity)
                knob
                    .offset(x: CGFloat(normalized) * travel)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .highPriorityGesture(drag(travel: travel))
            .onChange(of: dragLive) { _, live in
                guard !live, editing else { return }
                editing = false
                onEditing(false)
            }
        }
        .frame(height: rowHeight)
        .modifier(KeyboardSteps(cornerRadius: rowHeight / 2) { dx, _ in
            guard dx != 0 else { return }
            step(dx > 0 ? .increment : .decrement)
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in step(direction) }
    }

    /// One step of a fiftieth of the travel — the keyboard's and VoiceOver's
    /// — bracketed like a drag so the owner persists it.
    private func step(_ direction: AccessibilityAdjustmentDirection) {
        let step = (range.upperBound - range.lowerBound) / 50
        onEditing(true)
        switch direction {
        case .increment: value = min(range.upperBound, value + step)
        case .decrement: value = max(range.lowerBound, value - step)
        @unknown default: break
        }
        onEditing(false)
    }

    /// 0…1 along the track.
    private var normalized: Float {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    private var knob: some View {
        Circle()
            .fill(Color.white)
            .overlay(
                Circle().strokeBorder(
                    Color.black.opacity(style == .dark ? 0 : 0.14), lineWidth: 1))
            .frame(width: knobDiameter, height: knobDiameter)
            .shadow(
                color: .black.opacity(style == .dark ? 0.4 : 0.15),
                radius: style == .dark ? 3 : 2, y: 1)
            .allowsHitTesting(false)
    }

    private func drag(travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($dragLive) { _, live, _ in live = true }
            .onChanged { gesture in
                // The same slack as the pad's: a bare tap (or the two of a
                // double-tap on the label) writes nothing.
                guard editing || abs(gesture.translation.width) > 3 else { return }
                if !editing {
                    editing = true
                    onEditing(true)
                }
                // The knob's centre travels over the width less one knob, so
                // the knob never hangs off either end of the track.
                let t = min(max((gesture.location.x - knobDiameter / 2) / travel, 0), 1)
                value = range.lowerBound + Float(t) * (range.upperBound - range.lowerBound)
            }
    }
}

#if DEBUG
private struct GradientTrackSliderPreview: View {
    @State private var temp: Float = -150
    @State private var tint: Float = 20

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                GradientTrackSlider(
                    value: $temp, range: -600 ... -40,
                    colors: [EditorPalette.blue, EditorPalette.rgb(0xD8D8DC), EditorPalette.amber],
                    style: .dark)
                GradientTrackSlider(
                    value: $tint, range: -150...150,
                    colors: [EditorPalette.green, EditorPalette.rgb(0xD8D8DC), EditorPalette.magenta],
                    style: .dark)
            }
            .padding(16)
            .frame(width: 393)
            .background(EditorPalette.rgb(0x1C1C1E))

            VStack(spacing: 8) {
                GradientTrackSlider(
                    value: $temp, range: -600 ... -40,
                    colors: [EditorPalette.blue, EditorPalette.rgb(0xD8D8DC), EditorPalette.amber],
                    style: .light)
                GradientTrackSlider(
                    value: $tint, range: -150...150,
                    colors: [EditorPalette.green, EditorPalette.rgb(0xD8D8DC), EditorPalette.magenta],
                    style: .light)
            }
            .padding(12)
            .frame(width: 298)
            .background(Color.white)
        }
        .padding(20)
        .background(EditorPalette.rgb(0xF2F2F7))
    }
}

#Preview("Gradient track sliders") {
    GradientTrackSliderPreview()
}
#endif

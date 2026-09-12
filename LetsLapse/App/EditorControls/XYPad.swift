import SwiftUI

// Mirrors the XY pad of boards 2a / 5a (dark, 170 / 180 pt) and 3b (the Mac's
// light pad, 170 pt) — spec §2 "XY pads", and `board-logic.js` `pad()` for the
// pointer behaviour.

/// The two looks a pad and its readouts come in: the dark editors' (amber
/// knob, white margin words) and the Mac rail's (accent knob over a light
/// card, black readouts).
enum XYPadStyle {
    case dark, light
}

/// A two-axis control: one knob, two fields.
///
/// The pad speaks in normalized coordinates and nothing else — x 0…1 left to
/// right, y 0…1 BOTTOM to top, so "up is more" holds for every pad however
/// its fields are scaled. The panel maps each axis to its field's range,
/// presentation sign (Temp warm-up, vignette lighten-up) and neutral; the
/// pad only knows where the crosshair goes. That keeps every pad one view and
/// the field arithmetic in one place beside the slider rows it replaces.
///
/// The first moved point of a drag puts the knob under the finger (the
/// board jumps the knob on pointer-down; here a bare tap writes nothing, see
/// `dragSlack`) and the drag follows it; a double-tap resets both fields
/// through `onReset`. `onEditing` brackets the drag so the owner can persist
/// on release, float its 1:1 loupe, and stand its own pan/paging gestures
/// down while a finger owns the pad.
struct XYPad: View {
    /// Normalized: x 0…1 left → right, y 0…1 BOTTOM → top.
    @Binding var value: CGPoint
    /// Where the crosshair sits, normalized — both axes' neutral.
    var neutral: CGPoint
    var words: PadWords
    var background: PadBackground
    var style: XYPadStyle
    var height: CGFloat
    /// The two fields' names, for the spoken label — the pad itself only
    /// knows its corner words.
    var yName: String = ""
    var xName: String = ""
    var onEditing: (Bool) -> Void = { _ in }
    /// Double-tap. The owner decides what a reset means (a timeline retires
    /// the fields from the moment; a still writes the neutrals).
    var onReset: () -> Void = {}

    /// Flips false on cancel as well as end — the healer for a drag that dies
    /// without `onEnded`, the same guard `MediaResizeHandle` keeps.
    @GestureState private var dragLive = false
    @State private var editing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Metrics

    private var knobDiameter: CGFloat { style == .dark ? 30 : 24 }
    private var knobRing: CGFloat { style == .dark ? 3 : 2.5 }
    private var knobFill: Color { style == .dark ? LL.amber : LL.accent }
    private var cornerRadius: CGFloat { style == .dark ? 14 : 10 }
    private var crosshair: Color {
        style == .dark ? Color.white.opacity(0.35) : Color.black.opacity(0.25)
    }
    private var wordSize: CGFloat { style == .dark ? 10.5 : 10 }
    private var wordInk: Color { style == .dark ? Color.white.opacity(0.85) : .white }
    private var wordShadow: Double { style == .dark ? 0.6 : 0.7 }
    private var wordInsetVertical: CGFloat { style == .dark ? 7 : 6 }
    private var wordInsetHorizontal: CGFloat { style == .dark ? 10 : 8 }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                background.view(light: style == .light)
                crosshairLines(in: size)
                knob
                    .position(
                        x: value.x * size.width,
                        y: (1 - value.y) * size.height)
            }
            .overlay(alignment: .top) { word(words.top).padding(.top, wordInsetVertical) }
            .overlay(alignment: .bottom) { word(words.bottom).padding(.bottom, wordInsetVertical) }
            .overlay(alignment: .leading) { word(words.left).padding(.leading, wordInsetHorizontal) }
            .overlay(alignment: .trailing) { word(words.right).padding(.trailing, wordInsetHorizontal) }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            // The drag is HIGH priority: on iOS the editor can be one page of
            // a `.page` TabView (`FullscreenMediaSheet`, multi-frame
            // projects), and a horizontal pad move is exactly the gesture
            // that pager wants — a plain or simultaneous drag would let it
            // take the page while the knob followed. Double-tap (double-click
            // on the Mac) resets both fields; it rides alongside as a
            // simultaneous gesture attached AFTER the drag, so the two
            // touch-downs of a double-tap — which the zero-distance drag also
            // sees — do not swallow it.
            .highPriorityGesture(drag(in: size))
            .simultaneousGesture(TapGesture(count: 2).onEnded { reset() })
            .onChange(of: dragLive) { _, live in
                guard !live, editing else { return }
                editing = false
                onEditing(false)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .modifier(KeyboardSteps(cornerRadius: cornerRadius) { dx, dy in
            step(x: CGFloat(dx) * 0.02, y: CGFloat(dy) * 0.02)
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        // VoiceOver's swipe up/down walks the dominant (vertical) axis; the
        // horizontal one is a pair of custom actions on the same element —
        // the readouts under the pad are text, not controls, so without
        // these the X field would be unreachable with VoiceOver.
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(y: 0.05)
            case .decrement: step(y: -0.05)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Toward \(words.right)") { step(x: 0.05) }
        .accessibilityAction(named: "Toward \(words.left)") { step(x: -0.05) }
    }

    /// One accessibility step, bracketed like a drag so the owner persists
    /// it and, with a timeline, writes it as one edit.
    private func step(x dx: CGFloat = 0, y dy: CGFloat = 0) {
        onEditing(true)
        value = CGPoint(
            x: min(max(value.x + dx, 0), 1),
            y: min(max(value.y + dy, 0), 1))
        onEditing(false)
    }

    private var accessibilityLabel: String {
        let axes = "\(words.bottom) to \(words.top), \(words.left) to \(words.right)"
        guard !yName.isEmpty, !xName.isEmpty else { return axes }
        return "\(yName) and \(xName) pad. \(axes)"
    }

    // MARK: - Layers

    private func crosshairLines(in size: CGSize) -> some View {
        Path { path in
            let x = (neutral.x * size.width).rounded() + 0.5
            let y = ((1 - neutral.y) * size.height).rounded() + 0.5
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
        .stroke(crosshair, lineWidth: 1)
        .allowsHitTesting(false)
    }

    private var knob: some View {
        Circle()
            .fill(knobFill)
            .overlay(Circle().strokeBorder(Color.white, lineWidth: knobRing))
            .frame(width: knobDiameter, height: knobDiameter)
            .shadow(
                color: .black.opacity(style == .dark ? 0.5 : 0.4),
                radius: style == .dark ? 8 : 5,
                y: style == .dark ? 2 : 1)
            .allowsHitTesting(false)
    }

    private func word(_ text: String) -> some View {
        Text(text)
            .font(.system(size: wordSize, weight: .semibold))
            .foregroundStyle(wordInk)
            .shadow(color: .black.opacity(wordShadow), radius: 2, y: 1)
            .lineLimit(1)
            .allowsHitTesting(false)
    }

    // MARK: - Input

    /// How far a finger has to travel before the pad treats the touch as a
    /// drag. A zero-distance drag sees every touch-down — including the two
    /// of a double-tap — and writing on the first event made every tap a
    /// real edit: with a timeline, keyframes materialised under a tap the
    /// reset then only half undid. Under the slack nothing is written; a
    /// real drag still lands the knob under the finger from its first moved
    /// point.
    private static let dragSlack: CGFloat = 3

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($dragLive) { _, live, _ in live = true }
            .onChanged { gesture in
                guard size.width > 0, size.height > 0 else { return }
                guard editing
                    || abs(gesture.translation.width) > Self.dragSlack
                    || abs(gesture.translation.height) > Self.dragSlack else { return }
                if !editing {
                    editing = true
                    onEditing(true)
                }
                value = CGPoint(
                    x: min(max(gesture.location.x / size.width, 0), 1),
                    y: min(max(1 - gesture.location.y / size.height, 0), 1))
            }
    }

    private func reset() {
        if reduceMotion {
            onReset()
        } else {
            withAnimation(.easeOut(duration: 0.2)) { onReset() }
        }
    }

    private var accessibilityValue: String {
        let up = Int((value.y * 100).rounded())
        let right = Int((value.x * 100).rounded())
        return "\(up) percent toward \(words.top), \(right) percent toward \(words.right)"
    }
}

/// Keyboard access on the Mac: the native sliders the pads replaced were
/// focusable, so Full Keyboard Access could reach every field; a pointer-
/// only pad would lose that. Tab lands on the control, the arrow keys step
/// it (`onMoveCommand`, ±1 per key on each axis), and a focus ring in the
/// accent says which control has it. Nothing on iOS — the pads are touch
/// there, and VoiceOver has its own actions.
struct KeyboardSteps: ViewModifier {
    var cornerRadius: CGFloat
    /// `(dx, dy)` in −1 / 0 / +1, y up.
    var step: (Int, Int) -> Void
    #if os(macOS)
    @FocusState private var isFocused: Bool
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: isFocused ? 2 : 0)
                    .allowsHitTesting(false))
            .onMoveCommand { direction in
                switch direction {
                case .up: step(0, 1)
                case .down: step(0, -1)
                case .left: step(-1, 0)
                case .right: step(1, 0)
                @unknown default: break
                }
            }
        #else
        content
        #endif
    }
}

/// The two readouts under a pad — `Exposure +0.30 · Contrast +12` — in the
/// app's existing formats, label secondary and value accent (dark) or primary
/// (light), accent when the field travels, with the keyframe diamond beside
/// the label of a keyframed field.
struct PadReadouts: View {
    var yLabel: String
    var yValue: String
    var yKeyframed: Bool
    var xLabel: String
    var xValue: String
    var xKeyframed: Bool
    var accent: Color
    var style: XYPadStyle

    private var fontSize: CGFloat { style == .dark ? 12.5 : 11.5 }
    private var labelInk: Color {
        style == .dark ? EditorPalette.secondaryOnDark : EditorPalette.secondaryOnLight
    }

    var body: some View {
        HStack {
            readout(label: yLabel, value: yValue, keyframed: yKeyframed)
            Spacer(minLength: 8)
            readout(label: xLabel, value: xValue, keyframed: xKeyframed)
        }
        .font(.system(size: fontSize, weight: .semibold))
        .monospacedDigit()
        .padding(.horizontal, style == .dark ? 4 : 2)
    }

    private func readout(label: String, value: String, keyframed: Bool) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(labelInk)
            if keyframed { KeyframeDiamond() }
            Text(value)
                .foregroundStyle(keyframed ? accent : (style == .dark ? accent : Color.primary))
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(keyframed ? "\(label), keyframed" : label)
        .accessibilityValue(value)
    }
}

/// Treatment 1e-A's mark for a value that travels over time — the same 7 pt
/// diamond `PhotoAdjustmentsPanel` and `RotationSlider` each kept a private
/// copy of, hoisted so the pad readouts and the tool chips can share it. A dot
/// means "non-neutral"; a diamond means "varies over time". It is pinned to
/// the design tokens, not the surface's accent, so the mark reads the same on
/// the amber editors and the orange Mac rail.
struct KeyframeDiamond: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(LL.amber)
            .overlay(
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .strokeBorder(LL.accent, lineWidth: 1))
            .frame(width: 7, height: 7)
            .rotationEffect(.degrees(45))
            .accessibilityHidden(true)
    }
}

#if DEBUG
private struct XYPadPreview: View {
    var style: XYPadStyle
    @State private var exposure = CGPoint(x: 0.56, y: 0.53)
    @State private var white = CGPoint(x: 0.5, y: 0.42)
    @State private var mixer = CGPoint(x: 0.5, y: 0.5)

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(pads.enumerated()), id: \.offset) { _, pad in
                XYPad(
                    value: pad.value, neutral: pad.neutral, words: pad.spec.words,
                    background: pad.background, style: style, height: 170,
                    onEditing: { _ in }, onReset: { pad.value.wrappedValue = pad.neutral })
                PadReadouts(
                    yLabel: pad.labels.0, yValue: pad.values.0, yKeyframed: pad.keyframed,
                    xLabel: pad.labels.1, xValue: pad.values.1, xKeyframed: false,
                    accent: style == .dark ? LL.amber : LL.accent, style: style)
            }
        }
        .padding(16)
        .frame(width: 361)
        .background(style == .dark ? Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255) : .white)
    }

    private struct Sample {
        var spec: PadSpec
        var background: PadBackground
        var value: Binding<CGPoint>
        var neutral: CGPoint
        var labels: (String, String)
        var values: (String, String)
        var keyframed: Bool
    }

    private var pads: [Sample] {
        [
            Sample(
                spec: EditorTool.expCon.pad!, background: .expCon, value: $exposure,
                neutral: CGPoint(x: 0.5, y: 0.5), labels: ("Exposure", "Contrast"),
                values: ("+0.30", "+12"), keyframed: true),
            Sample(
                spec: EditorTool.whiteBalance.pad!, background: .whiteBalance, value: $white,
                neutral: CGPoint(x: 0.5, y: 0.42), labels: ("Temp", "Tint"),
                values: ("6500 K", "0"), keyframed: false),
            Sample(
                spec: EditorTool.mixer.pad!, background: .mixer(hueDegrees: 30), value: $mixer,
                neutral: CGPoint(x: 0.5, y: 0.5), labels: ("Hue", "Luminance"),
                values: ("0", "0"), keyframed: false),
        ]
    }
}

#Preview("Pads · dark") {
    XYPadPreview(style: .dark)
}

#Preview("Pads · light") {
    XYPadPreview(style: .light)
}
#endif

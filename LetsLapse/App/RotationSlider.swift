import SwiftUI
import LetsLapseKit

/// The fine-rotation control: a slider that rests in the middle and reads in
/// degrees, ±10 by default — the range that levels a horizon shot nearly
/// level rather than one shot sideways.
///
/// One component, two homes. The Edit screen's Rotation section turns the
/// whole project; a text layer's TEXT & SIZE section turns that layer. Both
/// speak the same vocabulary — the same travel, the same readout, the same
/// double-tap-the-label reset — so a rotation means one thing wherever it
/// is set. `style` is the only difference: `.stacked` is the adjustment
/// panel's row shape (label over a full-width track, readout at the right),
/// `.inline` the overlay panel's (label, track and readout on one line).
///
/// Positive is clockwise as displayed, the same direction the geometry
/// (`FrameRotation`) and SwiftUI's `rotationEffect` read a positive angle.
/// A slider tick within a fifth of a degree of centre snaps to exactly
/// zero, so the resting state is genuinely "no rotation" and never
/// 0.03° of resample for nothing.
struct RotationSlider: View {
    enum Style {
        /// `PhotoAdjustmentsPanel`'s row: label above a full-width track.
        case stacked
        /// `OverlayEditingPanel`'s row: label, track and readout on one line.
        case inline
    }

    var label: String = "Angle"
    @Binding var degrees: Double
    var range: ClosedRange<Double> = FrameRotation.range
    var style: Style = .stacked
    var accent: Color = LL.accent
    /// Told when the thumb is grabbed and let go — the owners persist on
    /// release rather than per tick, like every other slider they host.
    var onEditing: ((Bool) -> Void)?
    /// True when the angle travels over the clip — the adjustment panel's
    /// keyframe diamond beside the label, and an accent readout.
    var isKeyframed: Bool = false
    /// Where a double-tapped label's reset goes when the owner has a
    /// timeline to consider; unset writes zero straight into the binding.
    var onReset: (() -> Void)?

    private func reset() {
        if let onReset { onReset() } else { degrees = 0 }
    }

    /// Closer than this to zero snaps to zero.
    static let centreSnap: Double = 0.2

    private var isNeutral: Bool { !FrameRotation.isActive(degrees) }

    /// The readout: "0°" at rest, "+2.5°" / "−3.0°" otherwise — a tenth of a
    /// degree is the finest a finger can set and the finest an eye can see.
    static func readout(_ degrees: Double) -> String {
        guard FrameRotation.isActive(degrees) else { return "0°" }
        let text = String(format: "%+.1f°", degrees)
        // A real minus sign, the way the exposure readout would print one.
        return text.replacingOccurrences(of: "-", with: "−")
    }

    private var snapped: Binding<Double> {
        Binding(
            get: { degrees },
            set: { next in
                let clamped = min(max(next, range.lowerBound), range.upperBound)
                degrees = abs(clamped) < Self.centreSnap ? 0 : clamped
            })
    }

    var body: some View {
        switch style {
        case .stacked: stacked
        case .inline: inline
        }
    }

    private var stacked: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                if isKeyframed { keyframeDiamond }
                Spacer()
                Text(Self.readout(degrees))
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isKeyframed ? accent : (isNeutral ? Color.secondary : Color.primary))
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { reset() }
            slider
        }
    }

    private var inline: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { reset() }
            slider
            Text(Self.readout(degrees))
                .font(.system(size: 12, weight: .semibold))
                .monospaced()
                .foregroundStyle(isNeutral ? Color.secondary : accent)
                .frame(width: 58, alignment: .trailing)
        }
    }

    private var slider: some View {
        Slider(value: snapped, in: range) { editing in
            onEditing?(editing)
        }
        .tint(accent)
        .accessibilityLabel(isKeyframed ? "\(label), keyframed" : label)
        .accessibilityValue(Self.readout(degrees))
    }

    /// The same mark `PhotoAdjustmentsPanel` puts beside a travelling colour.
    private var keyframeDiamond: some View {
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

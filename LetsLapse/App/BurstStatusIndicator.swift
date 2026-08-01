import SwiftUI

/// The burst pill: one component for every burst variant. The bar carries the
/// feel, the number carries the truth — the only branch is whether a total
/// exists. A capped burst fills continuously toward `taken/total` with a
/// `taken/total` readout; an open (Bulb) run draws a decay zebra — newest
/// stripe brightest — with a bare counter. Nothing else differs.
///
/// Passive by design: no hit target, no accessibility action — stopping an
/// open burst is the shutter's job. Width-agnostic; the host sets the frame
/// (249×26 pt in the capture slot). Spec mirror:
/// docs/design/iOS/capture-photo.burst.portrait.svg.
struct BurstStatusIndicator: View {
    /// Frames (or outputs) counted so far. Photo bursts mount the pill on
    /// the first shot; Interval mounts it at run start, where a 0 renders
    /// as the bare track and a "0" — the first tick fills it in.
    var taken: Int
    /// The burst's frame cap, or nil for an open-ended run (Bulb, Interval).
    var total: Int?

    /// A stripe's own cell repeats every 13 pt until the run reaches the
    /// right edge; past that the pitch compresses to `barWidth / n`.
    private static let naturalPitch: CGFloat = 13
    /// Stripe width as a share of its cell. The 0.9 pt floor keeps a stripe
    /// from vanishing entirely once the pitch drops below a point — beyond
    /// that the ramp reads as a textured wash and the number does the work.
    private static let stripeDuty: CGFloat = 0.55
    private static let minStripeWidth: CGFloat = 0.9
    /// CSS `ease`, the reference implementation's curve for reflows.
    static func ease(_ duration: Double) -> Animation {
        .timingCurve(0.25, 0.1, 0.25, 1, duration: duration)
    }

    var body: some View {
        HStack(spacing: 10) {
            bar
            countReadout
        }
        .padding(.leading, 12)
        .padding(.trailing, 11)
        .frame(height: 26)
        .background(Color.black.opacity(0.5), in: Capsule())
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Burst")
        .accessibilityValue(total.map { "\(taken) of \($0)" } ?? "\(taken)")
    }

    private var bar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Color.white.opacity(0.16))
                if let total {
                    fixedFill(barWidth: geometry.size.width, total: total)
                } else {
                    zebra(barWidth: geometry.size.width)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 5)
    }

    private func fixedFill(barWidth: CGFloat, total: Int) -> some View {
        Capsule()
            .fill(LL.amber)
            .frame(width: barWidth * min(1, CGFloat(taken) / CGFloat(max(1, total))))
            .animation(.timingCurve(0.25, 0.9, 0.3, 1, duration: 0.19), value: taken)
    }

    private func zebra(barWidth: CGFloat) -> some View {
        let pitch = CGFloat(taken) * Self.naturalPitch > barWidth
            ? barWidth / CGFloat(taken)
            : Self.naturalPitch
        let stripeWidth = max(Self.minStripeWidth, pitch * Self.stripeDuty)
        return ForEach(0..<max(0, taken), id: \.self) { index in
            ZebraStripe(
                index: index,
                count: taken,
                pitch: pitch,
                width: stripeWidth,
                entersAnimated: index == taken - 1)
        }
    }
}

/// One zebra stripe. A separate view so each stripe owns its entrance —
/// scaleX 0.15 → 1 with a fade, anchored left — while position, width and
/// ramp opacity re-tween whenever a new shot recomputes the pitch.
private struct ZebraStripe: View {
    var index: Int
    var count: Int
    var pitch: CGFloat
    var width: CGFloat
    /// Only the stripe born by the newest shot grows in; the rest were
    /// already on screen (or arrive with seeded state) and just appear.
    var entersAnimated: Bool
    @State private var entered: Bool

    init(index: Int, count: Int, pitch: CGFloat, width: CGFloat, entersAnimated: Bool) {
        self.index = index
        self.count = count
        self.pitch = pitch
        self.width = width
        self.entersAnimated = entersAnimated
        // Stripes that don't animate in are visible from their first frame;
        // only the newborn one starts collapsed.
        _entered = State(initialValue: !entersAnimated)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(LL.amber)
            .frame(width: width)
            .scaleEffect(x: entered ? 1 : 0.15, y: 1, anchor: .leading)
            .offset(x: CGFloat(index) * pitch)
            .animation(BurstStatusIndicator.ease(0.17), value: count)
            // Decay ramp: oldest 30% → newest 100%, linear across the run.
            // It re-spreads on every shot, slightly slower than the layout
            // tween so ageing reads as its own movement.
            .opacity(entered ? 0.3 + 0.7 * (count == 1 ? 1 : Double(index) / Double(count - 1)) : 0)
            .animation(BurstStatusIndicator.ease(0.26), value: count)
            .onAppear {
                guard !entered else { return }
                withAnimation(.easeOut(duration: 0.21)) { entered = true }
            }
    }
}

extension BurstStatusIndicator {
    /// `taken` in amber, the denominator (when one exists) in dim white.
    /// Tabular by construction — the count swaps with no transition, so the
    /// only movement is the bar's.
    private var countReadout: some View {
        HStack(spacing: 0) {
            Text("\(taken)")
                .foregroundStyle(LL.amber)
            if let total {
                Text("/\(total)")
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .lineLimit(1)
        .frame(width: 46, alignment: .trailing)
    }
}

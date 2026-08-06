import SwiftUI

/// The render gauge (design 5a): the rig, already built, with the lens turned
/// into the readout. Replaces the plain `Circle().trim` ring that used to sit
/// over the footage on Processing and Collections export.
///
/// The arc around the pipe is a *sweep*, not a fill — the design deliberately
/// moves the resolution into the number, and lets the sweep keep the motion
/// honest between progress updates (a blend can go many seconds without one).
/// The four-stage checklist, the live frame counts and the ETA line under this
/// carry the rest of the state.
struct LLRigProgress: View {
    /// The renderer's real fraction, 0…1.
    var progress: Double
    /// Diameter of the mark. The lens is 34% of it, so the readout stops being
    /// legible well before the mark stops reading — 120 is the floor that keeps
    /// the digits comfortable, and is the size the design uses in-app.
    var size: CGFloat = 120

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    /// A frozen frame well past the mount-in, so Reduce Motion gets a mark that
    /// reads as deliberate rather than as a stalled spinner.
    private static let stillTime = LLRigBeats.loop * 3.25

    private var percent: Int { Int((min(1, max(0, progress)) * 100).rounded()) }

    var body: some View {
        ZStack {
            // Soft vignette instead of the old hard black disc: the mark has its
            // own silver body and amber bloom, and a cut edge around it over a
            // photograph looked like a sticker.
            RadialGradient(
                stops: [
                    .init(color: .black.opacity(0.55), location: 0),
                    .init(color: .black.opacity(0.45), location: 0.55),
                    .init(color: .black.opacity(0), location: 1),
                ],
                center: .center, startRadius: 0, endRadius: size * 0.78)
                .frame(width: size * 1.56, height: size * 1.56)

            ZStack {
                if reduceMotion {
                    LLRigMark(build: 1, time: Self.stillTime, style: .gauge, sweep: true)
                } else {
                    TimelineView(.animation) { context in
                        LLRigMark(
                            build: 1,
                            time: context.date.timeIntervalSince(start),
                            style: .gauge,
                            sweep: true)
                    }
                }

                readout
                    .position(
                        x: size * LLRigMark.lensUnitCentre.x,
                        y: size * LLRigMark.lensUnitCentre.y)
            }
            .frame(width: size, height: size)
        }
        .frame(width: size * 1.56, height: size * 1.56)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rendering")
        .accessibilityValue("\(percent) percent")
        .accessibilityAddTraits(.updatesFrequently)
        .onAppear { start = Date() }
    }

    private var readout: some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.012) {
            Text("\(percent)")
                .font(.system(size: size * 0.13, weight: .semibold).monospacedDigit())
                .foregroundStyle(LLRigPalette.accent.color())
            Text("%")
                .font(.system(size: size * 0.07, weight: .medium))
                .foregroundStyle(Color(.sRGB, red: 0x8A / 255, green: 0x9A / 255, blue: 0xB5 / 255))
        }
        .fixedSize()
    }
}

#if DEBUG
#Preview("Gauge") {
    VStack(spacing: 24) {
        LLRigProgress(progress: 0.34)
        LLRigProgress(progress: 0.87, size: 92)
    }
    .padding(40)
    .background(Color(.sRGB, red: 0.1, green: 0.12, blue: 0.16))
}
#endif

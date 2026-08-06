import SwiftUI

/// The cold-launch holding state (design 4a): the rig assembles itself, the
/// wordmark rises, and the app takes over. Roughly two seconds door to door —
/// which is the runway a cold start needs anyway, spent on the mark instead of
/// on a blank canvas.
///
/// The static launch screen behind this is already the same field colour (see
/// `LaunchBackground` in the asset catalog and `UILaunchScreen_BackgroundColor`
/// in the build settings), so the hand-off from UIKit to SwiftUI is invisible.
///
/// Dark in both appearances, deliberately. The mark's home is the app icon's
/// navy, and Create opens straight into the camera — so a light launch would
/// hand off into a black viewfinder a moment later, which is a worse seam than
/// a dark launch handing off into a light app.
struct LaunchAnimationView: View {
    var onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    /// How long the overlay stays up before the host crossfades it away.
    private var hold: Double { reduceMotion ? 0.6 : LLRigBeats.build }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let mark = min(260, max(150, side * 0.46))

            ZStack {
                LLRigPalette.field.color().ignoresSafeArea()

                Group {
                    if reduceMotion {
                        // No assembly, no bloom pulse — the settled mark, faded in.
                        stack(mark: mark, build: 1, time: 0, rise: (1, 0))
                    } else {
                        TimelineView(.animation) { context in
                            let t = context.date.timeIntervalSince(start)
                            stack(
                                mark: mark,
                                build: min(1, t / LLRigBeats.build),
                                time: t,
                                rise: riseState(at: t))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("LetsLapse")
        .accessibilityAddTraits(.isImage)
        #if os(iOS)
        // The field is dark whatever the system appearance is, so in light mode
        // the status bar would be black-on-navy. Hiding it for the two seconds
        // the mark is up is cheaper than flipping the window's colour scheme,
        // which would bleed light content through the cross-fade on the way out.
        .statusBarHidden(true)
        #endif
        .task {
            // Restart the clock on appear rather than trusting the `@State`
            // initialiser — a scene that is built ahead of being shown would
            // otherwise begin the build with the screen still dark.
            start = Date()
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            onFinish()
        }
    }

    private func stack(
        mark: CGFloat, build: Double, time: Double, rise: (opacity: Double, offset: CGFloat)
    ) -> some View {
        VStack(spacing: mark * 0.22) {
            LLRigMark(build: build, time: time)
                .frame(width: mark, height: mark)
            wordmark(size: mark * 0.125, opacity: rise.opacity, rise: rise.offset)
        }
    }

    private func riseState(at t: Double) -> (opacity: Double, offset: CGFloat) {
        let p = min(1, max(0, (t - LLRigBeats.wordmark.delay) / LLRigBeats.wordmark.duration))
        let eased = LLEase(0.2, 1, 0.3, 1)(p)
        return (eased, CGFloat((1 - eased) * 9))
    }

    private func wordmark(size: CGFloat, opacity: Double, rise: CGFloat) -> some View {
        Text("LETSLAPSE")
            .font(.system(size: size, weight: .semibold))
            .kerning(size * 0.26)
            // The tracking is applied after the last glyph too; pull it back so
            // the word stays optically centred.
            .padding(.leading, size * 0.26)
            .foregroundStyle(LLRigPalette.wordmark.color())
            .opacity(opacity)
            .offset(y: rise)
    }
}

extension LaunchAnimationView {
    /// Whether a cold launch should hold for the build.
    ///
    /// Screenshot runs drive the app straight to a screen with an `LL_` hook and
    /// must not sit through two seconds of animation first — so *any* hook
    /// suppresses it, rather than a hardcoded list that goes stale every time a
    /// new hook lands. `LL_LAUNCH=1` forces it back on so the splash itself can
    /// be captured.
    static var shouldPlayOnLaunch: Bool {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["LL_LAUNCH"] == "1" { return true }
        if environment.keys.contains(where: { $0.hasPrefix("LL_") }) { return false }
        #endif
        return true
    }
}

#if DEBUG
#Preview("Launch") {
    LaunchAnimationView(onFinish: {})
}
#endif

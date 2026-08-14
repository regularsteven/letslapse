#if os(watchOS) || os(macOS)
import SwiftUI
#if os(watchOS)
import WatchKit
#endif

/// The screen a worn remote settles into during a long shoot.
///
/// A timelapse is hands-off for minutes or hours, and for all of that time the
/// controls are riding on a wrist that is doing other things. Slide-to-commit
/// makes a *brush* harmless; it can't make a deliberate-looking drag from a
/// sleeve, a bag strap or a coat cuff harmless. After 90 s of no interaction
/// the controls simply go away, and the pads with them — a gesture cannot
/// reach a control that is not on screen.
///
/// What replaces them is the thing you actually want from across a room:
/// still recording, for how long, until when. Monochrome and inset-bordered so
/// it is recognisable at a glance as "locked, and fine".
///
/// Unlocking is crown rotation, the platform's own convention and the one
/// input a sleeve cannot produce.
struct ControlsLockedView: View {
    var elapsed: String
    var subline: String
    var stopsAt: String?
    /// 0…1 — how far through the unlock turn we are.
    var unlockProgress: Double

    var body: some View {
        ZStack {
            RemoteTint.ground
                .ignoresSafeArea()

            // Faint diagonal hatch: a second, non-colour signal that this is a
            // held state rather than a dimmed one.
            Rectangle()
                .fill(.white.opacity(0.022))
                .mask(hatch)
                .ignoresSafeArea()

            VStack(spacing: 7) {
                if unlockProgress > 0.02 {
                    unlockRing
                } else {
                    lockedBody
                }
            }
            .padding(.horizontal, RemoteMetric.gutter)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 3)
                .ignoresSafeArea()
        )
    }

    private var hatch: some View {
        GeometryReader { geometry in
            Path { path in
                let step: CGFloat = 12
                let span = geometry.size.width + geometry.size.height
                var x = -geometry.size.height
                while x < span {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x + geometry.size.height, y: geometry.size.height))
                    x += step
                }
            }
            .stroke(.white, lineWidth: 6)
        }
    }

    private var lockedBody: some View {
        VStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))

            Text("CONTROLS LOCKED")
                .font(.system(size: 11, weight: .bold))
                .kerning(0.8)
                .foregroundStyle(.white.opacity(0.75))

            HStack(spacing: 5) {
                Circle()
                    .fill(RemoteTint.record)
                    .frame(width: 7, height: 7)
                Text(elapsed)
                    .font(.system(size: 25, weight: .bold).monospacedDigit())
            }

            Text(subline)
                .font(RemoteType.subline)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let stopsAt {
                Text(stopsAt)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Text("Turn the crown to unlock")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 2)
        }
    }

    private var unlockRing: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.14), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: min(1, unlockProgress))
                    .stroke(RemoteTint.link, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "lock.open.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(RemoteTint.link)
            }
            .frame(width: 84, height: 84)

            Text("Keep turning")
                .font(.system(size: 14, weight: .bold))
            Text("Controls return at full turn")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
    }
}

/// The watch's own charge, for the lock screen.
///
/// Deliberately the WATCH's and labelled as such. The phone's battery is the
/// one that decides whether the shoot survives, but it isn't on the wire — so
/// showing an unlabelled percentage here would invite reading it as the
/// phone's, which is the wrong number to trust a two-hour run to.
enum RemoteBattery {
    static var watchPercent: Int? {
        #if os(watchOS)
        let device = WKInterfaceDevice.current()
        if !device.isBatteryMonitoringEnabled {
            device.isBatteryMonitoringEnabled = true
        }
        let level = device.batteryLevel
        guard level >= 0 else { return nil }
        return Int((level * 100).rounded())
        #else
        return nil
        #endif
    }
}
#endif

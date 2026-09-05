import SwiftUI
import LetsLapseKit

/// How worried a chip's value should look.
enum ShootPeekLevel {
    case normal, warn, alert

    var tint: Color {
        switch self {
        case .normal: return .white.opacity(0.85)
        case .warn: return LL.amber
        case .alert: return Color(red: 1, green: 59 / 255, blue: 48 / 255)
        }
    }
}

/// Everything a scheduled peek shows, as a value — so the card is a dumb
/// renderer and the capture screen owns every decision about what is true.
struct ShootPeekReadout: Equatable {
    /// The shoot's label when the schedule carried one, else the mode word.
    var title: String?
    var frameCount = 0
    /// The last frame this run banked. Nil until one has been decoded — the
    /// card simply drops the picture and its caption, rather than holding a
    /// grey rectangle open for something that may never arrive.
    var thumbnail: Image?
    var thumbnailAge: TimeInterval?
    /// nil while there is nothing to judge (a plain run with no cadence to
    /// miss); the line is then omitted rather than guessed at.
    var onSchedule: Bool?
    var elapsed = "0:00"
    var thermal = "nominal"
    var thermalLevel: ShootPeekLevel = .normal
    var space: String?
    var spaceLevel: ShootPeekLevel = .normal
    /// The running readout's own amber line, verbatim, so the peek and the
    /// live screen can never disagree about the exposure.
    var exposure: String?
    var blendLine: String?
}

/// The card a scheduled peek lifts the blackout to show.
///
/// **Why a card and not the viewfinder.** The peek exists to answer "is this
/// shoot going well?" from wherever the operator is standing, without a finger
/// on a phone that is on a tripod. A restored live viewfinder answers that
/// badly — at three metres it says the screen is on and nothing else — and it
/// costs the OLED exactly what the blackout was turned on to save. This is
/// legible at that distance and around 94 % black.
///
/// The reading order is the order the operator's questions arrive: what the
/// last frame looked like, how many there are, whether they are landing on
/// time, then the conditions, then the exposure. The footer is part of the
/// feature rather than chrome — a screen that goes black unannounced reads as
/// a crash, and naming the next peek is what means the phone need never be
/// touched. There are deliberately **no controls**: a shutter-sized target on
/// a screen meant for a glance is how a tripod gets nudged. A tap anywhere
/// hands over the real screen, which is the only route to the stop control.
///
/// Drawn from `docs/design/iOS/capture-interval.running.peek.portrait.svg`;
/// a deliberate sibling of `CaptureStandby`'s overlay, which is the same
/// vocabulary one state earlier.
struct ShootPeekCard: View {
    let readout: ShootPeekReadout
    /// When the cover comes back. Nil holds the footer's countdown blank.
    let endsAt: Date?
    let nextPeekAt: Date?

    private static let thumbnailWidth: CGFloat = 160
    private static let chipWidth: CGFloat = 98

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                header
                latestFrame
                hero
                verdict
                chips
                exposure
                Spacer(minLength: 24)
                footer
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: 420)
        }
        .ignoresSafeArea()
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(spacing: 8) {
            Text("SHOOTING")
                .font(.system(size: 12, weight: .heavy))
                .kerning(2.4)
                .foregroundStyle(LL.accent)
            if let title = readout.title {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        }
        .padding(.bottom, 27)
    }

    @ViewBuilder
    private var latestFrame: some View {
        if let thumbnail = readout.thumbnail {
            VStack(spacing: 8) {
                thumbnail
                    .resizable()
                    .scaledToFill()
                    .frame(width: Self.thumbnailWidth, height: Self.thumbnailWidth * 3 / 4)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.white.opacity(0.2), lineWidth: 1)
                    }
                Text(ageCaption)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.bottom, 26)
        }
    }

    private var ageCaption: String {
        guard let age = readout.thumbnailAge, age >= 0 else { return "latest frame" }
        return "latest frame · \(DurationFormatter.compactAge(age)) ago"
    }

    private var hero: some View {
        VStack(spacing: 2) {
            Text(readout.frameCount.formatted(.number))
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(LL.amber)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("frames")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private var verdict: some View {
        if let onSchedule = readout.onSchedule {
            HStack(spacing: 9) {
                Circle()
                    .fill(onSchedule
                          ? Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
                          : LL.amber)
                    .frame(width: 8, height: 8)
                Text(onSchedule ? "On schedule" : "Falling behind")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 20)
        }
    }

    private var chips: some View {
        HStack(spacing: 8) {
            chip("ELAPSED", readout.elapsed, .normal)
            chip("THERMAL", readout.thermal, readout.thermalLevel)
            if let space = readout.space {
                chip("SPACE", space, readout.spaceLevel)
            }
        }
        .padding(.bottom, 30)
    }

    private func chip(_ label: String, _ value: String, _ level: ShootPeekLevel) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .heavy))
                .kerning(1.2)
                .foregroundStyle(.white.opacity(0.35))
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(level.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: Self.chipWidth, height: 53)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var exposure: some View {
        VStack(spacing: 8) {
            if let exposure = readout.exposure {
                Text(exposure)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(LL.amber)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if let blendLine = readout.blendLine {
                Text(blendLine)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    /// The bar and the two lines that make the blackout's return read as the
    /// schedule working rather than as a fault.
    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 12) {
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule()
                        .fill(LL.amber.opacity(0.8))
                        .frame(width: 130 * remainingFraction(at: context.date))
                }
                .frame(width: 130, height: 3)

                Text(returnLine(at: context.date))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.35))
                Text("Tap for the viewfinder")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.22))
            }
        }
        .padding(.bottom, 34)
    }

    private func remainingFraction(at now: Date) -> CGFloat {
        guard let endsAt else { return 0 }
        let remaining = endsAt.timeIntervalSince(now)
        return CGFloat(min(1, max(0, remaining / ShootPeekSchedule.peekSeconds)))
    }

    private func returnLine(at now: Date) -> String {
        var parts: [String] = []
        if let endsAt {
            let remaining = max(0, Int(endsAt.timeIntervalSince(now).rounded(.up)))
            parts.append("Screen returns in \(remaining) s")
        }
        if let nextPeekAt {
            parts.append("next peek \(nextPeekAt.formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }
}

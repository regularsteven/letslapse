import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Standby overlay

/// The screen a phone shows while it waits for a scheduled shoot.
///
/// It is deliberately almost nothing: black to the edges (an OLED panel
/// showing black draws next to no power, and a bright screen in a dark room
/// is its own kind of light pollution), the screen dimmed to a tenth of a
/// stop above off, and one number — how long until the shutter.
///
/// Behind it there is no capture session at all until the warm-up fires; see
/// `CaptureView.enterStandbyIfScheduled`.
struct StandbyOverlay: View {
    var scheduled: ScheduledRecording
    /// Driven by the capture screen's half-second tick rather than a clock of
    /// its own — one timer is enough, and it is already running.
    var now: Date
    /// True once the camera has been woken behind the overlay (T−60 s).
    var isWarmingCamera: Bool
    var onCancel: () -> Void

    #if os(iOS)
    /// The brightness to put back on the way out. Captured on appear so a
    /// user who dimmed or raised the screen themselves gets their own value
    /// back, not a guess.
    @State private var brightnessToRestore: CGFloat?
    /// Low enough to be invisible across a dark room, high enough that the
    /// countdown can still be read by walking up to it.
    private static let standbyBrightness: CGFloat = 0.05
    #endif

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 20)

                Text("STANDBY")
                    .font(.system(size: 12, weight: .heavy))
                    .tracking(2.4)
                    .foregroundStyle(LL.accent)

                if let label = scheduled.label, !label.isEmpty {
                    Text(label)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.top, 10)
                        .padding(.horizontal, 24)
                }

                Text(countdownText)
                    .font(.system(size: 54, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(LL.amber)
                    .padding(.top, 14)
                    .accessibilityLabel("Starts in \(countdownText)")

                Text("Starts at \(startTimeText)")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 6)

                summary
                    .padding(.top, 26)

                statusChip
                    .padding(.top, 18)

                Spacer(minLength: 20)

                Button(action: onCancel) {
                    Text("Cancel scheduled shoot")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(
                            Capsule().stroke(Color.white.opacity(0.28), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 32)
                .padding(.bottom, 34)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            #if os(iOS)
            brightnessToRestore = UIScreen.main.brightness
            UIScreen.main.brightness = Self.standbyBrightness
            #endif
        }
        .onDisappear {
            #if os(iOS)
            if let brightnessToRestore {
                UIScreen.main.brightness = brightnessToRestore
            }
            brightnessToRestore = nil
            #endif
        }
    }

    /// What the shoot is armed to do, in the capture screen's own vocabulary.
    private var summary: some View {
        HStack(spacing: 8) {
            standbyChip(title: "EVERY", value: intervalText)
            if let minutes = scheduled.durationMinutes {
                standbyChip(title: "FOR", value: durationText(minutes))
            }
            if let frames = scheduled.blendDepth {
                standbyChip(title: "BLEND", value: frames > 1 ? "\(frames)" : "Off")
            }
        }
        .padding(.horizontal, 20)
    }

    private func standbyChip(title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.35))
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(minWidth: 74)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    /// Before the warm-up, the honest status is "the camera is off". After it,
    /// the phone is visibly doing something, and says so.
    @ViewBuilder
    private var statusChip: some View {
        if isWarmingCamera {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(LL.amber)
                Text("Preparing camera…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LL.amber)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(
                Capsule().fill(LL.amber.opacity(0.12))
            )
            .overlay(
                Capsule().stroke(LL.amber.opacity(0.35), lineWidth: 1)
            )
        } else {
            HStack(spacing: 8) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 11))
                Text("Camera off to save power")
                    .font(.system(size: 13))
            }
            .foregroundStyle(.white.opacity(0.35))
        }
    }

    // MARK: Text

    private var remaining: TimeInterval {
        max(0, scheduled.startDate.timeIntervalSince(now))
    }

    /// HH:MM:SS, always all three fields — a countdown that changes width as
    /// it crosses an hour reads as a glitch on a screen with nothing else on
    /// it, and this one is stared at.
    private var countdownText: String {
        let total = Int(remaining.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private var startTimeText: String {
        scheduled.startDate.formatted(date: .omitted, time: .shortened)
    }

    private var intervalText: String {
        let seconds = scheduled.intervalSeconds
        return seconds < 1 || seconds != seconds.rounded()
            ? String(format: "%.1fs", seconds)
            : "\(Int(seconds))s"
    }

    private func durationText(_ minutes: Int) -> String {
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        if minutes > 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}

// MARK: - Schedule sheet

/// Arms a shoot for a wall-clock time. Start time and run length only — the
/// spacing and the blend depth are already set on the capture screen behind
/// it, and asking for them twice would be asking which of the two answers is
/// the real one.
struct ScheduleShootSheet: View {
    /// The capture screen's current dials, carried into the schedule so the
    /// shoot fires with what was armed rather than with whatever the screen
    /// was left on afterwards.
    var intervalSeconds: Double
    var blendFrames: Int?
    var onSchedule: (ScheduledRecording) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Minutes; nil is "until I stop it".
    private enum Duration: Hashable {
        case off, minutes(Int), custom

        var label: String {
            switch self {
            case .off: return "Off"
            case .minutes(let m): return m % 60 == 0 ? "\(m / 60)h" : "\(m)m"
            case .custom: return "Custom"
            }
        }
    }

    private static let presets: [Duration] = [
        .off, .minutes(30), .minutes(60), .minutes(120), .minutes(240), .custom,
    ]

    /// The floor the picker enforces. Fixed at the moment the sheet opens: a
    /// range whose lower bound crept forward under the user's finger would
    /// snatch the value they were choosing.
    private let earliest: Date
    @State private var startDate: Date
    @State private var duration: Duration = .off
    @State private var customMinutes = 90
    @State private var label = ""

    init(intervalSeconds: Double, blendFrames: Int?, onSchedule: @escaping (ScheduledRecording) -> Void) {
        self.intervalSeconds = intervalSeconds
        self.blendFrames = blendFrames
        self.onSchedule = onSchedule
        let floor = Date().addingTimeInterval(5 * 60)
        self.earliest = floor
        // Opens ten minutes out, on the minute — a round number to nudge, not
        // an odd one to correct.
        let opening = Date().addingTimeInterval(10 * 60)
        let rounded = Calendar.current.date(
            bySetting: .second, value: 0, of: opening) ?? opening
        _startDate = State(initialValue: max(floor, rounded))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(.white.opacity(0.25))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .padding(.bottom, 18)

            Text("Schedule shoot")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
            Text("The screen goes dark and the camera powers down until a minute before the start.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
                .padding(.bottom, 20)

            DatePicker(
                "Starts",
                selection: $startDate,
                in: earliest...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .tint(LL.amber)
            .padding(.bottom, 18)

            Text("Run for")
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .padding(.bottom, 8)

            HStack(spacing: 6) {
                ForEach(Self.presets, id: \.self) { option in
                    let isSelected = duration == option
                    Button {
                        duration = option
                    } label: {
                        Text(option.label)
                            .font(.system(size: 12, weight: isSelected ? .bold : .regular))
                            .foregroundStyle(isSelected ? .black : .white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                isSelected ? LL.amber : Color.white.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, duration == .custom ? 10 : 18)

            if duration == .custom {
                Stepper(value: $customMinutes, in: 15...720, step: 15) {
                    HStack {
                        Text("Length")
                            .foregroundStyle(.white)
                        Spacer()
                        Text(customLabel)
                            .fontWeight(.bold)
                            .foregroundStyle(LL.amber)
                    }
                    .font(.system(size: 14))
                }
                .padding(.bottom, 18)
            }

            TextField("", text: $label, prompt: Text("Label (optional)")
                .foregroundColor(.white.opacity(0.35)))
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .padding(.vertical, 11)
                .padding(.horizontal, 12)
                .background(
                    Color.white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .padding(.bottom, 14)

            HStack(spacing: 10) {
                Image(systemName: "timer")
                    .font(.system(size: 18))
                    .foregroundStyle(LL.amber)
                Text(dialsSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LL.amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.bottom, 16)

            Button {
                onSchedule(ScheduledRecording(
                    startDate: startDate,
                    intervalSeconds: intervalSeconds,
                    durationMinutes: durationMinutes,
                    blendDepth: blendFrames,
                    label: label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil
                        : label.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
                dismiss()
            } label: {
                Text("Schedule")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(LL.amber, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
        .preferredColorScheme(.dark)
        #if os(iOS)
        // Sized to the content, measured on a 16 Pro — a detent taller than
        // the sheet leaves a band of empty card under the confirm button,
        // which reads as a form with something missing from it.
        .presentationDetents([.height(duration == .custom ? 530 : 470)])
        #else
        .frame(minWidth: 380, minHeight: 560)
        #endif
    }

    private var durationMinutes: Int? {
        switch duration {
        case .off: return nil
        case .minutes(let m): return m
        case .custom: return customMinutes
        }
    }

    private var customLabel: String {
        if customMinutes % 60 == 0 { return "\(customMinutes / 60)h" }
        if customMinutes > 60 { return "\(customMinutes / 60)h \(customMinutes % 60)m" }
        return "\(customMinutes)m"
    }

    /// What the shoot will inherit from the screen behind the sheet, said out
    /// loud so nobody has to remember what the dials were on.
    private var dialsSummary: String {
        let spacing = intervalSeconds < 1 || intervalSeconds != intervalSeconds.rounded()
            ? String(format: "%.1fs", intervalSeconds)
            : "\(Int(intervalSeconds))s"
        var text = "Shoots every \(spacing)"
        if let blendFrames {
            text += blendFrames > 1 ? ", blending \(blendFrames) frames" : ", no blending"
        }
        return text + " — the dials set on the capture screen."
    }
}

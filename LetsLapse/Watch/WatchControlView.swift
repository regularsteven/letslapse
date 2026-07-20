import SwiftUI

/// Remote capture in three states: Ready (states its precondition),
/// Recording (giant no-look controls), Unreachable (explains the fix).
struct WatchControlView: View {
    @EnvironmentObject private var remote: WatchCaptureRemote
    @State private var now = Date()
    @State private var isoAdjust: Double = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let amber = Color(red: 1, green: 0.7, blue: 0.25)

    var body: some View {
        Group {
            if remote.recordingState == .recording {
                recordingScreen
            } else if remote.isReachable && remote.isCameraActive {
                readyScreen
            } else {
                unreachableScreen
            }
        }
        .onAppear {
            remote.refreshState()
        }
        .onReceive(timer) { date in
            now = date
        }
    }

    // MARK: - Ready

    private var readyScreen: some View {
        VStack(spacing: 6) {
            Label("Ready · camera open", systemImage: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(readyDetailLine)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 4)

            Button {
                remote.startRecording()
            } label: {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.9), lineWidth: 3)
                    Circle()
                        .fill(Color.red)
                        .padding(7)
                    Text("START")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 96, height: 96)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(remote.isSending)

            Spacer(minLength: 4)

            exposureControl

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .navigationTitle("LetsLapse")
    }

    /// One-tap exposure lock, mirrored by the button state — no readouts to
    /// squint at once locked, just the frozen ISO/shutter and an unlock.
    private var exposureControl: some View {
        Group {
            if remote.isExposureLocked {
                VStack(spacing: 4) {
                    Label(lockedExposureLabel, systemImage: "lock.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(amber)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Button {
                        remote.unlockExposure()
                    } label: {
                        Text("Unlock exposure")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.plain)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            } else {
                Button {
                    remote.lockExposure()
                } label: {
                    Label("Lock exposure", systemImage: "lock.open")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.plain)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .disabled(remote.isSending || !remote.isReachable)
    }

    private var isoLabel: String {
        "ISO \(Int(remote.lockedISO.rounded()))"
    }

    private var lockedExposureLabel: String {
        "\(isoLabel) · \(shutterLabel(remote.lockedShutter))"
    }

    private func shutterLabel(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds >= 1 { return String(format: "%.1fs", seconds) }
        return "1/\(Int((1 / seconds).rounded()))"
    }

    private var readyDetailLine: String {
        var parts: [String] = []
        if let formatLine = remote.formatLine {
            parts.append(formatLine)
        }
        if remote.plannedSpeed > 0 {
            parts.append("\(remote.plannedSpeed)× planned")
        }
        return parts.isEmpty ? "Waiting for camera details" : parts.joined(separator: " · ")
    }

    // MARK: - Recording

    private var recordingScreen: some View {
        VStack(spacing: 7) {
            HStack {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                    Text("REC")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
                Spacer()
                Text(elapsedTime)
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
            }

            HStack {
                Text(liveEstimateLine)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(amber)
                Spacer()
                if remote.isExposureLocked {
                    Text("\(isoLabel) 🔒")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(amber)
                        .lineLimit(1)
                }
            }

            if remote.sequenceMode == "ramp" {
                burstToggle
            } else {
                Button {
                    remote.triggerMoment()
                } label: {
                    Label(
                        remote.isRampActive ? "End marker" : "Marker",
                        systemImage: "flag.fill"
                    )
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.plain)
                .background(
                    remote.isRampActive ? amber.opacity(0.35) : Color.white.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .disabled(remote.isSending || !remote.isReachable)
            }

            Button {
                remote.stopRecording()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(red: 1, green: 0.41, blue: 0.38))
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.plain)
            .background(Color.red.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.red.opacity(0.6), lineWidth: 1)
            )
            .disabled(remote.isSending || !remote.isReachable)

            intervalDots

            Text(sequenceCaption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 6)
        .focusable(remote.isExposureLocked)
        .digitalCrownRotation(
            $isoAdjust,
            from: remote.isoMin,
            through: remote.isoMax,
            by: 50,
            sensitivity: .medium
        )
        .onChange(of: isoAdjust) { newValue in
            guard remote.isExposureLocked else { return }
            remote.setISO(newValue)
        }
        .onChange(of: remote.isExposureLocked) { locked in
            if locked { isoAdjust = remote.lockedISO }
        }
        .onAppear { isoAdjust = remote.lockedISO }
    }

    /// The 24⇄240 toggle — one giant tap, mirrored by the button state.
    private var burstToggle: some View {
        HStack(spacing: 6) {
            burstSegment(label: baseRateLabel, isActive: !remote.isRampHighRate)
            burstSegment(label: "⚡ burst", isActive: remote.isRampHighRate)
        }
    }

    private func burstSegment(label: String, isActive: Bool) -> some View {
        Button {
            // Either side toggles: there are only two states.
            remote.triggerMoment()
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isActive ? .black : .white)
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.plain)
        .background(
            isActive ? amber : Color.white.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .disabled(remote.isSending || !remote.isReachable)
    }

    private var baseRateLabel: String {
        remote.captureFPS > 0 ? "\(remote.captureFPS)" : "base"
    }

    /// One amber dot per burst/marker interval, pulsing while one is open.
    private var intervalDots: some View {
        HStack(spacing: 4) {
            if remote.rampIntervalCount == 0 {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 22, height: 4)
            } else {
                ForEach(0..<min(remote.rampIntervalCount, 10), id: \.self) { index in
                    Circle()
                        .fill(amber.opacity(
                            remote.isRampActive && index == remote.rampIntervalCount - 1 ? 1 : 0.55
                        ))
                        .frame(width: 6, height: 6)
                }
            }
        }
        .frame(height: 8)
    }

    private var sequenceCaption: String {
        let count = remote.rampIntervalCount
        if remote.sequenceMode == "ramp" {
            let state = remote.isRampHighRate ? "burst active" : "base rate"
            return "\(state) · \(count) interval\(count == 1 ? "" : "s")"
        }
        return "\(count) marker\(count == 1 ? "" : "s")"
    }

    private var liveEstimateLine: String {
        guard remote.plannedSpeed > 0 else { return "recording…" }
        var line = "@\(remote.plannedSpeed)×"
        if let startedAt = remote.recordingStartedAt, remote.captureFPS > 0, remote.outputFPS > 0 {
            let elapsed = max(0, now.timeIntervalSince(startedAt))
            let outputSeconds = elapsed * Double(remote.captureFPS)
                / Double(remote.plannedSpeed) / Double(remote.outputFPS)
            line += " → \(clipLabel(outputSeconds))"
        }
        return line
    }

    private func clipLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0s" }
        if seconds < 9.95 { return String(format: "%.1fs", seconds) }
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    // MARK: - Unreachable

    private var unreachableScreen: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Image(systemName: "iphone")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("Open the camera on iPhone")
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
            Text("The remote works while the LetsLapse capture screen is open.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
            Button {
                remote.reconnect()
            } label: {
                Text("Ping iPhone")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(remote.isSending)
        }
        .padding(.horizontal, 6)
    }

    private var elapsedTime: String {
        guard let startedAt = remote.recordingStartedAt else { return "00:00" }
        return DurationFormatter.recordingTime(from: max(0, now.timeIntervalSince(startedAt)))
    }
}

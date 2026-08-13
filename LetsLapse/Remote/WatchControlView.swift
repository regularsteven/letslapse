// This file is compiled into BOTH the watch app and the universal app target
// — and that target also builds iOS, where a second WCSession delegate would
// sit alongside WatchRemoteControlReceiver contending for the single
// `WCSession.default.delegate` slot. So the condition is macOS-POSITIVE, not
// watchOS-negative: the remote exists on the wrist and on the Mac, nowhere
// else. See Remote/ in the project layout.
#if os(watchOS) || os(macOS)
import SwiftUI

/// Remote capture in three states: Ready (states its precondition),
/// Recording (giant no-look controls), Unreachable (explains the fix).
struct WatchControlView: View {
    @EnvironmentObject private var remote: WatchCaptureRemote
    @Environment(\.scenePhase) private var scenePhase
    @State private var now = Date()
    @State private var lastAutoRefreshAt = Date.distantPast
    @State private var isoAdjust: Double = 0
    @State private var showIntervalPicker = false
    @State private var showFramesPicker = false
    @State private var showStopAtSheet = false
    /// Armed burst length in seconds; 0 = none, so ⚡ runs open-ended. The
    /// last choice (including "none") is the default for every later run.
    @AppStorage("letslapse.watch.burstDefaultSeconds") private var armedBurstSeconds = 1
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let amber = Color(red: 1, green: 0.7, blue: 0.25)
    // Mirrors of the phone's option lists; the phone rejects anything else.
    // The picker offers the fixed counts only — the adaptive depths
    // (Psycho/Safe) are chosen on the phone, where Safe's gating lives, and
    // show here as labels.
    private let intervalOptions: [Double] = [0.5, 1.0, 2.0, 3.0, 5.0, 10.0]
    private let frameOptions = BlendDepth.fixedOptions

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
        // A watchOS app suspends on wrist-down and resumes on wrist-up without
        // firing `onAppear`, so a resume mid-shoot would otherwise keep showing
        // whatever state was last known. Re-pull whenever we return to active.
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                remote.reconnect()
            }
        }
        .onReceive(timer) { date in
            now = date
            autoRefreshIfDisconnected(at: date)
        }
    }

    /// While the "open the camera" screen is up, quietly re-ask the phone every
    /// few seconds. Connection loss is often one dropped message — a single
    /// missed round-trip previously parked this screen until a manual ping,
    /// even mid-recording. Screen-gated, so it costs nothing once connected.
    private func autoRefreshIfDisconnected(at date: Date) {
        guard remote.recordingState != .recording,
              !(remote.isReachable && remote.isCameraActive),
              !remote.isSending,
              date.timeIntervalSince(lastAutoRefreshAt) >= 4 else { return }
        lastAutoRefreshAt = date
        remote.refreshState()
    }

    // MARK: - Ready

    private var readyScreen: some View {
        ScrollView {
            VStack(spacing: 8) {
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

                modeSelector

                if remote.isBulbMode {
                    Label("Bulb · start, then slide to stop", systemImage: "circle.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(amber)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.vertical, 2)
                }

                if remote.captureMode == .interval {
                    intervalRow
                    framesRow
                }

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
                    .frame(width: 92, height: 92)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(remote.isSending)

                exposureControl
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .navigationTitle("LetsLapse")
    }

    /// The capture modes as tappable rows — same vocabulary as the phone's
    /// mode buttons, selected row marked in amber. Photo is a phone-only mode
    /// (it gates on device motion the wrist can't stand in for), so it isn't
    /// offered here.
    private var modeSelector: some View {
        VStack(spacing: 4) {
            ForEach(CaptureMode.allCases.filter { $0 != .photo }) { mode in
                Button {
                    remote.setCaptureMode(mode)
                } label: {
                    HStack {
                        Text(mode.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        if remote.captureMode == mode {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(amber)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    remote.captureMode == mode ? amber.opacity(0.22) : Color.white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
        }
        .disabled(remote.isSending || !remote.isReachable)
    }

    private var intervalRow: some View {
        Button {
            showIntervalPicker = true
        } label: {
            HStack {
                Text("Every")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(intervalLabel(remote.intervalSeconds))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(amber)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .disabled(remote.isSending || !remote.isReachable)
        .sheet(isPresented: $showIntervalPicker) {
            List(intervalOptions, id: \.self) { seconds in
                Button {
                    remote.setIntervalSeconds(seconds)
                    showIntervalPicker = false
                } label: {
                    HStack {
                        Text(intervalLabel(seconds))
                        Spacer()
                        if remote.intervalSeconds == seconds {
                            Image(systemName: "checkmark")
                                .foregroundStyle(amber)
                        }
                    }
                }
            }
        }
    }

    private var framesRow: some View {
        Button {
            showFramesPicker = true
        } label: {
            HStack {
                Text("Blend")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(blendDepthLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(amber)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .disabled(remote.isSending || !remote.isReachable)
        .sheet(isPresented: $showFramesPicker) {
            List(frameOptions, id: \.frames) { option in
                Button {
                    remote.setFramesPerBlend(option.frames)
                    showFramesPicker = false
                } label: {
                    HStack {
                        Text(option.frames == 1 ? option.label : "\(option.frames) · \(option.label)")
                        Spacer()
                        if remote.blendDepth == .fixed(option.frames) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(amber)
                        }
                    }
                }
            }
        }
    }

    private func intervalLabel(_ seconds: Double) -> String {
        seconds == seconds.rounded(.down) ? "\(Int(seconds)) s" : String(format: "%.1f s", seconds)
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
        // What ⚡ will do. The burst chips are durations (1s/4s/8s) and the
        // toggle's left segment is the base rate, so without this the burst
        // rate appeared nowhere at all — a camera set to base 25 / burst 50
        // read exactly like one with no ramp configured. ⚡ matches the burst
        // segment's own glyph. Suppressed when it matches the base rate, or
        // in the still modes, which have no burst.
        if remote.rampFPS > 0, remote.rampFPS != remote.baseFPS {
            parts.append("⚡\(remote.rampFPS)")
        }
        if remote.plannedSpeed > 0 {
            parts.append("\(remote.plannedSpeed)× planned")
        }
        return parts.isEmpty ? "Waiting for camera details" : parts.joined(separator: " · ")
    }

    // MARK: - Recording

    /// Scrolls so the timed-burst row fits above the stop slider even on the
    /// small cases — everything stays reachable, nothing gets clipped.
    private var recordingScreen: some View {
        ScrollView {
            recordingControls
        }
        .crownAdjustable(
            $isoAdjust,
            from: remote.isoMin,
            through: remote.isoMax,
            by: 50,
            isEnabled: remote.isExposureLocked
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

    private var recordingControls: some View {
        VStack(spacing: 6) {
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
                Text(remote.captureMode == .video ? liveEstimateLine : runSettingsLine)
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

            HStack(spacing: 6) {
                exposureLockButton
                if remote.captureMode != .video {
                    captureCountBadge
                } else if remote.sequenceMode == "ramp" {
                    burstToggle
                } else {
                    markerButton
                }
            }

            if remote.captureMode == .video && remote.sequenceMode == "ramp" {
                timedBurstRow
            }

            SlideToStop(
                enabled: !remote.isSending && remote.isReachable,
                label: slideToStopLabel
            ) {
                remote.stopRecording()
            }

            stopAtControl

            if remote.captureMode == .video {
                intervalDots

                Text(sequenceCaption)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 6)
    }

    /// Mid-shoot AE/AF lock — amber = locked, so you can grab a lock the moment
    /// a tram crosses the frame and release it once the light settles again.
    private var exposureLockButton: some View {
        Button {
            if remote.isExposureLocked {
                remote.unlockExposure()
            } else {
                remote.lockExposure()
            }
        } label: {
            Image(systemName: remote.isExposureLocked ? "lock.fill" : "lock.open")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(remote.isExposureLocked ? .black : .white)
                .frame(width: 48, height: 34)
        }
        .buttonStyle(.plain)
        .background(
            remote.isExposureLocked ? amber : Color.white.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .disabled(remote.isSending || !remote.isReachable)
        .accessibilityLabel(remote.isExposureLocked ? "Unlock exposure" : "Lock exposure")
    }

    private var markerButton: some View {
        Button {
            remote.triggerMoment()
        } label: {
            Label(
                remote.isRampActive ? "End marker" : "Marker",
                systemImage: "flag.fill"
            )
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.plain)
        .background(
            remote.isRampActive ? amber.opacity(0.35) : Color.white.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .disabled(remote.isSending || !remote.isReachable)
    }

    /// One segmented control, two states — base rate ⇄ burst. Each side
    /// *selects* its state (tapping the active side is a no-op): ⚡ starts a
    /// burst — the armed length, or open-ended when none is armed — and the
    /// fps side returns to base, which is also how a running burst is
    /// cancelled early. Only ⚡ ever starts anything, so a fumbled tap on the
    /// fps number can no longer fire a burst.
    private var burstToggle: some View {
        HStack(spacing: 0) {
            burstSegment(label: baseRateLabel, isActive: !remote.isRampHighRate) {
                guard remote.isRampHighRate else { return }
                remote.triggerMoment()
            }
            burstSegment(label: burstSegmentLabel, isActive: remote.isRampHighRate) {
                guard !remote.isRampHighRate else { return }
                if armedBurstSeconds > 0 {
                    remote.triggerTimedBurst(seconds: armedBurstSeconds)
                } else {
                    remote.triggerMoment()
                }
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func burstSegment(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isActive ? .black : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.plain)
        .background(
            isActive ? amber : .clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .disabled(remote.isSending || !remote.isReachable)
    }

    /// ⚡ previews what pressing it will do: the armed length, or open-ended.
    private var burstSegmentLabel: String {
        armedBurstSeconds > 0 ? "⚡ \(armedBurstSeconds)s" : "⚡ burst"
    }

    /// Labels from the sequence's resting rate, never `captureFPS` — that one
    /// tracks the active segment and reads the burst rate mid-burst, which
    /// mislabeled this chip "120" during and just after a burst. Falls back
    /// to `captureFPS` for phone builds that predate the baseFPS key.
    private var baseRateLabel: String {
        if remote.baseFPS > 0 { return "\(remote.baseFPS)" }
        return remote.captureFPS > 0 ? "\(remote.captureFPS)" : "base"
    }

    /// The armed burst length — a setting, not a trigger. One chip may be
    /// ticked (radio-with-off: tapping it again deselects); ⚡ fires whatever
    /// is armed, and the phone still owns the revert timer so the drop back
    /// to base lands even if the watch sleeps mid-burst. Chips are local and
    /// safe to fumble, so they never disable. The tick matches the ready
    /// screen's selected-option vocabulary; amber *fill* stays reserved for
    /// the toggle's live segment.
    private var timedBurstRow: some View {
        // 1/4/8, not 1/2/4 (2026-08-11 ramp review): seam eases are funded by
        // burst footage, and under ~4 s at 100 fps a ramped seam eats the
        // whole burst bridging its own cuts. 1 s stays as the "just a beat"
        // accent; 2 s promised more than post could keep.
        HStack(spacing: 6) {
            timedBurstButton(seconds: 1)
            timedBurstButton(seconds: 4)
            timedBurstButton(seconds: 8)
        }
    }

    private func timedBurstButton(seconds: Int) -> some View {
        let isArmed = armedBurstSeconds == seconds
        return Button {
            armedBurstSeconds = isArmed ? 0 : seconds
        } label: {
            HStack(spacing: 3) {
                if isArmed {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(amber)
                }
                Text("\(seconds)s")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.plain)
        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel("\(seconds) second burst length")
        .accessibilityAddTraits(isArmed ? [.isSelected] : [])
    }

    /// Interval's counterpart of the burst toggle's slot: how many outputs
    /// have landed so far.
    private var captureCountBadge: some View {
        Text("\(remote.captureCount) \(remote.blendDepth.blends ? "blends" : "photos")")
            .font(.system(size: 13, weight: .bold).monospacedDigit())
            .foregroundStyle(amber)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var blendDepthLabel: String {
        switch remote.blendDepth {
        case .fixed(1): return "Off"
        case .fixed(let frames): return "\(frames) frames"
        case .unthrottled: return "Psycho"
        case .throttled: return "Safe"
        }
    }

    private var runSettingsLine: String {
        if remote.isBulbMode {
            return remote.blendDepth == .fixed(1) ? "Bulb · single frame" : "Bulb · long exposure"
        }
        let every = "every \(intervalLabel(remote.intervalSeconds))"
        switch remote.blendDepth {
        case .fixed(1): return every
        case .fixed(let frames): return "\(every) · \(frames) fr"
        case .unthrottled: return "\(every) · Psycho"
        case .throttled: return "\(every) · Safe"
        }
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
            // Name the rate rather than just the state: "burst active" told
            // you a burst was running but never at what rate.
            let state: String
            if remote.isRampHighRate {
                state = remote.rampFPS > 0 ? "burst \(remote.rampFPS)" : "burst active"
            } else {
                state = remote.baseFPS > 0 ? "base \(remote.baseFPS)" : "base rate"
            }
            return "\(state) · \(count) interval\(count == 1 ? "" : "s")"
        }
        return "\(count) marker\(count == 1 ? "" : "s")"
    }

    private var liveEstimateLine: String {
        guard remote.plannedSpeed > 0 else { return "recording…" }
        var line = "@\(remote.plannedSpeed)×"
        // Deliberately the BASE rate, not `captureFPS`. captureFPS reports the
        // segment running right now, so mid-burst this multiplied the whole
        // elapsed time by the burst rate — the projected clip length doubled
        // the instant a burst started and halved when it ended, as though the
        // entire take had been shot at the burst rate.
        //
        // The base rate makes this a slight UNDER-estimate while a burst runs
        // (those seconds really do yield more frames), which is the honest
        // direction to be wrong in: it drifts by the burst's share of the take
        // instead of lying about all of it. An exact figure needs the frame
        // count per segment, which the camera has and does not send.
        let estimateFPS = remote.baseFPS > 0 ? remote.baseFPS : remote.captureFPS
        if let startedAt = remote.recordingStartedAt, estimateFPS > 0, remote.outputFPS > 0 {
            let elapsed = max(0, now.timeIntervalSince(startedAt))
            let outputSeconds = elapsed * Double(estimateFPS)
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
            // Never disabled: this is the recovery control. A stuck send used
            // to gray it out exactly when the user needed it most.
            Button {
                remote.reconnect()
            } label: {
                Text("Ping iPhone")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.horizontal, 6)
    }

    private var elapsedTime: String {
        guard let startedAt = remote.recordingStartedAt else { return "00:00" }
        return DurationFormatter.recordingTime(from: max(0, now.timeIntervalSince(startedAt)))
    }

    // MARK: - Scheduled stop

    /// The slider label doubles as the countdown once a stop is scheduled.
    private var slideToStopLabel: String {
        guard let unit = remote.stopAtUnit else { return "Slide to stop" }
        switch unit {
        case .minutes:
            guard let deadline = remote.stopAtDeadline else { return "Slide to stop" }
            let remaining = max(0, deadline.timeIntervalSince(now))
            return "Stopping in \(DurationFormatter.recordingTime(from: remaining))"
        case .frames:
            if let target = remote.stopAtTargetCount {
                return "Stopping in \(max(0, target - remote.captureCount)) frames"
            }
            if let deadline = remote.stopAtDeadline {
                let seconds = max(0, deadline.timeIntervalSince(now))
                let frames = Int((seconds * Double(max(1, remote.captureFPS))).rounded(.up))
                return "Stopping in \(frames) frames"
            }
            return "Slide to stop"
        }
    }

    @ViewBuilder
    private var stopAtControl: some View {
        if remote.stopAtUnit != nil {
            Button {
                remote.cancelScheduledStop()
            } label: {
                Text("Cancel Stop At")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(amber)
                    .frame(maxWidth: .infinity, minHeight: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(remote.isSending || !remote.isReachable)
        } else {
            Button {
                showStopAtSheet = true
            } label: {
                Text("Stop at…")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(remote.isSending || !remote.isReachable)
            .sheet(isPresented: $showStopAtSheet) {
                StopAtSheet { unit, amount in
                    remote.scheduleStop(unit: unit, amount: amount)
                }
                .environmentObject(remote)
            }
        }
    }
}

/// Mini modal for "stop at…": pick minutes or frames, dial the number with a
/// vertical swipe or the crown, confirm or cancel. Amounts are totals for the
/// whole run — "stop at" the 10-minute mark, not in 10 more minutes — so the
/// dial floors just past what the run has already used (a passed mark can't
/// be dialled) and a live caption shows when the stop would land. Frames is
/// Interval-only: a video run's total frame count outgrows a wrist dial.
private struct StopAtSheet: View {
    var onConfirm: (ScheduledStopUnit, Int) -> Void
    @EnvironmentObject private var remote: WatchCaptureRemote
    @Environment(\.dismiss) private var dismiss

    @State private var unit: ScheduledStopUnit = .minutes
    @State private var amount = 10
    @State private var crownValue: Double = 10
    @State private var appliedDragSteps = 0
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let amber = Color(red: 1, green: 0.7, blue: 0.25)

    private var upperBound: Int { unit == .minutes ? 180 : 999 }
    private var defaultAmount: Int { unit == .minutes ? 10 : 50 }

    private var elapsedSeconds: TimeInterval {
        guard let startedAt = remote.recordingStartedAt else { return 0 }
        return max(0, now.timeIntervalSince(startedAt))
    }

    /// The first amount still ahead of the run. Clamped into the dial range —
    /// a run past the 180-minute cap pins the dial at 180, and confirming
    /// that stops on the spot.
    private var lowerBound: Int {
        let floor = unit == .minutes ? Int(elapsedSeconds / 60) + 1 : remote.captureCount + 1
        return min(max(1, floor), upperBound)
    }

    var body: some View {
        VStack(spacing: 6) {
            Text("Stop at")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 4) {
                unitChip(.minutes, label: "Minutes")
                if remote.captureMode != .video {
                    unitChip(.frames, label: "Frames")
                }
            }

            Text("\(amount)")
                .font(.system(size: 42, weight: .bold).monospacedDigit())
                .foregroundStyle(amber)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            // One step per 12 points of vertical travel;
                            // swiping up increases.
                            let steps = Int(-value.translation.height / 12)
                            let delta = steps - appliedDragSteps
                            if delta != 0 {
                                appliedDragSteps = steps
                                setAmount(amount + delta)
                            }
                        }
                        .onEnded { _ in appliedDragSteps = 0 }
                )
                .crownAdjustable(
                    $crownValue,
                    from: Double(lowerBound),
                    through: Double(upperBound),
                    by: 1
                )
                .onChange(of: crownValue) { newValue in
                    let rounded = Int(newValue.rounded())
                    if rounded != amount {
                        setAmount(rounded)
                    }
                }

            Text(unit == .minutes ? "minutes" : "frames")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(landingCaption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.plain)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Button {
                    onConfirm(unit, amount)
                    dismiss()
                } label: {
                    Text("Set")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.plain)
                .background(amber, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(.horizontal, 4)
        .onAppear { setAmount(max(defaultAmount, lowerBound)) }
        .onReceive(timer) { date in
            now = date
            // The run keeps moving while the dial is up; keep the floor
            // ahead of it.
            if amount < lowerBound { setAmount(lowerBound) }
        }
    }

    /// Where the stop would land, live — makes total-vs-remaining unambiguous
    /// while dialling.
    private var landingCaption: String {
        switch unit {
        case .minutes:
            let remaining = max(0, Double(amount) * 60 - elapsedSeconds)
            return "stops in \(shortDuration(remaining))"
        case .frames:
            return "stops in \(max(0, amount - remote.captureCount)) frames"
        }
    }

    private func shortDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }

    private func unitChip(_ chipUnit: ScheduledStopUnit, label: String) -> some View {
        Button {
            guard unit != chipUnit else { return }
            unit = chipUnit
            setAmount(max(defaultAmount, lowerBound))
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(unit == chipUnit ? .black : .white)
                .frame(maxWidth: .infinity, minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            unit == chipUnit ? amber : Color.white.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func setAmount(_ newValue: Int) {
        let clamped = min(max(lowerBound, newValue), upperBound)
        amount = clamped
        crownValue = Double(clamped)
    }
}

/// Slide-right-to-stop: deliberate friction so a sleeve brush or stray tap
/// can't end a long capture. The stop fires only when the thumb is released
/// past most of its travel; anything less springs back.
private struct SlideToStop: View {
    var enabled: Bool
    var label: String = "Slide to stop"
    var onStop: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var didFire = false

    private let height: CGFloat = 34
    private let stopRed = Color(red: 1, green: 0.41, blue: 0.38)

    var body: some View {
        GeometryReader { geometry in
            let thumbSize = height - 4
            let travel = max(1, geometry.size.width - thumbSize - 4)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.red.opacity(0.25))
                Capsule()
                    .stroke(Color.red.opacity(0.6), lineWidth: 1)
                HStack(spacing: 3) {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Image(systemName: "chevron.right.2")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(stopRed)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .opacity(labelOpacity(travel: travel))

                Circle()
                    .fill(Color.red)
                    .overlay(
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .frame(width: thumbSize, height: thumbSize)
                    .padding(2)
                    .offset(x: dragOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                guard enabled, !didFire else { return }
                                dragOffset = min(max(0, value.translation.width), travel)
                            }
                            .onEnded { _ in
                                guard enabled, !didFire else { return }
                                if dragOffset >= travel * 0.85 {
                                    didFire = true
                                    dragOffset = travel
                                    onStop()
                                    // If the stop failed and this control is
                                    // still on screen, be ready to try again.
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                        didFire = false
                                        dragOffset = 0
                                    }
                                } else {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        dragOffset = 0
                                    }
                                }
                            }
                    )
            }
        }
        .frame(height: height)
        .opacity(enabled ? 1 : 0.5)
    }

    private func labelOpacity(travel: CGFloat) -> Double {
        max(0, 1 - Double(dragOffset / (travel * 0.6)))
    }
}
#endif

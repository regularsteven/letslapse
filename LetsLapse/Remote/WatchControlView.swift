// This file is compiled into BOTH the watch app and the universal app target
// — and that target also builds iOS, where a second WCSession delegate would
// sit alongside WatchRemoteControlReceiver contending for the single
// `WCSession.default.delegate` slot. So the condition is macOS-POSITIVE, not
// watchOS-negative: the remote exists on the wrist and on the Mac, nowhere
// else. See Remote/ in the project layout.
#if os(watchOS) || os(macOS)
import SwiftUI

/// The remote, organised on one rule: **every irreversible gesture goes
/// vertical, horizontal stays navigation.**
///
/// Burst commits upward, stop commits downward, and paging between tabs is the
/// only thing a sideways swipe can ever do. That separation is what makes a
/// multi-tab recording screen safe to wear — the earlier draft of this redesign
/// put slide-to-stop on the horizontal axis and it was rejected on exactly this
/// point: swipe, swipe, swipe, whoops.
///
/// Three phases, and within a shoot three tabs:
/// - **Armed** — states its precondition and starts the run.
/// - **Recording** — burst · controls · stop.
/// - **Unreachable** — explains the fix.
struct WatchControlView: View {
    @EnvironmentObject private var remote: WatchCaptureRemote
    @Environment(\.scenePhase) private var scenePhase
    @State private var now = Date()
    @State private var lastAutoRefreshAt = Date.distantPast
    @State private var isoAdjust: Double = 0
    @State private var burstRateAdjust: Double = 0
    @State private var recordingTab: RecordingTab = .burst
    @State private var showIntervalPicker = false
    @State private var showFramesPicker = false
    @State private var showStopAtSheet = false
    /// State-driven rather than a bare `NavigationLink` so the screenshot hook
    /// can land straight on the framing screen.
    @State private var showFramingPreview = false
    @State private var lastInteractionAt = Date()
    @State private var isLocked = false
    @State private var unlockCrown: Double = 0
    @State private var lastUnlockCrown: Double = 0
    @State private var unlockProgress: Double = 0
    /// Armed burst length in seconds; 0 = none, so a commit runs open-ended.
    /// The last choice (including "none") is the default for every later run.
    @AppStorage("letslapse.watch.burstDefaultSeconds") private var armedBurstSeconds = 1
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Mirrors of the phone's option lists; the phone rejects anything else.
    // The picker offers the fixed counts only — the adaptive depths
    // (Psycho/Safe) are chosen on the phone, where Safe's gating lives, and
    // show here as labels.
    private let intervalOptions: [Double] = [0.5, 1.0, 2.0, 3.0, 5.0, 10.0]
    private let frameOptions = BlendDepth.fixedOptions

    /// How long the controls stay up with nobody touching them. Long enough to
    /// think between bursts, short enough that a walk to the next vantage
    /// point locks it.
    private let idleLockSeconds: TimeInterval = 90
    /// Crown units for a full unlock turn. `sensitivity: .medium` puts roughly
    /// this much travel in one revolution — but crown feel is not decidable on
    /// a Mac (see CrownAdjustment's note), so this figure is a starting point
    /// to be judged on a real wrist.
    private let unlockTravel: Double = 60

    /// Left to right, in the order the design fixes them: the thing you do
    /// often, the thing you consider, the thing that ends the shoot. Stop is
    /// deliberately furthest from burst.
    private enum RecordingTab: Hashable {
        case burst
        case controls
        case stop
    }

    private enum Phase {
        case recording
        case armed
        /// Linked, app on screen, camera closed — one button fixes it.
        case cameraClosed
        /// Linked, app on screen, mid-blend. The camera can't open until the
        /// render stops, so this screen offers to stop it.
        case phoneBusy
        /// Linked, app on screen, in a setup flow. Arming leaves the flow up
        /// underneath, so this one asks first.
        case inSetup
        case unreachable
    }

    private var phase: Phase {
        if remote.recordingState == .recording { return .recording }
        guard remote.isReachable else { return .unreachable }
        if remote.isCameraActive { return .armed }
        // The camera is closed. Whether that is fixable from here depends
        // entirely on whether the app is actually on screen: `sendMessage`
        // will wake a suspended iPhone app in the background, but
        // `AVCaptureSession` cannot start there. Offering an Arm button to a
        // phone in a pocket would be a button that cannot work — so the
        // background case falls through to the screen that says what to do.
        guard remote.phoneAppState == "active" else { return .unreachable }
        switch remote.phoneFlow {
        case "processing": return .phoneBusy
        case "setup": return .inSetup
        default: return .cameraClosed
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .recording: recordingTabs
                case .armed: armedTabs
                case .cameraClosed: cameraClosedScreen
                case .phoneBusy: phoneBusyScreen
                case .inSetup: inSetupScreen
                case .unreachable: unreachableScreen
                }
            }
            .navigationDestination(isPresented: $showFramingPreview) {
                FramingPreviewView()
                    .environmentObject(remote)
            }
            // A zero-distance drag sees every touch-down without consuming it,
            // so the idle timer resets on any interaction — including the ones
            // that end up being handled by a pad or the pager — without any
            // control having to remember to report itself.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in lastInteractionAt = Date() }
            )
            .overlay {
                if isLocked {
                    lockedOverlay
                }
            }
            #if os(watchOS)
            // The system already draws the time of day in this bar, which is
            // why no screen here draws a clock of its own — the design mock
            // shows one because a mock has no status bar.
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .onAppear {
            remote.refreshState()
            lastInteractionAt = Date()
        }
        // A watchOS app suspends on wrist-down and resumes on wrist-up without
        // firing `onAppear`, so a resume mid-shoot would otherwise keep showing
        // whatever state was last known. Re-pull whenever we return to active.
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                remote.reconnect()
                // Wrist-up is an interaction. Locking the instant you look at
                // it would be the opposite of helpful.
                lastInteractionAt = Date()
            }
        }
        .onReceive(timer) { date in
            now = date
            autoRefreshIfDisconnected(at: date)
            updateIdleLock(at: date)
        }
        // Landing back on the burst tab for each new shoot means the tab you
        // reach for blind is always the same one. Ending a shoot resets it too,
        // so a stop can't leave you parked on the stop tab.
        .onChange(of: remote.recordingState) { _ in
            recordingTab = .burst
        }
        #if os(watchOS) && DEBUG
        // The screenshot hook names a screen; the tab it lives on is the
        // view's business, not the remote's.
        .onAppear {
            switch remote.debugPreviewScreen {
            case "controls", "armed-setup": recordingTab = .controls
            case "stop": recordingTab = .stop
            case "locked": isLocked = true
            case "unlocking":
                isLocked = true
                unlockProgress = 0.6
            case "framing", "framing-stale", "framing-aids",
                 "framing-square", "framing-tall", "framing-wide":
                showFramingPreview = true
            default: break
            }
        }
        #endif
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

    // MARK: - Paging

    /// `.page` does not exist on macOS, and a hand-rolled pager there would be
    /// a lot of new code for a window nobody swipes. The Mac gets the same
    /// screens behind a segmented header — the same split `CrownAdjustment`
    /// already makes for crown-versus-scroll-wheel.
    @ViewBuilder
    private func paged<Content: View>(
        selection: Binding<RecordingTab>,
        labels: [(RecordingTab, String)],
        @ViewBuilder content: () -> Content
    ) -> some View {
        #if os(watchOS)
        TabView(selection: selection) {
            content()
        }
        .tabViewStyle(.page)
        #else
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(labels, id: \.0) { tab, label in
                    Button {
                        selection.wrappedValue = tab
                    } label: {
                        Text(label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(selection.wrappedValue == tab ? .black : .white)
                            .frame(maxWidth: .infinity, minHeight: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        selection.wrappedValue == tab ? Color.white : Color.white.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                }
            }
            .padding(.horizontal, RemoteMetric.gutter)
            content()
        }
        #endif
    }

    // MARK: - Recording

    /// The header lives OUTSIDE the pager on purpose. watchOS vertically
    /// centres a page whose content doesn't fill it, so a header drawn inside
    /// each tab sat at a different height on each one and visibly jumped as
    /// you paged — the one element whose whole job is to be the constant.
    /// Hoisting it also means the run's identity is stated once, not three
    /// times.
    private var recordingTabs: some View {
        VStack(spacing: 4) {
            recordingHeader
                .padding(.horizontal, RemoteMetric.gutter)

            paged(
                selection: $recordingTab,
                labels: [(.burst, burstTabLabel), (.controls, "Set"), (.stop, "End")]
            ) {
                burstTab.tag(RecordingTab.burst)
                controlsTab.tag(RecordingTab.controls)
                stopTab.tag(RecordingTab.stop)
            }
            // Covers the pager, not the header: the run's identity stays
            // readable while you deal with the failure, and the card can be
            // reached from whichever tab you happened to be on.
            .overlay {
                if let failure = remote.lastFailure {
                    failureCard(failure)
                }
            }
        }
    }

    private var burstTabLabel: String {
        remote.captureMode == .video ? (isMarkerMode ? "Mark" : "Burst") : "Run"
    }

    /// Whether a burst has anywhere to go.
    ///
    /// A camera whose fastest format at this resolution IS its base rate has
    /// nothing to switch to — common on webcams and on 4K at the top rate —
    /// and the phone's own format sheet says so in as many words: bursts mark
    /// intervals instead. A pad labelled BURST there would name something the
    /// phone will not do.
    ///
    /// The `rampFPS > baseFPS` fallback covers a phone build that predates the
    /// `availableBurstFPS` key: it still reports a burst rate, and an absent
    /// key must not turn every burst pad on the wrist into a mark pad.
    private var hasBurstRate: Bool {
        !remote.availableBurstFPS.isEmpty
            || (remote.rampFPS > 0 && remote.rampFPS > remote.baseFPS)
    }

    private var isRampMode: Bool {
        remote.captureMode == .video && remote.sequenceMode == "ramp" && hasBurstRate
    }

    /// Everything Video does that isn't a rate switch — marks-only, and a ramp
    /// with nowhere to ramp to. The two behave identically from here.
    private var isMarkerMode: Bool {
        remote.captureMode == .video && !isRampMode
    }

    // MARK: Tab 1 — in-shoot

    /// No `ScrollView`, by design. A vertical scroll would fight the commit
    /// gesture for the same axis, and the whole safety argument rests on that
    /// axis meaning exactly one thing. If this tab ever stops fitting, the
    /// answer is to move something to the controls tab.
    private var burstTab: some View {
        VStack(spacing: RemoteMetric.rowGap) {
            // The pad outranks the rows below it: if anything has to give,
            // it must not be the control you use without looking.
            if isRampMode {
                burstPad.layoutPriority(1)
                timedBurstRow
            } else if isMarkerMode {
                markPad.layoutPriority(1)
            } else {
                captureCountPanel.layoutPriority(1)
            }

            exposureLockRow
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RemoteMetric.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The commit that starts a burst — and, while one is running, the commit
    /// that ends it early. Same gesture, same axis, so there is never a second
    /// thing to learn.
    @ViewBuilder
    private var burstPad: some View {
        if remote.isRampHighRate {
            SlideToCommit(
                direction: .up,
                tint: RemoteTint.burst,
                title: burstLiveTitle,
                hint: "Slide up to end",
                enabled: !remote.isSending && remote.isReachable
            ) {
                remote.triggerMoment()
            }
        } else {
            SlideToCommit(
                direction: .up,
                tint: RemoteTint.burst,
                title: "BURST",
                hint: armedBurstSeconds > 0 ? "Slide up · \(armedBurstSeconds)s" : "Slide up to burst",
                enabled: !remote.isSending && remote.isReachable
            ) {
                if armedBurstSeconds > 0 {
                    remote.triggerTimedBurst(seconds: armedBurstSeconds)
                } else {
                    remote.triggerMoment()
                }
            }
        }
    }

    /// Names the rate a running burst is actually at — "bursting" alone never
    /// told you whether the phone had reached the rate you asked for.
    private var burstLiveTitle: String {
        remote.rampFPS > 0 ? "\(remote.rampFPS) FPS" : "BURSTING"
    }

    /// Marker mode has no rate to switch to, so the pad drops a mark instead.
    /// Same axis, same friction — the vocabulary doesn't change just because
    /// the payload does.
    private var markPad: some View {
        SlideToCommit(
            direction: .up,
            tint: RemoteTint.burst,
            title: remote.isRampActive ? "END MARK" : "MARK",
            hint: remote.isRampActive ? "Slide up to close" : "Slide up to mark",
            enabled: !remote.isSending && remote.isReachable
        ) {
            remote.triggerMoment()
        }
    }

    /// Interval's counterpart: nothing to commit, so the pad's slot goes to
    /// the number that is actually changing.
    private var captureCountPanel: some View {
        VStack(spacing: 2) {
            Text("\(remote.captureCount)")
                .font(RemoteType.hero.monospacedDigit())
                .foregroundStyle(RemoteTint.burst)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(remote.blendDepth.blends ? "blends" : "photos")
                .font(RemoteType.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: RemoteMetric.padHeight)
        .background(
            RoundedRectangle(cornerRadius: RemoteMetric.padCorner, style: .continuous)
                .fill(RemoteTint.surface)
        )
    }

    /// The armed burst length — a setting, not a trigger. One chip may be
    /// ticked (radio-with-off: tapping it again deselects); the pad fires
    /// whatever is armed, and the phone still owns the revert timer so the
    /// drop back to base lands even if the watch sleeps mid-burst. Chips are
    /// local and safe to fumble, so they never disable.
    private var timedBurstRow: some View {
        // 1/4/8, not 1/2/4 (2026-08-11 ramp review): seam eases are funded by
        // burst footage, and under ~4 s at 100 fps a ramped seam eats the
        // whole burst bridging its own cuts. 1 s stays as the "just a beat"
        // accent; 2 s promised more than post could keep.
        HStack(spacing: 5) {
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
            Text("\(seconds)s")
                .font(RemoteType.control)
                .foregroundStyle(isArmed ? RemoteTint.burst : .white.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: RemoteMetric.chipHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isArmed ? RemoteTint.burst.opacity(0.16) : RemoteTint.surfaceRaised,
            in: RoundedRectangle(cornerRadius: RemoteMetric.chipCorner, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RemoteMetric.chipCorner, style: .continuous)
                .strokeBorder(isArmed ? RemoteTint.burst : .clear, lineWidth: 1.5)
        )
        .accessibilityLabel("\(seconds) second burst length")
        .accessibilityAddTraits(isArmed ? [.isSelected] : [])
    }

    // MARK: Tab 2 — the considered controls

    /// Crown territory, and the reason this tab never scrolls: on watchOS the
    /// crown drives whichever of the two is live, and a scroll view would take
    /// it first. Exactly one thing owns the crown per screen.
    private var controlsTab: some View {
        VStack(spacing: RemoteMetric.rowGap) {
            if isRampMode {
                burstRateLadder
            } else if isMarkerMode {
                markerModeNote
            } else {
                intervalRow
                framesRow
            }

            if remote.isExposureLocked {
                lockedExposureRow
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RemoteMetric.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .crownAdjustable(
            crownBinding,
            from: crownRange.lowerBound,
            through: crownRange.upperBound,
            by: crownStep,
            isEnabled: crownOwner != .none
        )
        .onChange(of: burstRateAdjust) { newValue in
            guard crownOwner == .burstRate else { return }
            let rate = nearestBurstRate(to: newValue)
            guard rate != remote.rampFPS else { return }
            remote.setBurstFPS(rate)
        }
        .onChange(of: isoAdjust) { newValue in
            guard crownOwner == .iso else { return }
            remote.setISO(newValue)
        }
        .onChange(of: remote.isExposureLocked) { locked in
            if locked { isoAdjust = remote.lockedISO }
        }
        .onChange(of: remote.rampFPS) { fps in
            burstRateAdjust = Double(fps)
        }
        .onAppear {
            isoAdjust = remote.lockedISO
            burstRateAdjust = Double(remote.rampFPS)
        }
    }

    /// One owner at a time, decided by what this tab is actually showing. The
    /// burst ladder wins where it exists; otherwise a locked exposure gets the
    /// crown back, which is where ISO lived before the redesign.
    private enum CrownOwner {
        case burstRate
        case iso
        case none
    }

    private var crownOwner: CrownOwner {
        if isRampMode && !remote.availableBurstFPS.isEmpty { return .burstRate }
        if remote.isExposureLocked { return .iso }
        return .none
    }

    private var crownBinding: Binding<Double> {
        crownOwner == .burstRate ? $burstRateAdjust : $isoAdjust
    }

    private var crownRange: ClosedRange<Double> {
        switch crownOwner {
        case .burstRate:
            let rates = remote.availableBurstFPS
            let low = Double(rates.first ?? remote.rampFPS)
            let high = Double(rates.last ?? remote.rampFPS)
            return low...max(low + 1, high)
        case .iso, .none:
            return remote.isoMin...max(remote.isoMin + 1, remote.isoMax)
        }
    }

    private var crownStep: Double {
        crownOwner == .burstRate ? 1 : 50
    }

    /// The crown moves through a continuous range; the rates are a sparse
    /// ladder. Snap to the nearest rung so every detent lands on something the
    /// camera can actually shoot.
    private func nearestBurstRate(to value: Double) -> Int {
        let rates = remote.availableBurstFPS
        guard !rates.isEmpty else { return remote.rampFPS }
        return rates.min(by: { abs(Double($0) - value) < abs(Double($1) - value) }) ?? remote.rampFPS
    }

    private var burstRateLadder: some View {
        VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text("\(remote.rampFPS)")
                        .font(RemoteType.hero)
                        .foregroundStyle(RemoteTint.burst)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("fps")
                        .font(RemoteType.caption)
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer(minLength: 2)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(burstMultipleLabel)
                            .font(.system(size: 12, weight: .bold))
                        Text("base \(remote.baseFPS) fps")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.48))
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                }

                rateLadderBars

            Text("Turn the crown to change")
                .font(RemoteType.caption)
                .foregroundStyle(.white.opacity(0.42))
        }
    }

    /// How much slower the burst will play back — the number that says what a
    /// burst is *for*, which a bare fps figure never does.
    private var burstMultipleLabel: String {
        guard remote.baseFPS > 0, remote.rampFPS > 0 else { return "—" }
        let multiple = Double(remote.rampFPS) / Double(remote.baseFPS)
        if multiple >= 10 || multiple == multiple.rounded() {
            return "\(Int(multiple.rounded()))× slower"
        }
        return String(format: "%.1f× slower", multiple)
    }

    private var rateLadderBars: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(remote.availableBurstFPS, id: \.self) { fps in
                let isSelected = fps == remote.rampFPS
                VStack(spacing: 3) {
                    Capsule()
                        .fill(RemoteTint.burst)
                        .frame(height: isSelected ? 10 : 6)
                        .overlay(
                            Capsule()
                                .stroke(RemoteTint.burst.opacity(0.25), lineWidth: isSelected ? 2 : 0)
                        )
                    Text("\(fps)")
                        .font(.system(size: 9, weight: isSelected ? .bold : .regular))
                        .foregroundStyle(isSelected ? RemoteTint.burst : .white.opacity(0.45))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard fps != remote.rampFPS else { return }
                    remote.setBurstFPS(fps)
                }
            }
        }
        .frame(height: 26, alignment: .bottom)
        .disabled(remote.isSending || !remote.isReachable)
    }

    /// Two ways to arrive here and they are not the same fact: the shoot is
    /// set to mark intervals, or it wanted to switch rate and this format has
    /// nowhere faster to go. Saying which one is the difference between "as
    /// configured" and "change the resolution on the phone".
    private var markerModeNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(remote.sequenceMode == "ramp" ? "NO BURST RATE" : "MARKS ONLY")
                .font(RemoteType.sectionLabel)
                .kerning(0.7)
                .foregroundStyle(.white.opacity(0.5))
            Text(remote.sequenceMode == "ramp"
                 ? "This format has nothing faster than \(remote.baseFPS) fps, so bursts mark intervals instead."
                 : "Marked intervals keep their real speed. The frame rate never changes.")
                .font(RemoteType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lockedExposureRow: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .bold))
            Text(lockedExposureLabel)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            if crownOwner == .iso {
                Text("CROWN")
                    .font(.system(size: 9, weight: .bold))
                    .kerning(0.6)
                    .foregroundStyle(RemoteTint.link)
            }
        }
        .foregroundStyle(RemoteTint.burst)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 28)
        .background(RemoteTint.surface, in: RoundedRectangle(cornerRadius: RemoteMetric.rowCorner, style: .continuous))
    }

    // MARK: Tab 3 — end shoot

    /// Stop slides *down*; burst slides *up*. Opposite axes, opposite colours,
    /// and two tabs apart — three independent reasons a fumble can't end a
    /// shoot. Like tab 1, no scrolling.
    private var stopTab: some View {
        VStack(spacing: RemoteMetric.rowGap) {
            SlideToCommit(
                direction: .down,
                tint: RemoteTint.record,
                title: "STOP",
                hint: slideToStopHint,
                enabled: !remote.isSending && remote.isReachable,
                height: 88
            ) {
                remote.stopRecording()
            }
            .layoutPriority(1)

            stopAtRow
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RemoteMetric.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The hint doubles as the countdown once a stop is scheduled.
    private var slideToStopHint: String {
        guard let unit = remote.stopAtUnit else { return "Slide down to stop" }
        switch unit {
        case .minutes:
            guard let deadline = remote.stopAtDeadline else { return "Slide down to stop" }
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
            return "Slide down to stop"
        }
    }

    @ViewBuilder
    private var stopAtRow: some View {
        if remote.stopAtUnit != nil {
            Button {
                remote.cancelScheduledStop()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Stop at")
                            .font(RemoteType.control)
                        Text(scheduledStopCaption)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer(minLength: 4)
                    Text("Cancel")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(RemoteTint.link)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: RemoteMetric.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(RemoteTint.surface, in: RoundedRectangle(cornerRadius: RemoteMetric.rowCorner, style: .continuous))
            .disabled(remote.isSending || !remote.isReachable)
        } else {
            Button {
                showStopAtSheet = true
            } label: {
                HStack {
                    Text("Stop at…")
                        .font(RemoteType.control)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: RemoteMetric.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(RemoteTint.surface, in: RoundedRectangle(cornerRadius: RemoteMetric.rowCorner, style: .continuous))
            .disabled(remote.isSending || !remote.isReachable)
            .sheet(isPresented: $showStopAtSheet) {
                StopAtSheet { unit, amount in
                    remote.scheduleStop(unit: unit, amount: amount)
                }
                .environmentObject(remote)
            }
        }
    }

    private var scheduledStopCaption: String {
        guard let unit = remote.stopAtUnit else { return "" }
        switch unit {
        case .minutes:
            guard let deadline = remote.stopAtDeadline else { return "" }
            return "in \(DurationFormatter.recordingTime(from: max(0, deadline.timeIntervalSince(now))))"
        case .frames:
            guard let target = remote.stopAtTargetCount else { return "" }
            return "in \(max(0, target - remote.captureCount)) frames"
        }
    }

    // MARK: - Shared recording chrome

    /// One header on every tab, so paging never costs you the run's identity.
    /// The time of day the design mock shows lives in the system status bar on
    /// a real watch, so it isn't drawn here.
    private var recordingHeader: some View {
        VStack(spacing: 2) {
            HStack(spacing: 5) {
                Circle()
                    .fill(RemoteTint.record)
                    .frame(width: 6.5, height: 6.5)
                Text(isMarkerMode && remote.isRampActive ? "MARK" : "REC")
                    .font(RemoteType.statusWord)
                    .kerning(0.6)
                Text(elapsedTime)
                    .font(RemoteType.clock)
                Spacer(minLength: 0)
            }

            HStack(spacing: 4) {
                Text(remote.captureMode == .video ? liveEstimateLine : runSettingsLine)
                    .font(RemoteType.subline)
                    .foregroundStyle(.white.opacity(0.56))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                // One slot, and link state outranks ornament: a send in flight
                // or a dead link is a fact about whether the controls work at
                // all, which matters more than how many intervals have gone by.
                //
                // Beside the run info they describe, NOT above the tab bar —
                // at the foot of the screen the dots read as a second page
                // indicator, two rows saying "which of N" about different
                // things entirely.
                if let chip = linkChip {
                    chip
                } else if remote.captureMode == .video {
                    intervalDots
                }
            }

            Divider()
                .overlay(Color.white.opacity(0.15))
        }
    }

    /// Mid-shoot AE/AF lock. Amber fill = locked, so you can grab a lock the
    /// moment a tram crosses the frame and release it once the light settles.
    private var exposureLockRow: some View {
        RemoteToggleRow(
            title: "AE/AF Lock",
            isOn: remote.isExposureLocked,
            enabled: !remote.isSending && remote.isReachable,
            isPending: remote.pendingCommand == .lockExposure
                || remote.pendingCommand == .unlockExposure
        ) {
            if remote.isExposureLocked {
                remote.unlockExposure()
            } else {
                remote.lockExposure()
            }
        }
    }

    /// "sending" while a command is in flight, "no link" once the phone is out
    /// of reach. Nil when there is nothing to say, which is most of the time.
    @ViewBuilder
    private var linkChip: (some View)? {
        if remote.isSending {
            HStack(spacing: 3) {
                Circle()
                    .fill(RemoteTint.link)
                    .frame(width: 5, height: 5)
                Text("sending")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        } else if !remote.isReachable {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                Text("no link")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(RemoteTint.warn)
        }
    }

    /// One amber dot per burst/marker interval, pulsing while one is open.
    private var intervalDots: some View {
        HStack(spacing: 3) {
            if remote.rampIntervalCount == 0 {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 18, height: 3)
            } else {
                ForEach(0..<min(remote.rampIntervalCount, 10), id: \.self) { index in
                    Circle()
                        .fill(RemoteTint.burst.opacity(
                            remote.isRampActive && index == remote.rampIntervalCount - 1 ? 1 : 0.55
                        ))
                        .frame(width: 5, height: 5)
                }
            }
        }
        .frame(height: 6)
    }

    // MARK: - Lock

    /// Locks only during a shoot, and only with nothing else demanding
    /// attention. Idle on the armed screen means you are about to press START;
    /// idle behind a failure banner means the banner has not been read yet.
    private func updateIdleLock(at date: Date) {
        guard !isLocked else { return }
        guard phase == .recording,
              remote.lastFailure == nil,
              !remote.isSending,
              !showStopAtSheet,
              date.timeIntervalSince(lastInteractionAt) >= idleLockSeconds else { return }
        isLocked = true
        unlockProgress = 0
        unlockCrown = 0
        lastUnlockCrown = 0
    }

    private var lockedOverlay: some View {
        ControlsLockedView(
            elapsed: elapsedTime,
            subline: remote.captureMode == .video ? liveEstimateLine : runSettingsLine,
            stopsAt: lockedStatusLine,
            unlockProgress: unlockProgress
        )
        // The crown is the only input here, so nothing contests it.
        .crownAdjustable($unlockCrown, from: 0, through: 10_000, by: 1)
        .onChange(of: unlockCrown) { newValue in
            // Absolute travel, so it unlocks whichever way you turn — a rule
            // about direction is one more thing to remember at the exact
            // moment you want the controls back.
            unlockProgress += abs(newValue - lastUnlockCrown) / unlockTravel
            lastUnlockCrown = newValue
            if unlockProgress >= 1 {
                isLocked = false
                unlockProgress = 0
                lastInteractionAt = Date()
            }
        }
        // A shoot that ends while locked has nothing left to protect.
        .onChange(of: remote.recordingState) { state in
            if state != .recording { isLocked = false }
        }
    }

    /// What is worth reading across a room: when this stops, and whether the
    /// wrist will still be awake for it.
    private var lockedStatusLine: String? {
        var parts: [String] = []
        if let deadline = remote.stopAtDeadline {
            parts.append("Stops in \(DurationFormatter.recordingTime(from: max(0, deadline.timeIntervalSince(now))))")
        } else if let target = remote.stopAtTargetCount {
            parts.append("Stops in \(max(0, target - remote.captureCount)) frames")
        }
        if let percent = RemoteBattery.watchPercent {
            parts.append("⌚︎ \(percent)%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Failure

    /// Says what did NOT happen, in words, and offers the one useful action.
    ///
    /// The whole point is that the state never lied: the toggle did not move,
    /// the burst did not start. With nothing to un-learn there is no reason to
    /// press anything twice, which is the habit this screen exists to prevent.
    private func failureCard(_ failure: RemoteCommandFailure) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(failure.message)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(RemoteTint.warn)
                    .fixedSize(horizontal: false, vertical: true)

                if let unchanged = failure.command.unchangedDescription(
                    isExposureLocked: remote.isExposureLocked
                ) {
                    Text(unchanged)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 5) {
                    Button {
                        remote.dismissFailure()
                    } label: {
                        Text("Dismiss")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(RemoteTint.surfaceRaised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                    Button {
                        remote.retryFailedCommand()
                    } label: {
                        Text("Try again")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(RemoteTint.warn, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .padding(.top, 2)

                // The reassurance that stops a failed AE/AF lock reading as a
                // failed shoot. Capture runs on the phone; the link is only
                // the remote.
                if remote.recordingState == .recording {
                    Text("Capture is unaffected. The phone keeps recording.")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .background(
                // Opaque ground UNDER the tint. A translucent card let the
                // burst pad ghost through its own error message, which is a
                // poor way to be told something didn't work.
                RoundedRectangle(cornerRadius: RemoteMetric.padCorner, style: .continuous)
                    .fill(RemoteTint.ground)
                    .overlay(
                        RoundedRectangle(cornerRadius: RemoteMetric.padCorner, style: .continuous)
                            .fill(RemoteTint.warn.opacity(0.14))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: RemoteMetric.padCorner, style: .continuous)
                    .strokeBorder(RemoteTint.warn.opacity(0.6), lineWidth: 1)
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RemoteMetric.gutter)
        .background(RemoteTint.ground)
    }

    // MARK: - Armed

    /// Two pages, same rule as the recording tabs: the thing you came to do,
    /// then the things you might want to consider first. START lives on page
    /// one and is a tap — it's the one commit that begins rather than ends, and
    /// an accidental start costs a deleted clip, not a lost shoot.
    private var armedTabs: some View {
        VStack(spacing: 4) {
            armedHeader
                .padding(.horizontal, RemoteMetric.gutter)

            paged(
                selection: armedTabBinding,
                labels: [(.burst, "Ready"), (.controls, "Setup")]
            ) {
                armedScreen.tag(RecordingTab.burst)
                armedControlsScreen.tag(RecordingTab.controls)
            }
        }
    }

    /// Reuses `recordingTab` so the two phases can't disagree about which page
    /// is showing; `.stop` never appears here.
    private var armedTabBinding: Binding<RecordingTab> {
        Binding(
            get: { recordingTab == .controls ? .controls : .burst },
            set: { recordingTab = $0 }
        )
    }

    private var armedScreen: some View {
        ScrollView {
            VStack(spacing: RemoteMetric.rowGap) {
                RemoteSegmented(
                    options: CaptureMode.allCases.filter { $0 != .photo }.map { ($0, $0.rawValue) },
                    selection: remote.captureMode,
                    enabled: !remote.isSending && remote.isReachable
                ) { mode in
                    remote.setCaptureMode(mode)
                }

                if remote.isBulbMode {
                    Label("Bulb · start, then slide to stop", systemImage: "circle.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(RemoteTint.burst)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                exposureLockRow

                checkFramingRow

                startButton
            }
            .padding(.horizontal, RemoteMetric.gutter)
            .padding(.bottom, 6)
        }
    }

    /// One tap away, not always on. A live preview costs the link and the
    /// phone's session real work, and framing is something you do in bursts of
    /// attention — so it opens when you ask and stops the moment you leave.
    private var checkFramingRow: some View {
        Button {
            showFramingPreview = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 14, weight: .semibold))
                Text("Check framing")
                    .font(RemoteType.control)
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(RemoteTint.link.opacity(0.6))
            }
            .foregroundStyle(RemoteTint.link)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: RemoteMetric.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RemoteTint.link.opacity(0.12), in: RoundedRectangle(cornerRadius: RemoteMetric.rowCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RemoteMetric.rowCorner, style: .continuous)
                .strokeBorder(RemoteTint.link.opacity(0.5), lineWidth: 1)
        )
    }

    private var armedHeader: some View {
        VStack(spacing: 2) {
            HStack(spacing: 5) {
                Circle()
                    .fill(RemoteTint.go)
                    .frame(width: 6.5, height: 6.5)
                Text("ARMED")
                    .font(RemoteType.statusWord)
                    .kerning(0.6)
                Spacer(minLength: 0)
            }
            HStack {
                Text(readyDetailLine)
                    .font(RemoteType.subline)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            Divider()
                .overlay(Color.white.opacity(0.15))
        }
    }

    private var startButton: some View {
        Button {
            remote.startRecording()
        } label: {
            Text("START")
                .font(.system(size: 17, weight: .heavy))
                .kerning(1)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RemoteTint.record, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .disabled(remote.isSending)
    }

    /// Page two: the settings that used to crowd the ready screen. They are
    /// still one horizontal swipe away, which is the same distance the phone
    /// puts them behind a sheet.
    private var armedControlsScreen: some View {
        ScrollView {
            VStack(spacing: RemoteMetric.rowGap) {
                if remote.captureMode == .interval {
                    intervalRow
                    framesRow
                } else {
                    burstRateSummaryRow
                }

                if remote.isExposureLocked {
                    lockedExposureRow
                }
            }
            .padding(.horizontal, RemoteMetric.gutter)
            .padding(.bottom, 6)
        }
    }

    /// Video's counterpart of the interval/blend rows — a read-out, because
    /// the rate is dialled on the controls tab once a shoot is running and on
    /// the phone before one is.
    private var burstRateSummaryRow: some View {
        HStack {
            Text("Burst")
                .font(RemoteType.control)
            Spacer(minLength: 4)
            Text(remote.availableBurstFPS.isEmpty ? "None available" : "\(remote.rampFPS) fps")
                .font(RemoteType.control)
                .foregroundStyle(remote.availableBurstFPS.isEmpty ? .secondary : RemoteTint.burst)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: RemoteMetric.rowHeight)
        .background(RemoteTint.surface, in: RoundedRectangle(cornerRadius: RemoteMetric.rowCorner, style: .continuous))
    }

    private var intervalRow: some View {
        Button {
            showIntervalPicker = true
        } label: {
            HStack {
                Text("Every")
                    .font(RemoteType.control)
                Spacer(minLength: 4)
                Text(intervalLabel(remote.intervalSeconds))
                    .font(RemoteType.control)
                    .foregroundStyle(RemoteTint.burst)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: RemoteMetric.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RemoteTint.surface, in: RoundedRectangle(cornerRadius: RemoteMetric.rowCorner, style: .continuous))
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
                                .foregroundStyle(RemoteTint.burst)
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
                    .font(RemoteType.control)
                Spacer(minLength: 4)
                Text(blendDepthLabel)
                    .font(RemoteType.control)
                    .foregroundStyle(RemoteTint.burst)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: RemoteMetric.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RemoteTint.surface, in: RoundedRectangle(cornerRadius: RemoteMetric.rowCorner, style: .continuous))
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
                                .foregroundStyle(RemoteTint.burst)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Phone state

    /// The remote's home when there is nothing to control.
    ///
    /// The old screen said "Open the camera on iPhone", which is advice rather
    /// than a control — and useless advice if the phone is already clamped to
    /// a tripod on the other side of a field. One button gets the camera back.
    private var cameraClosedScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RemoteMetric.rowGap) {
                phoneStateHeader(tint: RemoteTint.link, label: "LINKED")

                Image(systemName: "video.slash.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(RemoteTint.warn)
                    .padding(.top, 2)

                Text("Camera closed")
                    .font(.system(size: 16, weight: .bold))
                Text(cameraClosedDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)

                armCameraButton(title: "Arm camera")

                if let lastCaptureAt = remote.lastCaptureAt {
                    Text("Last shoot · \(relativeAge(lastCaptureAt))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(RemoteTint.surface, in: RoundedRectangle(cornerRadius: RemoteMetric.rowCorner, style: .continuous))
                }
            }
            .padding(.horizontal, RemoteMetric.gutter)
            .padding(.bottom, 6)
        }
    }

    private var cameraClosedDetail: String {
        switch remote.phoneFlow {
        case "done": return "LetsLapse is showing a finished clip"
        default: return "LetsLapse is on the Library screen"
        }
    }

    /// The CPU-heavy case. A progress figure and an estimate turn waiting into
    /// a decision rather than a mystery.
    private var phoneBusyScreen: some View {
        ScrollView {
            VStack(spacing: RemoteMetric.rowGap) {
                phoneStateHeader(tint: RemoteTint.warn, label: "PHONE BUSY")

                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.14), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: min(1, max(0, remote.exportProgress ?? 0)))
                        .stroke(RemoteTint.warn, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(Int(((remote.exportProgress ?? 0) * 100).rounded()))%")
                            .font(.system(size: 22, weight: .heavy).monospacedDigit())
                        if let eta = remote.exportETASeconds, eta > 0 {
                            Text("≈\(shortDuration(eta))")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                .frame(width: 78, height: 78)
                .padding(.vertical, 2)

                Text(remote.exportTitle ?? "Creating clip")
                    .font(.system(size: 14, weight: .bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = remote.exportSubtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                NavigationLink {
                    CancelExportConfirmation { remote.cancelExport() }
                } label: {
                    Text("Cancel export")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(RemoteTint.record)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(RemoteTint.surface, in: RoundedRectangle(cornerRadius: RemoteMetric.rowCorner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: RemoteMetric.rowCorner, style: .continuous)
                        .strokeBorder(RemoteTint.record.opacity(0.55), lineWidth: 1)
                )
            }
            .padding(.horizontal, RemoteMetric.gutter)
            .padding(.bottom, 6)
        }
    }

    /// Settings in progress are never discarded silently — the remote says
    /// what arming will cost before it takes over. It costs nothing, in fact:
    /// the capture screen opens *over* the flow and leaves it standing.
    private var inSetupScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RemoteMetric.rowGap) {
                phoneStateHeader(tint: RemoteTint.link, label: "IN SETUP")

                Text(remote.flowTitle ?? "Setup")
                    .font(.system(size: 16, weight: .bold))

                if let step = remote.flowStep, let total = remote.flowStepCount, total > 0 {
                    HStack(spacing: 6) {
                        Text("Step \(step) of \(total)")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                        Spacer(minLength: 0)
                        HStack(spacing: 2.5) {
                            ForEach(1...total, id: \.self) { index in
                                Capsule()
                                    .fill(index <= step ? RemoteTint.link : .white.opacity(0.2))
                                    .frame(width: 11, height: 3.5)
                            }
                        }
                    }
                }

                Text("Arming the camera leaves setup on screen. Your steps stay saved.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)

                armCameraButton(title: "Arm camera anyway")
            }
            .padding(.horizontal, RemoteMetric.gutter)
            .padding(.bottom, 6)
        }
    }

    private func armCameraButton(title: String) -> some View {
        Button {
            remote.armCamera()
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(.black)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RemoteTint.go, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .disabled(remote.isSending)
    }

    private func phoneStateHeader(tint: Color, label: String) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(tint)
                    .frame(width: 6.5, height: 6.5)
                Text(label)
                    .font(.system(size: 11, weight: .bold))
                    .kerning(0.7)
                    .foregroundStyle(.white.opacity(0.8))
                Spacer(minLength: 0)
            }
            Divider()
                .overlay(Color.white.opacity(0.15))
        }
    }

    /// "2m ago" — coarse on purpose. The exact minute of a finished shoot is
    /// never the question; "recent or not" always is.
    private func relativeAge(_ date: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }

    private func shortDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 { return "\(total / 3600)h \((total % 3600) / 60)m" }
        if total >= 60 { return "\(total / 60)m \(total % 60)s" }
        return "\(total)s"
    }

    // MARK: - Unreachable

    private var unreachableScreen: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Image(systemName: remote.phoneAppState == "active" ? "iphone" : "iphone.slash")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            // Two genuinely different situations, and the fix differs. A
            // backgrounded app can be woken by a message but cannot start a
            // capture session, so this screen must not pretend a button would
            // help — it names the one thing that does.
            Text(remote.phoneAppState == "active"
                 ? "Open the camera on iPhone"
                 : "Open LetsLapse on iPhone")
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(remote.phoneAppState == "active"
                 ? "The remote works while the LetsLapse capture screen is open."
                 : "LetsLapse isn't on screen. The camera can't open until it is.")
                .font(RemoteType.caption)
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
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(RemoteTint.surface, in: RoundedRectangle(cornerRadius: RemoteMetric.rowCorner, style: .continuous))
        }
        .padding(.horizontal, RemoteMetric.gutter)
    }

    // MARK: - Labels

    private var elapsedTime: String {
        guard let startedAt = remote.recordingStartedAt else { return "00:00" }
        return DurationFormatter.recordingTime(from: max(0, now.timeIntervalSince(startedAt)))
    }

    private func intervalLabel(_ seconds: Double) -> String {
        seconds == seconds.rounded(.down) ? "\(Int(seconds)) s" : String(format: "%.1f s", seconds)
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

    private var blendDepthLabel: String {
        switch remote.blendDepth {
        case .fixed(1): return "Off"
        case .fixed(let frames): return "\(frames) frames"
        case .unthrottled: return "Psycho"
        case .throttled: return "Safe"
        }
    }

    private var readyDetailLine: String {
        var parts: [String] = []
        if let formatLine = remote.formatLine {
            parts.append(formatLine)
        }
        // What a burst will do. The chips are durations (1s/4s/8s) and the
        // pad's own label is a verb, so without this the burst rate appeared
        // nowhere at all — a camera set to base 25 / burst 50 read exactly
        // like one with no ramp configured. Suppressed when it matches the
        // base rate, or in the still modes, which have no burst.
        if remote.rampFPS > 0, remote.rampFPS != remote.baseFPS {
            parts.append("⚡\(remote.rampFPS)")
        }
        if remote.plannedSpeed > 0 {
            parts.append("\(remote.plannedSpeed)× planned")
        }
        return parts.isEmpty ? "Waiting for camera details" : parts.joined(separator: " · ")
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
}

/// The one place on this remote where a confirmation earns its keep:
/// destructive, slow to undo, and never time-critical. Everything else commits
/// by sliding instead — friction where the cost is a lost shoot, words where
/// the cost is a lost hour of rendering.
private struct CancelExportConfirmation: View {
    var onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RemoteMetric.rowGap) {
                Text("Cancel the export?")
                    .font(.system(size: 17, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your clip settings are kept. You'll go back to the blend setup, then the camera can arm.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    onCancel()
                    dismiss()
                } label: {
                    Text("Cancel export")
                        .font(.system(size: 14, weight: .heavy))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(RemoteTint.record, in: RoundedRectangle(cornerRadius: 13, style: .continuous))

                Button {
                    dismiss()
                } label: {
                    Text("Let it finish")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(RemoteTint.surface, in: RoundedRectangle(cornerRadius: RemoteMetric.rowCorner, style: .continuous))
            }
            .padding(.horizontal, RemoteMetric.gutter)
            .padding(.bottom, 6)
        }
    }
}

// MARK: - Shared controls

/// A settled row carrying a switch. Hand-rolled rather than SwiftUI's `Toggle`
/// because the knob has to be able to say "sending" without moving — a switch
/// that flips before the phone has agreed is a switch that lies.
struct RemoteToggleRow: View {
    var title: String
    var isOn: Bool
    var enabled: Bool
    /// True while this row's own command is in flight. The knob stays exactly
    /// where it is and the ROW fills instead — a switch that flips before the
    /// phone has agreed is a switch that lies, and once it has lied once you
    /// have to check the phone every time.
    var isPending: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(RemoteType.control)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                if isPending {
                    Text("Sending…")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                } else {
                    ZStack(alignment: isOn ? .trailing : .leading) {
                        Capsule()
                            .fill(isOn ? RemoteTint.go : RemoteTint.surfaceTrack)
                            .frame(width: 37, height: 21)
                        Circle()
                            .fill(.white)
                            .frame(width: 17, height: 17)
                            .padding(.horizontal, 2)
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: RemoteMetric.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(alignment: .leading) {
            RoundedRectangle(cornerRadius: RemoteMetric.rowCorner, style: .continuous)
                .fill(RemoteTint.surface)
                .overlay(alignment: .leading) {
                    if isPending {
                        // An indeterminate sweep, not a progress bar: we do not
                        // know how long the link will take, and pretending to
                        // would be its own small lie.
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(.white.opacity(0.10))
                                .frame(width: geometry.size.width * 0.44)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: RemoteMetric.rowCorner, style: .continuous))
        }
        // Repeat taps are swallowed, not queued: a second tap during a send is
        // almost always impatience, and queueing it would toggle twice.
        .disabled(!enabled || isPending)
        .accessibilityLabel(title)
        .accessibilityValue(isPending ? "Sending" : (isOn ? "On" : "Off"))
        .accessibilityAddTraits(.isButton)
    }
}

/// The segmented control the design uses for mutually exclusive modes.
struct RemoteSegmented<Value: Hashable>: View {
    var options: [(Value, String)]
    var selection: Value
    var enabled: Bool
    var onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let isSelected = value == selection
                Button {
                    guard value != selection else { return }
                    onSelect(value)
                } label: {
                    Text(label)
                        .font(.system(size: 12.5, weight: isSelected ? .bold : .semibold))
                        .foregroundStyle(isSelected ? .black : .white.opacity(0.58))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    isSelected ? Color.white : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
        }
        .padding(2)
        .background(RemoteTint.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .disabled(!enabled)
    }
}

// MARK: - Stop at

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
                .foregroundStyle(RemoteTint.link)
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
                .background(RemoteTint.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

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
                .background(RemoteTint.link, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            unit == chipUnit ? RemoteTint.link : Color.white.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func setAmount(_ newValue: Int) {
        let clamped = min(max(lowerBound, newValue), upperBound)
        amount = clamped
        crownValue = Double(clamped)
    }
}
#endif

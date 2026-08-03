import Foundation
import WatchConnectivity
#if os(watchOS)
import WatchKit
#endif

enum WatchRecordingState: String {
    case idle
    case recording
}

@MainActor
final class WatchCaptureRemote: NSObject, ObservableObject {
    @Published private(set) var recordingState: WatchRecordingState = .idle {
        didSet {
            guard recordingState != oldValue else { return }
            #if os(watchOS)
            syncKeepAwake()
            #endif
        }
    }
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var isReachable = false
    @Published private(set) var statusText = "Connecting"
    @Published private(set) var isSending = false
    @Published private(set) var sequenceMode = "ramp"
    @Published private(set) var markerCount = 0
    @Published private(set) var rampIntervalCount = 0
    @Published private(set) var segmentCount = 0
    @Published private(set) var isRampActive = false
    @Published private(set) var isRampHighRate = false
    @Published private(set) var isCameraActive = false
    /// Seconds of the timed burst now running (1/2/4), nil when none — drives
    /// the highlighted chip in the burst row. Local optimism only; it clears
    /// the moment the phone reports the ramp back at base rate.
    @Published private(set) var timedBurstSeconds: Int?
    @Published private(set) var captureMode: CaptureMode = .video
    @Published private(set) var intervalSeconds: Double = 2
    /// Matches the phone's default (10); the phone's state push corrects
    /// any drift on connection.
    @Published private(set) var blendDepth: BlendDepth = .fixed(10)
    /// Mirrors Photo mode's Bulb (hold-open) toggle. When true, the shutter is
    /// a start/stop toggle over one long exposure.
    @Published private(set) var isBulbMode = false
    @Published private(set) var captureCount = 0
    @Published private(set) var stopAtUnit: ScheduledStopUnit?
    @Published private(set) var stopAtDeadline: Date?
    @Published private(set) var stopAtTargetCount: Int?
    @Published private(set) var formatLine: String?
    @Published private(set) var captureFPS = 0
    /// The sequence's resting rate — what the base chip labels itself with.
    /// `captureFPS` reads the burst rate mid-burst, so it can't be the label.
    @Published private(set) var baseFPS = 0
    @Published private(set) var plannedSpeed = 0
    @Published private(set) var outputFPS = 0
    @Published private(set) var isExposureLocked = false
    @Published private(set) var lockedISO: Double = 0
    @Published private(set) var lockedShutter: Double = 0
    @Published private(set) var lockedLensPosition: Double = 0.5
    @Published private(set) var isoMin: Double = 25
    @Published private(set) var isoMax: Double = 3200

    /// Monotonic id for the in-flight send: lets the reply, the error, and the
    /// stuck-send watchdog agree on which send they're finishing, so a late
    /// callback can't clear (or a watchdog can't kill) a newer send's state.
    private var sendToken = 0
    /// True while the DEBUG screenshot hook is faking a live shoot — real
    /// session state must not overwrite it.
    private var isDebugPreview = false

    override init() {
        super.init()
        #if os(watchOS)
        // Shoots are hands-off by design: stretch the frontmost grace period
        // (2 → 8 minutes) so a wrist-down doesn't immediately cost the
        // connection. The extended runtime session below covers the rest.
        WKExtension.shared().isFrontmostTimeoutExtended = true
        #if DEBUG
        applyDebugPreviewStateIfRequested()
        #endif
        #endif
        activate()
    }

    func activate() {
        guard WCSession.isSupported() else {
            statusText = "Unavailable"
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func refreshState() {
        send(command: "state")
    }

    func startRecording() {
        send(command: "startRecording")
    }

    func stopRecording() {
        send(command: "stopRecording")
    }

    func triggerMoment() {
        send(command: "triggerMoment")
    }

    /// Burst for a fixed window: the phone flips to the ramp rate and reverts
    /// to the base rate on its own after `seconds` — no second tap needed.
    func triggerTimedBurst(seconds: Int) {
        send(command: "timedBurst", value: Double(seconds))
    }

    func lockExposure() {
        send(command: "lockExposure")
    }

    func unlockExposure() {
        send(command: "unlockExposure")
    }

    func setISO(_ iso: Double) {
        send(command: "setISO", value: iso)
    }

    func setLensPosition(_ position: Double) {
        send(command: "setLensPosition", value: position)
    }

    func setCaptureMode(_ mode: CaptureMode) {
        send(command: "setCaptureMode", extra: [WatchMessageKey.captureMode: mode.rawValue])
    }

    func setIntervalSeconds(_ seconds: Double) {
        send(command: "setIntervalSeconds", value: seconds)
    }

    func setFramesPerBlend(_ frames: Int) {
        send(command: "setFramesPerBlend", value: Double(frames))
    }

    func scheduleStop(unit: ScheduledStopUnit, amount: Int) {
        send(
            command: "scheduleStop",
            value: Double(amount),
            extra: [WatchMessageKey.stopAtUnit: unit.rawValue])
    }

    func cancelScheduledStop() {
        send(command: "cancelScheduledStop")
    }

    func send(command: String, value: Double? = nil, extra: [String: Any] = [:]) {
        // A debug-preview dummy never talks to a phone: on a paired simulator
        // a real reply would stomp the staged state mid-screenshot (replies
        // apply state directly, bypassing applyState's guard).
        guard !isDebugPreview else { return }
        guard WCSession.default.activationState == .activated else {
            statusText = "Connecting"
            return
        }

        guard WCSession.default.isReachable else {
            isReachable = false
            statusText = "Phone unavailable"
            return
        }

        var payload: [String: Any] = [WatchMessageKey.command: command]
        if let value {
            payload[WatchMessageKey.value] = value
        }
        for (key, extraValue) in extra {
            payload[key] = extraValue
        }

        let startedAt = Date()
        sendToken += 1
        let token = sendToken
        isSending = true
        statusText = "Sending"
        WCSession.default.sendMessage(
            payload,
            replyHandler: { [weak self] reply in
                Task { @MainActor in
                    self?.apply(reply: reply, startedAt: startedAt, command: command, sent: payload, token: token)
                }
            },
            errorHandler: { [weak self] error in
                Task { @MainActor in
                    guard let self, self.sendToken == token else { return }
                    self.isSending = false
                    self.statusText = error.localizedDescription
                }
            }
        )
        // Watchdog: WC can drop both callbacks when the session resets
        // mid-flight. Without this, isSending sticks true and every control —
        // including the recovery ping — stays disabled until app relaunch.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, self.sendToken == token, self.isSending else { return }
            self.isSending = false
            self.statusText = "No response from iPhone"
        }
    }

    private func apply(reply: [String: Any], startedAt: Date, command: String, sent: [String: Any], token: Int) {
        // A stale reply (a newer send is already in flight) still carries an
        // authoritative state snapshot — apply it, but leave the bookkeeping
        // and status line to the send that's actually pending.
        if sendToken == token {
            isSending = false
        }
        isReachable = true

        if let rawState = reply[WatchMessageKey.recordingState] as? String,
           let state = WatchRecordingState(rawValue: rawState) {
            recordingState = state
        }
        applySequenceState(reply)
        applyRecordingStartedAt(reply)

        let status = reply[WatchMessageKey.status] as? String ?? "ok"
        if status == "accepted" {
            // The phone really ran it — mirror the effect even if a newer send
            // has since gone out; the state is real either way.
            applyAcceptedCommand(command, sent: sent, fallbackStartedAt: startedAt)
            // Start/stop flip this screen optimistically; the phone's real
            // transition publishes moments later. If it never comes (camera
            // failed to start: thermal, interruption, revoked permission),
            // nothing else corrects a phantom REC screen — the idle-screen
            // auto-poll deliberately stays off while "recording". One
            // reconciliation pull closes that hole.
            if command == "startRecording" || command == "stopRecording" {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    self?.refreshState()
                }
            }
        }
        guard sendToken == token else { return }
        switch status {
        case "accepted":
            statusText = "Command accepted"
        case "ok":
            statusText = "Ready"
        case "unavailable":
            statusText = reply[WatchMessageKey.message] as? String ?? "Capture screen inactive"
        default:
            statusText = reply[WatchMessageKey.message] as? String ?? "Command failed"
        }
    }

    /// Applies a full state snapshot (live message, application context, or the
    /// stored context read at activation). Deliberately does NOT touch
    /// `isReachable`: a stored context can be hours old and says nothing about
    /// the link right now — reachability always comes from the session itself.
    private func applyState(_ payload: [String: Any]) {
        guard !isDebugPreview else { return }
        if let rawState = payload[WatchMessageKey.recordingState] as? String,
           let state = WatchRecordingState(rawValue: rawState) {
            if recordingState == .recording, state == .idle, stopAtUnit != nil {
                // The capture ended while a scheduled stop was armed. The
                // whole point of "stop at" is walking away, so land the news
                // on the wrist instead of silently falling back to Ready.
                playHaptic(.success)
            }
            recordingState = state
        }
        applySequenceState(payload)
        applyRecordingStartedAt(payload)
    }

    private func applyAcceptedCommand(_ command: String, sent: [String: Any], fallbackStartedAt: Date) {
        switch command {
        case "startRecording":
            recordingState = .recording
            if recordingStartedAt == nil {
                recordingStartedAt = fallbackStartedAt
            }
            if captureMode == .video, segmentCount == 0 {
                segmentCount = 1
            }
            playHaptic(.start)
        case "stopRecording":
            recordingState = .idle
            recordingStartedAt = nil
            markerCount = 0
            rampIntervalCount = 0
            segmentCount = 0
            isRampActive = false
            isRampHighRate = false
            timedBurstSeconds = nil
            playHaptic(.stop)
        case "triggerMoment":
            if recordingState == .recording {
                isRampActive.toggle()
                isRampHighRate = isRampActive && sequenceMode == "ramp"
                if isRampActive {
                    rampIntervalCount = max(1, rampIntervalCount + 1)
                    markerCount = rampIntervalCount
                }
                // A manual toggle takes over from any timed burst.
                timedBurstSeconds = nil
                playHaptic(.click)
            }
        case "timedBurst":
            if recordingState == .recording {
                if !isRampActive {
                    isRampActive = true
                    isRampHighRate = sequenceMode == "ramp"
                    rampIntervalCount = max(1, rampIntervalCount + 1)
                    markerCount = rampIntervalCount
                }
                if let seconds = sent[WatchMessageKey.value] as? Double {
                    timedBurstSeconds = Int(seconds)
                    scheduleTimedBurstReconciliation(afterSeconds: seconds + 2.5)
                }
                playHaptic(.click)
            }
        case "lockExposure":
            isExposureLocked = true
            playHaptic(.click)
        case "unlockExposure":
            isExposureLocked = false
            playHaptic(.click)
        case "setCaptureMode":
            // The phone's echo lags one UI pass behind the accepted command,
            // so reflect what we sent immediately and let the authoritative
            // state converge.
            if let token = sent[WatchMessageKey.captureMode] as? String,
               let mode = CaptureMode(token: token) {
                captureMode = mode
            }
            playHaptic(.click)
        case "setIntervalSeconds":
            if let seconds = sent[WatchMessageKey.value] as? Double {
                intervalSeconds = seconds
            }
            playHaptic(.click)
        case "setFramesPerBlend":
            if let frames = sent[WatchMessageKey.value] as? Double {
                blendDepth = .fixed(Int(frames))
            }
            playHaptic(.click)
        case "scheduleStop":
            // Mirror the phone's math immediately; its authoritative echo
            // arrives a beat later. Amounts are totals for the whole run,
            // anchored to its start — never "N more from now".
            if let raw = sent[WatchMessageKey.stopAtUnit] as? String,
               let unit = ScheduledStopUnit(rawValue: raw),
               let amount = sent[WatchMessageKey.value] as? Double {
                stopAtUnit = unit
                let runStart = recordingStartedAt ?? Date()
                switch unit {
                case .minutes:
                    stopAtDeadline = runStart.addingTimeInterval(amount * 60)
                    stopAtTargetCount = nil
                case .frames:
                    if captureMode == .video {
                        // Base rate, matching the phone's selectedFrameRate —
                        // captureFPS reads the burst rate mid-burst and would
                        // put this countdown out of step with the real one.
                        let fps = Double(max(1, baseFPS > 0 ? baseFPS : captureFPS))
                        stopAtDeadline = runStart.addingTimeInterval(amount / fps)
                        stopAtTargetCount = nil
                    } else {
                        stopAtDeadline = nil
                        stopAtTargetCount = Int(amount)
                    }
                }
            }
            playHaptic(.click)
        case "cancelScheduledStop":
            stopAtUnit = nil
            stopAtDeadline = nil
            stopAtTargetCount = nil
            playHaptic(.click)
        default:
            break
        }
    }

    /// The phone reverts a timed burst on its own; the pushes announcing it
    /// can be lost, and nothing polls while the REC screen is up — a lost
    /// revert used to leave the burst chip lit for the rest of the shoot.
    /// Pull the truth shortly after the revert is due, and keep pulling on a
    /// short lead while the chip still reads as bursting: the revert itself
    /// runs late when the segment switch waits out a long file finalize.
    private func scheduleTimedBurstReconciliation(afterSeconds: Double, attempt: Int = 0) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(afterSeconds * 1_000_000_000))
            guard let self,
                  self.timedBurstSeconds != nil,
                  self.recordingState == .recording else { return }
            self.refreshState()
            if attempt < 8 {
                self.scheduleTimedBurstReconciliation(afterSeconds: 3, attempt: attempt + 1)
            }
        }
    }

    /// Command acknowledgment is the haptic plus the button state itself —
    /// no readouts to squint at on a tripod rig.
    private func playHaptic(_ type: WatchHapticType) {
        #if os(watchOS)
        switch type {
        case .start: WKInterfaceDevice.current().play(.start)
        case .stop: WKInterfaceDevice.current().play(.stop)
        case .click: WKInterfaceDevice.current().play(.click)
        case .success: WKInterfaceDevice.current().play(.success)
        }
        #endif
    }

    private enum WatchHapticType {
        case start
        case stop
        case click
        case success
    }

    func reconnect() {
        activate()
        #if os(watchOS)
        // Also the re-entry point after wrist-up: an extended runtime session
        // that expired (1 h cap) or failed to start while inactive can only
        // be replaced while the app is frontmost — which is exactly now.
        syncKeepAwake()
        #endif
        // Always attempt the refresh — send() itself reports "Connecting" or
        // "Phone unavailable" when it can't go out, so a ping is never a
        // silent no-op.
        refreshState()
    }

    // MARK: - Keep-awake

    #if os(watchOS)
    /// Keeps the app running through wrist-down while a shoot records. watchOS
    /// offers no way to hold the display awake, but an extended runtime
    /// session keeps the app alive and frontmost with the session connected,
    /// so a wrist-raise lands straight back on live controls instead of a
    /// reconnect. Needs the `mindfulness` entry in `WKBackgroundModes`.
    private var extendedSession: WKExtendedRuntimeSession?

    private func syncKeepAwake() {
        if recordingState == .recording {
            startExtendedSessionIfNeeded()
        } else {
            endExtendedSession()
        }
    }

    private func startExtendedSessionIfNeeded() {
        if let extendedSession,
           extendedSession.state == .running || extendedSession.state == .scheduled {
            return
        }
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        extendedSession = session
    }

    private func endExtendedSession() {
        extendedSession?.invalidate()
        extendedSession = nil
    }
    #endif

    #if os(watchOS) && DEBUG
    /// `SIMCTL_CHILD_LL_UI_PREVIEW=recording` fakes a live ramp shoot so the
    /// recording screen can be screenshotted in the Watch simulator without a
    /// paired phone actually capturing.
    private func applyDebugPreviewStateIfRequested() {
        guard ProcessInfo.processInfo.environment["LL_UI_PREVIEW"] == "recording" else { return }
        // Freeze this fake state: applyState refuses real session payloads
        // (context seed, live pushes) while the flag is up, so the screenshot
        // can't be yanked back to reality mid-shot.
        isDebugPreview = true
        isReachable = true
        isCameraActive = true
        captureMode = .video
        sequenceMode = "ramp"
        captureFPS = 24
        baseFPS = 24
        plannedSpeed = 30
        outputFPS = 30
        formatLine = "4K · 24 fps"
        rampIntervalCount = 2
        recordingStartedAt = Date().addingTimeInterval(-83)
        recordingState = .recording
    }
    #endif

    private func applySequenceState(_ payload: [String: Any]) {
        if let mode = payload[WatchMessageKey.sequenceMode] as? String {
            sequenceMode = mode
        }
        if let count = payload[WatchMessageKey.markerCount] as? Int {
            markerCount = count
        }
        if let count = payload[WatchMessageKey.rampIntervalCount] as? Int {
            rampIntervalCount = count
        }
        if let count = payload[WatchMessageKey.segmentCount] as? Int {
            segmentCount = count
        }
        if let isActive = payload[WatchMessageKey.isRampActive] as? Bool {
            if isRampActive, !isActive, timedBurstSeconds != nil {
                // The phone's timed revert just landed — a tick on the wrist
                // beats glancing down to watch the rate flip back.
                playHaptic(.click)
            }
            isRampActive = isActive
            if !isActive {
                timedBurstSeconds = nil
            }
        }
        if let isHighRate = payload[WatchMessageKey.isRampHighRate] as? Bool {
            isRampHighRate = isHighRate
        }
        if let cameraActive = payload[WatchMessageKey.cameraActive] as? Bool {
            isCameraActive = cameraActive
        }
        // token-tolerant: a phone build from before the mode merge may still
        // mirror "Live Blend", which resolves to Interval.
        if let token = payload[WatchMessageKey.captureMode] as? String,
           let mode = CaptureMode(token: token) {
            captureMode = mode
        }
        if let seconds = payload[WatchMessageKey.intervalSeconds] as? Double, seconds > 0 {
            intervalSeconds = seconds
        }
        // The token names the depth (fixed counts, Psycho, Safe); phone
        // builds from before the adaptive depths only send the numeric key.
        if let token = payload[WatchMessageKey.blendDepth] as? String,
           let depth = BlendDepth(token: token) {
            blendDepth = depth
        } else if let frames = payload[WatchMessageKey.framesPerBlend] as? Int, frames > 0 {
            blendDepth = .fixed(frames)
        }
        if let bulb = payload[WatchMessageKey.isBulbMode] as? Bool {
            isBulbMode = bulb
        }
        if let count = payload[WatchMessageKey.captureCount] as? Int {
            captureCount = count
        }
        // Scheduled stop: every payload is a full snapshot, so an absent unit
        // means no schedule — clear rather than keep stale countdowns. Command
        // replies are exempt (they run before the optimistic apply).
        if let raw = payload[WatchMessageKey.stopAtUnit] as? String,
           let unit = ScheduledStopUnit(rawValue: raw) {
            stopAtUnit = unit
            if let timestamp = payload[WatchMessageKey.stopAtDeadline] as? TimeInterval {
                stopAtDeadline = Date(timeIntervalSince1970: timestamp)
            } else {
                stopAtDeadline = nil
            }
            stopAtTargetCount = payload[WatchMessageKey.stopAtTargetCount] as? Int
        } else if payload[WatchMessageKey.captureMode] != nil {
            stopAtUnit = nil
            stopAtDeadline = nil
            stopAtTargetCount = nil
        }
        if let line = payload[WatchMessageKey.formatLine] as? String {
            formatLine = line
        }
        if let fps = payload[WatchMessageKey.captureFPS] as? Int, fps > 0 {
            captureFPS = fps
        }
        if let fps = payload[WatchMessageKey.baseFPS] as? Int, fps > 0 {
            baseFPS = fps
        }
        if let speed = payload[WatchMessageKey.plannedSpeed] as? Int, speed > 0 {
            plannedSpeed = speed
        }
        if let fps = payload[WatchMessageKey.outputFPS] as? Int, fps > 0 {
            outputFPS = fps
        }
        if let locked = payload[WatchMessageKey.isExposureLocked] as? Bool {
            isExposureLocked = locked
        }
        if let iso = payload[WatchMessageKey.lockedISO] as? Double, iso > 0 {
            lockedISO = iso
        }
        if let shutter = payload[WatchMessageKey.lockedShutter] as? Double, shutter > 0 {
            lockedShutter = shutter
        }
        if let lens = payload[WatchMessageKey.lockedLensPosition] as? Double {
            lockedLensPosition = lens
        }
        if let min = payload[WatchMessageKey.isoMin] as? Double, min > 0 {
            isoMin = min
        }
        if let max = payload[WatchMessageKey.isoMax] as? Double, max > 0 {
            isoMax = max
        }
        if recordingState == .idle {
            markerCount = 0
            rampIntervalCount = 0
            segmentCount = 0
            isRampActive = false
            isRampHighRate = false
            timedBurstSeconds = nil
        }
    }

    private func applyRecordingStartedAt(_ payload: [String: Any]) {
        if recordingState == .recording,
           let timestamp = payload[WatchMessageKey.recordingStartedAt] as? TimeInterval {
            recordingStartedAt = Date(timeIntervalSince1970: timestamp)
        } else if recordingState == .idle {
            recordingStartedAt = nil
        }
    }
}

extension WatchCaptureRemote: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let reachable = session.isReachable
        // The phone pushes a full snapshot into the application context on
        // every change, and it survives both apps relaunching. Seed from it so
        // a cold start mid-shoot shows the shoot immediately instead of
        // betting everything on one live round-trip (which can lose to a busy
        // phone main thread and leave "open the camera" up during a recording).
        let storedContext = session.receivedApplicationContext
        Task { @MainActor in
            guard !self.isDebugPreview else { return }
            self.isReachable = reachable
            self.statusText = error == nil ? "Ready" : (error?.localizedDescription ?? "Connection failed")
            if !storedContext.isEmpty {
                self.applyState(storedContext)
            }
            self.refreshState()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            guard !self.isDebugPreview else { return }
            self.isReachable = session.isReachable
            self.statusText = session.isReachable ? "Ready" : "Phone unavailable"
            // The phone can come within reach after we've already activated
            // (screen wakes, capture screen opens, we drift back into range).
            // Activation's one-shot `refreshState` is long past by then, so
            // pull the live capture state now — otherwise a shoot that began
            // while we were out of reach reads as idle until a manual ping.
            if session.isReachable {
                self.refreshState()
            }
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        // Contexts can be delivered from a queue at launch, well after the
        // phone sent them — reachability comes from the session, not from the
        // fact that bytes arrived.
        let reachable = session.isReachable
        Task { @MainActor in
            guard !self.isDebugPreview else { return }
            self.isReachable = reachable
            self.applyState(applicationContext)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            guard !self.isDebugPreview else { return }
            // A live message just landed — the counterpart is reachable now.
            self.isReachable = true
            self.applyState(message)
        }
    }
}

#if os(watchOS)
extension WatchCaptureRemote: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}

    nonisolated func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        // Expired (1 h cap), superseded, or refused because the app wasn't
        // frontmost — drop the handle so the next sync can start a fresh one.
        Task { @MainActor in
            if self.extendedSession === extendedRuntimeSession {
                self.extendedSession = nil
            }
        }
    }
}
#endif

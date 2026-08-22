// This file is compiled into BOTH the watch app and the universal app target
// — and that target also builds iOS, where a second WCSession delegate would
// sit alongside WatchRemoteControlReceiver contending for the single
// `WCSession.default.delegate` slot. So the condition is macOS-POSITIVE, not
// watchOS-negative: the remote exists on the wrist and on the Mac, nowhere
// else. See Remote/ in the project layout.
#if os(watchOS) || os(macOS)
import CoreGraphics
import Foundation
import ImageIO
#if os(watchOS)
import WatchKit
#endif

/// One decoded look through the phone's lens.
struct RemotePreviewFrame {
    let image: CGImage
    let pixelWidth: Int
    let pixelHeight: Int
    /// Signed degrees off level, or nil when the phone has no motion reading
    /// yet. Nil hides the horizon bar entirely — drawing it at zero would
    /// claim "perfectly level", the one wrong answer that looks right.
    let rollDegrees: Double?

    var aspect: Double {
        guard pixelHeight > 0 else { return 1 }
        return Double(pixelWidth) / Double(pixelHeight)
    }
}

/// A command that did not take effect, and enough to say so honestly and try
/// again. The payload is kept verbatim so a retry re-sends the original intent
/// rather than re-deriving one from state that has since moved.
struct RemoteCommandFailure: Identifiable {
    let id = UUID()
    let command: WatchCaptureCommand
    let payload: [String: Any]
    /// What the link or the phone said, in its own words.
    let message: String
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
    /// Which command is in flight, so the control that sent it can say so
    /// itself rather than the whole screen greying out anonymously.
    @Published private(set) var pendingCommand: WatchCaptureCommand?
    /// The last command that did not land, kept until it is retried or
    /// dismissed. A remote that silently drops a command teaches people to
    /// press everything twice — which is exactly the habit that ends a shoot
    /// by accident. See `RemoteCommandFailure`.
    @Published private(set) var lastFailure: RemoteCommandFailure?
    @Published private(set) var sequenceMode = "ramp"
    @Published private(set) var markerCount = 0
    @Published private(set) var rampIntervalCount = 0
    @Published private(set) var segmentCount = 0
    @Published private(set) var isRampActive = false
    @Published private(set) var isRampHighRate = false
    /// A mark's IN is placed and its OUT is not.
    @Published private(set) var isMarkActive = false
    @Published private(set) var markIntervalCount = 0
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
    /// Interval's MODE dial as the camera has it — Off · Holy Grail · Scanner.
    @Published private(set) var intervalMode: IntervalCaptureMode = .basic
    /// EVERY is pacing itself. `intervalSeconds` then reports what the pacing
    /// has *arrived at*, not what anyone chose, so the remote labels it "Auto".
    @Published private(set) var intervalAuto = false
    /// Whichever MODE readout is live, nil when neither is. See
    /// `WatchMessageKey`'s notes: absent means "no such run", never "zeroed".
    @Published private(set) var holyGrail: HolyGrailReadout?
    @Published private(set) var scanner: ScannerReadout?

    /// The ramp's live numbers as they arrive over the wire.
    struct HolyGrailReadout: Equatable {
        var shutterSeconds: Double
        var iso: Double
        var sceneEV: Double
        /// Shutter is pinned and ISO is carrying the ramp — the operator's cue
        /// to stop the shoot or accept grain.
        var isISORamping: Bool
        /// The scene has outrun the hardware; frames keep coming but no longer
        /// track the light.
        var isClipped: Bool
        var isCapturingRAW: Bool
    }

    /// Scanner's live numbers. `phase` is `ScannerEngine.State.rawValue`, kept
    /// as a String because the engine is an iOS-only app type and this struct
    /// has to decode on watchOS too.
    struct ScannerReadout: Equatable {
        var phase: String
        var frames: Int
        var shutterSeconds: Double
        var iso: Double
        var isCapturingRAW: Bool
        var waitingForDeviceSteady: Bool

        var isSettling: Bool { phase == "disturbed" }
    }
    @Published private(set) var stopAtUnit: ScheduledStopUnit?
    @Published private(set) var stopAtDeadline: Date?
    @Published private(set) var stopAtTargetCount: Int?
    @Published private(set) var formatLine: String?
    @Published private(set) var captureFPS = 0
    /// The sequence's resting rate — what the base chip labels itself with.
    /// `captureFPS` reads the burst rate mid-burst, so it can't be the label.
    @Published private(set) var baseFPS = 0
    /// The rate ⚡ will run at. Distinct from `captureFPS`, which reports the
    /// segment running right now — the burst chips are durations, not rates,
    /// so without this the remote can't say what a burst will actually do.
    @Published private(set) var rampFPS = 0
    /// Every rate a burst could switch to at the current format, ascending.
    /// Empty means this camera has nothing faster than its base rate — the
    /// rate ladder says so rather than offering a burst that can't run.
    @Published private(set) var availableBurstFPS: [Int] = []
    /// Every base frame rate this lens and resolution can shoot, ascending.
    @Published private(set) var availableBaseFPS: [Int] = []
    @Published private(set) var plannedSpeed = 0
    @Published private(set) var outputFPS = 0
    @Published private(set) var isExposureLocked = false
    @Published private(set) var lockedISO: Double = 0
    @Published private(set) var lockedShutter: Double = 0
    @Published private(set) var lockedLensPosition: Double = 0.5
    @Published private(set) var isoMin: Double = 25
    @Published private(set) var isoMax: Double = 3200

    // MARK: What the phone is doing instead of being a camera

    /// `home` · `setup` · `processing` · `done`.
    @Published private(set) var phoneFlow = "home"
    /// "active" while the phone app is on screen, "background" once it truly
    /// leaves. The phone has published this since the link's first version and
    /// nothing ever read it — it is the difference between "app open on
    /// another screen, one tap from the camera" and "locked in a pocket,
    /// nothing this remote can do".
    @Published private(set) var phoneAppState = "active"
    @Published private(set) var flowTitle: String?
    @Published private(set) var flowStep: Int?
    @Published private(set) var flowStepCount: Int?
    @Published private(set) var exportProgress: Double?
    @Published private(set) var exportETASeconds: Double?
    @Published private(set) var exportTitle: String?
    @Published private(set) var exportSubtitle: String?
    @Published private(set) var lastCaptureAt: Date?

    // MARK: Framing preview

    /// The most recent frame, decoded. Held rather than re-decoded per draw:
    /// at 1 Hz the decode is cheap, but the view redraws far more often than
    /// that.
    @Published private(set) var previewFrame: RemotePreviewFrame?
    /// When the last frame LANDED, by this device's clock. Deliberately not
    /// the phone's capture timestamp: the two clocks disagree by an unknown
    /// amount, and an age readout computed across them can go negative — which
    /// is a very confident way to lie about how fresh a frame is.
    @Published private(set) var previewReceivedAt: Date?
    /// Consecutive failed frame requests. Three is stale; one is a hiccup.
    @Published private(set) var previewMisses = 0

    /// Monotonic id for the in-flight send: lets the reply, the error, and the
    /// stuck-send watchdog agree on which send they're finishing, so a late
    /// callback can't clear (or a watchdog can't kill) a newer send's state.
    private var sendToken = 0
    /// True while the DEBUG screenshot hook is faking a live shoot — real
    /// session state must not overwrite it.
    private var isDebugPreview = false

    /// The pipe to the capture screen. Everything below this line is about
    /// what the remote does with state, not how the bytes travel.
    private let transport: any CaptureRemoteTransport

    /// The pipe each platform's remote speaks by default. A Watch reaches an
    /// iPhone over WatchConnectivity; a Mac reaches an iPad or iPhone over the
    /// local network, because `WCSession` does not exist on macOS at all.
    static func defaultTransport() -> any CaptureRemoteTransport {
        #if os(watchOS)
        return WatchConnectivityTransport()
        #else
        return LocalNetworkTransport()
        #endif
    }

    /// Resolved inside the body rather than as a default argument: default
    /// arguments are evaluated in a nonisolated context, and both concrete
    /// transports are main-actor isolated.
    init(transport: (any CaptureRemoteTransport)? = nil) {
        let transport = transport ?? Self.defaultTransport()
        self.transport = transport
        super.init()
        self.transport.delegate = self
        #if os(watchOS)
        // Shoots are hands-off by design; the extended runtime session
        // (syncKeepAwake) is what carries the app through wrist-down.
        // `isFrontmostTimeoutExtended` used to stretch the frontmost grace
        // period too, but it's been a no-op since watchOS 7.
        #endif
        // The screenshot hook runs on the Mac too, not just the watch. The Mac
        // remote is the same `WatchControlView` on a 208×248 canvas, and it is
        // the surface these screens are hardest to reach on for real: driving
        // an iPad on a tripod through a sunset is not a screenshot run. Same
        // DEBUG gate, same frozen state.
        #if DEBUG && (os(watchOS) || os(macOS))
        applyDebugPreviewStateIfRequested()
        #endif
        activate()
    }

    func activate() {
        // A permanently unavailable transport must not fall through to
        // activate + refreshState: the poll's own pre-flight would overwrite
        // this with "Connecting" and sit there forever.
        if let reason = transport.unavailabilityReason {
            statusText = reason
            return
        }
        transport.activate()
    }

    func refreshState() {
        send(.state)
    }

    func startRecording() {
        send(.startRecording)
    }

    func stopRecording() {
        send(.stopRecording)
    }

    func triggerMoment() {
        send(.triggerMoment)
    }

    /// Burst for a fixed window: the phone flips to the ramp rate and reverts
    /// to the base rate on its own after `seconds` — no second tap needed.
    /// Place a mark's IN, or close the open one. `seconds > 0` asks the phone
    /// to place the OUT on its own timer.
    func toggleMark(seconds: Int = 0) {
        send(.toggleMark, value: seconds > 0 ? Double(seconds) : nil)
    }

    func triggerTimedBurst(seconds: Int) {
        send(.timedBurst, value: Double(seconds))
    }

    func lockExposure() {
        send(.lockExposure)
    }

    func unlockExposure() {
        send(.unlockExposure)
    }

    func setISO(_ iso: Double) {
        send(.setISO, value: iso)
    }

    func setLensPosition(_ position: Double) {
        send(.setLensPosition, value: position)
    }

    func setCaptureMode(_ mode: CaptureMode) {
        send(.setCaptureMode, extra: [WatchMessageKey.captureMode: mode.rawValue])
    }

    func setIntervalSeconds(_ seconds: Double) {
        send(.setIntervalSeconds, value: seconds)
    }

    /// Arms Interval's MODE dial from the remote — the command that makes a
    /// Holy Grail or Scanner shoot startable without walking to the camera.
    /// Idle-only on the phone; it also switches the camera to Interval, since
    /// that is the only mode these belong to.
    func setIntervalMode(_ mode: IntervalCaptureMode) {
        send(.setIntervalMode, extra: [WatchMessageKey.intervalMode: mode.rawValue])
    }

    /// EVERY on/off Auto. The phone owns the validity rule (Scanner can't leave
    /// it, Off can't reach it) and rejects rather than silently ignoring, so a
    /// refusal surfaces as a banner instead of a control that did nothing.
    func setAutoInterval(_ auto: Bool) {
        send(.setAutoInterval, value: auto ? 1 : 0)
    }

    /// Scanner only: throw away the pose just captured, without ending the run.
    func deleteLastFrame() {
        send(.deleteLastFrame)
    }

    func setFramesPerBlend(_ frames: Int) {
        send(.setFramesPerBlend, value: Double(frames))
    }

    /// The rate a burst switches to. Unlike the other setters this one is live
    /// mid-shoot — the whole point of the controls tab is changing what the
    /// next burst will do without stopping the run.
    func setBurstFPS(_ fps: Int) {
        send(.setBurstFPS, value: Double(fps))
    }

    /// Idle only — this one re-applies the capture format on the phone, so the
    /// armed screen is the only place it is offered.
    func setBaseFPS(_ fps: Int) {
        send(.setBaseFPS, value: Double(fps))
    }

    /// Ramp or marker. Baked into the sequence at start, so idle only too.
    func setSequenceMode(_ mode: String) {
        send(.setSequenceMode, extra: [WatchMessageKey.sequenceMode: mode])
    }

    func scheduleStop(unit: ScheduledStopUnit, amount: Int) {
        send(
            .scheduleStop,
            value: Double(amount),
            extra: [WatchMessageKey.stopAtUnit: unit.rawValue])
    }

    func cancelScheduledStop() {
        send(.cancelScheduledStop)
    }

    func armCamera() {
        send(.armCamera)
    }

    /// Ask for one frame. The framing screen calls this on a 1 Hz timer while
    /// it is on screen and never otherwise — asking IS the subscription, so an
    /// unopened screen costs the link nothing.
    func requestPreviewFrame() {
        #if os(watchOS) && DEBUG
        // The screenshot rig stands in for a live camera, so a staged frame
        // has to keep arriving — otherwise every framing screenshot ends up
        // showing the stale treatment, which is the one variant that stages
        // itself by backdating instead.
        if isDebugPreview, debugPreviewScreen != "framing-stale", previewFrame != nil {
            previewReceivedAt = Date()
            return
        }
        #endif
        send(.previewFrame)
    }

    /// Forget the last frame when the framing screen closes, so re-opening it
    /// shows "waiting" rather than a minute-old view of somewhere else.
    func clearPreviewFrame() {
        previewFrame = nil
        previewReceivedAt = nil
        previewMisses = 0
    }

    /// The shutter key is the presence test for each readout: a ramp that is
    /// running always has an exposure, and a payload without one is a payload
    /// from a camera that isn't ramping.
    private static func holyGrailReadout(from payload: [String: Any]) -> HolyGrailReadout? {
        guard let shutter = payload[WatchMessageKey.holyGrailShutter] as? Double else { return nil }
        return HolyGrailReadout(
            shutterSeconds: shutter,
            iso: payload[WatchMessageKey.holyGrailISO] as? Double ?? 0,
            sceneEV: payload[WatchMessageKey.holyGrailSceneEV] as? Double ?? 0,
            isISORamping: payload[WatchMessageKey.holyGrailISORamping] as? Bool ?? false,
            isClipped: payload[WatchMessageKey.holyGrailClipped] as? Bool ?? false,
            isCapturingRAW: payload[WatchMessageKey.holyGrailRAW] as? Bool ?? false)
    }

    private static func scannerReadout(from payload: [String: Any]) -> ScannerReadout? {
        guard let phase = payload[WatchMessageKey.scannerPhase] as? String else { return nil }
        return ScannerReadout(
            phase: phase,
            frames: payload[WatchMessageKey.scannerFrames] as? Int ?? 0,
            shutterSeconds: payload[WatchMessageKey.scannerShutter] as? Double ?? 0,
            iso: payload[WatchMessageKey.scannerISO] as? Double ?? 0,
            isCapturingRAW: payload[WatchMessageKey.scannerRAW] as? Bool ?? false,
            waitingForDeviceSteady: payload[WatchMessageKey.scannerWaitingForSteady] as? Bool ?? false)
    }

    private func applyPreviewFrame(_ payload: [String: Any]) {
        guard let encoded = payload[WatchMessageKey.previewImage] as? String,
              let data = Data(base64Encoded: encoded),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            // The reply arrived but carried no usable frame — the camera has
            // not produced one yet, or the encode failed. That is a miss, not
            // an error: the next tick usually has one.
            previewMisses += 1
            return
        }
        previewFrame = RemotePreviewFrame(
            image: image,
            pixelWidth: payload[WatchMessageKey.previewPixelWidth] as? Int ?? image.width,
            pixelHeight: payload[WatchMessageKey.previewPixelHeight] as? Int ?? image.height,
            rollDegrees: payload[WatchMessageKey.previewRollDegrees] as? Double)
        previewReceivedAt = Date()
        previewMisses = 0
    }

    func cancelExport() {
        send(.cancelExport)
    }

    func send(_ command: WatchCaptureCommand, value: Double? = nil, extra: [String: Any] = [:]) {
        var payload: [String: Any] = [WatchMessageKey.command: command.rawValue]
        if let value {
            payload[WatchMessageKey.value] = value
        }
        for (key, extraValue) in extra {
            payload[key] = extraValue
        }
        dispatch(command, payload: payload)
    }

    /// Re-send exactly what failed — the same payload, not a freshly built one.
    /// Rebuilding would re-read current state, and current state has moved on
    /// from the moment the command was issued.
    func retryFailedCommand() {
        guard let failure = lastFailure else { return }
        lastFailure = nil
        dispatch(failure.command, payload: failure.payload)
    }

    func dismissFailure() {
        lastFailure = nil
    }

    private func dispatch(_ command: WatchCaptureCommand, payload: [String: Any]) {
        // A debug-preview dummy never talks to a phone: on a paired simulator
        // a real reply would stomp the staged state mid-screenshot (replies
        // apply state directly, bypassing applyState's guard).
        guard !isDebugPreview else { return }
        // Pre-flight rather than letting the transport fail the send: these two
        // never reach the wire, and neither should mark a send in flight.
        guard transport.isActivated else {
            statusText = "Connecting"
            noteFailure(command, payload: payload, message: "Still connecting to iPhone")
            return
        }

        guard transport.isReachable else {
            isReachable = false
            statusText = "Phone unavailable"
            noteFailure(command, payload: payload, message: "iPhone is out of reach")
            return
        }

        let startedAt = Date()
        sendToken += 1
        let token = sendToken
        isSending = true
        pendingCommand = command
        statusText = "Sending"
        transport.send(
            payload,
            reply: { [weak self] reply in
                self?.apply(reply: reply, startedAt: startedAt, command: command, sent: payload, token: token)
            },
            failure: { [weak self] failure in
                guard let self, self.sendToken == token else { return }
                self.isSending = false
                self.pendingCommand = nil
                switch failure {
                case .notActivated: self.statusText = "Connecting"
                case .unreachable: self.statusText = "Phone unavailable"
                case .failed(let message): self.statusText = message
                }
                self.noteFailure(command, payload: payload, message: self.statusText)
            }
        )
        // Watchdog: a transport can drop both callbacks when the link resets
        // mid-flight. Without this, isSending sticks true and every control —
        // including the recovery ping — stays disabled until app relaunch.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, self.sendToken == token, self.isSending else { return }
            self.isSending = false
            self.pendingCommand = nil
            self.statusText = "No response from iPhone"
            self.noteFailure(command, payload: payload, message: "No response from iPhone")
        }
    }

    /// Records a command that did not take effect — but only the ones a person
    /// actually asked for. Polls fail all the time on a wrist that drifts out
    /// of range, and a banner for each would be noise that trains people to
    /// dismiss banners.
    private func noteFailure(_ command: WatchCaptureCommand, payload: [String: Any], message: String) {
        // A frame request that never came back is a miss like any other — the
        // framing screen counts them to decide when the picture has gone
        // stale, so the ones that fail on the wire have to count too.
        if command == .previewFrame {
            previewMisses += 1
        }
        guard command.isUserInitiated else { return }
        lastFailure = RemoteCommandFailure(command: command, payload: payload, message: message)
    }

    private func apply(reply: [String: Any], startedAt: Date, command: WatchCaptureCommand, sent: [String: Any], token: Int) {
        // A stale reply (a newer send is already in flight) still carries an
        // authoritative state snapshot — apply it, but leave the bookkeeping
        // and status line to the send that's actually pending.
        if sendToken == token {
            isSending = false
            pendingCommand = nil
        }
        isReachable = true

        if let rawState = reply[WatchMessageKey.recordingState] as? String,
           let state = WatchRecordingState(rawValue: rawState) {
            recordingState = state
        }
        applySequenceState(reply)
        applyRecordingStartedAt(reply)
        if command == .previewFrame {
            applyPreviewFrame(reply)
        }

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
            if command == .startRecording || command == .stopRecording {
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
            // The round trip completed and the phone acted — whatever went
            // wrong before is over, so the banner goes with it.
            lastFailure = nil
        case "ok":
            statusText = "Ready"
            lastFailure = nil
        case "unavailable":
            statusText = reply[WatchMessageKey.message] as? String ?? "Capture screen inactive"
            noteFailure(command, payload: sent, message: statusText)
        default:
            // Reached the phone and was refused. A different fact from "didn't
            // arrive", and the copy says so — retrying a refusal usually needs
            // something to change first.
            statusText = reply[WatchMessageKey.message] as? String ?? "Command failed"
            noteFailure(command, payload: sent, message: statusText)
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

    private func applyAcceptedCommand(_ command: WatchCaptureCommand, sent: [String: Any], fallbackStartedAt: Date) {
        // Exhaustive on purpose — no `default`. A new command should have to
        // say out loud that it mirrors nothing, rather than silently inheriting
        // "no optimistic state" from a catch-all.
        switch command {
        case .startRecording:
            recordingState = .recording
            if recordingStartedAt == nil {
                recordingStartedAt = fallbackStartedAt
            }
            if captureMode == .video, segmentCount == 0 {
                segmentCount = 1
            }
            playHaptic(.start)
        case .stopRecording:
            recordingState = .idle
            recordingStartedAt = nil
            markerCount = 0
            rampIntervalCount = 0
            segmentCount = 0
            isRampActive = false
            isRampHighRate = false
            isMarkActive = false
            markIntervalCount = 0
            timedBurstSeconds = nil
            playHaptic(.stop)
        case .triggerMoment:
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
        case .timedBurst:
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
        case .lockExposure:
            isExposureLocked = true
            playHaptic(.click)
        case .unlockExposure:
            isExposureLocked = false
            playHaptic(.click)
        case .setCaptureMode:
            // The phone's echo lags one UI pass behind the accepted command,
            // so reflect what we sent immediately and let the authoritative
            // state converge.
            if let token = sent[WatchMessageKey.captureMode] as? String,
               let mode = CaptureMode(token: token) {
                captureMode = mode
            }
            playHaptic(.click)
        case .setIntervalSeconds:
            if let seconds = sent[WatchMessageKey.value] as? Double {
                intervalSeconds = seconds
                // Picking a spacing is also how you leave Auto — mirroring the
                // coupling the phone applies, so the row doesn't read "Auto"
                // over a number the user just chose.
                intervalAuto = false
            }
            playHaptic(.click)
        case .setIntervalMode:
            if let token = sent[WatchMessageKey.intervalMode] as? String {
                let mode = IntervalCaptureMode(token: token)
                intervalMode = mode
                // The phone switches to Interval for these, and forces Auto
                // under Scanner. Echo both so the whole row settles at once
                // rather than in two visible steps a round-trip apart.
                captureMode = .interval
                if mode.requiresAutoInterval {
                    intervalAuto = true
                } else if !mode.supportsAutoInterval {
                    intervalAuto = false
                }
            }
            playHaptic(.click)
        case .setAutoInterval:
            if let value = sent[WatchMessageKey.value] as? Double {
                intervalAuto = value != 0
            }
            playHaptic(.click)
        case .deleteLastFrame:
            // Deliberately no optimistic decrement: the phone owns the count,
            // and a delete that raced a landing frame would leave the remote
            // one ahead of the camera — on the one screen where the count is
            // the whole point. The push that follows carries the truth.
            playHaptic(.click)
        case .setFramesPerBlend:
            if let frames = sent[WatchMessageKey.value] as? Double {
                blendDepth = .fixed(Int(frames))
            }
            playHaptic(.click)
        case .setBlendStrategy:
            // Mirrors nothing on the watch: the strategy is a Settings-level
            // fact the watch UI never shows. Mac-remote scripts use it.
            break
        case .scheduleStart:
            // Mirrors nothing: the armed alarm lives on the phone, and the
            // recording state will arrive as a push when it fires.
            break
        case .setBurstFPS:
            // Echoed locally so the ladder's selected rung moves with the
            // crown instead of lagging a round-trip behind it. No haptic —
            // the crown has its own detents, and this fires on every rung.
            if let fps = sent[WatchMessageKey.value] as? Double {
                rampFPS = Int(fps)
            }
        case .setBaseFPS:
            if let fps = sent[WatchMessageKey.value] as? Double {
                baseFPS = Int(fps)
                captureFPS = Int(fps)
            }
            playHaptic(.click)
        case .setSequenceMode:
            // The pad's whole vocabulary changes with this — BURST becomes
            // MARK IN — so echo it rather than waiting a round trip to find
            // out what the control in front of you now does.
            if let mode = sent[WatchMessageKey.sequenceMode] as? String {
                sequenceMode = mode
            }
            playHaptic(.click)
        case .scheduleStop:
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
        case .cancelScheduledStop:
            stopAtUnit = nil
            stopAtDeadline = nil
            stopAtTargetCount = nil
            playHaptic(.click)
        case .setISO, .setLensPosition:
            // The crown already moved the local value as it turned; echoing it
            // here would fight the gesture. No haptic either — the crown has
            // its own detents.
            break
        case .toggleMark:
            // The pad's word flips IN ⇄ OUT on this, so echo it rather than
            // leaving the control naming the wrong edge for a round trip.
            if recordingState == .recording {
                isMarkActive.toggle()
                if isMarkActive {
                    markIntervalCount += 1
                }
                playHaptic(.click)
            }
        case .previewFrame:
            // A poll. Its frame is taken in `apply`, alongside the state
            // snapshot the same reply carries.
            break
        case .armCamera, .cancelExport:
            // Nothing to mirror optimistically: both are requests for the
            // phone to change what it is doing, and the honest signal that it
            // worked is the next state snapshot saying so. Pull one shortly,
            // because opening a camera takes longer than a reply does.
            playHaptic(.click)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.refreshState()
            }
        case .state:
            // A poll, not an action. Its reply is a state snapshot and
            // `apply` has already taken it.
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
        // `.notStarted` counts as alive: `start()` is asynchronous, and the
        // state pushes that arrive while it settles must not replace the
        // session object — dropping the reference deallocs a starting/running
        // WKExtendedRuntimeSession mid-session ("WKExtendedRuntimeObject was
        // dealloced while running", 2026-08-11 watch log), and the shoot ends
        // up with no keep-awake at all. Only a session the system has
        // invalidated is dead enough to replace; the delegate below clears
        // the handle when that happens, so a refused start self-heals on the
        // next sync.
        if let extendedSession, extendedSession.state != .invalid {
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

    #if DEBUG && (os(watchOS) || os(macOS))
    /// Which screen the screenshot hook asked for, so the view can preselect
    /// the matching tab. Nil outside the hook.
    private(set) var debugPreviewScreen: String?

    /// `SIMCTL_CHILD_LL_UI_PREVIEW=<screen>` stages a shoot so any screen can
    /// be screenshotted in the Watch simulator without a paired phone actually
    /// capturing. One value per screen the design specs mirror:
    ///
    /// `recording` · `controls` · `stop` — the three in-shoot tabs
    /// `armed` · `armed-setup` — the two idle pages
    /// `marker` — a Video run in marks-only mode
    /// `interval` — an Interval run (no burst pad, no rate ladder)
    /// `no-burst` — a camera whose format has nothing faster than its base
    /// `mark-open` — a mark's IN placed, waiting on its OUT
    /// `sending` · `failed` · `locked` — the reliability and lock states
    private func applyDebugPreviewStateIfRequested() {
        guard let screen = ProcessInfo.processInfo.environment["LL_UI_PREVIEW"],
              !screen.isEmpty else { return }
        // Freeze this fake state: applyState refuses real session payloads
        // (context seed, live pushes) while the flag is up, so the screenshot
        // can't be yanked back to reality mid-shot.
        isDebugPreview = true
        debugPreviewScreen = screen
        isReachable = true
        isCameraActive = true
        captureMode = .video
        sequenceMode = "ramp"
        captureFPS = 24
        baseFPS = 24
        rampFPS = 100
        availableBurstFPS = [30, 60, 100, 120]
        availableBaseFPS = [24, 25, 30, 60]
        plannedSpeed = 30
        outputFPS = 30
        formatLine = "4K · 24 fps"
        rampIntervalCount = 2

        switch screen {
        case "marker":
            sequenceMode = "marker"
            markerCount = 2
        case "mark-open":
            isMarkActive = true
            markIntervalCount = 1
        case "interval":
            captureMode = .interval
            clearVideoOnlyStaging()
            intervalSeconds = 2
            blendDepth = .fixed(10)
            captureCount = 148
            formatLine = "12MP 4:3 · JPEG"
        // The two MODE runs, staged. Neither is otherwise reachable on a Mac:
        // they need a paired iPad on a tripod actually shooting, which is the
        // whole situation this remote exists to make unnecessary — and a
        // screenshot run can hardly go and shoot a sunset.
        case "holygrail":
            captureMode = .interval
            clearVideoOnlyStaging()
            intervalMode = .holyGrail
            intervalAuto = true
            intervalSeconds = 9
            blendDepth = .fixed(10)
            captureCount = 214
            formatLine = "12MP 4:3 · DNG"
            // Mid-ramp, deep enough that ISO has taken over — the state whose
            // whole purpose is telling the operator to decide something.
            holyGrail = HolyGrailReadout(
                shutterSeconds: 1.0, iso: 1250, sceneEV: 1.4,
                isISORamping: true, isClipped: false, isCapturingRAW: true)
        case "scanner", "scanner-settling":
            captureMode = .interval
            clearVideoOnlyStaging()
            intervalMode = .scanner
            intervalAuto = true
            blendDepth = .fixed(1)
            captureCount = 12
            formatLine = "12MP 4:3 · DNG"
            scanner = ScannerReadout(
                phase: screen == "scanner-settling" ? "disturbed" : "settled",
                frames: 12,
                shutterSeconds: 1.0 / 120,
                iso: 200,
                isCapturingRAW: true,
                waitingForDeviceSteady: false)
        case "scanner-armed":
            // Idle with Scanner selected: the setup page a Mac uses to arm the
            // iPad before walking away from it.
            captureMode = .interval
            clearVideoOnlyStaging()
            intervalMode = .scanner
            intervalAuto = true
            formatLine = "12MP 4:3 · DNG"
            recordingState = .idle
            return
        case "no-burst":
            availableBurstFPS = []
            rampFPS = 24
        case "armed", "armed-setup":
            // Idle, camera open — the two pages before a run starts.
            recordingState = .idle
            return
        case "armed-setup-marks":
            recordingState = .idle
            sequenceMode = "marker"
            return
        case "framing", "framing-stale", "framing-aids", "framing-portrait",
             "framing-square", "framing-tall", "framing-wide":
            recordingState = .idle
            // A portrait stage as well as a landscape one: the phone rotates
            // the buffer to the pose it is held in, so the watch has to be
            // able to receive a 9:16 frame and pillarbox it.
            let portrait = screen == "framing-portrait"
            if let image = Self.makeStagedPreviewImage(portrait: portrait) {
                previewFrame = RemotePreviewFrame(
                    image: image,
                    pixelWidth: portrait ? 234 : 416,
                    pixelHeight: portrait ? 416 : 234,
                    // A deliberately un-level phone, so the horizon bar and
                    // the angle chip are both exercised.
                    rollDegrees: screen == "framing" ? 0.4 : -3.0)
                // Stale is staged by backdating the arrival, so the real
                // staleness rule is what gets screenshotted rather than a
                // separate flag that could drift from it.
                previewReceivedAt = screen == "framing-stale"
                    ? Date().addingTimeInterval(-4.2)
                    : Date()
            }
            return
        case "camera-closed":
            isCameraActive = false
            recordingState = .idle
            phoneFlow = "home"
            lastCaptureAt = Date().addingTimeInterval(-120)
            return
        case "busy":
            isCameraActive = false
            recordingState = .idle
            phoneFlow = "processing"
            exportProgress = 0.42
            exportETASeconds = 80
            exportTitle = "Creating 12.4s clip"
            exportSubtitle = "Blended clip · camera unavailable"
            return
        case "setup":
            isCameraActive = false
            recordingState = .idle
            phoneFlow = "setup"
            flowTitle = "Guided Clip"
            flowStep = 3
            flowStepCount = 5
            return
        case "sending":
            isSending = true
            pendingCommand = .lockExposure
        case "failed":
            lastFailure = RemoteCommandFailure(
                command: .lockExposure,
                payload: [WatchMessageKey.command: WatchCaptureCommand.lockExposure.rawValue],
                message: "Didn't reach the phone")
        default:
            break
        }
        recordingStartedAt = Date().addingTimeInterval(-83)
        recordingState = .recording
    }

    /// Undoes the video defaults this hook seeds before the switch, for the
    /// screens that aren't video. A real Interval camera sends `rampFPS: 0` and
    /// an empty burst ladder (see `CaptureView.updateWatchContext`), so leaving
    /// them set would stage a header no camera can produce — a burst rate on a
    /// shoot that has no bursts.
    private func clearVideoOnlyStaging() {
        rampFPS = 0
        availableBurstFPS = []
        availableBaseFPS = []
        plannedSpeed = 0
        rampIntervalCount = 0
    }

    /// A stand-in landscape for the framing screenshots: sky, a horizon, and
    /// ground. Drawn rather than bundled so no asset has to ship in the
    /// release build for a DEBUG-only hook.
    private static func makeStagedPreviewImage(portrait: Bool = false) -> CGImage? {
        let width = portrait ? 234 : 416
        let height = portrait ? 416 : 234
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let horizon = Int(Double(height) * 0.46)
        for y in 0..<height {
            let isSky = y < horizon
            let t = isSky
                ? Double(y) / Double(max(1, horizon))
                : Double(y - horizon) / Double(max(1, height - horizon))
            let colour: CGColor = isSky
                ? CGColor(red: 0.17 + 0.10 * t, green: 0.24 + 0.11 * t, blue: 0.30 + 0.06 * t, alpha: 1)
                : CGColor(red: 0.20 - 0.13 * t, green: 0.23 - 0.14 * t, blue: 0.14 - 0.09 * t, alpha: 1)
            context.setFillColor(colour)
            context.fill(CGRect(x: 0, y: height - y - 1, width: width, height: 1))
        }
        // One dark mass off to the left so the thirds grid has something to
        // sit against.
        context.setFillColor(CGColor(red: 0.05, green: 0.06, blue: 0.05, alpha: 0.75))
        context.fill(CGRect(x: 34, y: 0, width: 60, height: height / 2 - 20))
        return context.makeImage()
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
        if let active = payload[WatchMessageKey.isMarkActive] as? Bool {
            isMarkActive = active
        }
        if let count = payload[WatchMessageKey.markIntervalCount] as? Int {
            markIntervalCount = count
        }
        if let cameraActive = payload[WatchMessageKey.cameraActive] as? Bool {
            isCameraActive = cameraActive
        }
        if let state = payload[WatchMessageKey.phoneAppState] as? String {
            phoneAppState = state
        }
        if let flow = payload[WatchMessageKey.phoneFlow] as? String {
            phoneFlow = flow
        }
        // Absent means "not applicable", not "unchanged" — every payload is a
        // full snapshot, so a finished export must be able to clear its own
        // progress ring rather than leaving it frozen at 87%.
        flowTitle = payload[WatchMessageKey.flowTitle] as? String
        flowStep = payload[WatchMessageKey.flowStep] as? Int
        flowStepCount = payload[WatchMessageKey.flowStepCount] as? Int
        exportProgress = payload[WatchMessageKey.exportProgress] as? Double
        exportETASeconds = payload[WatchMessageKey.exportETASeconds] as? Double
        exportTitle = payload[WatchMessageKey.exportTitle] as? String
        exportSubtitle = payload[WatchMessageKey.exportSubtitle] as? String
        if let timestamp = payload[WatchMessageKey.lastCaptureAt] as? TimeInterval {
            lastCaptureAt = Date(timeIntervalSince1970: timestamp)
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
        // Absent means the phone predates the MODE dial, so hold what we have
        // rather than snapping a live Scanner run back to Off.
        if let token = payload[WatchMessageKey.intervalMode] as? String {
            intervalMode = IntervalCaptureMode(token: token)
        }
        if let auto = payload[WatchMessageKey.intervalAuto] as? Bool {
            intervalAuto = auto
        }
        // These two CLEAR on absence, unlike the settings above, and the
        // asymmetry is deliberate: a state payload is a full snapshot, so a
        // missing readout means that mode is no longer running. Holding the
        // last one would leave the remote showing a ramp's final exposure over
        // a camera that stopped shooting minutes ago — the one lie a readout
        // whose whole job is "what is it doing right now" must not tell.
        // Guarded on a key every phone build sends, so a command reply (which
        // is not a snapshot) can't clear them.
        if payload[WatchMessageKey.captureMode] != nil {
            holyGrail = Self.holyGrailReadout(from: payload)
            scanner = Self.scannerReadout(from: payload)
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
        if let fps = payload[WatchMessageKey.rampFPS] as? Int {
            rampFPS = fps
        }
        // No `> 0` guard and no "keep the old value" fallback: empty is
        // meaningful here. A camera with nothing faster than its base rate
        // must be able to say so, and a format change that removes the last
        // burst rate has to clear a ladder drawn for the previous format.
        if let rates = payload[WatchMessageKey.availableBurstFPS] as? [Int] {
            availableBurstFPS = rates
        }
        if let rates = payload[WatchMessageKey.availableBaseFPS] as? [Int] {
            availableBaseFPS = rates
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
            isMarkActive = false
            markIntervalCount = 0
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

extension WatchCaptureRemote: CaptureRemoteTransportDelegate {
    func transportDidActivate(
        storedState: [String: Any]?,
        isReachable: Bool,
        errorMessage: String?
    ) {
        guard !isDebugPreview else { return }
        self.isReachable = isReachable
        statusText = errorMessage ?? "Ready"
        // Seed from the cached snapshot so a cold start mid-shoot shows the
        // shoot immediately instead of betting everything on one live
        // round-trip (which can lose to a busy phone main thread and leave
        // "open the camera" up during a recording).
        if let storedState {
            applyState(storedState)
        }
        refreshState()
    }

    func transportReachabilityDidChange(isReachable: Bool) {
        guard !isDebugPreview else { return }
        self.isReachable = isReachable
        statusText = isReachable ? "Ready" : "Phone unavailable"
        // The phone can come within reach after we've already activated
        // (screen wakes, capture screen opens, we drift back into range).
        // Activation's one-shot `refreshState` is long past by then, so
        // pull the live capture state now — otherwise a shoot that began
        // while we were out of reach reads as idle until a manual ping.
        if isReachable {
            refreshState()
        }
    }

    func transportDidReceiveState(_ payload: [String: Any], isReachable: Bool) {
        guard !isDebugPreview else { return }
        self.isReachable = isReachable
        applyState(payload)
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
#endif

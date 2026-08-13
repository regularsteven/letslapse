#if os(iOS)
import Foundation
import UIKit
import WatchConnectivity

// `WatchCaptureCommand` and `WatchRecordingState` live in
// Shared/WatchCaptureCommand.swift — both ends of the link need them.

final class WatchRemoteControlReceiver: NSObject, ObservableObject {
    static let shared = WatchRemoteControlReceiver()

    /// Serial queue for the blocking WatchConnectivity calls. `updateApplicationContext`
    /// synchronously waits on WC's XPC (its internal `applicationContext` getter uses
    /// `addOperations:waitUntilFinished:`), so calling it on the main thread hangs the
    /// UI and trips the 10s scene-update watchdog (0x8BADF00D) when the WC daemon is busy.
    private static let wcQueue = DispatchQueue(label: "com.letslapse.watch-connectivity")

    @Published private(set) var recordingState: WatchRecordingState = .idle
    @Published private(set) var isReachable = false

    private var isActivated = false
    /// False until the scene reports in — also the resting state of a
    /// background launch (Watch message wakes a not-running app), where no
    /// scene ever connects and commands must be refused, not "accepted".
    private var isAppActive = false
    /// Runs the command against the live capture screen; returns whether it
    /// actually did anything, so a guard-dropped command isn't reported as
    /// "accepted" (the Watch applies optimistic state on accepted replies —
    /// a false accept leaves it showing a recording that never started).
    private var commandHandler: ((WatchCaptureCommand, [String: Any]) -> Bool)?
    private var recordingStartedAt: Date?
    private var captureMode: CaptureMode = .video
    private var intervalSeconds: Double = 2
    private var framesPerBlend = 5
    private var blendDepthToken = "5"
    private var isBulbMode = false
    private var captureCount = 0
    private var stopAtUnit: ScheduledStopUnit?
    private var stopAtDeadline: Date?
    private var stopAtTargetCount: Int?
    private var sequenceMode: LiveCaptureSequence.Mode?
    private var markerCount = 0
    private var rampIntervalCount = 0
    private var segmentCount = 0
    private var isRampActive = false
    private var isRampHighRate = false
    private var formatLine: String?
    private var captureFPS = 0
    private var baseFPS = 0
    private var plannedSpeed = 0
    private var outputFPS = 0
    private var isExposureLocked = false
    private var lockedISO: Float = 0
    private var lockedShutter: Double = 0
    private var lockedLensPosition: Float = 0.5
    private var isoMin: Float = 25
    private var isoMax: Float = 3200

    /// The local-network camera link. Separate from WatchConnectivity because
    /// the two are not alternatives: an iPhone can serve a Watch and a Mac at
    /// once, and an iPad can only ever serve a Mac —
    /// `WCSession.isSupported()` is false there, since Apple Watch pairs with
    /// iPhone only. That is the platform test, NOT `#if os(iOS)`, which iPadOS
    /// satisfies.
    /// Created on first use rather than at init: this type is not
    /// `@MainActor`, and both the listener and `UIDevice.current` are.
    private(set) var remoteListener: CaptureRemoteListener?

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        guard !isActivated else { return }
        isActivated = true
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    @MainActor
    func setCommandHandler(_ handler: ((WatchCaptureCommand, [String: Any]) -> Bool)?) {
        let wasActive = commandHandler != nil
        commandHandler = handler
        if wasActive != (handler != nil) {
            // The listener's life is the capture screen's life. Advertising
            // from app launch instead would fire the Local Network prompt
            // before the camera exists, and would offer the Mac a camera that
            // refuses everything it's asked.
            if handler != nil {
                startLocalNetwork()
            } else {
                remoteListener?.stop()
            }
            publishState()
        }
    }

    @MainActor
    private func startLocalNetwork() {
        let listener = remoteListener ?? CaptureRemoteListener(
            deviceName: UIDevice.current.name,
            deviceModel: UIDevice.current.model)
        remoteListener = listener
        // Both closures route into the same handling the Watch uses, so a
        // command can't behave differently depending on the pipe.
        listener.respond = { [weak self] message in
            guard let self else { return [:] }
            return self.handle(message)
        }
        listener.currentState = { [weak self] in
            self?.statePayload() ?? [:]
        }
        listener.start()
    }

    /// Scene-phase mirror: `.background` is "away", everything else counts as
    /// active (Control Center over a live camera is still a usable camera).
    /// Backgrounding publishes immediately so the Watch's "Ready" screen
    /// doesn't keep pointing at a phone that's locked in a pocket.
    @MainActor
    func setAppActive(_ active: Bool) {
        guard isAppActive != active else { return }
        isAppActive = active
        LLog("watch-link appActive=\(active)")
        publishState()
    }

    /// The pending "stop at…" mirrored to the Watch; all-nil clears it.
    @MainActor
    func setScheduledStopContext(unit: ScheduledStopUnit?, deadline: Date?, targetCount: Int?) {
        let changed = self.stopAtUnit != unit
            || self.stopAtDeadline != deadline
            || self.stopAtTargetCount != targetCount
        self.stopAtUnit = unit
        self.stopAtDeadline = deadline
        self.stopAtTargetCount = targetCount
        if changed {
            publishState()
        }
    }

    /// The capture mode and its per-mode dials, mirrored so the Watch can
    /// select a mode and show the interval/depth it will start with. The
    /// numeric frames key keeps carrying the fixed counts (0 for adaptive
    /// depths, which stale Watch builds ignore); the token names the depth
    /// for builds that know Psycho/Safe.
    @MainActor
    func setModeContext(
        mode: CaptureMode,
        intervalSeconds: Double,
        blendDepth: BlendDepth,
        isBulbMode: Bool,
        captureCount: Int
    ) {
        let framesPerBlend = blendDepth.fixedFrames ?? 0
        let changed = self.captureMode != mode
            || self.intervalSeconds != intervalSeconds
            || self.framesPerBlend != framesPerBlend
            || self.blendDepthToken != blendDepth.token
            || self.isBulbMode != isBulbMode
            || self.captureCount != captureCount
        self.captureMode = mode
        self.intervalSeconds = intervalSeconds
        self.framesPerBlend = framesPerBlend
        self.blendDepthToken = blendDepth.token
        self.isBulbMode = isBulbMode
        self.captureCount = captureCount
        if changed {
            publishState()
        }
    }

    /// What the Watch shows before/while recording: the locked format, the
    /// planned speed, and the numbers its live estimate needs. `captureFPS`
    /// is the active segment's rate (flips to the burst rate mid-burst);
    /// `baseFPS` is the sequence's resting rate the base chip labels with.
    @MainActor
    func setCaptureContext(
        formatLine: String?,
        captureFPS: Int,
        baseFPS: Int,
        plannedSpeed: Int,
        outputFPS: Int
    ) {
        let changed = self.formatLine != formatLine
            || self.captureFPS != captureFPS
            || self.baseFPS != baseFPS
            || self.plannedSpeed != plannedSpeed
            || self.outputFPS != outputFPS
        self.formatLine = formatLine
        self.captureFPS = captureFPS
        self.baseFPS = baseFPS
        self.plannedSpeed = plannedSpeed
        self.outputFPS = outputFPS
        if changed {
            publishState()
        }
    }

    /// The manual-exposure state mirrored to the Watch so it can label the
    /// lock toggle and bound the Digital Crown ISO range.
    @MainActor
    func setExposureContext(
        isExposureLocked: Bool,
        lockedISO: Float,
        lockedShutter: Double,
        lockedLensPosition: Float,
        isoMin: Float,
        isoMax: Float
    ) {
        let changed = self.isExposureLocked != isExposureLocked
            || self.lockedISO != lockedISO
            || self.lockedShutter != lockedShutter
            || self.lockedLensPosition != lockedLensPosition
            || self.isoMin != isoMin
            || self.isoMax != isoMax
        self.isExposureLocked = isExposureLocked
        self.lockedISO = lockedISO
        self.lockedShutter = lockedShutter
        self.lockedLensPosition = lockedLensPosition
        self.isoMin = isoMin
        self.isoMax = isoMax
        if changed {
            publishState()
        }
    }

    @MainActor
    func setRecordingState(
        _ state: WatchRecordingState,
        startedAt: Date? = nil,
        sequenceMode: LiveCaptureSequence.Mode? = nil,
        markerCount: Int = 0,
        rampIntervalCount: Int = 0,
        segmentCount: Int = 0,
        isRampActive: Bool = false,
        isRampHighRate: Bool = false
    ) {
        recordingState = state
        recordingStartedAt = state == .recording ? startedAt : nil
        self.sequenceMode = state == .recording ? sequenceMode : nil
        self.markerCount = state == .recording ? markerCount : 0
        self.rampIntervalCount = state == .recording ? rampIntervalCount : 0
        self.segmentCount = state == .recording ? segmentCount : 0
        self.isRampActive = state == .recording ? isRampActive : false
        self.isRampHighRate = state == .recording ? isRampHighRate : false
        publishState()
    }

    @MainActor
    private func handle(_ message: [String: Any]) -> [String: Any] {
        guard let rawCommand = message[WatchMessageKey.command] as? String,
              let command = WatchCaptureCommand(rawValue: rawCommand) else {
            return response(status: "error", message: "Unknown command")
        }

        if command == .state {
            return response(status: "ok")
        }

        guard isAppActive else {
            return response(status: "unavailable", message: "LetsLapse is in the background on iPhone")
        }

        guard let commandHandler else {
            return response(status: "unavailable", message: "Capture screen is not active")
        }

        // Logged here rather than in the capture screen's handler so the
        // session log records every command the phone was asked to run,
        // including the ones its guards refuse. `state` polls are excluded
        // above — they arrive constantly and say nothing about the shoot.
        var logged: [String: Any] = ["command": command.rawValue]
        if let value = message[WatchMessageKey.value] as? Double { logged["value"] = value }
        if let token = message[WatchMessageKey.captureMode] as? String { logged["captureMode"] = token }
        if let unit = message[WatchMessageKey.stopAtUnit] as? String { logged["stopAtUnit"] = unit }

        guard commandHandler(command, message) else {
            // The handler's guards dropped it (already recording, bad value,
            // wrong mode for the command) — never report that as accepted.
            LLog("watch-link rejected command=\(command.rawValue)")
            logged["accepted"] = false
            CaptureSessionLogger.shared.log("watch_command", logged)
            return response(status: "rejected", message: "Command not available right now")
        }
        logged["accepted"] = true
        CaptureSessionLogger.shared.log("watch_command", logged)
        return response(status: "accepted")
    }

    @MainActor
    private func response(status: String, message: String? = nil) -> [String: Any] {
        var payload = statePayload()
        payload[WatchMessageKey.status] = status
        if let message {
            payload[WatchMessageKey.message] = message
        }
        return payload
    }

    @MainActor
    private func statePayload() -> [String: Any] {
        var payload: [String: Any] = [
            WatchMessageKey.recordingState: recordingState.rawValue
        ]
        if let recordingStartedAt {
            payload[WatchMessageKey.recordingStartedAt] = recordingStartedAt.timeIntervalSince1970
        }
        if let sequenceMode {
            payload[WatchMessageKey.sequenceMode] = sequenceMode.rawValue
        }
        payload[WatchMessageKey.markerCount] = markerCount
        payload[WatchMessageKey.rampIntervalCount] = rampIntervalCount
        payload[WatchMessageKey.segmentCount] = segmentCount
        payload[WatchMessageKey.isRampActive] = isRampActive
        payload[WatchMessageKey.isRampHighRate] = isRampHighRate
        // "Camera ready" requires the app on screen, not just the capture view
        // alive in a backgrounded hierarchy — backgrounding doesn't fire
        // onDisappear, so the handler alone would keep saying ready forever.
        payload[WatchMessageKey.cameraActive] = commandHandler != nil && isAppActive
        payload[WatchMessageKey.phoneAppState] = isAppActive ? "active" : "background"
        if let formatLine {
            payload[WatchMessageKey.formatLine] = formatLine
        }
        payload[WatchMessageKey.captureFPS] = captureFPS
        payload[WatchMessageKey.baseFPS] = baseFPS
        payload[WatchMessageKey.plannedSpeed] = plannedSpeed
        payload[WatchMessageKey.outputFPS] = outputFPS
        payload[WatchMessageKey.captureMode] = captureMode.rawValue
        payload[WatchMessageKey.intervalSeconds] = intervalSeconds
        payload[WatchMessageKey.framesPerBlend] = framesPerBlend
        payload[WatchMessageKey.blendDepth] = blendDepthToken
        payload[WatchMessageKey.isBulbMode] = isBulbMode
        payload[WatchMessageKey.captureCount] = captureCount
        if let stopAtUnit {
            payload[WatchMessageKey.stopAtUnit] = stopAtUnit.rawValue
        }
        if let stopAtDeadline {
            payload[WatchMessageKey.stopAtDeadline] = stopAtDeadline.timeIntervalSince1970
        }
        if let stopAtTargetCount {
            payload[WatchMessageKey.stopAtTargetCount] = stopAtTargetCount
        }
        payload[WatchMessageKey.isExposureLocked] = isExposureLocked
        payload[WatchMessageKey.lockedISO] = Double(lockedISO)
        payload[WatchMessageKey.lockedShutter] = lockedShutter
        payload[WatchMessageKey.lockedLensPosition] = Double(lockedLensPosition)
        payload[WatchMessageKey.isoMin] = Double(isoMin)
        payload[WatchMessageKey.isoMax] = Double(isoMax)
        return payload
    }

    @MainActor
    private func publishState() {
        // Built once, pushed down every live pipe. Note the ordering: the
        // local-network push happens BEFORE the WatchConnectivity guard
        // returns, because on iPad `isSupported()` is false and an early
        // return would silently take the Mac remote down with the watch link
        // that device can never have.
        let payload = statePayload()
        remoteListener?.publishState(payload)

        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        // Push to the Watch off the main thread: updateApplicationContext
        // blocks on WC's XPC and will hang the UI (watchdog kill) if run on
        // the main thread.
        Self.wcQueue.async {
            guard session.activationState == .activated else {
                // Not lost for good: activationDidComplete re-publishes the
                // (already updated) cache once the session comes up.
                LLog("watch-link publish dropped, session not activated yet")
                return
            }
            do {
                try session.updateApplicationContext(payload)
            } catch {
                LLog("watch-link updateApplicationContext failed: \(error)")
            }
            if session.isReachable {
                session.sendMessage(payload, replyHandler: nil, errorHandler: { error in
                    LLog("watch-link state push failed: \(error)")
                })
            }
        }
    }
}

extension WatchRemoteControlReceiver: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let reachable = session.isReachable
        LLog("watch-link activated state=\(activationState.rawValue) reachable=\(reachable) error=\(error.map(String.init(describing:)) ?? "none")")
        Task { @MainActor in
            self.isReachable = reachable
            // Cold launch opens the camera before async activation completes,
            // so the capture screen's first pushes were all dropped. The cache
            // behind them is current — flush it now, or a Watch already staring
            // at its "open the camera" screen never hears the camera is up
            // (its side sees no reachability change when the phone app opens).
            if activationState == .activated {
                self.publishState()
            }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        LLog("watch-link reachability -> \(reachable)")
        Task { @MainActor in
            self.isReachable = reachable
            // The Watch just came within reach — it may have missed the state
            // pushed when a shoot began out of range. Send a fresh snapshot now
            // so its live-message channel gets the current recording state
            // immediately, not only when it thinks to ask.
            if reachable {
                self.publishState()
            }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        LLog("watch-link received command=\((message[WatchMessageKey.command] as? String) ?? "?")")
        Task { @MainActor in
            replyHandler(self.handle(message))
        }
    }
}
#endif

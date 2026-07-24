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
    @Published private(set) var recordingState: WatchRecordingState = .idle
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
    @Published private(set) var captureMode: CaptureMode = .video
    @Published private(set) var intervalSeconds: Double = 2
    /// Matches the phone's default (10); the phone's state push corrects
    /// any drift on connection.
    @Published private(set) var framesPerBlend = 10
    @Published private(set) var captureCount = 0
    @Published private(set) var stopAtUnit: ScheduledStopUnit?
    @Published private(set) var stopAtDeadline: Date?
    @Published private(set) var stopAtTargetCount: Int?
    @Published private(set) var formatLine: String?
    @Published private(set) var captureFPS = 0
    @Published private(set) var plannedSpeed = 0
    @Published private(set) var outputFPS = 0
    @Published private(set) var isExposureLocked = false
    @Published private(set) var lockedISO: Double = 0
    @Published private(set) var lockedShutter: Double = 0
    @Published private(set) var lockedLensPosition: Double = 0.5
    @Published private(set) var isoMin: Double = 25
    @Published private(set) var isoMax: Double = 3200

    override init() {
        super.init()
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
        isSending = true
        statusText = "Sending"
        WCSession.default.sendMessage(
            payload,
            replyHandler: { [weak self] reply in
                Task { @MainActor in
                    self?.apply(reply: reply, startedAt: startedAt, command: command, sent: payload)
                }
            },
            errorHandler: { [weak self] error in
                Task { @MainActor in
                    self?.isSending = false
                    self?.statusText = error.localizedDescription
                }
            }
        )
    }

    private func apply(reply: [String: Any], startedAt: Date, command: String, sent: [String: Any]) {
        isSending = false
        isReachable = true

        if let rawState = reply[WatchMessageKey.recordingState] as? String,
           let state = WatchRecordingState(rawValue: rawState) {
            recordingState = state
        }
        applySequenceState(reply)
        applyRecordingStartedAt(reply)

        let status = reply[WatchMessageKey.status] as? String ?? "ok"
        switch status {
        case "accepted":
            applyAcceptedCommand(command, sent: sent, fallbackStartedAt: startedAt)
            statusText = "Command accepted"
        case "ok":
            statusText = "Ready"
        case "unavailable":
            statusText = reply[WatchMessageKey.message] as? String ?? "Capture screen inactive"
        default:
            statusText = reply[WatchMessageKey.message] as? String ?? "Command failed"
        }
    }

    private func applyState(_ payload: [String: Any]) {
        isReachable = true
        if let rawState = payload[WatchMessageKey.recordingState] as? String,
           let state = WatchRecordingState(rawValue: rawState) {
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
            playHaptic(.stop)
        case "triggerMoment":
            if recordingState == .recording {
                isRampActive.toggle()
                isRampHighRate = isRampActive && sequenceMode == "ramp"
                if isRampActive {
                    rampIntervalCount = max(1, rampIntervalCount + 1)
                    markerCount = rampIntervalCount
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
                framesPerBlend = Int(frames)
            }
            playHaptic(.click)
        case "scheduleStop":
            // Mirror the phone's math immediately; its authoritative echo
            // arrives a beat later.
            if let raw = sent[WatchMessageKey.stopAtUnit] as? String,
               let unit = ScheduledStopUnit(rawValue: raw),
               let amount = sent[WatchMessageKey.value] as? Double {
                stopAtUnit = unit
                switch unit {
                case .minutes:
                    stopAtDeadline = Date().addingTimeInterval(amount * 60)
                    stopAtTargetCount = nil
                case .frames:
                    if captureMode == .video {
                        stopAtDeadline = Date().addingTimeInterval(amount / Double(max(1, captureFPS)))
                        stopAtTargetCount = nil
                    } else {
                        stopAtDeadline = nil
                        stopAtTargetCount = captureCount + Int(amount)
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

    /// Command acknowledgment is the haptic plus the button state itself —
    /// no readouts to squint at on a tripod rig.
    private func playHaptic(_ type: WatchHapticType) {
        #if os(watchOS)
        switch type {
        case .start: WKInterfaceDevice.current().play(.start)
        case .stop: WKInterfaceDevice.current().play(.stop)
        case .click: WKInterfaceDevice.current().play(.click)
        }
        #endif
    }

    private enum WatchHapticType {
        case start
        case stop
        case click
    }

    func reconnect() {
        activate()
        if WCSession.default.activationState == .activated, WCSession.default.isReachable {
            refreshState()
        } else {
            statusText = "Connecting"
        }
    }

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
            isRampActive = isActive
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
        if let frames = payload[WatchMessageKey.framesPerBlend] as? Int, frames > 0 {
            framesPerBlend = frames
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
        Task { @MainActor in
            self.isReachable = session.isReachable
            self.statusText = error == nil ? "Ready" : (error?.localizedDescription ?? "Connection failed")
            self.refreshState()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            self.statusText = session.isReachable ? "Ready" : "Phone unavailable"
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
        Task { @MainActor in
            self.applyState(applicationContext)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            self.applyState(message)
        }
    }
}

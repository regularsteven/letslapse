import Foundation
import WatchConnectivity

enum WatchRecordingState: String {
    case idle
    case recording
}

private enum WatchMessageKey {
    static let command = "command"
    static let status = "status"
    static let recordingState = "recordingState"
    static let recordingStartedAt = "recordingStartedAt"
    static let sequenceMode = "sequenceMode"
    static let markerCount = "markerCount"
    static let rampIntervalCount = "rampIntervalCount"
    static let segmentCount = "segmentCount"
    static let isRampActive = "isRampActive"
    static let isRampHighRate = "isRampHighRate"
    static let message = "message"
}

@MainActor
final class WatchCaptureRemote: NSObject, ObservableObject {
    @Published private(set) var recordingState: WatchRecordingState = .idle
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var isReachable = false
    @Published private(set) var statusText = "Connecting"
    @Published private(set) var lastRoundTripMilliseconds: Int?
    @Published private(set) var isSending = false
    @Published private(set) var sequenceMode = "ramp"
    @Published private(set) var markerCount = 0
    @Published private(set) var rampIntervalCount = 0
    @Published private(set) var segmentCount = 0
    @Published private(set) var isRampActive = false
    @Published private(set) var isRampHighRate = false

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

    private func send(command: String) {
        guard WCSession.default.activationState == .activated else {
            statusText = "Connecting"
            return
        }

        guard WCSession.default.isReachable else {
            isReachable = false
            statusText = "Phone unavailable"
            return
        }

        let startedAt = Date()
        isSending = true
        statusText = "Sending"
        WCSession.default.sendMessage(
            [WatchMessageKey.command: command],
            replyHandler: { [weak self] reply in
                Task { @MainActor in
                    self?.apply(reply: reply, startedAt: startedAt, command: command)
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

    private func apply(reply: [String: Any], startedAt: Date, command: String) {
        isSending = false
        isReachable = true
        lastRoundTripMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)

        if let rawState = reply[WatchMessageKey.recordingState] as? String,
           let state = WatchRecordingState(rawValue: rawState) {
            recordingState = state
        }
        applySequenceState(reply)
        applyRecordingStartedAt(reply)

        let status = reply[WatchMessageKey.status] as? String ?? "ok"
        switch status {
        case "accepted":
            applyAcceptedCommand(command, fallbackStartedAt: startedAt)
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

    private func applyAcceptedCommand(_ command: String, fallbackStartedAt: Date) {
        switch command {
        case "startRecording":
            recordingState = .recording
            if recordingStartedAt == nil {
                recordingStartedAt = fallbackStartedAt
            }
            if segmentCount == 0 {
                segmentCount = 1
            }
        case "stopRecording":
            recordingState = .idle
            recordingStartedAt = nil
            markerCount = 0
            rampIntervalCount = 0
            segmentCount = 0
            isRampActive = false
            isRampHighRate = false
        case "triggerMoment":
            if recordingState == .recording {
                isRampActive.toggle()
                isRampHighRate = isRampActive && sequenceMode == "ramp"
                if isRampActive {
                    rampIntervalCount = max(1, rampIntervalCount + 1)
                    markerCount = rampIntervalCount
                }
            }
        default:
            break
        }
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

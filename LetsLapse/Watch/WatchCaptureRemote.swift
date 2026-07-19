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
    static let message = "message"
}

@MainActor
final class WatchCaptureRemote: NSObject, ObservableObject {
    @Published private(set) var recordingState: WatchRecordingState = .idle
    @Published private(set) var isReachable = false
    @Published private(set) var statusText = "Connecting"
    @Published private(set) var lastRoundTripMilliseconds: Int?
    @Published private(set) var isSending = false

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
                    self?.apply(reply: reply, startedAt: startedAt)
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

    private func apply(reply: [String: Any], startedAt: Date) {
        isSending = false
        lastRoundTripMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)

        if let rawState = reply[WatchMessageKey.recordingState] as? String,
           let state = WatchRecordingState(rawValue: rawState) {
            recordingState = state
        }

        let status = reply[WatchMessageKey.status] as? String ?? "ok"
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

    private func applyState(_ payload: [String: Any]) {
        if let rawState = payload[WatchMessageKey.recordingState] as? String,
           let state = WatchRecordingState(rawValue: rawState) {
            recordingState = state
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

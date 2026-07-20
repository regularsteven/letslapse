#if os(iOS)
import Foundation
import WatchConnectivity

enum WatchCaptureCommand: String {
    case startRecording
    case stopRecording
    case state
}

enum WatchRecordingState: String {
    case idle
    case recording
}

private enum WatchMessageKey {
    static let command = "command"
    static let status = "status"
    static let recordingState = "recordingState"
    static let recordingStartedAt = "recordingStartedAt"
    static let message = "message"
}

final class WatchRemoteControlReceiver: NSObject, ObservableObject {
    static let shared = WatchRemoteControlReceiver()

    @Published private(set) var recordingState: WatchRecordingState = .idle
    @Published private(set) var isReachable = false

    private var isActivated = false
    private var commandHandler: ((WatchCaptureCommand) -> Void)?
    private var recordingStartedAt: Date?

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
    func setCommandHandler(_ handler: ((WatchCaptureCommand) -> Void)?) {
        commandHandler = handler
    }

    @MainActor
    func setRecordingState(_ state: WatchRecordingState, startedAt: Date? = nil) {
        recordingState = state
        recordingStartedAt = state == .recording ? startedAt : nil
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

        guard let commandHandler else {
            return response(status: "unavailable", message: "Capture screen is not active")
        }

        commandHandler(command)
        return response(status: "accepted")
    }

    @MainActor
    private func response(status: String, message: String? = nil) -> [String: Any] {
        var payload: [String: Any] = [
            WatchMessageKey.status: status,
            WatchMessageKey.recordingState: recordingState.rawValue,
        ]
        if let recordingStartedAt {
            payload[WatchMessageKey.recordingStartedAt] = recordingStartedAt.timeIntervalSince1970
        }
        if let message {
            payload[WatchMessageKey.message] = message
        }
        return payload
    }

    @MainActor
    private func publishState() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        var payload: [String: Any] = [
            WatchMessageKey.recordingState: recordingState.rawValue
        ]
        if let recordingStartedAt {
            payload[WatchMessageKey.recordingStartedAt] = recordingStartedAt.timeIntervalSince1970
        }
        try? session.updateApplicationContext(payload)
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
    }
}

extension WatchRemoteControlReceiver: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
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
        Task { @MainActor in
            replyHandler(self.handle(message))
        }
    }
}
#endif

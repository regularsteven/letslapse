#if os(iOS)
import Foundation
import WatchConnectivity

enum WatchCaptureCommand: String {
    case startRecording
    case stopRecording
    case triggerMoment
    case lockExposure
    case unlockExposure
    case setISO
    case setLensPosition
    case state
}

enum WatchRecordingState: String {
    case idle
    case recording
}

final class WatchRemoteControlReceiver: NSObject, ObservableObject {
    static let shared = WatchRemoteControlReceiver()

    @Published private(set) var recordingState: WatchRecordingState = .idle
    @Published private(set) var isReachable = false

    private var isActivated = false
    private var commandHandler: ((WatchCaptureCommand, Double?) -> Void)?
    private var recordingStartedAt: Date?
    private var sequenceMode: LiveCaptureSequence.Mode?
    private var markerCount = 0
    private var rampIntervalCount = 0
    private var segmentCount = 0
    private var isRampActive = false
    private var isRampHighRate = false
    private var formatLine: String?
    private var captureFPS = 0
    private var plannedSpeed = 0
    private var outputFPS = 0
    private var isExposureLocked = false
    private var lockedISO: Float = 0
    private var lockedShutter: Double = 0
    private var lockedLensPosition: Float = 0.5
    private var isoMin: Float = 25
    private var isoMax: Float = 3200

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
    func setCommandHandler(_ handler: ((WatchCaptureCommand, Double?) -> Void)?) {
        let wasActive = commandHandler != nil
        commandHandler = handler
        if wasActive != (handler != nil) {
            publishState()
        }
    }

    /// What the Watch shows before/while recording: the locked format, the
    /// planned speed, and the numbers its live estimate needs.
    @MainActor
    func setCaptureContext(
        formatLine: String?,
        captureFPS: Int,
        plannedSpeed: Int,
        outputFPS: Int
    ) {
        let changed = self.formatLine != formatLine
            || self.captureFPS != captureFPS
            || self.plannedSpeed != plannedSpeed
            || self.outputFPS != outputFPS
        self.formatLine = formatLine
        self.captureFPS = captureFPS
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

        guard let commandHandler else {
            return response(status: "unavailable", message: "Capture screen is not active")
        }

        commandHandler(command, message[WatchMessageKey.value] as? Double)
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
        payload[WatchMessageKey.cameraActive] = commandHandler != nil
        if let formatLine {
            payload[WatchMessageKey.formatLine] = formatLine
        }
        payload[WatchMessageKey.captureFPS] = captureFPS
        payload[WatchMessageKey.plannedSpeed] = plannedSpeed
        payload[WatchMessageKey.outputFPS] = outputFPS
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
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        let payload = statePayload()
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

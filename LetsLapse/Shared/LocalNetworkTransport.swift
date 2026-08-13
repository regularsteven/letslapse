#if os(macOS)
import Foundation
import Network

/// A discovered camera, as shown in the Mac remote's picker.
struct DiscoveredCamera: Identifiable, Equatable {
    var id: String { name + model }
    var name: String
    var model: String
    var isRecording: Bool
    var pairingID: String
    var endpoint: NWEndpoint

    static func == (lhs: DiscoveredCamera, rhs: DiscoveredCamera) -> Bool {
        lhs.id == rhs.id && lhs.isRecording == rhs.isRecording && lhs.pairingID == rhs.pairingID
    }
}

/// The Mac end of the local-network link: browses for cameras, connects to one
/// with a pairing code, and speaks `CaptureRemoteFrame` over TLS-PSK.
///
/// Reply correlation lives here rather than in the protocol, because this is
/// the transport that needs it: one socket carries both replies and
/// unsolicited pushes, and a push landing mid-flight must never be mistaken
/// for an accept.
@MainActor
final class LocalNetworkTransport: NSObject, ObservableObject, CaptureRemoteTransport {
    @Published private(set) var cameras: [DiscoveredCamera] = []
    /// Set when browsing is impossible rather than merely empty — on macOS 15+
    /// a denied Local Network prompt otherwise looks exactly like "no cameras
    /// found", which is the single most confusing failure this link has.
    @Published private(set) var browseFailure: String?
    /// The last thing the connection actually did. Surfaced in the UI because
    /// every interesting failure here is silent: a wrong code never fails the
    /// client, and a denied Local Network permission looks like an absent
    /// camera. Without this the only symptom is a window that does nothing.
    @Published private(set) var connectionDiagnostic: String?

    weak var delegate: CaptureRemoteTransportDelegate?

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var connectTimeout: Task<Void, Never>?

    /// Pending replies by frame id. A command whose reply never arrives is
    /// failed by the remote's own send watchdog, so this only has to not leak.
    private var pending: [UInt32: (CaptureRemoteSendFailure?, [String: Any]?) -> Void] = [:]
    private var nextID: UInt32 = 1

    private(set) var isActivated = false
    private(set) var isReachable = false

    /// Nothing here is permanently impossible — a Mac can always in principle
    /// reach a camera — so a failed browse is reported through `browseFailure`
    /// and the connection state, not as a dead transport.
    var unavailabilityReason: String? { nil }

    /// A socket keeps no history: unlike WatchConnectivity's application
    /// context, there is nothing cached to seed a cold start from.
    var storedState: [String: Any]? { nil }

    // MARK: - Discovery

    func startBrowsing() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: CaptureRemoteService.type, domain: nil),
            using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.browseFailure = nil
                case .failed(let error):
                    self?.browseFailure = error.localizedDescription
                case .waiting(let error):
                    // Most often the Local Network permission, which on macOS
                    // is granted per-app in System Settings ▸ Privacy.
                    self?.browseFailure = error.localizedDescription
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.apply(results) }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        cameras = []
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        cameras = results.compactMap { result in
            guard case .bonjour(let txt) = result.metadata else { return nil }
            return DiscoveredCamera(
                name: txt[CaptureRemoteService.TXTKey.deviceName] ?? "Camera",
                model: txt[CaptureRemoteService.TXTKey.model] ?? "",
                isRecording: txt[CaptureRemoteService.TXTKey.recordingState]
                    == WatchRecordingState.recording.rawValue,
                pairingID: txt[CaptureRemoteService.TXTKey.pairingID] ?? "",
                endpoint: result.endpoint)
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: - Connection

    func connect(to camera: DiscoveredCamera, code: String) {
        disconnect()
        let connection = NWConnection(
            to: camera.endpoint,
            using: CaptureRemotePairing.parameters(code: code))
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handle(state, name: camera.name) }
        }
        self.connection = connection
        connection.start(queue: .main)

        // A WRONG PAIRING CODE NEVER FAILS THE CLIENT. The mismatch surfaces
        // as -9846 bad MAC on the camera's first read; this side simply sits
        // in .preparing forever. Verified on device. Without this timeout a
        // mistyped code is indistinguishable from an unresponsive camera.
        connectTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled, !self.isActivated else { return }
            self.disconnect()
            self.delegate?.transportDidActivate(
                storedState: nil,
                isReachable: false,
                errorMessage: "Couldn't pair — check the code on the camera")
        }
    }

    func disconnect() {
        connectTimeout?.cancel()
        connectTimeout = nil
        connection?.cancel()
        connection = nil
        isActivated = false
        isReachable = false
        failAllPending(.notActivated)
    }

    /// `CaptureRemoteTransport` conformance. Connecting needs a camera and a
    /// code, which only the picker has, so activation is `connect(to:code:)`.
    func activate() {
        startBrowsing()
    }

    private func handle(_ state: NWConnection.State, name: String) {
        switch state {
        case .setup: connectionDiagnostic = "setup"
        case .preparing: connectionDiagnostic = "preparing"
        case .waiting(let error): connectionDiagnostic = "waiting: \(error)"
        case .failed(let error): connectionDiagnostic = "failed: \(error)"
        case .cancelled: connectionDiagnostic = "cancelled"
        case .ready: connectionDiagnostic = "ready"
        @unknown default: connectionDiagnostic = "unknown"
        }
        switch state {
        case .ready:
            connectTimeout?.cancel()
            connectTimeout = nil
            isActivated = true
            isReachable = true
            delegate?.transportDidActivate(
                storedState: nil, isReachable: true, errorMessage: nil)
            receiveFrame()
        case .failed(let error):
            isActivated = false
            isReachable = false
            failAllPending(.failed(error.localizedDescription))
            delegate?.transportReachabilityDidChange(isReachable: false)
        case .cancelled:
            isActivated = false
            isReachable = false
            delegate?.transportReachabilityDidChange(isReachable: false)
        default:
            break
        }
    }

    // MARK: - Framing

    func send(
        _ payload: [String: Any],
        reply: @escaping ([String: Any]) -> Void,
        failure: @escaping (CaptureRemoteSendFailure) -> Void
    ) {
        guard let connection, isActivated else {
            failure(.notActivated)
            return
        }
        let id = nextID
        nextID &+= 1
        let frame = CaptureRemoteFrame(id: id, kind: .command, body: payload)
        guard let data = try? CaptureRemoteCoder.encode(frame) else {
            failure(.failed("Could not encode command"))
            return
        }
        pending[id] = { sendFailure, response in
            if let sendFailure {
                failure(sendFailure)
            } else if let response {
                reply(response)
            }
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.pending.removeValue(forKey: id)?(.failed(error.localizedDescription), nil)
            }
        })
    }

    private func receiveFrame() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, isComplete, error in
            guard let header, header.count == 4, error == nil,
                  let length = try? CaptureRemoteCoder.decodeLength(header) else {
                if isComplete || error != nil {
                    Task { @MainActor in self?.dropConnection() }
                }
                return
            }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, isComplete, error in
                guard let body, body.count == length, error == nil else {
                    if isComplete || error != nil {
                        Task { @MainActor in self?.dropConnection() }
                    }
                    return
                }
                Task { @MainActor in
                    self?.route(body)
                    self?.receiveFrame()
                }
            }
        }
    }

    private func route(_ payload: Data) {
        guard let frame = try? CaptureRemoteCoder.decode(payload) else { return }
        switch frame.kind {
        case .reply:
            // Only a matching id resolves a send. An unmatched reply is
            // dropped rather than being applied to whatever is in flight.
            pending.removeValue(forKey: frame.id)?(nil, frame.body)
        case .push:
            delegate?.transportDidReceiveState(frame.body, isReachable: true)
        case .command:
            // A remote never receives commands.
            break
        }
    }

    private func dropConnection() {
        guard connection != nil else { return }
        connection = nil
        isActivated = false
        isReachable = false
        failAllPending(.unreachable)
        delegate?.transportReachabilityDidChange(isReachable: false)
    }

    private func failAllPending(_ failure: CaptureRemoteSendFailure) {
        let handlers = pending.values
        pending.removeAll()
        for handler in handlers { handler(failure, nil) }
    }
}
#endif

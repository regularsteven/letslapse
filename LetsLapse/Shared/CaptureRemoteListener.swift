// A Watch is a remote, never a camera, so it has no use for the listener — and
// excluding it here also keeps `LLog` (defined in the app target) out of the
// watch build.
#if !os(watchOS)
import Foundation
import Network

/// The camera end of the local-network link: advertises over Bonjour, accepts
/// one paired remote at a time, answers commands and pushes state.
///
/// **Foreground only, by platform rule.** iOS suspends network activity in the
/// background, so this lives exactly as long as the capture screen does. That
/// is the same constraint the app already had — the Watch link is refused when
/// the capture screen isn't up — but here it must be *said* in the UI rather
/// than left to look like a dead link.
@MainActor
final class CaptureRemoteListener: ObservableObject {
    enum State: Equatable {
        case idle
        case advertising
        case connected(peerName: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// The code the human types on the Mac. Regenerated whenever advertising
    /// restarts, so a code read off the screen an hour ago is not still valid.
    @Published private(set) var pairingCode: String?

    /// Answers a command message with a reply payload. This is deliberately the
    /// *same* function the Watch link calls, not a parallel implementation:
    /// the guards, the status vocabulary and the session logging all live in
    /// one place, so a command cannot behave differently depending on which
    /// pipe carried it.
    var respond: (([String: Any]) -> [String: Any])?
    /// Current state snapshot, for the TXT record only.
    var currentState: (() -> [String: Any])?

    private var listener: NWListener?
    private var connection: NWConnection?
    private var deviceName: String
    private var deviceModel: String

    init(deviceName: String, deviceModel: String) {
        self.deviceName = deviceName
        self.deviceModel = deviceModel
    }

    // MARK: - Lifecycle

    func start() {
        guard listener == nil else { return }
        let code = CaptureRemotePairing.generateCode()
        pairingCode = code

        do {
            let parameters = CaptureRemotePairing.parameters(code: code)
            // Let the peer reconnect quickly after a Wi-Fi blip rather than
            // waiting out TIME_WAIT on a fixed port.
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(
                type: CaptureRemoteService.type,
                txtRecord: txtRecord(code: code))
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.handleListenerState(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch {
            state = .failed(error.localizedDescription)
            LLog("remote-listener start failed: \(error)")
        }
    }

    func stop() {
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        pairingCode = nil
        state = .idle
    }

    private func txtRecord(code: String) -> NWTXTRecord {
        var txt = NWTXTRecord()
        txt[CaptureRemoteService.TXTKey.deviceName] = deviceName
        txt[CaptureRemoteService.TXTKey.model] = deviceModel
        txt[CaptureRemoteService.TXTKey.pairingID] = CaptureRemotePairing.pairingID(code: code)
        txt[CaptureRemoteService.TXTKey.recordingState] =
            (currentState?()[WatchMessageKey.recordingState] as? String) ?? WatchRecordingState.idle.rawValue
        return txt
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            self.state = .advertising
            // The code is logged until the camera has UI to show it. It is a
            // one-shot secret for one link on one LAN, regenerated every time
            // advertising restarts — but this line should go when the pairing
            // screen lands, rather than sit in the console forever.
            LLog("remote-listener advertising on \(listener?.port.map(String.init(describing:)) ?? "?") code=\(pairingCode ?? "?")")
        case .failed(let error):
            // The most likely cause in practice is Local Network permission
            // being denied, which otherwise looks identical to "no cameras
            // found" from the Mac side.
            self.state = .failed(error.localizedDescription)
            LLog("remote-listener failed: \(error)")
        case .cancelled:
            self.state = .idle
        default:
            break
        }
    }

    // MARK: - Connection

    private func accept(_ incoming: NWConnection) {
        // One remote at a time, and the NEWEST wins. Refusing the newcomer
        // instead looks tidier and is much worse in practice: a Mac that drops
        // off Wi-Fi without a clean close leaves a half-open connection here,
        // and until keepalive notices, every legitimate reconnection would be
        // turned away — on a window-mounted iPad that means walking over to
        // restart the capture screen. Entry is gated by the pairing code
        // shown on this device, so whoever connects is already trusted.
        if let existing = connection {
            LLog("remote-listener replacing existing peer")
            connection = nil
            existing.cancel()
        }
        connection = incoming
        incoming.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handleConnectionState(state, connection: incoming) }
        }
        incoming.start(queue: .main)
        receiveFrame(on: incoming)
    }

    private func handleConnectionState(_ state: NWConnection.State, connection incoming: NWConnection) {
        switch state {
        case .ready:
            self.state = .connected(peerName: "Remote")
            LLog("remote-listener peer connected")
        case .failed(let error):
            // A wrong pairing code lands here as -9846 bad MAC, not as a clean
            // handshake rejection.
            LLog("remote-listener peer failed: \(error)")
            dropPeer(incoming)
        case .cancelled:
            dropPeer(incoming)
        default:
            break
        }
    }

    private func dropPeer(_ incoming: NWConnection) {
        guard connection === incoming else { return }
        connection = nil
        if listener != nil {
            state = .advertising
        }
    }

    private func receiveFrame(on incoming: NWConnection) {
        incoming.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, isComplete, error in
            guard let header, header.count == 4, error == nil else {
                if isComplete || error != nil {
                    Task { @MainActor in self?.dropPeer(incoming) }
                }
                return
            }
            let length: Int
            do {
                length = try CaptureRemoteCoder.decodeLength(header)
            } catch {
                LLog("remote-listener bad frame length: \(error)")
                incoming.cancel()
                return
            }
            incoming.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, isComplete, error in
                guard let body, body.count == length, error == nil else {
                    if isComplete || error != nil {
                        Task { @MainActor in self?.dropPeer(incoming) }
                    }
                    return
                }
                Task { @MainActor in
                    self?.handle(body, on: incoming)
                    self?.receiveFrame(on: incoming)
                }
            }
        }
    }

    private func handle(_ payload: Data, on incoming: NWConnection) {
        guard let frame = try? CaptureRemoteCoder.decode(payload) else {
            LLog("remote-listener undecodable frame")
            return
        }
        guard frame.kind == .command else {
            // A camera has no use for replies or pushes; only the remote does.
            return
        }
        let response = respond?(frame.body)
            ?? [WatchMessageKey.status: "unavailable",
                WatchMessageKey.message: "Capture screen is not active"]
        send(CaptureRemoteFrame(id: frame.id, kind: .reply, body: response), on: incoming)
    }

    /// Push a state snapshot to the connected remote, if any.
    func publishState(_ payload: [String: Any]) {
        guard let connection else { return }
        send(.push(payload), on: connection)
    }

    private func send(_ frame: CaptureRemoteFrame, on incoming: NWConnection) {
        guard let data = try? CaptureRemoteCoder.encode(frame) else {
            LLog("remote-listener could not encode frame")
            return
        }
        incoming.send(content: data, completion: .contentProcessed { error in
            if let error {
                LLog("remote-listener send failed: \(error)")
            }
        })
    }
}
#endif

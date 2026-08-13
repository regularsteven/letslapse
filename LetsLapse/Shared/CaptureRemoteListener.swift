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

    /// Runs a command against the live capture screen and reports whether it
    /// actually did anything — same contract as the Watch receiver's handler,
    /// so a guard-dropped command is never reported as accepted.
    var commandHandler: ((WatchCaptureCommand, [String: Any]) -> Bool)?
    /// Supplies the current state snapshot for replies and pushes.
    var stateProvider: (() -> [String: Any])?

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
            (stateProvider?()[WatchMessageKey.recordingState] as? String) ?? WatchRecordingState.idle.rawValue
        return txt
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            self.state = .advertising
            LLog("remote-listener advertising on \(listener?.port.map(String.init(describing:)) ?? "?")")
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
        // One remote at a time: two Macs racing start/stop on one camera is
        // not a feature, and the second one silently losing commands would be
        // worse than being told it can't connect.
        guard connection == nil else {
            LLog("remote-listener refusing second peer")
            incoming.cancel()
            return
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
        let response = respond(to: frame.body)
        send(CaptureRemoteFrame(id: frame.id, kind: .reply, body: response), on: incoming)
    }

    /// Deliberately mirrors `WatchRemoteControlReceiver.handle` — same guards,
    /// same status vocabulary — so a command behaves identically whichever pipe
    /// carried it.
    private func respond(to message: [String: Any]) -> [String: Any] {
        var payload = stateProvider?() ?? [:]
        guard let raw = message[WatchMessageKey.command] as? String,
              let command = WatchCaptureCommand(rawValue: raw) else {
            payload[WatchMessageKey.status] = "error"
            payload[WatchMessageKey.message] = "Unknown command"
            return payload
        }
        if command == .state {
            payload[WatchMessageKey.status] = "ok"
            return payload
        }
        guard let commandHandler else {
            payload[WatchMessageKey.status] = "unavailable"
            payload[WatchMessageKey.message] = "Capture screen is not active"
            return payload
        }
        guard commandHandler(command, message) else {
            LLog("remote-listener rejected command=\(command.rawValue)")
            payload[WatchMessageKey.status] = "rejected"
            payload[WatchMessageKey.message] = "Command not available right now"
            return payload
        }
        // Re-read: the handler just changed the thing the reply describes.
        payload = stateProvider?() ?? payload
        payload[WatchMessageKey.status] = "accepted"
        return payload
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

// Throwaway CLI client for the local-network remote link — the brief's
// stage-3 prover: browse, connect, send `state`, print the dictionary. Exists
// so the camera side can be proved before any Mac UI does.
//
//   swiftc -O -o remote_probe remote_probe.swift \
//     ../Shared/CaptureRemoteFrame.swift ../Shared/CaptureRemotePairing.swift
//   ./remote_probe                 # browse only, list cameras
//   ./remote_probe <code>          # connect with a pairing code, poll state
//   ./remote_probe <code> <cmd>    # also send one command, e.g. startRecording
//
// Compiles the REAL Shared/ sources, so a wire-format change that breaks the
// app breaks this too.
import Foundation
import Network

let arguments = Array(CommandLine.arguments.dropFirst())
let pairingCode = arguments.first
let command = arguments.count > 1 ? arguments[1] : nil

func describe(_ dictionary: [String: Any]) -> String {
    dictionary.keys.sorted()
        .map { "  \($0) = \(dictionary[$0] ?? "nil")" }
        .joined(separator: "\n")
}

final class Probe {
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var nextID: UInt32 = 1

    func browse() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: CaptureRemoteService.type, domain: nil),
            using: parameters)
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("browsing for \(CaptureRemoteService.type)…")
            case .failed(let error):
                print("BROWSE FAILED: \(error)")
                print("On macOS 15+ a denied Local Network prompt looks exactly like this.")
                exit(1)
            case .waiting(let error):
                print("browse waiting: \(error)")
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard !results.isEmpty else {
                print("no cameras found yet…")
                return
            }
            for result in results {
                var label = "\(result.endpoint)"
                if case .bonjour(let txt) = result.metadata {
                    let name = txt[CaptureRemoteService.TXTKey.deviceName] ?? "?"
                    let model = txt[CaptureRemoteService.TXTKey.model] ?? "?"
                    let rec = txt[CaptureRemoteService.TXTKey.recordingState] ?? "?"
                    let pid = txt[CaptureRemoteService.TXTKey.pairingID] ?? "?"
                    label = "\(name) · \(model) · rec=\(rec) · pairing=\(pid)"
                }
                print("FOUND: \(label)")
            }
            if let code = pairingCode, let first = results.first {
                self?.browser?.cancel()
                self?.connect(to: first.endpoint, code: code)
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    private func connect(to endpoint: NWEndpoint, code: String) {
        print("connecting with code \(code)…")
        let connection = NWConnection(to: endpoint, using: CaptureRemotePairing.parameters(code: code))
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("connected — TLS-PSK handshake accepted")
                self?.receive()
                self?.send(command: "state")
                if let command {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self?.send(command: command)
                    }
                }
            case .failed(let error):
                print("CONNECT FAILED: \(error)")
                print("-9846 (bad MAC) means the pairing code is wrong.")
                exit(1)
            default:
                break
            }
        }
        self.connection = connection
        connection.start(queue: .main)
    }

    private func send(command: String) {
        guard let connection else { return }
        let frame = CaptureRemoteFrame(
            id: nextID,
            kind: .command,
            body: [WatchMessageKey.command: command])
        nextID += 1
        guard let data = try? CaptureRemoteCoder.encode(frame) else { return }
        print("→ \(command) (id \(frame.id))")
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receive() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, _, error in
            guard let header, header.count == 4, error == nil,
                  let length = try? CaptureRemoteCoder.decodeLength(header) else {
                print("link closed (\(String(describing: error)))")
                exit(0)
            }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, _ in
                if let body, let frame = try? CaptureRemoteCoder.decode(body) {
                    print("← \(frame.kind.rawValue) (id \(frame.id))")
                    print(describe(frame.body))
                }
                self?.receive()
            }
        }
    }
}

// @main rather than top-level code: this is compiled together with the real
// Shared/ sources, and swiftc only allows top-level expressions in main.swift.
@main
enum RemoteProbe {
    static func main() {
        // Unbuffered: this tool is always run under a timeout or piped into
        // head, and block-buffered stdout means a killed process prints
        // NOTHING — which reads as "the link is dead" rather than "you never
        // saw the output".
        setbuf(stdout, nil)
        let probe = Probe()
        probe.browse()
        RunLoop.main.run()
    }
}

// CLI client for the local-network remote link — the brief's stage-3 prover:
// browse, connect, drive a scripted sequence of commands, print the state that
// comes back. Exists so the camera side can be proved before (and without) any
// Mac UI.
//
//   swiftc -O -o remote_probe remote_probe.swift \
//     ../Shared/CaptureRemoteFrame.swift ../Shared/CaptureRemotePairing.swift
//   ./remote_probe                    # browse only, list cameras
//   ./remote_probe <code>             # connect with a pairing code, poll state
//   ./remote_probe <code> "<script>"  # run a sequence (see below)
//
// The script is comma-separated steps, run in order:
//
//   startRecording              a bare command
//   setIntervalMode:scanner     a command with its String extra (the key is
//                               inferred from the command — see `extraKey`)
//   setAutoInterval#1           a command with a numeric `value`
//   wait@3                      sleep 3 seconds
//   poll@2x8                    send `state` 8 times, 2 seconds apart
//
// e.g. the Scanner end-to-end run:
//   ./remote_probe 123456 "setIntervalMode:scanner,wait@1,startRecording,poll@2x15,deleteLastFrame,wait@1,state,stopRecording"
//
// `poll` and `state` print a one-line digest of the MODE keys rather than the
// whole dictionary, because the whole dictionary is 40 lines and the four
// numbers that matter get lost in it. `--verbose` prints everything.
//
// Compiles the REAL Shared/ sources, so a wire-format change that breaks the
// app breaks this too.
import Foundation
import Network

// Declarations only, no statements: this file is compiled with `@main`, and
// swiftc allows top-level *expressions* only in a file called main.swift.
let rawArguments = Array(CommandLine.arguments.dropFirst())
let verbose = rawArguments.contains("--verbose")
let arguments = rawArguments.filter { $0 != "--verbose" }
let pairingCode = arguments.first
let script = arguments.count > 1 ? arguments[1] : nil

/// Which payload key a command's String argument belongs under. The wire
/// contract names them per command rather than reusing one generic slot, so
/// the probe has to know the mapping too.
func extraKey(for command: String) -> String? {
    switch command {
    case "setIntervalMode": return WatchMessageKey.intervalMode
    case "setCaptureMode": return WatchMessageKey.captureMode
    case "setSequenceMode": return WatchMessageKey.sequenceMode
    case "scheduleStop": return WatchMessageKey.stopAtUnit
    case "setBlendStrategy": return WatchMessageKey.blendStrategy
    case "setFramesPerBlend": return WatchMessageKey.blendDepth
    default: return nil
    }
}

/// The keys worth watching while a MODE run is going. Everything else in a
/// state payload is stable for the length of a test.
func digest(_ body: [String: Any]) -> String {
    func string(_ key: String) -> String? { body[key].map { "\($0)" } }
    var parts: [String] = []
    parts.append("rec=" + (string(WatchMessageKey.recordingState) ?? "?"))
    if let mode = string(WatchMessageKey.intervalMode) { parts.append("mode=" + mode) }
    if let auto = string(WatchMessageKey.intervalAuto) { parts.append("auto=" + auto) }
    if let every = string(WatchMessageKey.intervalSeconds) { parts.append("every=" + every) }
    if let count = string(WatchMessageKey.captureCount) { parts.append("count=" + count) }
    // Holy Grail
    if let shutter = body[WatchMessageKey.holyGrailShutter] as? Double {
        let iso = body[WatchMessageKey.holyGrailISO] as? Double ?? 0
        let ev = body[WatchMessageKey.holyGrailSceneEV] as? Double ?? 0
        parts.append(String(format: "HG[%.4fs ISO %.0f EV %.2f%@%@]", shutter, iso, ev,
                            (body[WatchMessageKey.holyGrailISORamping] as? Bool ?? false) ? " isoRamp" : "",
                            (body[WatchMessageKey.holyGrailClipped] as? Bool ?? false) ? " CLIPPED" : ""))
    }
    // Scanner
    if let phase = string(WatchMessageKey.scannerPhase) {
        let frames = body[WatchMessageKey.scannerFrames] as? Int ?? 0
        let shutter = body[WatchMessageKey.scannerShutter] as? Double ?? 0
        let iso = body[WatchMessageKey.scannerISO] as? Double ?? 0
        parts.append(String(format: "SCAN[%@ frames=%d %.4fs ISO %.0f%@%@]", phase, frames, shutter, iso,
                            (body[WatchMessageKey.scannerRAW] as? Bool ?? false) ? " RAW" : "",
                            (body[WatchMessageKey.scannerWaitingForSteady] as? Bool ?? false) ? " UNSTEADY" : ""))
    }
    if let status = string(WatchMessageKey.status) { parts.append("status=" + status) }
    return parts.joined(separator: " ")
}

func describe(_ dictionary: [String: Any]) -> String {
    dictionary.keys.sorted()
        .map { "  \($0) = \(dictionary[$0] ?? "nil")" }
        .joined(separator: "\n")
}

final class Probe {
    /// Wall-clock zero for the reply timestamps, so a ramp's movement can be
    /// read against the interval it is supposed to be moving on.
    static let started = Date()
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
            // Select by pairing id, never by arrival order: with several
            // cameras advertising (the whole point of a multi-device field
            // rig), "first found" hands the code to the wrong camera and the
            // PSK handshake just hangs. The TXT pairing id is derived from
            // the code precisely so the right endpoint is identifiable
            // before connecting.
            if let code = pairingCode {
                let wanted = CaptureRemotePairing.pairingID(code: code)
                for result in results {
                    if case .bonjour(let txt) = result.metadata,
                       txt[CaptureRemoteService.TXTKey.pairingID] == wanted {
                        self?.browser?.cancel()
                        self?.connect(to: result.endpoint, code: code)
                        return
                    }
                }
                print("no camera with pairing \(wanted) yet — still browsing…")
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
                if let script {
                    // Off the main queue: the steps sleep, and the main queue
                    // is what the connection's own callbacks run on — blocking
                    // it would stall every reply the script is waiting to see.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                        self?.run(script: script)
                    }
                }
            case .failed(let error):
                print("CONNECT FAILED: \(error)")
                print("-9846 (bad MAC) means the pairing code is wrong.")
                exit(1)
            case .waiting(let error):
                // Worth printing, not swallowing: a sandboxed/denied Local
                // Network permission and an unreachable port both live here,
                // and silence made them indistinguishable from a slow link.
                print("connection waiting: \(error)")
            case .preparing:
                print("connection preparing…")
            case .cancelled:
                print("connection cancelled")
                exit(1)
            default:
                break
            }
        }
        self.connection = connection
        connection.start(queue: .main)
    }

    private func send(command: String, extra: String? = nil, value: Double? = nil) {
        guard let connection else { return }
        var body: [String: Any] = [WatchMessageKey.command: command]
        if let extra, let key = extraKey(for: command) {
            body[key] = extra
        }
        if let value {
            body[WatchMessageKey.value] = value
        }
        let frame = CaptureRemoteFrame(id: nextID, kind: .command, body: body)
        nextID += 1
        guard let data = try? CaptureRemoteCoder.encode(frame) else { return }
        var label = command
        if let extra { label += ":\(extra)" }
        if let value { label += "#\(value)" }
        print("→ \(label) (id \(frame.id))")
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Walks the script. Runs on a background queue — see the call site.
    private func run(script: String) {
        for rawStep in script.split(separator: ",") {
            let step = rawStep.trimmingCharacters(in: .whitespaces)
            guard !step.isEmpty else { continue }

            if step.hasPrefix("wait@") {
                let seconds = Double(step.dropFirst(5)) ?? 1
                print("… wait \(seconds)s")
                Thread.sleep(forTimeInterval: seconds)
                continue
            }
            if step.hasPrefix("poll@") {
                // "poll@2x8" — every 2 s, 8 times.
                let spec = step.dropFirst(5).split(separator: "x")
                let every = Double(spec.first ?? "1") ?? 1
                let times = Int(spec.count > 1 ? spec[1] : "5") ?? 5
                for index in 0..<times {
                    send(command: "state")
                    if index < times - 1 { Thread.sleep(forTimeInterval: every) }
                }
                continue
            }
            if let hash = step.firstIndex(of: "#") {
                send(command: String(step[step.startIndex..<hash]),
                     value: Double(step[step.index(after: hash)...]) ?? 0)
            } else if let colon = step.firstIndex(of: ":") {
                send(command: String(step[step.startIndex..<colon]),
                     extra: String(step[step.index(after: colon)...]))
            } else {
                send(command: step)
            }
            Thread.sleep(forTimeInterval: 0.6)
        }
        print("script complete — still listening; ^C to stop")
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
                    if verbose {
                        print("← \(frame.kind.rawValue) (id \(frame.id))")
                        print(describe(frame.body))
                    } else {
                        // One line per reply. A full payload is 40 lines and
                        // the four numbers a MODE run turns on get lost in it.
                        let stamp = String(format: "%.1f", Date().timeIntervalSince(Probe.started))
                        print("← [\(stamp)s] \(frame.kind.rawValue) \(digest(frame.body))")
                    }
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

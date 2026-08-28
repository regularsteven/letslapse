// A headless client for `_letslapse-xfer._tcp` — the project-transfer link's
// prover, in the same spirit as `remote_probe.swift`.
//
// Pairing is deliberately a human act (a code read off the serving device's
// Projects tab, typed on the Mac), which is right for the product and wrong for
// verifying the link: it makes the one thing worth checking — does a real
// project actually arrive intact? — unreachable without a person at both ends.
// This types the code, it does not bypass it.
//
// Build (it needs the protocol and the pairing derivation, nothing else):
//
//   swiftc -O -o /tmp/transfer_probe \
//       LetsLapse/tools/transfer_probe.swift \
//       LetsLapse/Shared/ProjectTransferProtocol.swift \
//       LetsLapse/Shared/CaptureRemotePairing.swift
//
// Run:
//
//   /tmp/transfer_probe <code> [--device NAME] [--list] [--pull N] [--out DIR]
//
// `--list` stops after printing the catalogue. `--pull N` fetches the Nth
// project (0-based) into `--out` and verifies every file's length against the
// manifest the server sent.

import Foundation
import Network

// `@main` rather than top-level code: this is compiled together with the real
// Shared/ sources, and swiftc allows top-level expressions only in main.swift.
@main
enum TransferProbe {
    static func main() throws {
        setvbuf(stdout, nil, _IONBF, 0)

        // MARK: - Arguments

        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let code = arguments.first, code.count == 6 else {
            FileHandle.standardError.write(Data("usage: transfer_probe <6-digit code> [--list] [--pull N] [--out DIR]\n".utf8))
            exit(2)
        }
        arguments.removeFirst()

        func option(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let listOnly = arguments.contains("--list")
        // More than one device advertises the moment a simulator is left
        // running beside a phone, and "the first result" is arbitrary — which
        // presents as "never became ready", i.e. as a wrong code.
        let wantedDevice = option("--device")?.lowercased()
        let pullIndex = option("--pull").flatMap(Int.init)
        let outputRoot = URL(fileURLWithPath: option("--out") ?? NSTemporaryDirectory())
            .appendingPathComponent("transfer_probe", isDirectory: true)

        func log(_ message: String) {
            print(message)
            fflush(stdout)
        }

        func die(_ message: String) -> Never {
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(1)
        }

        // MARK: - Discovery

        let discovered = DispatchSemaphore(value: 0)
        var endpoint: NWEndpoint?
        var deviceName = "?"

        let browseParameters = NWParameters()
        browseParameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: ProjectTransferService.type, domain: nil),
            using: browseParameters)
        browser.browseResultsChangedHandler = { results, _ in
            guard endpoint == nil else { return }
            func name(_ result: NWBrowser.Result) -> String {
                guard case .bonjour(let txt) = result.metadata else { return "" }
                return txt[ProjectTransferService.TXTKey.deviceName] ?? ""
            }
            let match = wantedDevice.map { wanted in
                results.first { name($0).lowercased().contains(wanted) }
            } ?? results.first
            guard let first = match else { return }
            if case .bonjour(let txt) = first.metadata {
                deviceName = txt[ProjectTransferService.TXTKey.deviceName] ?? "?"
                // The interface list is printed RAW and unfiltered: what a
                // USB-tethered iOS device reports is the thing this line
                // exists to answer, and the app's picker deliberately shows
                // nothing rather than guess when the answer is ambiguous.
                log("found \(deviceName) — \(txt[ProjectTransferService.TXTKey.projectCount] ?? "?") projects"
                    + " (v\(txt[ProjectTransferService.TXTKey.version] ?? "?"), \(first.interfaces.map { String(describing: $0.type) }.joined(separator: ",")))")
            }
            endpoint = first.endpoint
            discovered.signal()
        }
        browser.start(queue: .global())
        if discovered.wait(timeout: .now() + 15) == .timedOut {
            die("no device advertising \(ProjectTransferService.type) within 15s")
        }
        guard let endpoint else { die("no endpoint") }

        // MARK: - Connect

        let connection = NWConnection(
            to: endpoint,
            using: CaptureRemotePairing.parameters(
                code: code,
                salt: ProjectTransferService.pairingSalt,
                identity: "letslapse-transfer",
                bulkTransfer: true))

        let ready = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): die("connection failed: \(error)")
            default: break
            }
        }
        connection.start(queue: .global())
        if ready.wait(timeout: .now() + 10) == .timedOut {
            // A wrong code never fails the client — it surfaces as -9846 bad MAC on
            // the SERVER's first read and this side sits in .preparing forever.
            die("never became ready — wrong code, or the device isn't sharing")
        }
        log("paired with \(deviceName)")

        func send<Message: Encodable>(_ message: Message) {
            guard let data = try? PTCoder.control(message) else { die("encode failed") }
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { die("send failed: \(error)") }
            })
        }

        func nextFrame(timeout: TimeInterval = 60) -> PTFrame {
            let waiter = DispatchSemaphore(value: 0)
            var outcome: Result<PTFrame, Error>?
            PTFrameReader.receive(on: connection) { result in
                outcome = result
                waiter.signal()
            }
            if waiter.wait(timeout: .now() + timeout) == .timedOut { die("timed out waiting for a frame") }
            switch outcome! {
            case .success(let frame):
                if arguments.contains("--trace") {
                    log("  ← \(frame.type) \(frame.payload.count) bytes")
                }
                return frame
            case .failure(let error): die("read failed: \(error)")
            }
        }

        func kind(of frame: PTFrame) -> PTKind? {
            guard frame.type == .control,
                  let envelope = try? PTCoder.decoder.decode(PTEnvelope.self, from: frame.payload)
            else { return nil }
            return envelope.messageKind
        }

        // MARK: - List

        send(PTListRequest())
        var projects: [PTProjectInfo] = []
        while true {
            let frame = nextFrame()
            if kind(of: frame) == .error {
                let error = try? PTCoder.decoder.decode(PTError.self, from: frame.payload)
                die("server error: \(error?.code ?? "?") — \(error?.message ?? "")")
            }
            if kind(of: frame) == .listReply {
                projects = (try? PTCoder.decoder.decode(PTListReply.self, from: frame.payload))?.projects ?? []
                break
            }
        }
        // Tiles are lazy now, so ask for them the way the picker does — for
        // the rows it would have on screen. `--thumbs N` asks for the first N.
        var thumbnails: [UUID: Data] = [:]
        if let wanted = option("--thumbs").flatMap(Int.init), wanted > 0 {
            let batch = Array(projects.prefix(wanted))
            let started = Date()
            for project in batch { send(PTThumbnailRequest(captureID: project.captureID)) }
            while thumbnails.count < batch.count, Date().timeIntervalSince(started) < 120 {
                let frame = nextFrame(timeout: 120)
                guard kind(of: frame) == .thumbnail,
                      let reply = try? PTCoder.decoder.decode(PTThumbnailReply.self, from: frame.payload)
                else { continue }
                thumbnails[reply.captureID] = reply.data ?? Data()
            }
            let drawn = thumbnails.values.filter { !$0.isEmpty }
            log(String(format: "thumbnails: %d of %d drawn, %d KB total, %.1fs",
                       drawn.count, batch.count,
                       drawn.reduce(0) { $0 + $1.count } / 1024,
                       Date().timeIntervalSince(started)))
        }

        log("\(projects.count) project(s):")
        for (index, project) in projects.enumerated() {
            let thumbnail = thumbnails[project.captureID].map { "\($0.count / 1024) KB thumb" } ?? "no thumb"
            log(String(format: "  [%d] %@ — %d frames, %@, %@",
                       index,
                       project.name ?? "Untitled",
                       project.frameCount,
                       ByteCountFormatter.string(fromByteCount: project.totalBytes, countStyle: .file),
                       thumbnail))
        }
        if listOnly || pullIndex == nil {
            connection.cancel()
            exit(0)
        }

        // MARK: - Pull

        guard let pullIndex, projects.indices.contains(pullIndex) else { die("no project at that index") }
        let wanted = projects[pullIndex]
        let destination = outputRoot.appendingPathComponent(wanted.captureID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        log("pulling “\(wanted.name ?? "Untitled")” into \(destination.path)")

        send(PTTransferRequest(captureID: wanted.captureID))

        var manifest: [PTFileEntry] = []
        var handle: FileHandle?
        var currentEntry: PTFileEntry?
        var currentPart: URL?
        var currentFinal: URL?
        var writtenForEntry: Int64 = 0
        var totalReceived: Int64 = 0
        var lastAcked: Int64 = 0
        var landed: [String: Int64] = [:]
        let started = Date()

        /// The rename is the commit, exactly as the app's own client does it — so a
        /// truncated file stays a `.part` and the verification below sees it.
        func closeCurrent() {
            guard let openHandle = handle, let part = currentPart,
                  let final = currentFinal, let entry = currentEntry else { return }
            try? openHandle.close()
            handle = nil
            currentPart = nil
            currentFinal = nil
            currentEntry = nil
            guard writtenForEntry == entry.byteCount else {
                die("\(entry.relativePath): got \(writtenForEntry) bytes, manifest said \(entry.byteCount)")
            }
            try? FileManager.default.moveItem(at: part, to: final)
            landed[entry.relativePath] = writtenForEntry
        }

        loop: while true {
            let frame = nextFrame(timeout: 120)
            switch frame.type {
            case .data:
                guard let handle else { die("data frame with no open file") }
                try handle.write(contentsOf: frame.payload)
                writtenForEntry += Int64(frame.payload.count)
                totalReceived += Int64(frame.payload.count)
                // NOT optional. The ack window is the transfer's only
                // backpressure — a client that never acks makes the server
                // buffer the whole project in memory (measured: 4 GB sent,
                // 4 GB resident) until the window stalls it.
                // The second clause closes the tail: the server holds
                // `transferDone` until every byte is acked, and the interval
                // alone never covers the last partial one.
                let expected = manifest.reduce(0) { $0 + $1.byteCount }
                if totalReceived - lastAcked >= PTCoder.ackIntervalBytes
                    || (expected > 0 && totalReceived >= expected) {
                    lastAcked = totalReceived
                    send(PTAck(bytesReceived: totalReceived))
                }
            case .cancel:
                break
            case .control:
                switch kind(of: frame) {
                case .transferReady:
                    guard let readyMessage = try? PTCoder.decoder.decode(PTTransferReady.self, from: frame.payload)
                    else { die("bad transferReady") }
                    manifest = readyMessage.files
                    log("manifest: \(manifest.count) files, "
                        + ByteCountFormatter.string(fromByteCount: readyMessage.totalBytes, countStyle: .file))
                case .fileBegin:
                    guard let begin = try? PTCoder.decoder.decode(PTFileBegin.self, from: frame.payload)
                    else { die("bad fileBegin") }
                    closeCurrent()
                    let final = destination.appendingPathComponent(begin.file.relativePath)
                    try FileManager.default.createDirectory(
                        at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let part = final.appendingPathExtension("part")
                    FileManager.default.createFile(atPath: part.path, contents: nil)
                    handle = try FileHandle(forWritingTo: part)
                    currentEntry = begin.file
                    currentPart = part
                    currentFinal = final
                    writtenForEntry = 0
                case .transferDone:
                    closeCurrent()
                    break loop
                case .error:
                    let error = try? PTCoder.decoder.decode(PTError.self, from: frame.payload)
                    die("server error: \(error?.code ?? "?") — \(error?.message ?? "")")
                default:
                    break
                }
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        log("received \(landed.count)/\(manifest.count) files, "
            + ByteCountFormatter.string(fromByteCount: totalReceived, countStyle: .file)
            + String(format: " in %.1fs", elapsed))

        var problems: [String] = []
        for entry in manifest {
            guard let bytes = landed[entry.relativePath] else {
                problems.append("missing \(entry.relativePath)")
                continue
            }
            if bytes != entry.byteCount {
                problems.append("\(entry.relativePath): \(bytes) != \(entry.byteCount)")
            }
        }
        let strays = (try? FileManager.default.subpathsOfDirectory(atPath: destination.path))?
            .filter { $0.hasSuffix(".part") } ?? []
        if !strays.isEmpty { problems.append("left \(strays.count) .part file(s) behind") }

        if problems.isEmpty {
            log("TRANSFER PASS — every file matches the manifest byte for byte")
            connection.cancel()
            exit(0)
        } else {
            problems.forEach { log("FAIL: \($0)") }
            connection.cancel()
            exit(1)
        }

    }
}

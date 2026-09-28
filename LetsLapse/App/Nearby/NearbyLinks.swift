import CryptoKit
import Foundation
import LetsLapseKit
import Network

// MARK: - The asking side's links (2026-09-28)
//
// docs/nearby-originals-plan.md §6–7. Every frame of a link is handled on
// the link's own queue in arrival order — a `fileBegin` hopped to the main
// actor while its data frames were written here would let bytes land in
// the wrong file (the transfer client's rule, `PTLink`). Only progress and
// outcomes cross to the service.

/// "Which of these projects do you hold?" — one connection, `hello` both
/// ways, one question, one answer, closed.
final class NearbyQueryLink: @unchecked Sendable {
    typealias Outcome = Result<(NearbyHello, [NearbyHoldingsRow]), Error>

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let hello: NearbyHello
    private let origins: [UUID]
    private var peerHello: NearbyHello?
    private var completion: ((Outcome) -> Void)?
    /// The link holds itself until it finishes — nothing else does: its
    /// handlers hold it weakly, and a link let go mid-question takes its
    /// connection with it, silently (found on the first bench run,
    /// 2026-09-28). The 10 s timeout guarantees the finish.
    private var keepAlive: NearbyQueryLink?

    init(endpoint: NWEndpoint, parameters: NWParameters, hello: NearbyHello, origins: [UUID], queue: DispatchQueue) {
        connection = NWConnection(to: endpoint, using: parameters)
        self.queue = queue
        self.hello = hello
        self.origins = origins
    }

    func run(_ completion: @escaping (Outcome) -> Void) {
        queue.async { [self] in
            self.completion = completion
            keepAlive = self
            connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 10) { [weak self] in self?.finish(.failure(NearbyError.timedOut)) }
        }
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            send(hello)
            send(NearbyHoldingsQuery(originIDs: origins))
            receiveNext()
        case .failed(let error):
            finish(.failure(error))
        default:
            break
        }
    }

    private func send<Message: Encodable>(_ message: Message) {
        guard let data = try? PTCoder.control(message) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receiveNext() {
        PTFrameReader.receive(on: connection) { [weak self] result in self?.handle(result) }
    }

    private func handle(_ result: Result<PTFrame, Error>) {
        guard completion != nil else { return }
        switch result {
        case .failure(let error):
            finish(.failure(error))
        case .success(let frame):
            guard frame.type == .control, let kind = NearbyCoding.kind(of: frame.payload) else {
                receiveNext()
                return
            }
            switch kind {
            case .hello:
                peerHello = try? PTCoder.decoder.decode(NearbyHello.self, from: frame.payload)
                receiveNext()
            case .holdingsReply:
                guard let peerHello, let reply = try? PTCoder.decoder.decode(NearbyHoldingsReply.self, from: frame.payload) else {
                    finish(.failure(NearbyError.unexpected("The other device answered out of turn.")))
                    return
                }
                finish(.success((peerHello, reply.rows)))
            case .error:
                let refused = try? PTCoder.decoder.decode(PTError.self, from: frame.payload)
                finish(.failure(NearbyError.refused(refused?.message ?? "The other device refused.")))
            default:
                receiveNext()
            }
        }
    }

    private func finish(_ outcome: Outcome) {
        guard let completion else { return }
        self.completion = nil
        connection.cancel()
        completion(outcome)
        keepAlive = nil
    }
}

/// "Send me these files" — the import. Each file is written into the
/// project's own `tmp/`, hashed as it lands, checked (N8: this device's own
/// recorded SHA-256, else the serving device's, else the size) and only then
/// moved into place. A file that fails its check is thrown away and stops
/// the import; the files already in place stay.
final class NearbyImportLink: @unchecked Sendable {
    struct Outcome {
        var landed: [(name: String, bytes: Int64, sha256: String)]
        var bytes: Int64
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let hello: NearbyHello
    private let request: NearbyRequestFiles
    private let folder: URL
    private let expectedHashes: [String: String]
    private let source: String
    /// The only paths this import will write: what it asked for.
    private let requested: Set<String>

    private var continuation: CheckedContinuation<Outcome, Error>?
    private var progress: ((PicPlaceSyncProgress) -> Void)?
    private var peerHello: NearbyHello?
    private var ready: NearbyFilesReady?
    private var announced: [String: NearbyFileEntry] = [:]
    private var snapshot = PicPlaceSyncProgress(phase: .downloading)

    private var current: PTFileEntry?
    private var handle: FileHandle?
    private var partURL: URL?
    private var hasher = SHA256()
    private var written: Int64 = 0
    private var received: Int64 = 0
    private var lastAcked: Int64 = 0
    private var lastReport = Date.distantPast
    private var landed: [(name: String, bytes: Int64, sha256: String)] = []
    private var cancelled = false

    init(endpoint: NWEndpoint, parameters: NWParameters, hello: NearbyHello, request: NearbyRequestFiles,
         folder: URL, expectedHashes: [String: String], source: String, queue: DispatchQueue) {
        connection = NWConnection(to: endpoint, using: parameters)
        self.queue = queue
        self.hello = hello
        self.request = request
        self.folder = folder
        self.expectedHashes = expectedHashes
        self.source = source
        requested = Set(request.originals.flatMap { $0 } + request.blends)
        snapshot.source = source
    }

    func run(progress: @escaping (PicPlaceSyncProgress) -> Void) async throws -> Outcome {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !cancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                self.progress = progress
                progress(snapshot)
                connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
                connection.start(queue: queue)
                // Nothing at all within 15 s: the other device is gone.
                queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                    guard let self, self.ready == nil else { return }
                    self.fail(NearbyError.timedOut)
                }
            }
        }
    }

    /// Stop now: a cancel frame, the connection closed, the file being
    /// written thrown away. What already landed stays.
    func cancel() {
        queue.async { [self] in
            cancelled = true
            connection.send(content: PTCoder.cancelFrame(), completion: .contentProcessed { _ in })
            fail(CancellationError())
        }
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            let interfaces = connection.currentPath?.availableInterfaces.map { "\($0.name)/\($0.type)" }.joined(separator: ",") ?? "?"
            LLog("nearby: import link to \(source) ready via \(interfaces)")
            send(hello)
            send(request)
            receiveNext()
        case .failed(let error):
            fail(error)
        default:
            break
        }
    }

    private func send<Message: Encodable>(_ message: Message) {
        guard let data = try? PTCoder.control(message) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receiveNext() {
        PTFrameReader.receive(on: connection) { [weak self] result in
            guard let self, self.continuation != nil else { return }
            switch result {
            case .failure(let error):
                self.fail(error)
            case .success(let frame):
                self.handle(frame)
                if self.continuation != nil { self.receiveNext() }
            }
        }
    }

    private func handle(_ frame: PTFrame) {
        switch frame.type {
        case .cancel:
            break
        case .data:
            append(frame.payload)
        case .control:
            guard let kind = NearbyCoding.kind(of: frame.payload) else { return }
            switch kind {
            case .hello:
                peerHello = try? PTCoder.decoder.decode(NearbyHello.self, from: frame.payload)
                guard let peerHello, peerHello.serverID.lowercased() == hello.serverID.lowercased(),
                      peerHello.userUUID.lowercased() == hello.userUUID.lowercased() else {
                    fail(NearbyError.unexpected("The other device isn't signed in to this PicPlace account."))
                    return
                }
            case .filesReady:
                guard let ready = try? PTCoder.decoder.decode(NearbyFilesReady.self, from: frame.payload) else { return }
                begin(ready)
            case .fileBegin:
                guard let begin = try? PTCoder.decoder.decode(PTFileBegin.self, from: frame.payload) else { return }
                open(begin.file)
            case .filesDone:
                closeCurrentFile()
                guard continuation != nil else { return }
                snapshot.bytesDone = received
                progress?(snapshot)
                finish()
            case .error:
                let refused = try? PTCoder.decoder.decode(PTError.self, from: frame.payload)
                fail(NearbyError.refused(refused?.message ?? "\(source) stopped sending."))
            case .holdings, .holdingsReply, .requestFiles, .ack:
                break
            }
        }
    }

    private func begin(_ ready: NearbyFilesReady) {
        // Only what was asked for, only heavy files, only inside the folder.
        guard ready.originID == request.originID,
              ready.files.allSatisfy({ requested.contains($0.relativePath) && NearbyTrust.isSafeRelativePath($0.relativePath)
                  && PicPlaceSyncInventory.isHeavy($0.relativePath) }) else {
            fail(NearbyError.unexpected("\(source) offered files that weren't asked for."))
            return
        }
        do {
            try AppModel.checkStorageHeadroom(for: ready.totalBytes, at: folder)
        } catch {
            fail(error)
            return
        }
        self.ready = ready
        for file in ready.files { announced[file.relativePath] = file }
        snapshot.filesTotal = ready.files.count
        snapshot.bytesTotal = ready.totalBytes
        progress?(snapshot)
    }

    private func open(_ entry: PTFileEntry) {
        closeCurrentFile()
        guard continuation != nil else { return }
        guard let announcedEntry = announced[entry.relativePath], announcedEntry.byteCount == entry.byteCount else {
            fail(NearbyError.unexpected("\(source) sent \(entry.relativePath), which it hadn't announced."))
            return
        }
        let tmp = folder.appendingPathComponent("tmp", isDirectory: true)
        let part = tmp.appendingPathComponent("nearby-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: part.path, contents: nil)
            handle = try FileHandle(forWritingTo: part)
            partURL = part
            current = entry
            written = 0
            hasher = SHA256()
        } catch {
            fail(NearbyError.unexpected("Couldn't write \(entry.relativePath): \(error.localizedDescription)"))
        }
    }

    private func append(_ data: Data) {
        guard let handle, continuation != nil else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            fail(NearbyError.unexpected("Couldn't write to disk: \(error.localizedDescription)"))
            return
        }
        hasher.update(data: data)
        written += Int64(data.count)
        received += Int64(data.count)
        // Acked after the write returns — "this many bytes are on disk" —
        // every 8 MB and at the very end (the pump waits for the last one
        // before `filesDone`).
        let total = ready?.totalBytes ?? 0
        if received - lastAcked >= PTCoder.ackIntervalBytes || (total > 0 && received >= total) {
            lastAcked = received
            send(PTAck(bytesReceived: received))
        }
        if Date().timeIntervalSince(lastReport) > 0.2 {
            lastReport = Date()
            snapshot.bytesDone = received
            progress?(snapshot)
        }
    }

    /// The file is whole: checked, then moved into place — the move is the
    /// commit, so a torn file is never mistaken for one.
    private func closeCurrentFile() {
        guard let handle, let partURL, let entry = current else { return }
        try? handle.close()
        self.handle = nil
        self.partURL = nil
        current = nil
        guard written == entry.byteCount else {
            try? FileManager.default.removeItem(at: partURL)
            fail(NearbyError.unexpected("\(entry.relativePath) arrived incomplete."))
            return
        }
        let digest = AssetHash.prefix + hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let expected = expectedHashes[entry.relativePath] ?? announced[entry.relativePath]?.sha256
        if let expected, PicPlaceOriginalsCheck.normalized(expected) != PicPlaceOriginalsCheck.normalized(digest) {
            try? FileManager.default.removeItem(at: partURL)
            fail(NearbyError.damaged((entry.relativePath as NSString).lastPathComponent))
            return
        }
        let destination = folder.appendingPathComponent(entry.relativePath)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: partURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partURL)
            fail(NearbyError.unexpected("Couldn't put \(entry.relativePath) in place: \(error.localizedDescription)"))
            return
        }
        landed.append((entry.relativePath, entry.byteCount, digest))
        snapshot.filesDone = landed.count
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        connection.cancel()
        continuation.resume(returning: Outcome(landed: landed, bytes: received))
    }

    private func fail(_ error: Error) {
        if let handle { try? handle.close() }
        handle = nil
        if let partURL { try? FileManager.default.removeItem(at: partURL) }
        partURL = nil
        current = nil
        guard let continuation else { return }
        self.continuation = nil
        connection.cancel()
        continuation.resume(throwing: error)
    }

    /// The files in place so far — after a stop or a failure too, so the
    /// caller records their hashes either way (they stay; the next press
    /// asks only for the rest).
    func landedSoFar() -> [(name: String, bytes: Int64, sha256: String)] {
        queue.sync { landed }
    }
}

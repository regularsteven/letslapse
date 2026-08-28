// Every platform that has a library. A Watch is a remote, never a library.
//
// Serving from macOS was deferred to Phase 3 on the argument that a Mac's
// library is already reachable through Finder — true, but it is the wrong
// comparison: the thing being moved is a project, and the receiving device has
// no Finder to reach into. Mac→iPad is the same job as iPhone→iPad and now
// runs the same code. Only the stand-down rule differs, because a Mac has no
// scene-phase background to hang one on — see `idleTimeout`.
#if !os(watchOS)
import Foundation
import Network
#if os(iOS)
import UIKit
#endif

/// The serving half of a project transfer: advertises this device's library on
/// the local network, hands out a list, and streams one project's files to a
/// paired client.
///
/// **It never writes to the library and never deletes from it.** The serving
/// side is read-only by construction, and that property is worth keeping true
/// as the feature grows — a "Move" affordance would break it, and the failure
/// mode of a move that deletes after an install which later turns out to be
/// broken is losing a shoot.
///
/// Deliberately NOT `CaptureRemoteListener` with more commands. The two have
/// different lifetimes (that one lives exactly as long as the capture screen),
/// different threat surfaces (start a recording vs. read every project on the
/// device) and different traffic shapes (a few hundred bytes vs. sixteen
/// gigabytes). Sharing a listener would have coupled all three.
@MainActor
final class ProjectTransferServer: ObservableObject {
    /// Opt-in, OFF by default, and separate from `remote.allowRemoteAccess`:
    /// serving your whole library and driving the shutter are different grants.
    /// Settings ▸ Advanced.
    static let enabledKey = "transfer.sharingEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    struct TransferProgress: Equatable {
        var projectName: String
        var totalBytes: Int64
        var bytesTransferred: Int64
        var currentFile: String

        /// Nil rather than a guess when there is no honest denominator.
        var fraction: Double? {
            guard totalBytes > 0 else { return nil }
            return min(1, Double(bytesTransferred) / Double(totalBytes))
        }
    }

    @Published private(set) var isRunning = false
    /// Six digits, minted fresh on every arm. A code read off this screen an
    /// hour ago is not still valid, and this one grants read access to EVERY
    /// project on the device — which the sharing UI says out loud.
    @Published private(set) var pairingCode = ""
    @Published private(set) var activeTransfer: TransferProgress?
    /// Set when advertising is impossible rather than merely quiet — a denied
    /// Local Network prompt otherwise looks exactly like "nobody connected".
    @Published private(set) var failure: String?
    @Published private(set) var isPeerConnected = false

    private weak var model: AppModel?
    private var listener: NWListener?
    private var connection: NWConnection?
    /// Connections that have arrived but not yet reached `.ready`. A cabled
    /// device produces several per client attempt — see `accept`.
    private var pendingConnections: [NWConnection] = []
    private var job: TransferJob?
    /// Watches for a shoot starting under an in-flight transfer. A poll rather
    /// than an observation because the pump runs off the main actor and the
    /// answer lives on it; one check a second is far finer than the case needs.
    private var captureWatch: Task<Void, Never>?
    /// Stands the listener down after `idleTimeout` with nobody connected —
    /// the Mac's only stand-down, and a good second one on iOS.
    private var idleTimer: Task<Void, Never>?
    /// True when the listener stopped itself rather than being switched off,
    /// so the UI can say which happened and offer to arm again.
    @Published private(set) var stoodDownIdle = false

    /// Sizing a project walks its whole directory tree. Cached per arm — the
    /// library does not change under a server that refuses to serve while
    /// anything is writing to it.
    private var catalogue: [PTProjectInfo] = []

    /// `NWConnection`'s callbacks land here — deliberately not `.main`: a
    /// 16 GB transfer's send completions and receive frames have no business
    /// on the main actor, and the receive loop MUST keep running while the
    /// pump is streaming so a cancel can arrive mid-file.
    private let networkQueue = DispatchQueue(label: "com.regularsteven.letslapse.transfer.net")
    /// The file read + send pump. Blocks on backpressure, so it must never be
    /// the queue the completions arrive on.
    private let pumpQueue = DispatchQueue(
        label: "com.regularsteven.letslapse.transfer.pump", qos: .utility)

    init(model: AppModel? = nil) {
        self.model = model
    }

    func attach(model: AppModel) {
        self.model = model
    }

    // MARK: - Lifecycle

    func start() {
        guard listener == nil else { return }
        let code = CaptureRemotePairing.generateCode()
        pairingCode = code
        failure = nil

        do {
            let parameters = CaptureRemotePairing.parameters(
                code: code,
                salt: ProjectTransferService.pairingSalt,
                identity: "letslapse-transfer",
                bulkTransfer: true)
            parameters.allowLocalEndpointReuse = true
            // NO `requiredInterfaceType` and NO `prohibitedInterfaceTypes`,
            // anywhere in this feature. Listening on every interface is what
            // makes a USB-tethered device work with no extra code at all — a
            // cable presents to the Mac as a network interface. The moment
            // either appears the symptom is "the device just doesn't show up",
            // which reads as a Bonjour problem and isn't.
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(
                type: ProjectTransferService.type,
                txtRecord: txtRecord(code: code))
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.handleListenerState(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: networkQueue)
            isRunning = true
            stoodDownIdle = false
            restartIdleTimer()
            Task { await refreshCatalogue() }
        } catch {
            failure = error.localizedDescription
            LLog("transfer-server start failed: \(error)")
        }
    }

    func stop() {
        idleTimer?.cancel()
        idleTimer = nil
        abortTransfer(reason: nil)
        pendingConnections.forEach { $0.cancel() }
        pendingConnections = []
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        isRunning = false
        isPeerConnected = false
        pairingCode = ""
        catalogue = []
    }

    /// What the other end's picker shows. `UIDevice` on iOS; on a Mac the
    /// sharing name people already recognise (the one in Settings ▸ General ▸
    /// About and on AirDrop), falling back to the host name.
    static var deviceName: String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif
    }

    /// Coarse on purpose — it picks the glyph in the picker and disambiguates
    /// two devices with the same name, nothing more.
    static var deviceModel: String {
        #if os(iOS)
        return UIDevice.current.model
        #else
        return "Mac"
        #endif
    }

    /// How long a listener with nobody connected keeps advertising.
    ///
    /// **This is the Mac's stand-down rule.** iOS gets one for free — the app
    /// backgrounds and the listener stops — but a Mac has no scene-phase
    /// background to hang that on, so an armed Mac would otherwise advertise
    /// its whole library until the app quit. A code left advertising on a
    /// machine nobody is sitting at is the failure mode to design out, and 15
    /// minutes is long enough to walk to the other device and type six digits.
    ///
    /// The clock is reset by anything that means a human is still in this —
    /// arming, a peer connecting, a transfer finishing — so it only ever fires
    /// on real idleness. It applies on iOS too: it is a good rule there as
    /// well, just not the only one.
    static let idleTimeout: TimeInterval = 15 * 60

    private func restartIdleTimer() {
        idleTimer?.cancel()
        idleTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleTimeout * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isRunning else { return }
            // A peer sitting connected, or a transfer running, is not idle.
            guard self.connection == nil, self.job == nil else {
                self.restartIdleTimer()
                return
            }
            LLog("transfer-server standing down — idle for \(Int(Self.idleTimeout / 60)) minutes")
            self.stop()
            self.stoodDownIdle = true
        }
    }

    private func txtRecord(code: String) -> NWTXTRecord {
        var txt = NWTXTRecord()
        txt[ProjectTransferService.TXTKey.deviceName] = Self.deviceName
        txt[ProjectTransferService.TXTKey.model] = Self.deviceModel
        txt[ProjectTransferService.TXTKey.pairingID] = CaptureRemotePairing.pairingID(code: code)
        txt[ProjectTransferService.TXTKey.projectCount] = String(model?.captures.count ?? 0)
        txt[ProjectTransferService.TXTKey.version] = String(ProjectTransferService.version)
        return txt
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            failure = nil
            LLog("transfer-server advertising code=\(pairingCode)")
        case .failed(let error):
            // Most likely a denied Local Network permission, which otherwise
            // presents as "the Mac never finds this device".
            failure = error.localizedDescription
            isRunning = false
            LLog("transfer-server failed: \(error)")
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    private func refreshCatalogue() async {
        guard let model else { return }
        catalogue = await model.projectTransferCatalogue()
    }

    // MARK: - Connections

    /// One client at a time, newest wins — but **not until the newcomer is
    /// actually ready**, which is the part `CaptureRemoteListener` does not
    /// have to worry about and this does.
    ///
    /// A USB-tethered iPhone is on Wi-Fi *and* the cable at once, so a single
    /// `NWConnection` to its Bonjour name races both interfaces and this
    /// listener sees TWO inbound connections milliseconds apart. Evicting on
    /// arrival — the capture remote's rule — then kills one of them at random,
    /// and half the time it is the one the client settled on; the symptom is a
    /// connection that closes immediately after pairing, intermittently, only
    /// on a cabled device (measured 2026-08-27). Promoting on `.ready` instead
    /// keeps the newest-wins property — a half-open peer still cannot block a
    /// reconnection, because the newcomer never waits on it.
    private func accept(_ incoming: NWConnection) {
        pendingConnections.append(incoming)
        incoming.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handleConnectionState(state, connection: incoming) }
        }
        incoming.start(queue: networkQueue)
    }

    private func handleConnectionState(_ state: NWConnection.State, connection incoming: NWConnection) {
        switch state {
        case .ready:
            promote(incoming)
        case .failed(let error):
            // A wrong pairing code lands here as -9846 bad MAC on the first
            // read, not as a clean handshake rejection. It also lands here for
            // the losing half of the interface race above, which is routine.
            LLog("transfer-server peer failed: \(error)")
            forgetPending(incoming)
            dropPeer(incoming)
        case .cancelled:
            forgetPending(incoming)
            dropPeer(incoming)
        default:
            break
        }
    }

    private func promote(_ incoming: NWConnection) {
        guard forgetPending(incoming) else { return }   // already the live peer
        if let existing = connection, existing !== incoming {
            LLog("transfer-server replacing existing peer")
            abortTransfer(reason: nil)
            connection = nil
            existing.cancel()
        }
        connection = incoming
        isPeerConnected = true
        restartIdleTimer()
        LLog("transfer-server peer connected")
        receiveNext(on: incoming)
    }

    @discardableResult
    private func forgetPending(_ incoming: NWConnection) -> Bool {
        guard let index = pendingConnections.firstIndex(where: { $0 === incoming }) else {
            return false
        }
        pendingConnections.remove(at: index)
        return true
    }

    private func dropPeer(_ incoming: NWConnection) {
        guard connection === incoming else { return }
        LLog("transfer-server peer dropped")
        abortTransfer(reason: nil)
        // Cancelled explicitly rather than just forgotten: a connection left
        // un-cancelled after a reset keeps its queued sends (and their
        // completions) alive with nothing to deliver them to.
        incoming.cancel()
        connection = nil
        isPeerConnected = false
    }

    /// One frame, then re-arm. Runs for the life of the connection INCLUDING
    /// while the pump is streaming — a cancel arriving mid-file is the whole
    /// reason the payload is chunked rather than flushed until close.
    private func receiveNext(on incoming: NWConnection) {
        PTFrameReader.receive(on: incoming) { [weak self] result in
            switch result {
            case .failure:
                Task { @MainActor in self?.dropPeer(incoming) }
            case .success(let frame):
                Task { @MainActor in
                    guard let self, self.connection === incoming else { return }
                    self.handle(frame, on: incoming)
                    self.receiveNext(on: incoming)
                }
            }
        }
    }

    private func handle(_ frame: PTFrame, on incoming: NWConnection) {
        switch frame.type {
        case .cancel:
            abortTransfer(reason: nil)
        case .data:
            // A client has nothing to send us. Ignore rather than tear down.
            break
        case .control:
            guard let envelope = try? PTCoder.decoder.decode(PTEnvelope.self, from: frame.payload),
                  let kind = envelope.messageKind else {
                send(PTError(code: PTError.Code.unsupported, message: "Unrecognised message."), on: incoming)
                return
            }
            switch kind {
            case .listProjects:
                Task { await self.replyWithList(on: incoming) }
            case .ack:
                // The receive loop runs on the network queue, independent of
                // the pump — which is what lets an ack (or a cancel) land
                // while a file is streaming. Handled here on the main actor
                // for consistency with the rest of the vocabulary; the job's
                // own condition does the cross-thread wake.
                guard let ack = try? PTCoder.decoder.decode(PTAck.self, from: frame.payload) else { return }
                job?.recordAck(ack.bytesReceived)
            case .cancel:
                abortTransfer(reason: nil)
            case .requestThumbnail:
                guard let request = try? PTCoder.decoder.decode(
                    PTThumbnailRequest.self, from: frame.payload) else { return }
                // Answered whatever else is going on, like `listProjects`: it
                // is a few KB, and it runs off the main actor. It deliberately
                // does NOT touch the idle timer — a client scrolling a list is
                // browsing, and the 15-minute clock is about a device left
                // advertising with nobody there.
                Task { await self.replyWithThumbnail(request.captureID, on: incoming) }
            case .requestTransfer:
                guard let request = try? PTCoder.decoder.decode(
                    PTTransferRequest.self, from: frame.payload) else { return }
                beginTransfer(of: request.captureID, on: incoming)
            case .listReply, .transferReady, .fileBegin, .transferDone, .thumbnail, .error:
                // Server-to-client vocabulary; a client sending one is
                // confused, and answering it would only confuse us both.
                break
            }
        }
    }

    /// Answered whatever the app is doing. `listProjects` is kilobytes, and a
    /// client that cannot see the list has no idea *why* it cannot.
    private func replyWithList(on incoming: NWConnection) async {
        // Re-walked on every request rather than served from the arm-time
        // cache: a shoot finished since the code was minted is exactly the
        // project somebody is here to fetch, and a list that quietly omits it
        // is worse than a directory walk nobody notices.
        await refreshCatalogue()
        send(PTListReply(projects: catalogue), on: incoming)
    }

    private func replyWithThumbnail(_ captureID: UUID, on incoming: NWConnection) async {
        guard let model else { return }
        let data = await model.projectTransferThumbnail(for: captureID)
        // Still replies when there is nothing to draw, so the client can stop
        // asking rather than retrying a row that will never have a tile.
        send(PTThumbnailReply(captureID: captureID, data: data), on: incoming)
    }

    // MARK: - Serving one project

    private func beginTransfer(of captureID: UUID, on incoming: NWConnection) {
        guard let model else {
            send(PTError.notFound(), on: incoming)
            return
        }
        // A live shoot is the one thing that outranks everything here: reading
        // gigabytes off the disk under a capture is how both end up looking
        // broken. Blending and exporting refuse too — they are told apart by
        // sentence so the client can say which.
        if let reason = model.transferBlockReason {
            send(PTError.busy(reason), on: incoming)
            return
        }
        guard job == nil else {
            send(PTError.busy("That device is already sending a project."), on: incoming)
            return
        }
        // `try?` flattens the double optional: nil here is "no such project"
        // either way, which is the same sentence.
        guard let folder = model.projectTransferFolderURL(for: captureID),
              let manifestData = try? model.projectTransferManifestData(for: captureID) else {
            send(PTError.notFound(), on: incoming)
            return
        }

        let name = model.captures.first(where: { $0.id == captureID })
            .map { $0.name ?? $0.originalName } ?? "Project"
        let files = Self.fileManifest(folder: folder, manifestBytes: Int64(manifestData.count))
        let ready = PTTransferReady(captureID: captureID, files: files)
        LLog("transfer-server serving \(files.count) files, \(ready.totalBytes) bytes")
        send(ready, on: incoming)

        let job = TransferJob(captureID: captureID)
        self.job = job
        model.beginActivity(.servingTransfer)
        activeTransfer = TransferProgress(
            projectName: name,
            totalBytes: ready.totalBytes,
            bytesTransferred: 0,
            currentFile: "")
        startCaptureWatch()

        pumpQueue.async { [weak self] in
            Self.pump(
                job: job,
                connection: incoming,
                folder: folder,
                manifestData: manifestData,
                files: files,
                onProgress: { bytes, file in
                    Task { @MainActor in self?.reportProgress(job: job, bytes: bytes, file: file) }
                },
                onFinish: { error in
                    Task { @MainActor in self?.finishTransfer(job: job, error: error, on: incoming) }
                })
        }
    }

    private func reportProgress(job reporting: TransferJob, bytes: Int64, file: String) {
        guard job === reporting else { return }
        activeTransfer?.bytesTransferred = bytes
        activeTransfer?.currentFile = file
    }

    private func finishTransfer(job finishing: TransferJob, error: PTError?, on incoming: NWConnection) {
        guard job === finishing else {
            LLog("transfer-server pump finished for a job that is no longer current")
            return
        }
        LLog("transfer-server transfer finished error=\(error?.code ?? "none")")
        if let error {
            // A cancelled job says nothing further: the client asked, and it
            // already knows. Anything else is a sentence it needs.
            if error.code != PTError.Code.cancelled {
                send(error, on: incoming)
            }
        } else {
            send(PTTransferDone(captureID: finishing.captureID), on: incoming)
        }
        clearJob()
    }

    /// Stops the pump between chunks. Nothing further is written and the client
    /// keeps its partial tree — a resume picks it up from there.
    private func abortTransfer(reason: String?) {
        guard let job else { return }
        job.cancel()
        if let reason, let connection {
            send(PTError.busy(reason), on: connection)
        }
        clearJob()
    }

    private func clearJob() {
        guard job != nil else { return }
        job = nil
        restartIdleTimer()
        captureWatch?.cancel()
        captureWatch = nil
        activeTransfer = nil
        model?.endActivity(.servingTransfer)
    }

    private func startCaptureWatch() {
        captureWatch?.cancel()
        captureWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.job != nil else { return }
                guard self.model?.activeLibraryActivities.contains(.capture) == true else { continue }
                LLog("transfer-server aborting transfer — capture started")
                self.abortTransfer(reason: AppModel.LibraryActivity.capture.sentence)
                return
            }
        }
    }

    private func send<Message: Encodable>(_ message: Message, on incoming: NWConnection) {
        guard let data = try? PTCoder.control(message) else {
            LLog("transfer-server could not encode control frame")
            return
        }
        incoming.send(content: data, completion: .contentProcessed { error in
            if let error { LLog("transfer-server send failed: \(error)") }
        })
    }

    // MARK: - The file list

    /// Everything that travels, in the order it will be sent: `project.json`
    /// first, then the transferable subfolders in name order.
    ///
    /// Name order is not cosmetic — it makes a resumed pull prefix-shaped, so
    /// "78%" after a reconnect means the same thing it meant before the drop.
    ///
    /// Enumeration walks exactly `ProjectArchive.transferableSubfolders`,
    /// which is what the installer accepts. Anything else would be sent over
    /// the wire for however many minutes that takes and then deleted on
    /// arrival, so both ends read the same constant.
    nonisolated static func fileManifest(folder: URL, manifestBytes: Int64) -> [PTFileEntry] {
        var entries: [PTFileEntry] = [
            PTFileEntry(relativePath: "project.json", byteCount: manifestBytes)
        ]
        let fileManager = FileManager.default
        for subfolder in ProjectArchive.transferableSubfolders {
            let root = folder.appendingPathComponent(subfolder, isDirectory: true)
            guard let walker = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles])
            else { continue }
            var found: [PTFileEntry] = []
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }
                // Relative to the project folder, so the receiving side
                // reconstructs `source/…` verbatim — which is exactly the
                // shape `installStagedProject` expects to rename into place.
                let relative = url.path.hasPrefix(folder.path + "/")
                    ? String(url.path.dropFirst(folder.path.count + 1))
                    : subfolder + "/" + url.lastPathComponent
                found.append(PTFileEntry(
                    relativePath: relative,
                    byteCount: Int64(values?.fileSize ?? 0)))
            }
            entries.append(contentsOf: found.sorted { $0.relativePath < $1.relativePath })
        }
        return entries
    }

    // MARK: - The send pump

    /// Reads each file and writes it to the socket, in chunks, with real
    /// backpressure.
    ///
    /// The backpressure is the detail that decides whether this ships. Disk
    /// reads far outrun a phone's Wi-Fi and `NWConnection.send` queues without
    /// bound, so left alone a 16 GB transfer grows a multi-gigabyte send queue
    /// and the app is jetsammed. The semaphore caps in-flight chunks; because
    /// the read loop is ours, it sits in plain code rather than inside an
    /// AppleArchive byte-stream conformance called from somebody else's
    /// worker threads.
    ///
    /// Runs on `pumpQueue` and BLOCKS there. It must never be the queue the
    /// connection's completions arrive on, or the wait deadlocks the signal.
    #if DEBUG
    /// `LL_TRANSFER_SINK=null` — read and frame every byte but never hand it to
    /// the connection. Purely a memory bisect: it is the only way to tell "the
    /// read path retains" from "the send path retains" when the app's footprint
    /// tracks bytes sent one for one and the ack window says the wire is
    /// keeping up. Kept because that question came up once and will again.
    private static let nullSink =
        ProcessInfo.processInfo.environment["LL_TRANSFER_SINK"] == "null"
    #else
    private static let nullSink = false
    #endif

    private nonisolated static func pump(
        job: TransferJob,
        connection: NWConnection,
        folder: URL,
        manifestData: Data,
        files: [PTFileEntry],
        onProgress: @escaping @Sendable (Int64, String) -> Void,
        onFinish: @escaping @Sendable (PTError?) -> Void
    ) {
        // There is no in-flight semaphore here, and there was: a counting
        // semaphore signalled from `.contentProcessed`, which is the obvious
        // design and is worth exactly nothing. That completion fires when the
        // framework has TAKEN the bytes, not when they have drained, so it
        // never bounded anything — and it brought two hazards of its own, both
        // of which fired on device in one session: a drain that took its
        // permits without handing them back killed the app on every completed
        // transfer (libdispatch traps on disposing a semaphore below its
        // initial value), and an unbounded `wait()` parked the pump forever
        // when a killed peer left completions that never fired, poisoning the
        // serial pump queue for every later transfer.
        //
        // The ack window replaces it and is strictly better: the server is
        // never more than `PTCoder.ackWindowBytes` ahead of what the client has
        // actually WRITTEN TO DISK, which bounds outstanding sends by
        // construction and means something true rather than something local.
        var sent: Int64 = 0
        var lastReport = Date.distantPast

        // A heartbeat, because the two things that can go wrong here are
        // invisible from the receiving end and identical to each other from
        // the outside: unbounded buffering (footprint climbs, then the system
        // throttles the process) and thermal throttling (footprint flat, rate
        // falls anyway). A simulator can show neither.
        let pumpStarted = Date()
        var lastHeartbeat = Date()
        var lastHeartbeatBytes: Int64 = 0
        func heartbeat(_ file: String) {
            let now = Date()
            let elapsed = now.timeIntervalSince(lastHeartbeat)
            guard elapsed >= 5 else { return }
            let rate = Double(sent - lastHeartbeatBytes) / elapsed / 1_000_000
            lastHeartbeat = now
            lastHeartbeatBytes = sent
            LLog(String(
                format: "transfer-pump %.2f GB sent, ahead %d MB, %.1f MB/s, footprint %d MB, thermal %d, %@",
                Double(sent) / 1e9, (sent - job.ackedSnapshot) / 1_000_000, rate,
                TransferMemory.footprintBytes / 1_000_000,
                ProcessInfo.processInfo.thermalState.rawValue,
                file))
            _ = pumpStarted
        }

        func write(_ data: Data) -> PTError? {
            if job.isCancelled { return PTError(code: PTError.Code.cancelled, message: "Cancelled.") }
            // The real backpressure: hold here until the client has written
            // what we already sent, to within one window. The semaphore below
            // only bounds concurrent `send` CALLS — it cannot bound bytes,
            // because `.contentProcessed` fires on hand-off rather than on
            // drain, which is how a 12 GB transfer became 12 GB of resident
            // memory before this existed.
            // The null sink sends nothing, so nothing can ever be acked — the
            // window has to stand aside or the bisect stalls at 32 MB.
            guard nullSink || job.awaitAck(
                sent: sent, window: PTCoder.ackWindowBytes, timeout: 60) else {
                return PTError(code: PTError.Code.readFailed,
                               message: "The other device stopped acknowledging data.")
            }
            if job.isCancelled { return PTError(code: PTError.Code.cancelled, message: "Cancelled.") }
            guard !nullSink else { return nil }
            // The completion is kept only to LEARN about a failure — it is not
            // waited on, because waiting on it proves nothing (see above) and
            // a peer that dies can leave it uncalled.
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { job.fail(error.localizedDescription) }
            })
            return job.failure.map { PTError(code: PTError.Code.readFailed, message: $0) }
        }

        for entry in files {
            if job.isCancelled {
                onFinish(PTError(code: PTError.Code.cancelled, message: "Cancelled."))
                return
            }
            guard let begin = try? PTCoder.control(PTFileBegin(file: entry)) else {
                onFinish(PTError(code: PTError.Code.readFailed,
                                 message: "Couldn't describe \(entry.relativePath)."))
                return
            }
            if let error = write(begin) { onFinish(error); return }
            onProgress(sent, entry.relativePath)

            // `project.json` is generated in memory and never exists on this
            // device's disk — the one entry with no file behind it.
            if entry.relativePath == "project.json" {
                var offset = 0
                while offset < manifestData.count {
                    let end = min(manifestData.count, offset + PTCoder.chunkBytes)
                    let slice = manifestData.subdata(in: offset..<end)
                    guard let frame = try? PTCoder.frame(.data, payload: slice) else {
                        onFinish(PTError(code: PTError.Code.readFailed, message: "Couldn't frame the manifest."))
                        return
                    }
                    if let error = write(frame) { onFinish(error); return }
                    sent += Int64(slice.count)
                    offset = end
                }
                onProgress(sent, entry.relativePath)
                continue
            }

            let url = folder.appendingPathComponent(entry.relativePath)
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                // Everything already landed stays staged on the client; a later
                // resume re-reconciles against a fresh file list.
                onFinish(PTError(code: PTError.Code.readFailed,
                                 message: "Couldn't read \(entry.relativePath) on the other device."))
                return
            }
            defer { try? handle.close() }

            while true {
                if job.isCancelled {
                    onFinish(PTError(code: PTError.Code.cancelled, message: "Cancelled."))
                    return
                }
                // **The autorelease pool is load-bearing, not hygiene.**
                //
                // `FileHandle.read` is Objective-C underneath and autoreleases
                // the Data it returns. A dispatch block gets an implicit pool
                // that drains when the BLOCK finishes — and this block is the
                // entire transfer, so without a pool per chunk every 4 MB read
                // in a 12 GB project is held until the last one lands.
                //
                // Measured on an iPhone 16 Pro (2026-08-27): `phys_footprint`
                // tracked bytes read one for one — 5.16 GB read, 5233 MB
                // resident — and then memory pressure collapsed flash reads
                // from 972 MB/s to 0.3 MB/s, which from the client looks
                // exactly like a network problem. Proved with
                // `LL_TRANSFER_SINK=null`: with `connection.send` never called
                // at all, the growth was identical, which is what ruled the
                // send queue out and pointed here.
                //
                // A simulator cannot show this: the payloads are kilobytes and
                // the memory is the Mac's.
                var outcome: PTError??
                autoreleasepool {
                    let chunk: Data?
                    do {
                        chunk = try handle.read(upToCount: PTCoder.chunkBytes)
                    } catch {
                        outcome = .some(PTError(
                            code: PTError.Code.readFailed,
                            message: "Couldn't read \(entry.relativePath): \(error.localizedDescription)"))
                        return
                    }
                    guard let chunk, !chunk.isEmpty else {
                        outcome = .some(nil)  // end of file
                        return
                    }
                    guard let frame = try? PTCoder.frame(.data, payload: chunk) else {
                        outcome = .some(PTError(
                            code: PTError.Code.readFailed,
                            message: "Couldn't frame \(entry.relativePath)."))
                        return
                    }
                    if let error = write(frame) {
                        outcome = .some(error)
                        return
                    }
                    sent += Int64(chunk.count)
                }
                if case .some(let error) = outcome {
                    if let error { onFinish(error); return }
                    break  // this file is done
                }
                if Date().timeIntervalSince(lastReport) > 0.2 {
                    lastReport = Date()
                    onProgress(sent, entry.relativePath)
                }
                heartbeat(entry.relativePath)
            }
        }

        // Before telling the client the job is done, wait until it has
        // acknowledged EVERY byte. This is the old drain's job done properly:
        // the drain could only prove the framework had taken the bytes, which
        // is not the same as their having landed — and it is exactly the
        // distinction that made a completed transfer look finished while
        // gigabytes were still queued in memory.
        if !nullSink, !job.awaitAck(sent: sent, window: 0, timeout: 60) {
            onFinish(PTError(code: PTError.Code.readFailed,
                             message: "The other device stopped acknowledging data."))
            return
        }
        if job.isCancelled {
            onFinish(PTError(code: PTError.Code.cancelled, message: "Cancelled."))
            return
        }
        if let failure = job.failure {
            onFinish(PTError(code: PTError.Code.readFailed, message: failure))
            return
        }
        LLog("transfer-server pump drained \(sent) bytes")
        onProgress(sent, "")
        onFinish(nil)
    }
}

/// This process's real memory footprint, the number iOS jetsams against.
///
/// Here rather than in a diagnostics file because it answers one specific
/// question that a device raises and a simulator never does: is the send pump's
/// backpressure actually holding, or is `NWConnection` buffering the whole
/// transfer? `resident_size` is the wrong number — it counts clean pages the
/// kernel can evict for free — so this is `phys_footprint`, which is what the
/// memory-limit machinery uses.
enum TransferMemory {
    static var footprintBytes: Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}

/// One in-flight transfer's shared state: a cancel latch set from the main
/// actor and read from the pump, and the first send error to land.
final class TransferJob: @unchecked Sendable {
    let captureID: UUID
    /// An `NSCondition` rather than a plain lock: the pump blocks on it waiting
    /// for the client's acknowledgement to catch up, and the receive loop
    /// wakes it. Cancellation signals it too, so a cancel never has to wait
    /// out the window's timeout.
    private let lock = NSCondition()
    private var cancelled = false
    private var failureMessage: String?
    private var ackedBytes: Int64 = 0

    init(captureID: UUID) {
        self.captureID = captureID
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.broadcast()
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func fail(_ message: String) {
        lock.lock()
        if failureMessage == nil { failureMessage = message }
        cancelled = true
        lock.broadcast()
        lock.unlock()
    }

    var failure: String? {
        lock.lock()
        defer { lock.unlock() }
        return failureMessage
    }

    /// For the pump's heartbeat only — "how far ahead of the client am I?",
    /// which is what says whether the window is doing anything.
    var ackedSnapshot: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return ackedBytes
    }

    /// The client has written this many payload bytes. Monotonic: a late ack
    /// carrying an older count is ignored rather than winding the window back.
    func recordAck(_ bytes: Int64) {
        lock.lock()
        if bytes > ackedBytes { ackedBytes = bytes }
        lock.broadcast()
        lock.unlock()
    }

    /// Blocks the pump until the client is within `window` bytes of `sent`.
    ///
    /// This is the transfer's real backpressure — the send completion is not
    /// one (see `PTCoder.ackWindowBytes`). Returns false when the wait timed
    /// out, which is a client that has stopped acking: without the timeout a
    /// stalled peer would park this queue for the life of the process.
    func awaitAck(sent: Int64, window: Int64, timeout: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !cancelled, sent - ackedBytes > window {
            guard lock.wait(until: deadline) else { return false }
        }
        return true
    }
}
#endif

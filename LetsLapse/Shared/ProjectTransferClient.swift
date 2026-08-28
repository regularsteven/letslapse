// Every platform that has a library. A Watch is a remote, never a library, so
// it is the one exclusion — the same rule as the rest of this feature.
#if !os(watchOS)
import Foundation
import Network

/// A device offering its library, as shown in the Mac's picker.
struct DiscoveredLibrary: Identifiable, Equatable {
    var id: String { name + model + pairingID }
    var name: String
    var model: String
    var projectCount: Int
    var pairingID: String
    var version: Int
    /// How this device was found. A USB-tethered iPhone presents to the Mac as
    /// a network interface, so it is discovered by exactly the same browser as
    /// a Wi-Fi one — but **what `InterfaceType` it reports is a device check,
    /// not something to assume**, so this is shown verbatim rather than
    /// translated into a "USB" badge that might be a lie.
    var interfaces: [String]
    var endpoint: NWEndpoint

    static func == (lhs: DiscoveredLibrary, rhs: DiscoveredLibrary) -> Bool {
        lhs.id == rhs.id && lhs.projectCount == rhs.projectCount
    }
}

/// The importing half of a project transfer: browse, pair, list, pull.
///
/// The pull lands in `<StorageRoot>/Incoming/<sourceProjectID>/`, file by file,
/// each written as `<name>.part` and renamed on completion — the rename IS the
/// commit, so a truncated file can never be mistaken for a whole one. Nothing
/// reaches the library until every file is down: a dropped transfer leaves a
/// staged partial, never a broken project.
@MainActor
final class ProjectTransferClient: ObservableObject {
    struct Progress: Equatable {
        var fileName: String
        var bytesReceived: Int64
        var totalBytes: Int64

        var fraction: Double? {
            guard totalBytes > 0 else { return nil }
            return min(1, Double(bytesReceived) / Double(totalBytes))
        }
    }

    enum Phase: Equatable {
        case browsing
        case enteringCode(DiscoveredLibrary)
        case connecting(DiscoveredLibrary)
        case selectingProject
        case transferring(Progress)
        /// Every file is down; the tree is being renamed into the library.
        case installing
        case done(projectName: String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .browsing
    @Published private(set) var libraries: [DiscoveredLibrary] = []
    @Published private(set) var projects: [PTProjectInfo] = []
    /// Set when browsing is impossible rather than merely empty — on macOS a
    /// denied Local Network prompt otherwise looks exactly like "no devices
    /// found", which is the single most confusing failure this link has.
    @Published private(set) var browseFailure: String?
    /// True when that failure is specifically "this copy of the app has no
    /// Local Network grant" (`NoAuth`, -65555). Worth its own flag because the
    /// generic advice — go and look in Privacy & Security — reads as
    /// already-done: the permission is granted per COPY of the app, so the list
    /// can hold several LetsLapse rows with every switch on and still refuse
    /// the one that is running.
    @Published private(set) var browseNeedsPermission = false
    @Published private(set) var peerName: String?
    /// Picker tiles that have arrived, by project. A row with no entry draws
    /// the placeholder and asks once; a row whose answer was "nothing to draw"
    /// is remembered in `thumbnailsAsked` so it never asks again.
    @Published private(set) var thumbnails: [UUID: Data] = [:]
    private var thumbnailsAsked: Set<UUID> = []

    private weak var model: AppModel?
    private var browser: NWBrowser?
    /// Rebuilds the browser whenever it has failed — see `startBrowsing`.
    private var browseKeepAlive: Task<Void, Never>?
    private var link: PTLink?
    private var connectTimeout: Task<Void, Never>?
    private var pullingCaptureID: UUID?

    init(model: AppModel? = nil) {
        self.model = model
    }

    func attach(model: AppModel) {
        self.model = model
    }

    // MARK: - Discovery

    /// Starts looking for devices, and KEEPS looking.
    ///
    /// `NWBrowser` does not recover from `.failed`, and a refused Local Network
    /// permission fails it for good — so granting the permission changed
    /// nothing until the window was closed and reopened, which is not something
    /// anybody should have to work out. Rebuilding it on a timer means the list
    /// fills in by itself a second or two after permission is granted, and the
    /// same loop covers a Wi-Fi drop or a network change for free.
    func startBrowsing() {
        guard browseKeepAlive == nil else { return }
        beginBrowse()
        browseKeepAlive = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                guard self.browseFailure != nil else { continue }
                self.beginBrowse()
            }
        }
    }

    private func beginBrowse() {
        browser?.cancel()
        browser = nil
        let parameters = NWParameters()
        // Same as the camera remote's browser, and for the same reason plus
        // one: peer-to-peer covers two devices with no shared network, and NOT
        // restricting the interface is what lets a USB-tethered device be
        // found by this code with no second transport.
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: ProjectTransferService.type, domain: nil),
            using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.browseFailure = nil
                    self?.browseNeedsPermission = false
                case .failed(let error), .waiting(let error):
                    self?.browseFailure = error.localizedDescription
                    self?.browseNeedsPermission = Self.isNoAuth(error)
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.apply(results)
                LLog("transfer-client sees \(self?.libraries.count ?? 0) device(s): "
                    + (self?.libraries.map(\.name).joined(separator: ", ") ?? ""))
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stopBrowsing() {
        browseKeepAlive?.cancel()
        browseKeepAlive = nil
        browser?.cancel()
        browser = nil
        libraries = []
    }

    /// `kDNSServiceErr_NoAuth` — mDNS's way of saying this process was refused
    /// Local Network access. Matched on the string too: the case shape of
    /// `NWError` is not something to bet a user-facing explanation on.
    private static func isNoAuth(_ error: NWError) -> Bool {
        if case .dns(let code) = error, code == -65555 { return true }
        return "\(error)".contains("NoAuth")
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        libraries = results.compactMap { result in
            guard case .bonjour(let txt) = result.metadata else { return nil }
            return DiscoveredLibrary(
                name: txt[ProjectTransferService.TXTKey.deviceName] ?? "Device",
                model: txt[ProjectTransferService.TXTKey.model] ?? "",
                projectCount: Int(txt[ProjectTransferService.TXTKey.projectCount] ?? "") ?? 0,
                pairingID: txt[ProjectTransferService.TXTKey.pairingID] ?? "",
                version: Int(txt[ProjectTransferService.TXTKey.version] ?? "") ?? 0,
                interfaces: result.interfaces.map { String(describing: $0.type) },
                endpoint: result.endpoint)
        }
        .sorted { $0.name < $1.name }

        // A device that goes away must take the selection with it, or the
        // window shows "Looking for devices…" AND an enabled Connect button
        // wired to a stale endpoint.
        if case .enteringCode(let selected) = phase,
           !libraries.contains(where: { $0.id == selected.id }) {
            phase = .browsing
        }
    }

    // MARK: - Pairing

    func select(_ library: DiscoveredLibrary) {
        LLog("transfer-client selected \(library.name) [\(library.model)]")
        phase = .enteringCode(library)
    }

    func backToBrowsing() {
        disconnect()
        phase = .browsing
    }

    func connect(to library: DiscoveredLibrary, code: String) {
        guard code.count == 6 else { return }
        disconnect()
        phase = .connecting(library)
        peerName = library.name

        LLog("transfer-client connecting to \(library.name)")
        let link = PTLink(
            endpoint: library.endpoint,
            code: code,
            stagingRoot: StorageRoot.incomingRootURL)
        self.link = link
        link.onReady = { [weak self] in
            Task { @MainActor in self?.linkBecameReady() }
        }
        link.onList = { [weak self] projects in
            Task { @MainActor in self?.receivedList(projects) }
        }
        link.onThumbnail = { [weak self] captureID, data in
            Task { @MainActor in self?.receivedThumbnail(captureID, data: data) }
        }
        link.onProgress = { [weak self] file, received, total in
            Task { @MainActor in
                self?.phase = .transferring(Progress(
                    fileName: file, bytesReceived: received, totalBytes: total))
            }
        }
        link.onDone = { [weak self] captureID in
            Task { @MainActor in await self?.install(captureID) }
        }
        link.onFailure = { [weak self] message in
            Task { @MainActor in self?.fail(message) }
        }
        link.start()

        // A WRONG PAIRING CODE NEVER FAILS THE CLIENT. The mismatch surfaces as
        // -9846 bad MAC on the *server's* first read; this side simply sits in
        // .preparing forever. Verified on device for the camera remote, and
        // this is the same handshake. Copied verbatim rather than rediscovered.
        connectTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard case .connecting = self.phase else { return }
            LLog("transfer-client pairing timed out after 8s — wrong code, or the device stopped sharing")
            self.disconnect()
            self.phase = .failed("Incorrect code — try again.")
        }
    }

    private func linkBecameReady() {
        LLog("transfer-client paired, asking for the project list")
        connectTimeout?.cancel()
        connectTimeout = nil
        link?.send(PTListRequest())
    }

    /// Asks for one row's tile, once. Called as rows appear, so a 300-project
    /// library costs the handful of decodes the human actually looked at
    /// rather than 300 up front.
    func requestThumbnailIfNeeded(for captureID: UUID) {
        guard let link, !thumbnailsAsked.contains(captureID) else { return }
        thumbnailsAsked.insert(captureID)
        link.send(PTThumbnailRequest(captureID: captureID))
    }

    private func receivedThumbnail(_ captureID: UUID, data: Data?) {
        guard let data else { return }   // nothing to draw; the placeholder stands
        thumbnails[captureID] = data
    }

    private func receivedList(_ list: [PTProjectInfo]) {
        LLog("transfer-client received \(list.count) projects")
        thumbnails = [:]
        thumbnailsAsked = []
        projects = list
        // A list arriving mid-transfer is a stale reply; don't yank the screen
        // back to the picker under a running pull.
        switch phase {
        case .transferring, .installing, .done: break
        default: phase = .selectingProject
        }
    }

    /// What this pull needs against what the library's volume has, or nil when
    /// it fits.
    ///
    /// Checked BEFORE a byte moves, which matters far more on a 128 GB iPhone
    /// than on a Mac: the alternative is discovering it 11 GB in, with the
    /// staged tree occupying the very space that ran out. The 1 GB margin is
    /// headroom for the install, which renames rather than copies but still
    /// wants somewhere to write `library.json`.
    func storageShortfall(for info: PTProjectInfo) -> String? {
        guard info.totalBytes > 0 else { return nil }
        let available = (try? StorageRoot.current.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        guard available > 0, available < info.totalBytes + 1_000_000_000 else { return nil }
        return """
            Not enough storage to import this project. It needs \
            \(LLFormat.bytes(info.totalBytes)) but only \(LLFormat.bytes(available)) is \
            available. Free up space and try again.
            """
    }

    func requestProject(_ info: PTProjectInfo) {
        guard let link else { return }
        if let shortfall = storageShortfall(for: info) {
            phase = .failed(shortfall)
            return
        }
        pullingCaptureID = info.captureID
        phase = .transferring(Progress(
            fileName: "", bytesReceived: 0, totalBytes: info.totalBytes))
        link.send(PTTransferRequest(captureID: info.captureID))
    }

    /// Stops the pull. The server stops writing, the link discards the partial
    /// tree on its own queue (nothing else may touch it), and the link stays
    /// usable for a second attempt.
    func cancelTransfer() {
        link?.cancelTransfer()
        pullingCaptureID = nil
        phase = projects.isEmpty ? .browsing : .selectingProject
    }

    func disconnect() {
        connectTimeout?.cancel()
        connectTimeout = nil
        link?.close()
        link = nil
        pullingCaptureID = nil
        peerName = nil
    }

    private func fail(_ message: String) {
        LLog("transfer-client failed: \(message)")
        // The link has already discarded whatever it had staged — that tree is
        // its property, not this object's.
        pullingCaptureID = nil
        phase = .failed(message)
    }

    private func install(_ captureID: UUID) async {
        guard let model else { return }
        LLog("transfer-client all files down, installing")
        phase = .installing
        do {
            let capture = try await model.commitIncoming(captureID: captureID)
            pullingCaptureID = nil
            phase = .done(projectName: capture?.name ?? capture?.originalName ?? "Project")
        } catch {
            fail(error.localizedDescription)
        }
    }
}

// MARK: - The link

/// One connection's worth of framing and staging, off the main actor.
///
/// Every frame is handled on the connection's own queue, in arrival order —
/// which is not an optimisation but a correctness requirement: a `fileBegin`
/// hopped to the main actor while its data frames were written here would let
/// bytes land in the wrong file. Only progress and outcomes cross to the UI.
final class PTLink: @unchecked Sendable {
    var onReady: (@Sendable () -> Void)?
    var onList: (@Sendable ([PTProjectInfo]) -> Void)?
    var onThumbnail: (@Sendable (UUID, Data?) -> Void)?
    var onProgress: (@Sendable (String, Int64, Int64) -> Void)?
    var onDone: (@Sendable (UUID) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?

    private let connection: NWConnection
    private let stagingRoot: URL
    private let queue = DispatchQueue(label: "com.regularsteven.letslapse.transfer.client")

    private var captureID: UUID?
    private var staging: URL?
    private var handle: FileHandle?
    private var partURL: URL?
    private var finalURL: URL?
    private var entryBytesWritten: Int64 = 0
    private var currentEntry: PTFileEntry?
    private var received: Int64 = 0
    private var totalBytes: Int64 = 0
    private var lastReport = Date.distantPast
    private var isFinished = false
    /// Payload bytes at the last ack sent. The server will not run more than
    /// `PTCoder.ackWindowBytes` ahead of this — it is the only backpressure
    /// the transfer has, because the send completion is not one.
    private var lastAckedBytes: Int64 = 0

    init(endpoint: NWEndpoint, code: String, stagingRoot: URL) {
        self.stagingRoot = stagingRoot
        self.connection = NWConnection(
            to: endpoint,
            using: CaptureRemotePairing.parameters(
                code: code,
                salt: ProjectTransferService.pairingSalt,
                identity: "letslapse-transfer",
                bulkTransfer: true))
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.receiveNext()
            case .failed(let error):
                self.finish(error.localizedDescription)
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send<Message: Encodable>(_ message: Message) {
        guard let data = try? PTCoder.control(message) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func cancelTransfer() {
        connection.send(content: PTCoder.cancelFrame(), completion: .contentProcessed { _ in })
        queue.async { [weak self] in self?.abandonStaging() }
    }

    func close() {
        connection.cancel()
        queue.async { [weak self] in self?.abandonStaging() }
    }

    /// The staged tree, its open handle and its `.part` all belong to this
    /// queue. Deleting the folder from anywhere else would race the writer —
    /// and the server can still be pushing frames that were already in flight
    /// when the cancel went out, so `staging` is nilled to make every one of
    /// them a no-op rather than a file re-created under a deleted folder.
    private func abandonStaging() {
        if let handle { try? handle.close() }
        handle = nil
        partURL = nil
        finalURL = nil
        currentEntry = nil
        if staging != nil, let captureID {
            AppModel.discardIncoming(captureID: captureID)
        }
        staging = nil
    }

    /// Terminal. Every failure path lands here, and every failure path drops
    /// the partial tree — with no resume in this phase, a stranded 12 GB is
    /// disk nobody can spend.
    private func finish(_ message: String) {
        guard !isFinished else { return }
        isFinished = true
        abandonStaging()
        onFailure?(message)
    }

    private func receiveNext() {
        PTFrameReader.receive(on: connection) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finish(error.localizedDescription)
            case .success(let frame):
                self.handle(frame)
                if !self.isFinished { self.receiveNext() }
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
            guard let envelope = try? PTCoder.decoder.decode(PTEnvelope.self, from: frame.payload),
                  let kind = envelope.messageKind else { return }
            switch kind {
            case .listReply:
                guard let reply = try? PTCoder.decoder.decode(PTListReply.self, from: frame.payload) else { return }
                onList?(reply.projects)
            case .thumbnail:
                guard let reply = try? PTCoder.decoder.decode(PTThumbnailReply.self, from: frame.payload) else { return }
                onThumbnail?(reply.captureID, reply.data)
            case .transferReady:
                guard let ready = try? PTCoder.decoder.decode(PTTransferReady.self, from: frame.payload) else { return }
                beginTransfer(ready)
            case .fileBegin:
                guard let begin = try? PTCoder.decoder.decode(PTFileBegin.self, from: frame.payload) else { return }
                openFile(begin.file)
            case .transferDone:
                guard let done = try? PTCoder.decoder.decode(PTTransferDone.self, from: frame.payload) else { return }
                completeTransfer(done.captureID)
            case .error:
                let decoded = try? PTCoder.decoder.decode(PTError.self, from: frame.payload)
                finish(decoded?.message ?? "The other device stopped the transfer.")
            case .listProjects, .requestTransfer, .cancel, .ack, .requestThumbnail:
                // Client-to-server vocabulary; a server sending one is
                // confused, and answering it would only confuse us both.
                break
            }
        }
    }

    // MARK: Staging

    private func beginTransfer(_ ready: PTTransferReady) {
        captureID = ready.captureID
        totalBytes = ready.totalBytes
        received = 0
        lastAckedBytes = 0
        do {
            staging = try AppModel.stageIncoming(captureID: ready.captureID)
        } catch {
            finish("Couldn't make room for the transfer: \(error.localizedDescription)")
        }
    }

    private func openFile(_ entry: PTFileEntry) {
        // The previous file, if any, is complete the moment the next one is
        // announced — the server pipelines and never waits for an ack.
        closeCurrentFile()
        guard let staging else { return }
        let destination = staging.appendingPathComponent(entry.relativePath)
        let part = destination.appendingPathExtension("part")
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: part)
            FileManager.default.createFile(atPath: part.path, contents: nil)
            handle = try FileHandle(forWritingTo: part)
            partURL = part
            finalURL = destination
            currentEntry = entry
            entryBytesWritten = 0
        } catch {
            finish("Couldn't write \(entry.relativePath): \(error.localizedDescription)")
        }
    }

    private func append(_ data: Data) {
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            finish("Couldn't write to disk: \(error.localizedDescription)")
            return
        }
        entryBytesWritten += Int64(data.count)
        received += Int64(data.count)
        // Acked AFTER the write returns, so the count means "this many bytes
        // are on disk" rather than "in flight somewhere" — which is what makes
        // it safe for the server to stop holding them.
        //
        // The second clause is not an optimisation. The server will not send
        // `transferDone` until every byte is acked, and the interval alone
        // never covers the last partial one — so without it a transfer that is
        // not an exact multiple of the interval (i.e. all of them) hangs for
        // the server's 60 s timeout and then fails as "stopped acknowledging".
        let complete = totalBytes > 0 && received >= totalBytes
        if received - lastAckedBytes >= PTCoder.ackIntervalBytes || complete {
            lastAckedBytes = received
            send(PTAck(bytesReceived: received))
        }
        if Date().timeIntervalSince(lastReport) > 0.2 {
            lastReport = Date()
            onProgress?(currentEntry?.relativePath ?? "", received, totalBytes)
        }
    }

    /// The rename is the commit. A `.part` left behind is a file that never
    /// finished and is never trusted.
    private func closeCurrentFile() {
        guard let handle, let partURL, let finalURL, let entry = currentEntry else { return }
        try? handle.close()
        self.handle = nil
        self.partURL = nil
        self.finalURL = nil
        currentEntry = nil
        guard entryBytesWritten == entry.byteCount else {
            try? FileManager.default.removeItem(at: partURL)
            finish("\(entry.relativePath) arrived incomplete.")
            return
        }
        try? FileManager.default.removeItem(at: finalURL)
        do {
            try FileManager.default.moveItem(at: partURL, to: finalURL)
        } catch {
            finish("Couldn't finish \(entry.relativePath): \(error.localizedDescription)")
        }
    }

    /// Deliberately does NOT latch `isFinished`: the receive loop stays armed
    /// so the same link can list again and pull a second project. Only a
    /// failure is terminal.
    private func completeTransfer(_ id: UUID) {
        closeCurrentFile()
        guard !isFinished else { return }
        // Ownership of the staged tree passes to the installer here. Without
        // this, closing the window mid-install would send `abandonStaging`
        // after the folder had already become somebody else's job.
        staging = nil
        onProgress?("", totalBytes, totalBytes)
        onDone?(id)
    }

}
#endif

import Combine
import Foundation
import LetsLapseKit
import Network
#if os(iOS)
import UIKit
#endif

// MARK: - Nearby originals (2026-09-28)
//
// docs/nearby-originals-plan.md. A project that is a preview here (records
// and poster from PicPlace) whose originals are on another device of the
// same PicPlace account, on the same network, gets *Import originals from
// iPhone 18 Pro*: the files come straight over the local network, with no
// pairing code — the account is the trust.
//
// One service per app, app-wide (the code-based transfer server is armed by
// the Projects and Gallery views; this one feeds the editor). While this
// device is signed in with its library connected and holds the account's
// nearby key (PicPlaceNearbyKey.swift) it:
//
// - **listens** (unless Settings ▸ PicPlace ▸ *Let my devices import
//   originals from this one* is off) on `_letslapse-near._tcp`: a random
//   Bonjour name, a TXT record of a version and a daily tag only the
//   account's devices recognise — no name, no account, no project count;
// - **browses** for the same, and asks each device whose tag it recognises
//   which of the projects on screen here it holds (`want`);
// - **answers** the same question from them, and **sends** the originals
//   and blends of a project one of them asks for — only projects on
//   PicPlace in this account, only their heavy files, never while shooting.
//
// Local network only (no AWDL: its advertising cost a 5 GB pull most of its
// speed on 2026-08-29). An iPhone serves only while LetsLapse is open (N3):
// the service stands down in the background, as the transfer server does.
// The files ride the project transfer's frames and pump
// (`ProjectTransferServer.pump`): every lesson of that code — the ack
// window, the autorelease pool per chunk — comes with them.

@MainActor
final class NearbyService: ObservableObject {

    static let serviceType = "_letslapse-near._tcp"
    static let protocolVersion = 1
    static let tlsIdentity = "letslapse-nearby"

    /// Settings ▸ PicPlace ▸ *Let my devices import originals from this one*
    /// — on by default (N16). `-letslapse.nearby.serve NO` as a launch
    /// argument turns it off for a run without writing the setting.
    static let serveKey = "letslapse.nearby.serve"
    static var serveEnabled: Bool { UserDefaults.standard.object(forKey: serveKey) as? Bool ?? true }

    /// How long an answer stands before a page that appears asks again.
    static let answerLifetime: TimeInterval = 60
    /// How long a project stays wanted after its page last asked.
    static let wantLifetime: TimeInterval = 10 * 60

    /// What this device's links are keyed with — derived, never the key.
    struct Trust: Equatable {
        var key: Data
        var psk: Data
        var serverID: String
        var userUUID: String
        var deviceID: String
        var keyID: String
    }

    /// A device of this account seen on the network.
    struct Peer: Equatable {
        /// Its Bonjour instance name.
        let id: String
        var endpoint: NWEndpoint
        /// What it said it is, once a link has asked it.
        var hello: NearbyHello?
    }

    struct Answer: Equatable {
        var row: NearbyHoldingsRow
        var at: Date
    }

    @Published private(set) var isRunning = false
    @Published private(set) var peers: [String: Peer] = [:]
    /// Origin id → peer → what it holds of that project.
    @Published private(set) var answers: [UUID: [String: Answer]] = [:]
    /// A send in flight from this device, and to whom.
    @Published private(set) var serving: ProjectTransferServer.TransferProgress?
    @Published private(set) var servingTo: String?
    /// The last import that failed, by capture id — its sentence, for the
    /// preview page's line.
    @Published private(set) var importErrors: [UUID: String] = [:]
    /// Why the service can't see the network (Local Network access refused).
    @Published private(set) var failure: String?

    unowned let model: AppModel

    private var trust: Trust?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var browserRebuild: Task<Void, Never>?
    /// The wait before the next rebuild of a failed browser: 5 s, doubling
    /// to a minute while it keeps failing (a refused Local Network
    /// permission fails every time), back to 5 s once one works.
    private var browserRetryDelay: TimeInterval = 5
    /// The last failure logged, so a refusal is logged once, not every retry.
    private var loggedFailure: String?
    private var sessions: [ObjectIdentifier: NearbyServerSession] = [:]
    /// Origin id → when a page last asked.
    private var wanted: [UUID: Date] = [:]
    private var pendingAsks: Set<UUID> = []
    private var askFlush: Task<Void, Never>?
    /// Random per run: the default instance name would be the device's name.
    private let instanceName = "LetsLapse " + String(UUID().uuidString.prefix(8))
    private var advertisedDay = ""
    private var sceneActive = true
    private var observers = Set<AnyCancellable>()
    private var serveJob: TransferJob?
    private var serveSession: NearbyServerSession?
    private var serveOrigin: UUID?
    private var captureWatch: Task<Void, Never>?
    private let networkQueue = DispatchQueue(label: "com.regularsteven.letslapse.nearby.net")
    private let pumpQueue = DispatchQueue(label: "com.regularsteven.letslapse.nearby.pump", qos: .utility)
    #if DEBUG
    /// `LL_NEARBY_IMPORT=<latest|uuid>` presses Import once a device offers it.
    private var importHook = ProcessInfo.processInfo.environment["LL_NEARBY_IMPORT"]
    #endif

    init(model: AppModel) {
        self.model = model
        let picplace = model.picplace
        // `@Published` sends before the value changes: every trigger
        // re-reads the state a beat later.
        picplace.$nearbyKey.map { $0?.keyID }.removeDuplicates()
            .sink { [weak self] _ in self?.scheduleUpdate() }.store(in: &observers)
        picplace.$profile.map { $0?.accountKey }.removeDuplicates()
            .sink { [weak self] _ in self?.scheduleUpdate() }.store(in: &observers)
        picplace.$binding.map { $0?.accountKey }.removeDuplicates()
            .sink { [weak self] _ in self?.scheduleUpdate() }.store(in: &observers)
        picplace.$serverHasLibraries.removeDuplicates()
            .sink { [weak self] _ in self?.scheduleUpdate() }.store(in: &observers)
        // The Settings switch writes the default; the service follows it.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .map { _ in NearbyService.serveEnabled }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }.store(in: &observers)
    }

    // MARK: - Running

    func scheduleUpdate() {
        Task { @MainActor [weak self] in self?.update() }
    }

    /// Starts, restarts or stops the listener and the browser to match the
    /// session, the key, the switch and the scene.
    func update() {
        let desired = currentTrust()
        if desired != trust {
            stopAll()
            trust = desired
            if let desired { LLog("nearby: on — key \(desired.keyID), \(Self.serveEnabled ? "serving and browsing" : "browsing only")") }
        }
        guard let trust else { return }
        isRunning = true
        if browser == nil, browserRebuild == nil { startBrowsing() }
        if Self.serveEnabled {
            if listener == nil { startListening(trust) } else { readvertiseIfDayChanged(trust) }
        } else if listener != nil {
            stopListening()
        }
        #if DEBUG
        if let hook = importHook, let capture = hookCapture(hook) { want(capture.id) }
        #endif
    }

    /// The Settings switch.
    func setServeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.serveKey)
        update()
    }

    /// iOS: the service stands down in the background and comes back in
    /// front (a phone serves only while LetsLapse is open, N3).
    func setSceneActive(_ active: Bool) {
        guard sceneActive != active else { return }
        sceneActive = active
        update()
    }

    /// A library switch: the old model's service goes quiet for good.
    func shutDown() {
        observers.removeAll()
        sceneActive = false
        stopAll()
        trust = nil
    }

    private func currentTrust() -> Trust? {
        let picplace = model.picplace
        guard sceneActive, picplace.canSync, let profile = picplace.profile,
              let held = picplace.nearbyKey, held.isFresh else { return nil }
        let serverID = profile.serverID ?? profile.host
        return Trust(key: held.key,
                     psk: NearbyTrust.psk(key: held.key, serverID: serverID, userUUID: profile.userUUID),
                     serverID: serverID, userUUID: profile.userUUID, deviceID: profile.deviceID, keyID: held.keyID)
    }

    private func stopAll() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        browserRebuild?.cancel()
        browserRebuild = nil
        abortServe(reason: nil)
        for session in sessions.values { session.connection.cancel() }
        sessions = [:]
        peers = [:]
        answers = [:]
        if isRunning { LLog("nearby: off") }
        isRunning = false
    }

    private func hello(_ trust: Trust) -> NearbyHello {
        NearbyHello(version: Self.protocolVersion, serverID: trust.serverID, userUUID: trust.userUUID,
                    deviceID: trust.deviceID, name: DeviceName.current, platform: PicPlaceController.platform)
    }

    private func linkParameters(_ trust: Trust, bulk: Bool) -> NWParameters {
        let parameters = CaptureRemotePairing.parameters(key: trust.psk, identity: Self.tlsIdentity, bulkTransfer: bulk)
        parameters.includePeerToPeer = false
        return parameters
    }

    // MARK: - Listening

    private func startListening(_ trust: Trust) {
        do {
            let parameters = linkParameters(trust, bulk: true)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            advertisedDay = NearbyTrust.dayString(Date())
            listener.service = NWListener.Service(name: instanceName, type: Self.serviceType, domain: nil,
                                                  txtRecord: txtRecord(trust))
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerStateChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: networkQueue)
            self.listener = listener
        } catch {
            failure = error.localizedDescription
            LLog("nearby: could not listen — \(error)")
        }
    }

    private func stopListening() {
        abortServe(reason: nil)
        listener?.cancel()
        listener = nil
    }

    private func txtRecord(_ trust: Trust) -> NWTXTRecord {
        var txt = NWTXTRecord()
        txt["v"] = String(Self.protocolVersion)
        txt["t"] = NearbyTrust.discoveryTag(key: trust.key, day: Date())
        return txt
    }

    /// The tag changes at midnight UTC; peers accept yesterday's, so a
    /// listener that ran across it is found until its next foreground.
    private func readvertiseIfDayChanged(_ trust: Trust) {
        let today = NearbyTrust.dayString(Date())
        guard let listener, today != advertisedDay else { return }
        advertisedDay = today
        listener.service = NWListener.Service(name: instanceName, type: Self.serviceType, domain: nil,
                                              txtRecord: txtRecord(trust))
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            failure = nil
            LLog("nearby: listening as “\(instanceName)”")
        case .failed(let error):
            // Most likely Local Network access refused.
            failure = Self.isNoAuth(error) ? Self.noLocalNetwork : error.localizedDescription
            logFailureOnce("listener failed — \(error)")
            listener = nil
        default:
            break
        }
    }

    static let noLocalNetwork = "LetsLapse can't use the local network — allow it in Settings ▸ Privacy & Security ▸ Local Network."

    private func logFailureOnce(_ line: String) {
        guard line != loggedFailure else { return }
        loggedFailure = line
        LLog("nearby: \(line)")
    }

    static func isNoAuth(_ error: NWError) -> Bool {
        if case .dns(let code) = error, code == -65555 { return true }
        return "\(error)".contains("NoAuth")
    }

    // MARK: - Browsing

    private func startBrowsing() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.browserStateChanged(state) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.apply(results) }
        }
        browser.start(queue: networkQueue)
        self.browser = browser
    }

    private func browserStateChanged(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            if failure == Self.noLocalNetwork { failure = nil }
            if loggedFailure != nil { LLog("nearby: browsing again") }
            loggedFailure = nil
            browserRetryDelay = 5
        case .waiting(let error):
            if Self.isNoAuth(error) { failure = Self.noLocalNetwork }
        case .failed(let error):
            // An `NWBrowser` never recovers from `.failed` — a refused Local
            // Network permission killed the import window's browsing for
            // good until it was rebuilt (2026-08-27). So it is rebuilt, less
            // often each time it fails again.
            failure = Self.isNoAuth(error) ? Self.noLocalNetwork : error.localizedDescription
            logFailureOnce("browser failed — \(error); rebuilding it, less often each time (up to a minute)")
            browser?.cancel()
            browser = nil
            let delay = browserRetryDelay
            browserRetryDelay = min(60, browserRetryDelay * 2)
            browserRebuild = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.browserRebuild = nil
                self.update()
            }
        default:
            break
        }
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        guard let trust else { return }
        var seen: [String: NWEndpoint] = [:]
        var strangers = false
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint, name != instanceName else { continue }
            guard case let .bonjour(txt) = result.metadata, txt["v"] == String(Self.protocolVersion),
                  let tag = txt["t"] else { continue }
            guard NearbyTrust.accepts(tag: tag, key: trust.key) else {
                strangers = true
                continue
            }
            seen[name] = result.endpoint
        }
        // Another account's device — or one of this account's with a newer
        // key: one `/status` read (rate-limited) tells which.
        if strangers { model.picplace.nearbyKeyMayBeStale() }
        for id in peers.keys where seen[id] == nil {
            LLog("nearby: \(peers[id]?.hello?.name ?? id) left")
            peers[id] = nil
            for origin in answers.keys { answers[origin]?[id] = nil }
        }
        let recent = wanted.filter { Date().timeIntervalSince($0.value) < Self.wantLifetime }.map(\.key)
        for (id, endpoint) in seen where peers[id] == nil {
            peers[id] = Peer(id: id, endpoint: endpoint)
            LLog("nearby: found “\(id)”")
            // Introduce ourselves either way, so the peer's name is known.
            ask(id, about: recent)
        }
    }

    // MARK: - Asking

    /// A page showing `captureID` — the preview page, the project card, a
    /// prompt — wants to know whether a device nearby holds what it lacks.
    /// Gathered for a beat and asked of every device found; an answer
    /// younger than a minute is not asked again.
    func want(_ captureID: UUID) {
        guard let capture = model.capture(id: captureID) else { return }
        let origin = model.originID(of: capture)
        let last = wanted[origin]
        wanted[origin] = Date()
        guard trust != nil, !peers.isEmpty else { return }
        if let last, Date().timeIntervalSince(last) < Self.answerLifetime, answers[origin] != nil { return }
        pendingAsks.insert(origin)
        guard askFlush == nil else { return }
        askFlush = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self else { return }
            let origins = Array(self.pendingAsks)
            self.pendingAsks.removeAll()
            self.askFlush = nil
            for id in self.peers.keys { self.ask(id, about: origins) }
        }
    }

    private func ask(_ peerID: String, about origins: [UUID]) {
        guard let trust, let peer = peers[peerID] else { return }
        let link = NearbyQueryLink(endpoint: peer.endpoint, parameters: linkParameters(trust, bulk: false),
                                   hello: hello(trust), origins: origins, queue: networkQueue)
        link.run { [weak self] outcome in
            Task { @MainActor in self?.received(outcome, from: peerID, asked: origins) }
        }
    }

    private func received(_ outcome: Result<(NearbyHello, [NearbyHoldingsRow]), Error>, from peerID: String, asked: [UUID]) {
        guard var peer = peers[peerID], let trust else { return }
        switch outcome {
        case .success(let (hello, rows)):
            guard hello.version == Self.protocolVersion,
                  hello.serverID.lowercased() == trust.serverID.lowercased(),
                  hello.userUUID.lowercased() == trust.userUUID.lowercased() else {
                LLog("nearby: “\(peerID)” is not this account's — ignored")
                peers[peerID] = nil
                return
            }
            if peer.hello == nil { LLog("nearby: “\(peerID)” is \(hello.name) (\(hello.platform))") }
            peer.hello = hello
            peers[peerID] = peer
            let now = Date()
            let answered = Set(rows.map(\.originID))
            for row in rows { answers[row.originID, default: [:]][peerID] = Answer(row: row, at: now) }
            for origin in asked where !answered.contains(origin) { answers[origin]?[peerID] = nil }
            if !asked.isEmpty {
                let complete = rows.filter { $0.hasAllOriginals && $0.busy == nil }.count
                LLog("nearby: \(hello.name) holds \(rows.count) of \(asked.count) project(s) asked about — \(complete) with every original")
            }
            #if DEBUG
            runImportHook()
            #endif
        case .failure(let error):
            LLog("nearby: asking \(peer.hello?.name ?? "“\(peerID)”") failed — \(error.localizedDescription)")
            for origin in asked { answers[origin]?[peerID] = nil }
        }
    }

    // MARK: - Offers

    /// A device nearby that holds every file `shortfall` names and can send
    /// now — a Mac first (it never locks), else the first to answer (N14).
    func offer(for capture: AppModel.CaptureProject, shortfall: ProjectHoldings.Shortfall) -> NearbyOffer? {
        guard trust != nil else { return nil }
        let origin = model.originID(of: capture)
        guard let byPeer = answers[origin], !byPeer.isEmpty else { return nil }
        let blendFiles = Set(model.blends(for: capture).filter { shortfall.blendIDs.contains($0.id) }.map(\.outputFileName))
        let candidates: [(peer: Peer, hello: NearbyHello, answer: Answer)] = byPeer.compactMap { id, answer in
            guard let peer = peers[id], let hello = peer.hello, answer.row.busy == nil else { return nil }
            guard !shortfall.needsOriginals || answer.row.hasAllOriginals else { return nil }
            guard blendFiles.isSubset(of: Set(answer.row.blendFiles)) else { return nil }
            return (peer, hello, answer)
        }
        guard let best = candidates.min(by: { a, b in
            let aMac = a.hello.platform == "macos", bMac = b.hello.platform == "macos"
            if aMac != bMac { return aMac }
            return a.answer.at < b.answer.at
        }) else { return nil }
        return NearbyOffer(peerID: best.peer.id, deviceName: best.hello.name, platform: best.hello.platform)
    }

    func importError(for captureID: UUID) -> String? { importErrors[captureID] }

    func clearImportError(_ captureID: UUID) { importErrors[captureID] = nil }

    // MARK: - Importing (the asking side)

    /// Brings the files `shortfall` names from the device `offer` names into
    /// this project's folder, each checked against this device's own
    /// `assets.ndjson` hash (N8) and moved into place. Throws with the
    /// serving device's sentence when it refuses; `CancellationError` when
    /// stopped — the files that landed stay, and the next press asks only
    /// for the rest.
    func importFiles(capture: AppModel.CaptureProject, shortfall: ProjectHoldings.Shortfall, from offer: NearbyOffer,
                     progress: @escaping @MainActor (PicPlaceSyncProgress) -> Void) async throws -> (files: Int, bytes: Int64) {
        clearImportError(capture.id)
        guard let trust, let peer = peers[offer.peerID] else { throw NearbyError.gone(offer.deviceName) }
        let folder = model.projectFolderURL(for: capture)
        let origin = model.originID(of: capture)
        let missing = model.holdings(for: capture).originals.filter { !$0.isHere && shortfall.originals.contains($0.name) }
        let blends = model.blends(for: capture).filter { shortfall.blendIDs.contains($0.id) }.map(\.outputFileName)
        let request = NearbyRequestFiles(originID: origin, originals: missing.map(\.files), blends: blends)
        let recorded = await Task.detached(priority: .utility) { AssetRecords.load(inProjectFolder: folder) }.value
        var expected: [String: String] = [:]
        for record in recorded.ordered { if let hash = record.hash { expected[record.name] = hash } }
        let link = NearbyImportLink(endpoint: peer.endpoint, parameters: linkParameters(trust, bulk: true),
                                    hello: hello(trust), request: request, folder: folder,
                                    expectedHashes: expected, source: offer.deviceName, queue: networkQueue)
        LLog("nearby: importing \(missing.count) original(s) and \(blends.count) blend(s) of \(capture.displayTitle) from \(offer.deviceName)")
        let outcome: NearbyImportLink.Outcome
        do {
            outcome = try await withTaskCancellationHandler {
                try await link.run { snapshot in Task { @MainActor in progress(snapshot) } }
            } onCancel: {
                link.cancel()
            }
        } catch is CancellationError {
            let partial = link.landedSoFar()
            if !partial.isEmpty { try? model.assetStore.noteHashes(partial, inProjectFolder: folder) }
            LLog("nearby: import of \(capture.displayTitle) stopped — \(partial.count) file(s) in place")
            throw CancellationError()
        } catch {
            let partial = link.landedSoFar()
            if !partial.isEmpty { try? model.assetStore.noteHashes(partial, inProjectFolder: folder) }
            let sentence = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            importErrors[capture.id] = sentence
            answers[origin]?[offer.peerID] = nil
            LLog("nearby: import of \(capture.displayTitle) from \(offer.deviceName) failed — \(sentence)")
            throw error
        }
        try? model.assetStore.noteHashes(outcome.landed, inProjectFolder: folder)
        LLog("nearby: imported \(outcome.landed.count) file(s), \(LLFormat.bytes(outcome.bytes)) of \(capture.displayTitle) from \(offer.deviceName)")
        return (outcome.landed.count, outcome.bytes)
    }

    // MARK: - Serving (the holding side)

    private func accept(_ connection: NWConnection) {
        let session = NearbyServerSession(connection: connection)
        sessions[ObjectIdentifier(session)] = session
        connection.stateUpdateHandler = { [weak self, weak session] state in
            Task { @MainActor in
                guard let self, let session else { return }
                self.sessionStateChanged(state, session)
            }
        }
        connection.start(queue: networkQueue)
        // A peer that says nothing is let go.
        Task { @MainActor [weak self, weak session] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, let session, session.hello == nil else { return }
            self.close(session)
        }
    }

    private func sessionStateChanged(_ state: NWConnection.State, _ session: NearbyServerSession) {
        switch state {
        case .ready:
            receiveNext(session)
        case .failed(let error):
            // A key that isn't this account's lands here (`-9846 bad MAC`),
            // as does the losing half of a cabled device's two connections.
            LLog("nearby: a link failed — \(error)")
            close(session)
        case .cancelled:
            close(session)
        default:
            break
        }
    }

    private func close(_ session: NearbyServerSession) {
        guard sessions.removeValue(forKey: ObjectIdentifier(session)) != nil else { return }
        if serveSession === session { abortServe(reason: nil) }
        session.connection.cancel()
    }

    private func receiveNext(_ session: NearbyServerSession) {
        PTFrameReader.receive(on: session.connection) { [weak self, weak session] result in
            Task { @MainActor in
                guard let self, let session, self.sessions[ObjectIdentifier(session)] != nil else { return }
                switch result {
                case .failure:
                    self.close(session)
                case .success(let frame):
                    self.handle(frame, from: session)
                    if self.sessions[ObjectIdentifier(session)] != nil { self.receiveNext(session) }
                }
            }
        }
    }

    private func handle(_ frame: PTFrame, from session: NearbyServerSession) {
        switch frame.type {
        case .cancel:
            if serveSession === session { abortServe(reason: nil) }
        case .data:
            break
        case .control:
            guard let kind = NearbyCoding.kind(of: frame.payload) else { return }
            if kind != .hello, session.hello == nil {
                close(session)
                return
            }
            switch kind {
            case .hello:
                guard let hello = try? PTCoder.decoder.decode(NearbyHello.self, from: frame.payload),
                      let trust, hello.version == Self.protocolVersion,
                      hello.serverID.lowercased() == trust.serverID.lowercased(),
                      hello.userUUID.lowercased() == trust.userUUID.lowercased() else {
                    LLog("nearby: a link's hello is not this account's — closed")
                    close(session)
                    return
                }
                session.hello = hello
                send(self.hello(trust), on: session)
            case .holdings:
                guard let query = try? PTCoder.decoder.decode(NearbyHoldingsQuery.self, from: frame.payload) else { return }
                answerHoldings(query, session: session)
            case .requestFiles:
                guard let request = try? PTCoder.decoder.decode(NearbyRequestFiles.self, from: frame.payload) else { return }
                serve(request, session: session)
            case .ack:
                guard serveSession === session,
                      let ack = try? PTCoder.decoder.decode(PTAck.self, from: frame.payload) else { return }
                serveJob?.recordAck(ack.bytesReceived)
            case .holdingsReply, .filesReady, .fileBegin, .filesDone, .error:
                break
            }
        }
    }

    private func send<Message: Encodable>(_ message: Message, on session: NearbyServerSession) {
        guard let data = try? PTCoder.control(message) else { return }
        session.connection.send(content: data, completion: .contentProcessed { error in
            if let error { LLog("nearby: send failed — \(error)") }
        })
    }

    /// The live project here holding `origin` — a transferred copy's local
    /// id is not its origin id (the 2026-09-25 trap), so by the index first.
    private func localCapture(origin: UUID) -> AppModel.CaptureProject? {
        if let id = (try? model.libraryIndex?.projectID(originID: origin)) ?? nil, let capture = model.capture(id: id) {
            return capture
        }
        return model.capture(id: origin)
    }

    /// The account channel serves only projects on PicPlace (N2).
    private func isOnPicPlace(_ origin: UUID) -> Bool {
        guard let record = model.picplace.records[origin] else { return false }
        return record.revision > 0 || record.policy == "pull"
    }

    /// Why nothing can be sent now — a sentence the other device shows.
    private func busyReason() -> String? {
        if serveJob != nil { return "\(DeviceName.current) is already sending originals." }
        if model.activeLibraryActivities.contains(.servingTransfer) {
            return AppModel.LibraryActivity.servingTransfer.sentence
        }
        return model.transferBlockReason
    }

    private func answerHoldings(_ query: NearbyHoldingsQuery, session: NearbyServerSession) {
        let busy = busyReason() ?? (Self.serveEnabled ? nil : "\(DeviceName.current) isn't sharing its originals.")
        var jobs: [(origin: UUID, inputs: AppModel.HoldingsInputs)] = []
        for origin in query.originIDs.prefix(200) {
            guard isOnPicPlace(origin), let capture = localCapture(origin: origin) else { continue }
            jobs.append((origin, model.holdingsInputs(for: capture)))
        }
        Task { @MainActor [weak self, weak session] in
            let rows = await Task.detached(priority: .userInitiated) {
                jobs.map { job -> NearbyHoldingsRow in
                    let holdings = AppModel.buildHoldings(job.inputs)
                    return NearbyHoldingsRow(originID: job.origin, hasAllOriginals: holdings.hasAllOriginals,
                                             originalsBytes: nil,
                                             blendFiles: holdings.blends.filter(\.isHere).map(\.fileName),
                                             busy: busy)
                }
            }.value
            guard let self, let session, self.sessions[ObjectIdentifier(session)] != nil else { return }
            self.send(NearbyHoldingsReply(rows: rows), on: session)
        }
    }

    /// `path` when it names a heavy file of `kind` inside `folder` — never
    /// anything else, whatever a peer asks for.
    nonisolated static func servable(_ path: String, kind: PicPlaceOriginalsCheck.Kind, in folder: URL) -> Int64? {
        guard NearbyTrust.isSafeRelativePath(path), PicPlaceSyncInventory.heavyKind(path) == kind else { return nil }
        let url = folder.appendingPathComponent(path)
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize else { return nil }
        return Int64(size)
    }

    private func serve(_ request: NearbyRequestFiles, session: NearbyServerSession) {
        if let busy = busyReason() {
            send(PTError.busy(busy), on: session)
            return
        }
        guard Self.serveEnabled else {
            send(PTError.busy("\(DeviceName.current) isn't sharing its originals."), on: session)
            return
        }
        guard isOnPicPlace(request.originID), let capture = localCapture(origin: request.originID) else {
            send(PTError.notFound(), on: session)
            return
        }
        let folder = model.projectFolderURL(for: capture)
        let records = model.assetStore.records(inProjectFolder: folder)
        func entry(_ path: String, _ bytes: Int64) -> NearbyFileEntry {
            // A recorded hash only when the file is still the size recorded.
            let record = records[path]
            let hash = record?.bytes == bytes ? record?.hash : nil
            return NearbyFileEntry(relativePath: path, byteCount: bytes, sha256: hash)
        }
        var files: [NearbyFileEntry] = []
        for group in request.originals {
            guard let found = group.lazy.compactMap({ path in Self.servable(path, kind: .source, in: folder).map { (path, $0) } }).first else {
                send(PTError(code: PTError.Code.notFound, message: "\(DeviceName.current) no longer holds all of the originals."), on: session)
                return
            }
            files.append(entry(found.0, found.1))
        }
        for path in request.blends {
            guard let bytes = Self.servable(path, kind: .blend, in: folder) else {
                send(PTError(code: PTError.Code.notFound, message: "\(DeviceName.current) no longer holds that blend."), on: session)
                return
            }
            files.append(entry(path, bytes))
        }
        guard !files.isEmpty else {
            send(PTError.notFound(), on: session)
            return
        }
        let ready = NearbyFilesReady(originID: request.originID, files: files)
        send(ready, on: session)

        let job = TransferJob(captureID: capture.id)
        serveJob = job
        serveSession = session
        serveOrigin = request.originID
        model.beginActivity(.servingNearby)
        #if os(iOS)
        // A phone that locks mid-send stops sending (N3).
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
        serving = ProjectTransferServer.TransferProgress(projectName: capture.displayTitle, totalBytes: ready.totalBytes,
                                                        bytesTransferred: 0, currentFile: "")
        servingTo = session.hello?.name
        startCaptureWatch()
        LLog("nearby: sending \(files.count) file(s), \(LLFormat.bytes(ready.totalBytes)) of \(capture.displayTitle) to \(session.hello?.name ?? "a device")")
        let entries = files.map { PTFileEntry(relativePath: $0.relativePath, byteCount: $0.byteCount) }
        let connection = session.connection
        let service = WeakService(self)
        pumpQueue.async {
            ProjectTransferServer.pump(
                job: job, connection: connection, folder: folder, manifestData: Data(), files: entries,
                onProgress: { bytes, file in
                    Task { @MainActor in service.value?.serveProgressed(job, bytes: bytes, file: file) }
                },
                onFinish: { error in
                    Task { @MainActor in service.value?.finishServe(job, error: error) }
                })
        }
    }

    private func serveProgressed(_ job: TransferJob, bytes: Int64, file: String) {
        guard serveJob === job else { return }
        serving?.bytesTransferred = bytes
        serving?.currentFile = file
    }

    private func finishServe(_ job: TransferJob, error: PTError?) {
        guard serveJob === job, let session = serveSession, let origin = serveOrigin else { return }
        if let error {
            if error.code != PTError.Code.cancelled { send(error, on: session) }
            LLog("nearby: send stopped — \(error.message)")
        } else {
            send(NearbyFilesDone(originID: origin), on: session)
            LLog("nearby: sent \(LLFormat.bytes(serving?.totalBytes ?? 0)) to \(servingTo ?? "a device")")
        }
        clearServe()
    }

    /// The chip's Stop, a capture starting, the scene going: the pump stops
    /// between chunks and the other device keeps what landed.
    func stopServing() {
        abortServe(reason: "\(DeviceName.current) stopped sending.")
    }

    private func abortServe(reason: String?) {
        guard let job = serveJob else { return }
        job.cancel()
        if let reason, let session = serveSession { send(PTError.busy(reason), on: session) }
        clearServe()
    }

    private func clearServe() {
        guard serveJob != nil else { return }
        serveJob = nil
        serveSession = nil
        serveOrigin = nil
        serving = nil
        servingTo = nil
        captureWatch?.cancel()
        captureWatch = nil
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
        model.endActivity(.servingNearby)
    }

    /// A shoot outranks a send (the transfer server's rule).
    private func startCaptureWatch() {
        captureWatch?.cancel()
        captureWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.serveJob != nil else { return }
                guard self.model.activeLibraryActivities.contains(.capture) else { continue }
                LLog("nearby: send stopped — a shoot started")
                self.abortServe(reason: AppModel.LibraryActivity.capture.sentence)
                return
            }
        }
    }

    // MARK: - DEBUG

    #if DEBUG
    private func hookCapture(_ hook: String) -> AppModel.CaptureProject? {
        hook == "latest" ? model.newestCapture() : UUID(uuidString: hook).flatMap { model.capture(id: $0) }
    }

    /// `LL_NEARBY_IMPORT`: once a device offers the project's originals,
    /// press Import — once per run.
    private func runImportHook() {
        guard let hook = importHook, let capture = hookCapture(hook),
              let shortfall = model.availability(of: .pixelEdit, for: capture).shortfall,
              offer(for: capture, shortfall: shortfall) != nil else { return }
        importHook = nil
        LLog("LL_NEARBY_IMPORT: pressing Import for \(capture.displayTitle)")
        model.picplace.fetch(capture, shortfall: shortfall)
    }
    #endif
}

/// The service, weakly, for the pump's callbacks on its own queue.
private final class WeakService: @unchecked Sendable {
    weak var value: NearbyService?
    init(_ value: NearbyService) { self.value = value }
}

/// One connection to this device's listener.
final class NearbyServerSession {
    let connection: NWConnection
    var hello: NearbyHello?

    init(connection: NWConnection) {
        self.connection = connection
    }
}

enum NearbyError: LocalizedError {
    case gone(String)
    case timedOut
    case refused(String)
    case damaged(String)
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .gone(let name): return "\(name) isn't nearby any more."
        case .timedOut: return "The other device stopped answering."
        case .refused(let sentence): return sentence
        case .damaged(let file): return "\(file) arrived damaged — it doesn't match its fingerprint. Try again."
        case .unexpected(let what): return what
        }
    }
}

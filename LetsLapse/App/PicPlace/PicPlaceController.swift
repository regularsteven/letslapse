import Foundation
import SwiftUI
import LetsLapseKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The app's side of PicPlace (docs/picplace-sync-v1.md, v2 plan §3–4): who
/// is signed in, which account the OPEN LIBRARY belongs to, which projects
/// this library has pushed and how each push is going. Owned by `AppModel`
/// (`model.picplace`); the cards observe it directly.
///
/// Two kinds of state, in two homes (v2 plan §3.2). **Library state** lives
/// in the library: the binding (`PicPlace/account.json`, which account this
/// library is), and the sync records (`PicPlace/sync-state.json`, keyed by
/// `originID`). **Install state** lives with the install: the tokens (the
/// Keychain, one item per account) and the last account signed in on an
/// unbound library (`UserDefaults`). The server is the truth for what is
/// actually there, which the card re-reads when it appears.
///
/// The session at launch follows the library: bound + tokens for that
/// account → signed in silently; bound + no tokens → "Sign in as …", other
/// accounts refused; unbound → the last sign-in, and the offer to connect.
@MainActor
final class PicPlaceController: ObservableObject {

    struct Profile: Codable, Equatable {
        var username: String
        var name: String?
        var userUUID: String
        var deviceID: String          // the server's id for this install under this account
        var deviceName: String
        var server: String
        var serverID: String?
        var serverEnvironment: String?

        var host: String { PicPlaceConfiguration.host(of: server) }
        var accountKey: String { PicPlaceBindingRecord.accountKey(host: host, userUUID: userUUID) }
    }

    struct Usage: Equatable {
        var projects: Int
        var bytes: Int64
    }

    struct FolderSummary: Equatable {
        var files: Int
        var bytes: Int64
    }

    /// How the open library relates to the session.
    enum LibraryLink: Equatable {
        /// No `PicPlace/account.json`: the library belongs to nobody yet.
        case unbound
        /// Bound to the signed-in account — or bound and nobody signed in.
        case bound
        /// Bound to another account or server than the session's.
        case mismatch
    }

    enum ProjectState: Equatable {
        case signedOut
        /// Signed in, but this library is not (or not this account's): a sync
        /// would push into the wrong place.
        case notConnected
        case notSynced
        case changes(PicPlaceSyncRecord)
        case syncing(PicPlaceSyncProgress)
        case synced(PicPlaceSyncRecord)
        case failed(PicPlaceSyncRecord)
    }

    /// What the Projects-list pill shows; nil keeps the card quiet.
    enum ListState { case synced, syncing, failed }

    /// The session's cached profile — shown offline until the server says otherwise.
    private static let profileKey = "letslapse.picplace.account"
    /// The account key of the last sign-in, for libraries that are not bound.
    private static let sessionKey = "letslapse.picplace.session"
    /// v1's device-wide sync records, keyed by capture id; migrated once.
    private static let legacyRecordsKey = "letslapse.picplace.syncStates"

    @Published private(set) var binding: PicPlaceBindingRecord?
    @Published private(set) var profile: Profile?
    @Published private(set) var usage: Usage?
    @Published private(set) var records: [UUID: PicPlaceSyncRecord] = [:]
    @Published private(set) var progress: [UUID: PicPlaceSyncProgress] = [:]
    @Published private(set) var summaries: [UUID: FolderSummary] = [:]
    @Published private(set) var isSigningIn = false
    @Published private(set) var isConnecting = false
    @Published private(set) var lastSignInError: String?
    @Published private(set) var lastConnectError: String?
    @Published private(set) var serverString = PicPlaceConfiguration.serverString
    /// The "Connect this library?" question, raised after a sign-in on an
    /// unbound library and by the cards' Connect buttons.
    @Published var isOfferingConnect = false

    private unowned let model: AppModel
    private var client: PicPlaceClient!
    private var syncTasks: [UUID: Task<Void, Never>] = [:]
    private var summaryTasks: [UUID: Task<Void, Never>] = [:]
    private let signInFlow = PicPlaceSignIn()
    private let root = StorageRoot.current

    #if DEBUG
    /// `LL_PICPLACE=<state>` stages every project's card in one state for
    /// screenshots, no server needed: signed-out · not-connected · not-synced
    /// · changes · syncing · synced · failed.
    private var stagedState: ProjectState?
    #endif

    init(model: AppModel) {
        self.model = model
        binding = PicPlaceBindingRecord.read(inRoot: root)
        if binding == nil, PicPlaceBindingRecord.exists(inRoot: root) {
            LLog("picplace: \(PicPlaceBindingRecord.fileName) exists but could not be read — treating the library as unbound; the file is left as it is")
        }
        records = PicPlaceSyncState.load(root: root)
        migrateLegacyRecords()
        Self.migrateLegacyTokens()

        // The session follows the library (v2 plan §3.1).
        let sessionKey = binding?.accountKey ?? UserDefaults.standard.string(forKey: Self.sessionKey)
        var tokens = sessionKey.flatMap { PicPlaceKeychain.load(account: $0) }
        var tokensKey = tokens == nil ? nil : sessionKey
        profile = Self.loadProfile().flatMap { $0.accountKey == sessionKey ? $0 : nil }
        #if DEBUG
        // `LL_PICPLACE_TOKENS=<access>:<refresh>` signs the app in with tokens
        // obtained elsewhere (the picplace repo's curl walkthrough), so a
        // sync can be driven headlessly without typing a password into the
        // consent page. Stored under the account once /status names it.
        if let injected = ProcessInfo.processInfo.environment["LL_PICPLACE_TOKENS"] {
            let parts = injected.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                tokens = PicPlaceTokens(accessToken: parts[0], refreshToken: parts[1],
                                        expiresAt: Date().addingTimeInterval(3600), server: signInServer.absoluteString)
                tokensKey = nil
            }
        }
        stagedState = Self.stagedState(from: ProcessInfo.processInfo.environment["LL_PICPLACE"])
        // `LL_PICPLACE_SIGNIN=1|silent` presses Sign in at launch; `silent`
        // opens no browser, so a test drives the consent page itself and
        // delivers the callback URL (open -a <app> "letslapse://…").
        let signInHook = ProcessInfo.processInfo.environment["LL_PICPLACE_SIGNIN"]
        #endif
        client = PicPlaceClient(tokens: tokens, accountKey: tokensKey) { [weak self] in
            Task { @MainActor in self?.handleSignedOutByServer() }
        }
        #if DEBUG
        // `LL_PICPLACE_SIGNOUT=1` starts from a signed-out state: revokes the
        // device if one is registered and clears the tokens and defaults —
        // how a test run leaves a shared Mac the way it found it. It replaces
        // the launch-time bootstrap, which would otherwise race it and
        // register the device again.
        let signOutHook = ProcessInfo.processInfo.environment["LL_PICPLACE_SIGNOUT"] != nil
        #else
        let signOutHook = false
        #endif
        if signOutHook {
            // handled below
        } else if tokens != nil {
            Task { await bootstrapSession() }
        } else if profile != nil {
            profile = nil
            Self.saveProfile(nil)
        }
        #if DEBUG
        if signOutHook {
            Task { @MainActor in self.signOut() }
        } else if let signInHook {
            signInFlow.opensBrowser = signInHook != "silent"
            Task { @MainActor in self.signIn() }
        }
        #if os(macOS)
        // `LL_PICPLACE_NEST=<host>:<username>` binds an unbound library to a
        // staged account and runs the Mac nest — the rename into
        // `<root>/<host>/<username>/` and the relaunch — with no server, so
        // the mechanics are exercised on a scratch root.
        if binding == nil, let staged = ProcessInfo.processInfo.environment["LL_PICPLACE_NEST"] {
            let parts = staged.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                let record = PicPlaceBindingRecord(
                    server: .init(url: "https://\(parts[0])"),
                    user: .init(uuid: "staged-\(parts[1])", username: parts[1], name: "Staged \(parts[1])"),
                    boundByDevice: DeviceIdentity.id)
                Task { @MainActor in self.connect(with: record) }
            }
        }
        #endif
        #endif
    }

    // MARK: The library

    var libraryLink: LibraryLink {
        guard let binding else { return .unbound }
        guard let profile else { return .bound }
        return binding.matches(host: profile.host, userUUID: profile.userUUID, serverID: profile.serverID) ? .bound : .mismatch
    }

    var isSignedIn: Bool { profile != nil }

    /// Whether a project may be synced from here: signed in, and this
    /// library is this account's.
    var canSync: Bool { isSignedIn && binding != nil && libraryLink == .bound }

    /// The server a sign-in goes to: a bound library's own, else the setting.
    var signInServer: URL {
        if let binding, let url = URL(string: binding.server.url) { return url }
        return PicPlaceConfiguration.server
    }

    /// The host the cards name: the session's, else the library's, else the setting's.
    var sessionHost: String {
        profile?.host ?? binding?.server.host ?? PicPlaceConfiguration.serverHost
    }

    /// Where the Mac library would live once connected (v2 plan §3.3) — the
    /// Settings row's subtitle, so the person knows before saying yes.
    var connectDestinationDescription: String? {
        #if os(macOS)
        guard let profile, binding == nil else { return nil }
        let destination = StorageRoot.nestedRoot(host: profile.host, username: profile.username)
        if StorageRoot.isNested(host: profile.host, username: profile.username) { return nil }
        return "The library moves to \(destination.path) and LetsLapse relaunches."
        #else
        return nil
        #endif
    }

    /// A `letslapse://` URL the system delivered — the sign-in callback on
    /// macOS, where the default browser hands it to Launch Services. Returns
    /// false for anything that is not ours, so the caller can carry on.
    @discardableResult
    func handleCallbackURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == PicPlaceConfiguration.callbackScheme else { return false }
        let consumed = signInFlow.handleCallback(url)
        LLog("picplace: received \(url.scheme ?? "")://\(url.host ?? "")\(url.path)\(consumed ? " → completing sign-in" : " with no sign-in waiting; ignored")")
        return true // ours either way: never hand a letslapse:// URL to the archive importer
    }

    /// Abandon a sign-in the browser never finished.
    func cancelSignIn() {
        signInFlow.cancel()
    }

    // MARK: Sign in / out

    func signIn() {
        guard !isSigningIn else { return }
        isSigningIn = true
        lastSignInError = nil
        Task {
            defer { isSigningIn = false }
            do {
                let tokens = try await signInFlow.run(server: signInServer)
                await client.setTokens(tokens, accountKey: nil)
                try await establishProfile()
                if binding == nil { isOfferingConnect = true }
            } catch is PicPlaceSignIn.Cancelled {
                // Nothing to say: they closed it.
            } catch {
                LLog("picplace: sign-in failed: \(error)")
                lastSignInError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await client.setTokens(nil, accountKey: nil)
            }
        }
    }

    /// Sign this device out of the account: revoke it on the server (best
    /// effort) and forget the tokens. The library keeps its binding and its
    /// sync records — it still belongs to the account, it just has nobody
    /// signed in (v2 plan D10). Local files are untouched.
    func signOut() {
        for task in syncTasks.values { task.cancel() }
        syncTasks.removeAll()
        progress.removeAll()
        let deviceID = profile?.deviceID
        let key = profile?.accountKey ?? binding?.accountKey ?? UserDefaults.standard.string(forKey: Self.sessionKey)
        Task {
            if let deviceID {
                let _: PPEmpty? = try? await client.delete("devices/\(deviceID)")
            }
            await client.setTokens(nil, accountKey: nil)
        }
        if let key { PicPlaceKeychain.clear(account: key) }
        PicPlaceKeychain.clearLegacy()
        profile = nil
        usage = nil
        Self.saveProfile(nil)
        UserDefaults.standard.removeObject(forKey: Self.sessionKey)
    }

    /// Change the server (only while signed out and unbound — a token names
    /// a server, and so does a binding).
    @discardableResult
    func setServer(_ string: String) -> Bool {
        guard !isSignedIn, binding == nil else { return false }
        guard PicPlaceConfiguration.setServer(string) else { return false }
        serverString = PicPlaceConfiguration.serverString
        return true
    }

    private func bootstrapSession() async {
        do {
            try await establishProfile()
        } catch {
            // Offline at launch is fine: the stored profile stands until the
            // server says otherwise (a refused refresh calls handleSignedOutByServer).
            LLog("picplace: could not reach \(sessionHost) at launch: \(error)")
        }
    }

    struct LibraryMismatch: LocalizedError {
        var signedInAs: String
        var owner: String
        var host: String
        var errorDescription: String? {
            "Signed in as @\(signedInAs), but this library belongs to @\(owner) on \(host). Sign in as @\(owner), or disconnect the library in Settings."
        }
    }

    /// Read the handshake, check the account against the library's binding,
    /// register this device, store the tokens under the account. Idempotent.
    private func establishProfile() async throws {
        let status: PPStatus = try await client.get("status")
        let tokens = try await client.currentTokens()
        let host = PicPlaceConfiguration.host(of: tokens.server)
        let handle = status.user.username ?? status.user.name ?? "PicPlace"
        if let binding, !binding.matches(host: host, userUUID: status.user.uuid, serverID: status.server?.id) {
            // Somebody else's account on this library: keep nothing, register
            // nothing. The tokens were valid for them; they are not kept for
            // a session this library refuses.
            await client.setTokens(nil, accountKey: nil)
            throw LibraryMismatch(signedInAs: handle, owner: binding.user.displayHandle, host: binding.server.host)
        }
        let key = PicPlaceBindingRecord.accountKey(host: host, userUUID: status.user.uuid)
        try PicPlaceKeychain.save(tokens, account: key)
        await client.setTokens(tokens, accountKey: key)

        let registration: [String: PPDevice] = try await client.post("device", json: [
            "device_key": DeviceIdentity.id.uuidString.lowercased(),
            "name": Self.deviceName,
            "platform": Self.platform,
            "model": Self.hardwareModel,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "app_version": Self.appVersion,
        ])
        guard let device = registration["device"] else { throw PicPlaceAPIError(status: 500, code: nil, message: "PicPlace did not register this device.", claim: nil) }
        profile = Profile(username: handle, name: status.user.name, userUUID: status.user.uuid,
                          deviceID: device.id, deviceName: device.name, server: tokens.server,
                          serverID: status.server?.id, serverEnvironment: status.server?.environment)
        Self.saveProfile(profile)
        UserDefaults.standard.set(key, forKey: Self.sessionKey)
        upgradeBindingIfServerReportsItself(status)
        await refreshUsage(status: status)
    }

    /// A binding made before the server reported an instance id takes the
    /// id the first time the server does (v2 plan D1).
    private func upgradeBindingIfServerReportsItself(_ status: PPStatus) {
        guard var record = binding, record.server.id == nil, let server = status.server else { return }
        record.server.id = server.id
        record.server.environment = server.environment
        do {
            try record.write(inRoot: root)
            binding = record
            LLog("picplace: binding now carries server id \(server.id) (\(server.environment ?? "?"))")
        } catch {
            LLog("picplace: could not upgrade the binding: \(error)")
        }
    }

    /// The Settings card's "On PicPlace" line: how many of this account's
    /// projects are on the server and the bytes they take.
    func refreshUsage() {
        guard isSignedIn else { return }
        Task {
            if let status: PPStatus = try? await client.get("status") {
                await refreshUsage(status: status)
            }
        }
    }

    private func refreshUsage(status: PPStatus) async {
        if let projects = status.projects {
            usage = Usage(projects: projects.count, bytes: status.storage.usedBytes)
            return
        }
        let projects: [String: [PPProject]]? = try? await client.get("projects")
        usage = Usage(projects: projects?["projects"]?.count ?? 0, bytes: status.storage.usedBytes)
    }

    private func handleSignedOutByServer() {
        guard profile != nil else { return }
        for task in syncTasks.values { task.cancel() }
        syncTasks.removeAll()
        progress.removeAll()
        profile = nil
        usage = nil
        Self.saveProfile(nil)
        UserDefaults.standard.removeObject(forKey: Self.sessionKey)
        lastSignInError = "PicPlace signed this device out. Sign in again."
    }

    // MARK: Connect / disconnect the library

    /// The Connect buttons: raise the question (the cards present it).
    func offerConnect() {
        guard isSignedIn, binding == nil else { return }
        lastConnectError = nil
        isOfferingConnect = true
    }

    /// Bind the open library to the signed-in account (v2 plan D2–D3): write
    /// `PicPlace/account.json`; on the Mac, nest the library into
    /// `<root>/<host>/<username>/` and relaunch. iOS binds in place.
    func connectLibrary() {
        guard let profile, binding == nil else { return }
        let record = PicPlaceBindingRecord(
            server: .init(url: profile.server, id: profile.serverID, environment: profile.serverEnvironment),
            user: .init(uuid: profile.userUUID, username: profile.username, name: profile.name),
            boundByDevice: DeviceIdentity.id)
        connect(with: record)
    }

    private func connect(with record: PicPlaceBindingRecord) {
        guard binding == nil, !isConnecting else { return }
        isConnecting = true
        lastConnectError = nil
        let username = record.user.displayHandle
        #if os(macOS)
        if !StorageRoot.isNested(host: record.server.host, username: username) {
            // Everything queued lands, nothing further is written, the lock
            // goes — then the folders move and the app comes back on the
            // nested root (v2 plan §3.3).
            model.prepareForLibraryNest(reason: "The library is moving to its PicPlace folder; LetsLapse is relaunching.")
            do {
                try StorageRoot.nest(host: record.server.host, username: username, binding: record)
            } catch {
                LLog("picplace: nest failed: \(error)")
                lastConnectError = "Couldn't move the library into its PicPlace folder: \(error.localizedDescription)"
                model.abandonLibraryNest()
                isConnecting = false
                return
            }
            LLog("picplace: library bound to @\(username) on \(record.server.host) and nested at \(StorageRoot.nestedRoot(host: record.server.host, username: username).path) — relaunching")
            AppRelaunch.relaunchNow()
            return
        }
        #endif
        do {
            try record.write(inRoot: root)
            binding = record
            PicPlaceSyncState.save(records, root: root)
            LLog("picplace: library bound to @\(username) on \(record.server.host)")
        } catch {
            LLog("picplace: could not write the binding: \(error)")
            lastConnectError = "Couldn't connect this library: \(error.localizedDescription)"
        }
        isConnecting = false
    }

    /// "Disconnect this library": the binding and the sync records go; the
    /// projects stay, keep their origin ids, and would fork if pushed under
    /// another account (v2 plan §4.6). The session is untouched.
    func disconnectLibrary() {
        for task in syncTasks.values { task.cancel() }
        syncTasks.removeAll()
        progress.removeAll()
        PicPlaceBindingRecord.remove(inRoot: root)
        binding = nil
        records = [:]
        LLog("picplace: library disconnected")
    }

    // MARK: Project state

    func state(for capture: AppModel.CaptureProject) -> ProjectState {
        #if DEBUG
        if let stagedState { return stagedState }
        #endif
        guard isSignedIn else { return .signedOut }
        guard canSync else { return .notConnected }
        if let progress = progress[capture.id] { return .syncing(progress) }
        guard let record = records[model.originID(of: capture)] else { return .notSynced }
        if record.lastError != nil { return .failed(record) }
        if model.lastEdited(capture) > record.syncedAt { return .changes(record) }
        return .synced(record)
    }

    func listState(for captureID: UUID) -> ListState? {
        #if DEBUG
        if let stagedState {
            switch stagedState {
            case .syncing: return .syncing
            case .synced, .changes: return .synced
            case .failed: return .failed
            default: return nil
            }
        }
        #endif
        guard canSync else { return nil }
        if progress[captureID] != nil { return .syncing }
        guard let capture = model.capture(id: captureID), let record = records[model.originID(of: capture)] else { return nil }
        return record.lastError == nil ? .synced : .failed
    }

    /// Re-read the server's view of a project the card is showing: the
    /// devices that hold a copy (Also on), and whether it is still there at all.
    func refreshProject(_ captureID: UUID) {
        guard canSync, let capture = model.capture(id: captureID), progress[captureID] == nil else { return }
        let key = model.originID(of: capture)
        guard records[key] != nil else { return }
        Task {
            do {
                let detail: PPProjectDetail = try await client.get("projects/\(captureID.uuidString.lowercased())")
                let project = detail.project
                guard var record = records[key] else { return }
                record.alsoOn = project.presence.compactMap(\.device).filter { $0.id != profile?.deviceID }.map(\.name)
                records[key] = record
                PicPlaceSyncState.save(records, root: root)
            } catch let error as PicPlaceAPIError where error.status == 404 {
                // Deleted on the server: this device's record no longer describes anything.
                records[key] = nil
                PicPlaceSyncState.save(records, root: root)
            } catch {
                // Offline: keep what we knew.
            }
        }
    }

    /// The "341 files · 4.9 MB" line for a project that has never been
    /// synced — a folder walk, once per project, off the main actor.
    func summary(for capture: AppModel.CaptureProject) -> FolderSummary? {
        if let summary = summaries[capture.id] { return summary }
        guard summaryTasks[capture.id] == nil else { return nil }
        let folder = model.projectFolderURL(for: capture)
        let id = capture.id
        summaryTasks[id] = Task { [weak self] in
            let summary = await Task.detached(priority: .utility) { () -> FolderSummary in
                let entries = (try? PicPlaceSyncRun.listFiles(in: folder)) ?? []
                return FolderSummary(files: entries.count, bytes: entries.reduce(0) { $0 + $1.bytes })
            }.value
            self?.summaries[id] = summary
            self?.summaryTasks[id] = nil
        }
        return nil
    }

    // MARK: Sync

    func sync(_ capture: AppModel.CaptureProject) {
        guard canSync, syncTasks[capture.id] == nil else { return }
        let key = model.originID(of: capture)
        let project = PicPlaceSyncRun.Project(
            id: capture.id,
            folder: model.projectFolderURL(for: capture),
            name: capture.displayTitle,
            type: capture.isPhotoCapture ? "photo" : (capture.kind == .video ? "video" : "interval"),
            revision: Int(model.lastEdited(capture).timeIntervalSince1970 * 1000),
            capturedAt: capture.createdAt)
        let run = PicPlaceSyncRun(client: client, project: project, thisDeviceID: profile?.deviceID) { [weak self] progress in
            self?.progress[capture.id] = progress
        }
        progress[capture.id] = PicPlaceSyncProgress()
        summaries[capture.id] = nil
        let server = profile?.server ?? serverString
        syncTasks[capture.id] = Task {
            do {
                let record = try await run.run()
                records[key] = record
            } catch is CancellationError {
                // Cancelled by the user: the card goes back to what it was.
            } catch {
                LLog("picplace: sync of \(capture.id) failed: \(error)")
                var record = records[key] ?? PicPlaceSyncRecord(syncedAt: .distantPast, revision: 0, files: 0, bytes: 0, uploaded: 0, alsoOn: [], server: server, lastError: nil)
                record.lastError = (error as? PicPlaceAPIError)?.cardCaption
                    ?? (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                records[key] = record
            }
            PicPlaceSyncState.save(records, root: root)
            progress[capture.id] = nil
            syncTasks[capture.id] = nil
            refreshUsage()
        }
    }

    func cancelSync(_ id: UUID) {
        syncTasks[id]?.cancel()
    }

    // MARK: Persistence

    private static func loadProfile() -> Profile? {
        guard let data = UserDefaults.standard.data(forKey: profileKey) else { return nil }
        return try? JSONDecoder().decode(Profile.self, from: data)
    }

    private static func saveProfile(_ profile: Profile?) {
        if let profile, let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: profileKey)
        } else {
            UserDefaults.standard.removeObject(forKey: profileKey)
        }
    }

    /// v1 kept the records in `UserDefaults`, device-wide and keyed by
    /// capture id. Those that describe a project in THIS library move into
    /// its sync state under the project's origin id; the rest are dropped
    /// (a project they described lives in some other library, whose own
    /// records the server can restore). Runs once: the key is removed.
    private func migrateLegacyRecords() {
        guard let data = UserDefaults.standard.data(forKey: Self.legacyRecordsKey) else { return }
        defer { UserDefaults.standard.removeObject(forKey: Self.legacyRecordsKey) }
        guard let decoded = try? JSONDecoder().decode([String: PicPlaceSyncRecord].self, from: data) else { return }
        var moved = 0
        for (key, record) in decoded {
            guard let id = UUID(uuidString: key), let capture = model.capture(id: id) else { continue }
            let originID = model.originID(of: capture)
            if records[originID] == nil { records[originID] = record; moved += 1 }
        }
        if moved > 0 { PicPlaceSyncState.save(records, root: root) }
        LLog("picplace: migrated \(moved) of \(decoded.count) v1 sync record(s) into the library")
    }

    /// v1 kept one Keychain item; it becomes the item of the account the
    /// stored profile names, and that account becomes the session.
    private static func migrateLegacyTokens() {
        guard let legacy = PicPlaceKeychain.loadLegacy() else { return }
        defer { PicPlaceKeychain.clearLegacy() }
        guard let profile = loadProfile(), PicPlaceConfiguration.host(of: legacy.server) == profile.host else {
            LLog("picplace: a v1 sign-in with no matching profile was dropped; sign in again")
            return
        }
        do {
            try PicPlaceKeychain.save(legacy, account: profile.accountKey)
            UserDefaults.standard.set(profile.accountKey, forKey: sessionKey)
            LLog("picplace: v1 sign-in moved under \(profile.accountKey)")
        } catch {
            LLog("picplace: could not move the v1 sign-in: \(error)")
        }
    }

    // MARK: This device

    static var deviceName: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return UIDevice.current.name
        #endif
    }

    static var platform: String {
        #if os(macOS)
        return "macos"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
        #endif
    }

    static var hardwareModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    #if DEBUG
    private static func stagedState(from value: String?) -> ProjectState? {
        let demo = PicPlaceSyncRecord(syncedAt: Date().addingTimeInterval(-5 * 60), revision: 1, files: 341, bytes: 4_900_000,
                                      uploaded: 341, alsoOn: ["iPad Air"], server: PicPlaceConfiguration.serverString, lastError: nil)
        switch value {
        case "signed-out": return .signedOut
        case "not-connected": return .notConnected
        case "not-synced": return .notSynced
        case "changes":
            var record = demo
            record.syncedAt = Date().addingTimeInterval(-24 * 3600)
            return .changes(record)
        case "syncing":
            var progress = PicPlaceSyncProgress(phase: .uploading)
            progress.filesDone = 127; progress.filesTotal = 341
            progress.bytesDone = 1_800_000; progress.bytesTotal = 4_900_000
            return .syncing(progress)
        case "synced": return .synced(demo)
        case "failed":
            var record = demo
            record.lastError = "iPad Air holds the write claim until 14:32"
            return .failed(record)
        default: return nil
        }
    }
    #endif
}

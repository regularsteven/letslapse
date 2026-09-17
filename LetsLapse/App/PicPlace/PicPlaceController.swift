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
/// accounts refused; unbound → the Mac's sign-in on the library's server
/// (libraries plan L13: the session is the Mac's, one per server; the
/// binding decides whether a library syncs with it). Connecting is always
/// the person's press (L18).
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
        /// The account's projects on the server and their bytes.
        var projects: Int
        var bytes: Int64
        /// Server projects whose origin id this library does not hold — what
        /// a merge (stage 3) would bring here. The card names the count so
        /// "4 projects" beside a two-project library is not a mystery.
        var notInLibrary: Int = 0
    }

    struct FolderSummary: Equatable {
        /// Objects the policy sends (the records bundle counts as one) and their bytes.
        var files: Int
        var bytes: Int64
        /// The heavy set the policy leaves on this device.
        var heavyFiles = 0
        var heavyBytes: Int64 = 0
    }

    /// How the open library relates to the session.
    enum LibraryLink: Equatable {
        /// No `PicPlace/account.json`: the library belongs to nobody yet.
        case unbound
        /// Bound to the signed-in account — or bound and nobody signed in.
        case bound
        /// Bound to the account from before PicPlace kept libraries apart
        /// (no library uuid) on a server that now does: nothing runs until
        /// the person says which library this is — new, unfiled taken
        /// over, or an existing one linked (stage C). Never account-wide:
        /// that is how a phone pulled every unfiled project on 2026-09-17.
        case needsLibrary
        /// Bound to another account or server than the session's.
        case mismatch
    }

    enum ProjectState: Equatable {
        /// The project's sources are not on this device; its poster is (v2
        /// plan §3.6). Whatever the session, the card says so first.
        case previewOnly(PicPlaceSyncRecord?)
        /// Stage C: PicPlace holds this project in another library of the
        /// account (named when known); this library neither pushes nor
        /// pulls it.
        case elsewhere(String?)
        /// Stage 4: the project is in the conflicts list.
        case conflict(Conflict.Kind)
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
    enum ListState { case synced, syncing, failed, previewOnly }

    /// The cached profiles, per account — shown offline until the server
    /// says otherwise, and what "Sign in as @user" offers a signed-out
    /// library. `profileKey` is the single-profile key from before.
    private static let profilesKey = "letslapse.picplace.accounts"
    private static let profileKey = "letslapse.picplace.account"
    /// The account key of the last sign-in, for libraries that are not bound
    /// — v1/v2's single key, folded into `sessionsKey` once.
    private static let sessionKey = "letslapse.picplace.session"
    /// The Mac's sign-ins, one account key per server host (L13): an unbound
    /// library uses the one for the server it would sign in to.
    private static let sessionsKey = "letslapse.picplace.sessions"
    /// v1's device-wide sync records, keyed by capture id; migrated once.
    private static let legacyRecordsKey = "letslapse.picplace.syncStates"

    @Published internal(set) var binding: PicPlaceBindingRecord?
    @Published private(set) var profile: Profile?
    @Published private(set) var usage: Usage?
    @Published internal(set) var records: [UUID: PicPlaceSyncRecord] = [:]
    @Published private(set) var progress: [UUID: PicPlaceSyncProgress] = [:]
    @Published private(set) var summaries: [UUID: FolderSummary] = [:]
    @Published private(set) var isSigningIn = false
    @Published private(set) var isConnecting = false
    @Published private(set) var lastSignInError: String?
    @Published private(set) var lastConnectError: String?
    @Published private(set) var serverString = PicPlaceConfiguration.serverString
    /// `limits.manifest_max_bytes` from the last `/status`; 1 MB until then.
    private(set) var manifestMaxBytes: Int64 = 1 << 20
    /// The "Connect this library?" question, raised by the cards' Connect
    /// buttons (never by a sign-in, libraries plan L18): a sheet with the
    /// target — a new library on PicPlace, an existing one to link to, or
    /// the default library to take over — once the server keeps libraries
    /// apart; the one-line alert of v2 on a server that does not.
    @Published var isOfferingConnect = false
    @Published private(set) var connectOffer: ConnectOffer?
    /// The v2 question's case line (clean · fresh · merge, §4.1) — the
    /// server-without-libraries path, and the `LL_PICPLACE_BIND` staging.
    @Published private(set) var connectCaseText: String?
    /// What the last `/status` said about the account's libraries (stage C).
    @Published private(set) var serverHasLibraries = false
    @Published private(set) var serverLibraries: [PPLibrary] = []
    /// The first connection's progress while it runs (§4.1 step 4).
    @Published internal(set) var initialSyncProgress: InitialSyncProgress?
    var initialSyncTask: Task<Void, Never>?
    /// Stage 4: the rows a person has to decide, the last check, and whether
    /// one is running.
    @Published internal(set) var conflicts: [Conflict] = []
    @Published internal(set) var lastCheck: CheckOutcome?
    @Published internal(set) var isChecking = false
    @Published internal(set) var lastResolveError: String?
    /// The conflicts sheet, presented by whichever card is on screen.
    @Published var isReviewingConflicts = false
    var checkTask: Task<Void, Never>?
    var lastCheckAt: Date?
    var foregroundObserver: NSObjectProtocol?
    /// Auto-sync (§4.7): the switches, what it is doing, its timers and queues.
    /// The first two are this DEVICE's for this LIBRARY (`PicPlace/settings.json`,
    /// one entry per device; libraries plan L7) — *upload originals* starts
    /// OFF everywhere, is switched on only by the person, and is never sent
    /// to the server. Wi-Fi-only is the install's.
    @Published var autoSyncEnabled: Bool = PicPlaceController.librarySettings.autoSync {
        didSet { saveLibrarySettings(); autoSyncSettingChanged() }
    }
    @Published var autoOriginalsEnabled: Bool = PicPlaceController.librarySettings.autoOriginals {
        didSet { saveLibrarySettings(); autoSyncSettingChanged() }
    }
    @Published var wifiOnly: Bool = UserDefaults.standard.object(forKey: PicPlaceController.wifiOnlyKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(wifiOnly, forKey: Self.wifiOnlyKey); autoSyncSettingChanged() }
    }
    private static var librarySettings: PicPlaceLibrarySettings.Switches {
        PicPlaceLibrarySettings.resolve(root: StorageRoot.current, device: DeviceIdentity.id,
                                        legacyAutoSyncKey: autoSyncKey, legacyAutoOriginalsKey: autoOriginalsKey)
    }
    private func saveLibrarySettings() {
        do {
            try PicPlaceLibrarySettings.save(.init(autoSync: autoSyncEnabled, autoOriginals: autoOriginalsEnabled), root: root, device: DeviceIdentity.id)
        } catch {
            LLog("picplace: could not write the library's settings: \(error)")
        }
    }
    /// What auto-sync is doing right now (a spinner beside it), and the
    /// last thing that went wrong (no spinner; cleared by the next success
    /// or check).
    @Published internal(set) var autoStatus: String?
    @Published internal(set) var autoError: String?
    @Published internal(set) var isOnWiFi = true
    var pendingPushes: [UUID: Task<Void, Never>] = [:]
    /// The pushes that are due, in order, and the one worker that sends
    /// them one project at a time (a hundred imports are a hundred pushes;
    /// sent together they were refused together).
    var pushQueue: [UUID] = []
    var pushQueueTask: Task<Void, Never>?
    /// The queue's progress for the status line: how many this run of the
    /// queue has sent, of how many it took on.
    @Published internal(set) var pushQueueDone = 0
    @Published internal(set) var pushQueueTotal = 0
    /// Pushes and a check that were due while the network rule held them.
    var heldPushes: Set<UUID> = []
    var heldCheck = false
    var forcedNetwork = false
    var autoTimer: Timer?
    var originalsQueueTask: Task<Void, Never>?
    var pathMonitorBox: AnyObject?
    /// One usage refresh for a whole run of syncs, not two requests per project.
    var usageRefreshTask: Task<Void, Never>?
    /// Whether the last sync to fail did so because the server could not be
    /// reached at all — the queue stops on that rather than fail through
    /// its remaining projects one slow timeout at a time.
    var lastSyncFailedOffline = false
    /// The first two are legacy install-wide keys: read once into the
    /// library's `settings.json` (then removed), and still honoured from
    /// the argument domain for a run.
    static let autoSyncKey = "letslapse.picplace.autoSync"
    static let autoOriginalsKey = "letslapse.picplace.autoOriginals"
    static let wifiOnlyKey = "letslapse.picplace.wifiOnly"
    /// The server's watermark from the last index read (stage 4).
    var syncMeta = PicPlaceSyncState.Meta()

    func saveSyncState() {
        PicPlaceSyncState.save(records, meta: syncMeta, root: root)
    }

    /// What a Sync sends. Stage 2: the minimal set; the originals follow per
    /// project in stage 5. `LL_PICPLACE_POLICY=minimal|originals|everything`
    /// overrides it for a run.
    var policy: PicPlaceSyncPolicy {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["LL_PICPLACE_POLICY"], let forced = PicPlaceSyncPolicy(rawValue: raw) { return forced }
        #endif
        return .minimal
    }

    unowned let model: AppModel
    var client: PicPlaceClient!
    var syncTasks: [UUID: Task<Void, Never>] = [:]
    private var summaryTasks: [UUID: Task<Void, Never>] = [:]
    private let signInFlow = PicPlaceSignIn()
    let root = StorageRoot.current

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
        let loaded = PicPlaceSyncState.load(root: root)
        records = loaded.records
        syncMeta = loaded.meta
        migrateLegacyRecords()
        Self.migrateLegacyTokens()

        // The session follows the library (v2 plan §3.1): a bound library's
        // is its binding; an unbound one's is the Mac's sign-in on the server
        // it would sign in to (L13). A day of `PicPlace/session.json` per
        // library is over: a stale one is removed where found.
        var sessionKey = binding?.accountKey ?? Self.sessions[PicPlaceConfiguration.serverHost]
        try? FileManager.default.removeItem(at: PicPlaceBindingRecord.folderURL(inRoot: root).appendingPathComponent("session.json"))
        #if DEBUG && os(macOS)
        // A scratch root (`-storage.libraryRootPath …`) that is not bound is
        // not the person's library and must not borrow their session: a
        // test run refreshing their tokens would rotate the pair under
        // their own instance. Bound scratch roots and `LL_PICPLACE_TOKENS`
        // are the deliberate ways in.
        if binding == nil, StorageRoot.rootCameFromArguments, sessionKey != nil {
            LLog("picplace: scratch root — not using the install's session")
            sessionKey = nil
        }
        #endif
        var tokens = sessionKey.flatMap { PicPlaceKeychain.load(account: $0) }
        LLog("picplace: session \(sessionKey ?? "none") — \(tokens == nil ? "no tokens" : "tokens found")\(binding == nil ? "" : ", library bound to @\(binding!.user.displayHandle) on \(binding!.server.host)")")
        var tokensKey = tokens == nil ? nil : sessionKey
        profile = sessionKey.flatMap { Self.loadProfile(for: $0) }
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
        // `LL_PICPLACE_LIBRARIES=<n>` stages the connect sheet (stage C) with
        // n demo libraries and the unfiled entry, no server.
        if let raw = ProcessInfo.processInfo.environment["LL_PICPLACE_LIBRARIES"], let n = Int(raw) {
            let names = ["Holidays", "Client X", "Field 2026", "Timelapse gallery"]
            let demo = (0..<min(n, names.count)).map { i in
                PPLibrary(uuid: UUID().uuidString.lowercased(), name: names[i], projects: .init(count: [879, 40, 12, 300][i], byType: nil, deleted: nil),
                          usedBytes: 1_200_000_000, createdBy: nil, updatedBy: nil, deletedBy: nil, createdAt: Date(), updatedAt: Date(), deletedAt: nil)
            }
            serverHasLibraries = true
            serverLibraries = demo
            connectOffer = ConnectOffer(
                libraries: demo,
                defaultEntry: PPLibrary(uuid: nil, name: nil, projects: .init(count: 12, byType: nil, deleted: nil), usedBytes: 0,
                                        createdBy: nil, updatedBy: nil, deletedBy: nil, createdAt: nil, updatedAt: nil, deletedAt: nil),
                localCount: 398, suggestedName: StorageRoot.identity?.displayName ?? "Prague LetsLapse Shots",
                needsName: StorageRoot.identity?.namedByPerson != true)
            Task { @MainActor in self.isOfferingConnect = true }
        }
        // `LL_PICPLACE_BIND=clean|fresh|merge` stages the v2 connect question's
        // case line with no server (a server without libraries).
        if let staged = ProcessInfo.processInfo.environment["LL_PICPLACE_BIND"] {
            switch staged {
            case "clean": connectCaseText = "Nothing is on PicPlace yet. This library's 12 projects will be kept there — records and a preview each; originals stay here until you upload them."
            case "fresh": connectCaseText = "PicPlace holds 12 projects and this library is empty. They'll appear here as previews; originals download per project."
            case "merge": connectCaseText = "PicPlace holds 12 projects, this library 9. Projects on both sides stay in step, the rest are exchanged."
            default: break
            }
            Task { @MainActor in self.isOfferingConnect = true }
        }
        // `LL_PICPLACE_CONNECT=new:<name>|adopt:<name>|link:<uuid>` presses
        // Connect with that target once the session is up (stage C bench).
        if let raw = ProcessInfo.processInfo.environment["LL_PICPLACE_CONNECT"] {
            Task { @MainActor in
                for _ in 0..<60 where !self.isSignedIn || !self.serverHasLibraries { try? await Task.sleep(nanoseconds: 500_000_000) }
                guard self.isSignedIn, self.binding == nil else { LLog("picplace hook: LL_PICPLACE_CONNECT — not signed in or already bound"); return }
                let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
                switch parts.first {
                case "new": self.connectLibrary(target: .new, name: parts.count > 1 ? parts[1] : nil)
                case "adopt": self.connectLibrary(target: .adoptDefault, name: parts.count > 1 ? parts[1] : nil)
                case "link":
                    if parts.count > 1, let library = self.serverLibraries.first(where: { $0.uuid?.lowercased() == parts[1].lowercased() }) {
                        self.connectLibrary(target: .link(library), name: nil)
                    } else { LLog("picplace hook: LL_PICPLACE_CONNECT link — no such library \(parts.count > 1 ? parts[1] : "")") }
                default: LLog("picplace hook: LL_PICPLACE_CONNECT — unknown target \(raw)")
                }
            }
        }
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
            // A profile without tokens is stale: drop this library's view
            // of it (the cached copy stays for "Sign in as" elsewhere).
            profile = nil
        }
        #if DEBUG
        if signOutHook {
            Task { @MainActor in self.signOut() }
        } else if let signInHook {
            signInFlow.opensBrowser = signInHook != "silent"
            Task { @MainActor in self.signIn() }
        }
        // `LL_PICPLACE_DRYRUN=latest|<uuid>` runs the file side of a sync
        // with no server: classifies the folder, builds the records bundle
        // (left under `tmp/`), renders the poster, logs the inventory.
        if let target = ProcessInfo.processInfo.environment["LL_PICPLACE_DRYRUN"] {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)   // after the launch walk
                self.dryRun(target)
            }
        }
        #endif
        // Every build: the foreground and timer checks, the network monitor.
        // These sat inside the DEBUG block above until 2026-09-15, so the
        // Release app on the Mac never ran a timer or foreground check —
        // only launch and hand-pressed ones — while the Debug Simulator did.
        armChangeChecks()
        armAutoSync()
    }

    // MARK: The library

    var libraryLink: LibraryLink {
        guard let binding else { return .unbound }
        guard let profile else { return .bound }
        guard binding.matches(host: profile.host, userUUID: profile.userUUID, serverID: profile.serverID) else { return .mismatch }
        if serverHasLibraries, binding.library == nil { return .needsLibrary }
        return .bound
    }

    var isSignedIn: Bool { profile != nil }

    /// Whether a project may be synced from here: signed in, and this
    /// library is this account's.
    var canSync: Bool { isSignedIn && binding != nil && libraryLink == .bound }

    /// The server library this local library syncs (stage C): the binding's
    /// `library.uuid`. nil for a binding from before libraries — then every
    /// row of the account is in scope, as in v2.
    var scope: UUID? { binding?.library?.uuid }

    /// Whether `row` belongs to this library's scope.
    func inScope(_ row: PPProject) -> Bool {
        row.isIn(scope: scope, serverHasLibraries: serverHasLibraries)
    }

    /// The server's entry for this library, when the last `/status` had one.
    var serverLibrary: PPLibrary? {
        guard let scope else { return nil }
        return serverLibraries.first { $0.libraryUUID == scope }
    }

    /// The name a server library goes by here — its own, else the uuid's stub.
    func libraryName(for uuid: String?) -> String? {
        guard let uuid else { return nil }
        if let known = serverLibraries.first(where: { $0.uuid?.lowercased() == uuid.lowercased() })?.name { return known }
        return String(uuid.prefix(8))
    }

    /// The server a sign-in goes to: a bound library's own, else the setting.
    var signInServer: URL {
        if let binding, let url = URL(string: binding.server.url) { return url }
        return PicPlaceConfiguration.server
    }

    /// The host the cards name: the session's, else the library's, else the setting's.
    var sessionHost: String {
        profile?.host ?? binding?.server.host ?? PicPlaceConfiguration.serverHost
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
                // An unbound library is not offered the connect question
                // here (L18): the card says "Not on PicPlace — Connect…" and
                // the person chooses when.
                if binding != nil { runInitialSyncIfPending() }
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
        let host = profile?.host ?? binding?.server.host ?? PicPlaceConfiguration.serverHost
        let key = profile?.accountKey ?? binding?.accountKey ?? Self.sessions[host]
        Task {
            if let deviceID {
                let _: PPEmpty? = try? await client.delete("devices/\(deviceID)")
            }
            await client.setTokens(nil, accountKey: nil)
        }
        if let key {
            PicPlaceKeychain.clear(account: key)
            Self.saveProfile(nil, for: key)
        }
        PicPlaceKeychain.clearLegacy()
        profile = nil
        usage = nil
        Self.setSession(nil, forHost: host)
    }

    /// The Mac's sign-ins by server host (L13), with v2's single key folded
    /// in once (its host is the account key's prefix).
    private static var sessions: [String: String] {
        var map = UserDefaults.standard.dictionary(forKey: sessionsKey) as? [String: String] ?? [:]
        if let legacy = UserDefaults.standard.string(forKey: sessionKey) {
            let host = String(legacy.split(separator: "|", maxSplits: 1).first ?? "")
            if !host.isEmpty, map[host] == nil { map[host] = legacy }
            UserDefaults.standard.set(map, forKey: sessionsKey)
            UserDefaults.standard.removeObject(forKey: sessionKey)
        }
        return map
    }

    private static func setSession(_ accountKey: String?, forHost host: String) {
        var map = sessions
        map[host.lowercased()] = accountKey
        UserDefaults.standard.set(map, forKey: sessionsKey)
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
        // A transient failure of the handshake (a 500, a flaky link) must
        // not cost the launch its check: the profile is known, the check
        // fails or succeeds on its own.
        if isSignedIn { runInitialSyncIfPending() }
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
        Self.saveProfile(profile, for: key)
        Self.setSession(key, forHost: host)
        upgradeBindingIfServerReportsItself(status)
        noteLimits(status)
        noteLibraries(status)
        await repairBindingLibraryIfMissing(status)
        await refreshUsage(status: status)
    }

    /// What the server keeps apart (stage C): the feature and the list.
    func noteLibraries(_ status: PPStatus) {
        serverHasLibraries = status.hasLibraries
        serverLibraries = status.libraries ?? []
    }

    private func noteLimits(_ status: PPStatus) {
        if let cap = status.limits?.manifestMaxBytes, cap > 0 { manifestMaxBytes = cap }
        let perMinute = status.limits?.requestsPerMinute?.device
        Task { await client.setRateLimit(requestsPerMinute: perMinute) }
        #if DEBUG
        // `LL_PICPLACE_MANIFEST_CAP=<bytes>` forces the overflow path.
        if let forced = ProcessInfo.processInfo.environment["LL_PICPLACE_MANIFEST_CAP"].flatMap(Int64.init) { manifestMaxBytes = forced }
        #endif
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

    /// The library's scope put right against the server (stage C). Two
    /// things a pass must never read as "everything is filed elsewhere":
    /// a binding whose server library is MISSING — a binding made before
    /// the server kept libraries apart (stage A′ wrote the uuid and pushed
    /// into the default library; a v2 binding has no uuid at all, and takes
    /// the identity's), or a library purged elsewhere — is created under
    /// the binding's uuid and name; and the account's UNFILED rows that
    /// this library holds are assigned to it (`POST /libraries/{uuid}/projects`
    /// — exactly this library's, never the whole default, never another
    /// named library's). Runs at the handshake and before a check; the
    /// assignment only when the default library's count moved.
    private var unfiledCountSeen: Int?

    func repairBindingLibraryIfMissing(_ status: PPStatus) async {
        // A binding without a library is `.needsLibrary`: the person chooses
        // on the sheet (`connectLibrary(target:)` fills the binding in);
        // nothing is minted or assigned on their behalf.
        guard status.hasLibraries, canSync, let record = binding, let library = record.library else { return }
        let uuid = library.uuid.uuidString.lowercased()
        var libraries = status.libraries ?? []
        do {
            if !libraries.contains(where: { $0.libraryUUID == library.uuid }) {
                let created: PPLibraryResponse = try await client.put("libraries/\(uuid)", json: ["name": library.name, "adopt_default": false])
                LLog("picplace: library “\(library.name)” \(uuid) was not on \(sessionHost) — created (\(created.library.count) projects there)")
                libraries.append(created.library)
            }
            let unfiled = libraries.first { $0.isDefault }?.count ?? 0
            if unfiled > 0, unfiled != unfiledCountSeen {
                unfiledCountSeen = unfiled
                let rows: PPProjectIndex = try await client.get("projects", query: ["library": "null"])
                // "Held here" means the ORIGINALS are here: a preview pulled
                // from the account is some other library's project, never
                // this one's to file (the 2026-09-17 Simulator lesson).
                var mine: [String] = []
                if let index = model.libraryIndex {
                    for row in rows.projects where !row.isTombstone {
                        guard let origin = UUID(uuidString: row.uuid),
                              let localID = (try? index.projectID(originID: origin)) ?? nil,
                              let capture = model.capture(id: localID), !model.sourcesMissing(capture) else { continue }
                        mine.append(row.uuid.lowercased())
                    }
                }
                if !mine.isEmpty {
                    let result: PPAssignResult = try await client.post("libraries/\(uuid)/projects", json: ["projects": mine])
                    LLog("picplace: \(result.moved) of the account's \(unfiled) unfiled project(s) are this library's — filed under “\(library.name)” (\(result.unchanged ?? 0) already there, \(result.unknown?.count ?? 0) unknown)")
                    for origin in mine.compactMap(UUID.init(uuidString:)) { clearElsewhere(origin) }
                    saveSyncState()
                    unfiledCountSeen = nil
                } else {
                    LLog("picplace: none of the account's \(unfiled) unfiled project(s) is held here — left unfiled")
                }
            }
            if let refreshed: PPStatus = try? await client.get("status") { noteLibraries(refreshed) } else { serverLibraries = libraries }
        } catch {
            LLog("picplace: could not put the library's scope right on \(sessionHost): \(error)")
        }
    }

    /// The Settings card's "On PicPlace" line: how many of this account's
    /// projects are on the server and the bytes they take. `rows` spares
    /// the index read when the caller has just read it (the check).
    func refreshUsage(rows: [PPProject]? = nil) {
        guard isSignedIn else { return }
        Task {
            if let status: PPStatus = try? await client.get("status") {
                noteLimits(status)
                noteLibraries(status)
                await repairBindingLibraryIfMissing(status)
                await refreshUsage(status: status, rows: rows)
            }
        }
    }

    /// A refresh once the syncs in flight have settled — two requests for a
    /// run of pushes, not two per project.
    func scheduleUsageRefresh() {
        usageRefreshTask?.cancel()
        usageRefreshTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            guard let self else { return }
            usageRefreshTask = nil
            refreshUsage()
        }
    }

    private func refreshUsage(status: PPStatus, rows given: [PPProject]? = nil) async {
        // The index, not just the count: which of the account's projects are
        // NOT in this library is the number that explains the total.
        // The check's index carries tombstones; a deleted project is not one
        // this library is missing.
        var rows: [PPProject] = (given ?? []).filter { !$0.isTombstone }
        if given == nil {
            do {
                let index: PPProjectIndex = try await client.get("projects")
                rows = index.projects
            } catch {
                LLog("picplace: could not read the account's index: \(error)")
            }
        }
        // With libraries kept apart (stage C) the figures are THIS library's:
        // its rows on the server, its bytes, and what of it is not here yet.
        // Without, the account's, as in v2.
        let scoped = rows.filter { inScope($0) }
        let count = (serverHasLibraries && scope != nil) ? scoped.count : (status.projects?.count ?? rows.count)
        let bytes = serverLibrary?.usedBytes ?? status.storage.usedBytes
        var missing: [PPProject] = []
        if let index = model.libraryIndex {
            missing = scoped.filter { row in
                guard let uuid = UUID(uuidString: row.uuid) else { return true }
                return ((try? index.projectID(originID: uuid)) ?? nil) == nil
            }
        }
        if !missing.isEmpty {
            LLog("picplace: \(missing.count) of the library's \(count) project(s) on PicPlace are not here: "
                 + missing.map { "\($0.name) (\($0.uuid.prefix(8)), \($0.type))" }.joined(separator: "; "))
        }
        usage = Usage(projects: count, bytes: bytes, notInLibrary: missing.count)
    }

    private func handleSignedOutByServer() {
        guard profile != nil else { return }
        for task in syncTasks.values { task.cancel() }
        syncTasks.removeAll()
        progress.removeAll()
        if let key = profile?.accountKey { Self.saveProfile(nil, for: key) }
        if let host = profile?.host { Self.setSession(nil, forHost: host) }
        profile = nil
        usage = nil
        lastSignInError = "PicPlace signed this device out. Sign in again."
    }

    // MARK: Connect / disconnect the library

    /// Where a library goes on PicPlace (stage C, libraries plan §3.7).
    enum ConnectTarget: Equatable {
        /// A new library on PicPlace named after this one: its projects go up, nothing arrives.
        case new
        /// Name the account's default library after this one and take its
        /// projects over — how an account from before libraries becomes a
        /// named library in one call (`adopt_default`).
        case adoptDefault
        /// Link this library to an existing one on PicPlace: the two sides
        /// are exchanged (fresh when this library is empty, merge otherwise).
        case link(PPLibrary)
    }

    /// What the connect sheet shows: the account's libraries, the counts,
    /// and the name this library would take.
    struct ConnectOffer: Equatable {
        var libraries: [PPLibrary]
        var defaultEntry: PPLibrary?
        var localCount: Int
        var suggestedName: String
        var needsName: Bool

        /// The numbers for a target: what goes up, what arrives.
        func summary(for target: ConnectTarget) -> String {
            let local = "\(localCount) project\(localCount == 1 ? "" : "s")"
            switch target {
            case .new:
                return localCount == 0
                    ? "An empty library on PicPlace; captures and imports go up as you make them."
                    : "This library's \(local) go up — records and a preview each; originals stay here until you upload them. Nothing arrives."
            case .adoptDefault:
                let n = defaultEntry?.count ?? 0
                return "The \(n) unfiled project\(n == 1 ? "" : "s") on PicPlace become this library"
                    + (localCount == 0 ? " and arrive here as previews." : "; what is here and not there goes up, what is there and not here arrives as previews, and projects on both sides stay in step.")
            case .link(let library):
                let n = library.count
                if localCount == 0 {
                    return "All \(n) project\(n == 1 ? "" : "s") of “\(library.displayName)” arrive here as previews; originals download per project. Nothing goes up."
                }
                return "“\(library.displayName)” holds \(n) project\(n == 1 ? "" : "s"), this library \(local). Everything there that isn't here arrives as previews, everything here that isn't there goes up, and projects on both sides stay in step."
            }
        }
    }

    /// The Connect buttons: raise the question (the cards present it) —
    /// for an unbound library, and for one bound before libraries that
    /// has to say which library it is (`.needsLibrary`).
    func offerConnect() {
        guard isSignedIn, binding == nil || libraryLink == .needsLibrary else { return }
        Task { await offerConnectNow() }
    }

    private func offerConnectNow() async {
        lastConnectError = nil
        isConnecting = true
        defer { isConnecting = false }
        guard let status: PPStatus = try? await client.get("status") else {
            lastConnectError = "PicPlace couldn't be reached to check what it holds. Try again."
            return
        }
        noteLimits(status)
        noteLibraries(status)
        var localCount = 0
        if let counts = try? model.libraryIndex?.categoryCounts(LibraryIndex.ProjectQuery()) {
            localCount = counts.values.reduce(0, +)
        }
        guard serverHasLibraries else {
            // A server from before libraries: v2's one-line question, the
            // merge refused (libraries plan L17), one library per account
            // on this Mac (L10).
            #if os(macOS)
            if let other = Self.otherLibraryBound(to: profile) {
                lastConnectError = "This Mac already syncs “\(other.name)” (\(other.path)) with @\(profile?.username ?? "") on \(sessionHost), and this PicPlace does not keep libraries apart yet."
                return
            }
            #endif
            let described = ConnectCase(serverCount: status.projects?.count ?? 0, localCount: localCount)
            if described.isMerge {
                lastConnectError = "PicPlace already holds \(described.serverCount) project\(described.serverCount == 1 ? "" : "s") "
                    + "and this library has \(described.localCount). This PicPlace does not keep libraries apart yet, so a library can only "
                    + "connect to an account that is empty or into an empty library. Not connected."
                LLog("picplace: connect refused — merge case (\(described.serverCount) on the server, \(described.localCount) here) on a server without libraries")
                return
            }
            connectCaseText = described.text
            connectOffer = nil
            isOfferingConnect = true
            return
        }
        let libraries = (status.libraries ?? []).filter { !$0.isDefault && !$0.isTombstone }
        let identity = StorageRoot.identity
        connectOffer = ConnectOffer(
            libraries: libraries,
            defaultEntry: (status.libraries ?? []).first { $0.isDefault && $0.count > 0 },
            localCount: localCount,
            suggestedName: identity?.displayName ?? LibraryIdentity.defaultName(forRoot: root),
            needsName: identity?.namedByPerson != true)
        connectCaseText = nil
        isOfferingConnect = true
    }

    /// Bind the open library to the signed-in account (v2 plan D2–D3) at
    /// `target` on PicPlace (stage C): write `PicPlace/account.json` with the
    /// server library's uuid; the library stays in its folder (L19).
    func connectLibrary(target: ConnectTarget = .new, name: String? = nil) {
        guard let profile, binding == nil || libraryLink == .needsLibrary, !isConnecting else { return }
        let choosingForExistingBinding = binding != nil
        isConnecting = true
        lastConnectError = nil
        Task {
            defer { isConnecting = false }
            do {
                // The name first (L16): it is what PicPlace calls the library.
                if let name, LibraryIdentity.cleanName(name) != StorageRoot.identity?.name || StorageRoot.identity?.namedByPerson != true {
                    try StorageRoot.renameIdentity(to: name)
                }
                var library: PicPlaceBindingRecord.Library?
                var initialCase: PicPlaceBindingRecord.InitialSync.Case = .clean
                if serverHasLibraries {
                    guard let identity = StorageRoot.identity else { throw PicPlaceSyncRun.Failed(caption: "This library has no identity file.") }
                    switch target {
                    case .new, .adoptDefault:
                        #if os(macOS)
                        if let other = Self.otherLibraryBound(toServerLibrary: identity.id) {
                            throw PicPlaceSyncRun.Failed(caption: "This Mac already syncs “\(other.name)” (\(other.path)) as that library.")
                        }
                        #endif
                        let created = try await createServerLibrary(uuid: identity.id, name: identity.displayName, adoptDefault: target == .adoptDefault)
                        library = .init(uuid: created.uuid, name: identity.displayName)
                        initialCase = created.adopted > 0 ? (localCountNow() == 0 ? .fresh : .merge) : .clean
                    case .link(let server):
                        guard let uuid = server.libraryUUID else { throw PicPlaceSyncRun.Failed(caption: "That library has no id.") }
                        #if os(macOS)
                        if let other = Self.otherLibraryBound(toServerLibrary: uuid) {
                            throw PicPlaceSyncRun.Failed(caption: "This Mac already syncs “\(other.name)” (\(other.path)) as “\(server.displayName)”. One copy per library on a Mac.")
                        }
                        #endif
                        // The local library becomes a copy of that one: its
                        // identity takes the server library's uuid and name.
                        try StorageRoot.adoptIdentity(id: uuid, name: server.displayName)
                        library = .init(uuid: uuid, name: server.displayName)
                        initialCase = localCountNow() == 0 ? .fresh : .merge
                    }
                }
                var record = binding ?? PicPlaceBindingRecord(
                    server: .init(url: profile.server, id: profile.serverID, environment: profile.serverEnvironment),
                    user: .init(uuid: profile.userUUID, username: profile.username, name: profile.name),
                    boundByDevice: DeviceIdentity.id)
                record.library = library
                record.initialSync = .init(state: .pending, case: initialCase)
                if choosingForExistingBinding {
                    // Records from the account-wide days describe rows this
                    // library may not own: the scoped first sync rebuilds them.
                    records = [:]
                }
                try record.write(inRoot: root)
                binding = record
                saveSyncState()
                LLog("picplace: library \(choosingForExistingBinding ? "filed" : "bound") to @\(profile.username) on \(record.server.host)\(library.map { " as “\($0.name)” \($0.uuid.uuidString.lowercased())" } ?? "") — \(initialCase.rawValue)")
                isOfferingConnect = false
                connectOffer = nil
                runInitialSyncIfPending()
                scheduleUsageRefresh()
            } catch {
                LLog("picplace: could not connect this library: \(error)")
                lastConnectError = (error as? PicPlaceAPIError)?.cardCaption ?? (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                isOfferingConnect = false
                connectOffer = nil
            }
        }
    }

    private func localCountNow() -> Int {
        (try? model.libraryIndex?.categoryCounts(LibraryIndex.ProjectQuery()))?.values.reduce(0, +) ?? 0
    }

    /// `PUT /libraries/{uuid}` — create (or rename) the server library this
    /// one is; `409 uuid_taken` (another account holds the uuid) re-mints the
    /// local identity and tries once more.
    private func createServerLibrary(uuid: UUID, name: String, adoptDefault: Bool) async throws -> (uuid: UUID, adopted: Int) {
        var id = uuid
        for attempt in 0..<2 {
            do {
                let response: PPLibraryResponse = try await client.put("libraries/\(id.uuidString.lowercased())", json: ["name": name, "adopt_default": adoptDefault])
                if let known = response.library.libraryUUID { id = known }
                return (id, response.adopted ?? 0)
            } catch let error as PicPlaceAPIError where error.code == "uuid_taken" && attempt == 0 {
                let fresh = UUID()
                LLog("picplace: library id \(id.uuidString.lowercased()) belongs to another account — re-minting as \(fresh.uuidString.lowercased())")
                try StorageRoot.adoptIdentity(id: fresh, name: name)
                id = fresh
            }
        }
        throw PicPlaceSyncRun.Failed(caption: "PicPlace refused the library's id twice.")
    }

    /// The bound library on the server, put back when a push finds it gone
    /// (`422 library_unknown`): the same uuid and name, no adoption.
    func ensureServerLibrary() async -> Bool {
        guard let scope, let binding else { return false }
        do {
            let _: PPLibraryResponse = try await client.put("libraries/\(scope.uuidString.lowercased())", json: ["name": binding.library?.name ?? StorageRoot.identity?.displayName ?? "Library", "adopt_default": false])
            return true
        } catch {
            LLog("picplace: could not re-create library \(scope.uuidString.lowercased()): \(error)")
            return false
        }
    }

    /// A rename here reaches the server library it is (last writer wins,
    /// asks §6 Q6); offline it waits for the next connect-time PUT.
    func libraryRenamed(_ name: String) {
        guard var record = binding, record.library != nil else { return }
        record.library?.name = name
        try? record.write(inRoot: root)
        binding = record
        guard canSync, serverHasLibraries, let scope else { return }
        Task {
            do {
                let _: PPLibraryResponse = try await client.put("libraries/\(scope.uuidString.lowercased())", json: ["name": name, "adopt_default": false])
                LLog("picplace: library renamed “\(name)” on \(sessionHost)")
            } catch {
                LLog("picplace: could not rename the library on the server: \(error)")
            }
        }
    }

    #if os(macOS)
    /// The account's libraries that no known library on this Mac is a copy
    /// of — what "Add Library from PicPlace…" offers (stage C, §3.7).
    var librariesNotOnThisMac: [PPLibrary] {
        guard isSignedIn, serverHasLibraries else { return [] }
        var held = Set<UUID>()
        if let scope { held.insert(scope) }
        for entry in LibraryRegistry.entries where entry.isReachable {
            if let uuid = PicPlaceBindingRecord.read(inRoot: entry.url)?.library?.uuid { held.insert(uuid) }
        }
        return serverLibraries.filter { !$0.isDefault && !$0.isTombstone && $0.libraryUUID.map { !held.contains($0) } == true }
    }

    /// A local copy of `library` in `container`, bound and pending its first
    /// pull; the caller switches to it (commit + relaunch).
    func addLibraryFromPicPlace(_ library: PPLibrary, in container: URL) throws -> URL {
        guard let profile, let uuid = library.libraryUUID else { throw PicPlaceSyncRun.Failed(caption: "That library has no id.") }
        let template = PicPlaceBindingRecord(
            server: .init(url: profile.server, id: profile.serverID, environment: profile.serverEnvironment),
            user: .init(uuid: profile.userUUID, username: profile.username, name: profile.name),
            boundByDevice: DeviceIdentity.id)
        let root = try StorageRoot.createFromPicPlace(library: .init(uuid: uuid, name: library.displayName), binding: template, in: container)
        LibraryRegistry.register(root: root, identity: LibraryIdentity.read(inRoot: root))
        return root
    }

    /// Another known, reachable library on this Mac bound to this ACCOUNT —
    /// v2's one-library-per-account rule, kept only for a server that does
    /// not keep libraries apart.
    private static func otherLibraryBound(to profile: Profile?) -> LibraryRegistry.Entry? {
        guard let profile else { return nil }
        let current = StorageRoot.current.standardizedFileURL.resolvingSymlinksInPath().path
        return LibraryRegistry.entries.first { entry in
            guard entry.isReachable,
                  entry.url.standardizedFileURL.resolvingSymlinksInPath().path != current,
                  let other = PicPlaceBindingRecord.read(inRoot: entry.url) else { return false }
            return other.matches(host: profile.host, userUUID: profile.userUUID, serverID: profile.serverID)
        }
    }

    /// Another known, reachable library on this Mac that is a copy of the
    /// same SERVER library (stage C's rule: one copy per library per Mac —
    /// presence is per device, and two copies would overwrite each other's).
    private static func otherLibraryBound(toServerLibrary uuid: UUID) -> LibraryRegistry.Entry? {
        let current = StorageRoot.current.standardizedFileURL.resolvingSymlinksInPath().path
        return LibraryRegistry.entries.first { entry in
            guard entry.isReachable,
                  entry.url.standardizedFileURL.resolvingSymlinksInPath().path != current,
                  let other = PicPlaceBindingRecord.read(inRoot: entry.url) else { return false }
            return other.library?.uuid == uuid
        }
    }
    #endif

    /// "Disconnect this library": the binding and the sync records go; the
    /// projects stay, keep their origin ids, and would fork if pushed under
    /// another account (v2 plan §4.6). The session is untouched.
    func disconnectLibrary() {
        for task in syncTasks.values { task.cancel() }
        syncTasks.removeAll()
        progress.removeAll()
        initialSyncTask?.cancel()
        initialSyncTask = nil
        initialSyncProgress = nil
        PicPlaceBindingRecord.remove(inRoot: root)
        binding = nil
        records = [:]
        LLog("picplace: library disconnected")
    }

    /// The project's revision as the server compares it: its last edit in
    /// milliseconds — ROUNDED, because the document encoder rounds the stamp
    /// to the millisecond and a device that reads the document back must
    /// compute the same number the device that wrote it sent (a truncated
    /// in-memory stamp read as "moved" one launch later, 2026-09-15).
    func revision(of capture: AppModel.CaptureProject) -> Int {
        Int((model.lastEdited(capture).timeIntervalSince1970 * 1000).rounded())
    }

    // MARK: Project state

    /// A project whose sources are not on this device and which PicPlace
    /// accounts for — it has a poster, or this library pulled it (v2 plan
    /// §3.6). A project whose files simply went missing is not this.
    func isPreviewOnly(_ capture: AppModel.CaptureProject) -> Bool {
        guard model.sourcesMissing(capture) else { return false }
        if model.posterURL(for: capture) != nil { return true }
        return records[model.originID(of: capture)]?.policy == "pull"
    }

    func state(for capture: AppModel.CaptureProject) -> ProjectState {
        #if DEBUG
        if let stagedState { return stagedState }
        #endif
        if let conflict = conflicts.first(where: { $0.originID == model.originID(of: capture) }) { return .conflict(conflict.kind) }
        if isPreviewOnly(capture) { return .previewOnly(records[model.originID(of: capture)]) }
        guard isSignedIn else { return .signedOut }
        guard canSync else { return .notConnected }
        if let progress = progress[capture.id] { return .syncing(progress) }
        guard let record = records[model.originID(of: capture)] else { return .notSynced }
        if let other = record.elsewhereLibrary { return .elsewhere(record.elsewhereName ?? libraryName(for: other)) }
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
        guard let capture = model.capture(id: captureID) else { return nil }
        if conflicts.contains(where: { $0.originID == model.originID(of: capture) }) { return .failed }
        if isPreviewOnly(capture) { return .previewOnly }
        guard canSync else { return nil }
        if progress[captureID] != nil { return .syncing }
        guard let record = records[model.originID(of: capture)] else { return nil }
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
                let detail: PPProjectDetail = try await client.get("projects/\(key.uuidString.lowercased())")
                let project = detail.project
                guard var record = records[key] else { return }
                record.alsoOn = project.presence.compactMap(\.device).filter { $0.id != profile?.deviceID }.map(\.name)
                let heavy = (detail.assets ?? []).filter { $0.status == "confirmed" && PicPlaceSyncInventory.isHeavy($0.name) }
                record.serverHeavyFiles = heavy.count
                record.serverHeavyBytes = heavy.reduce(0) { $0 + ($1.bytes ?? 0) }
                records[key] = record
                saveSyncState()
            } catch let error as PicPlaceAPIError where error.status == 404 {
                // Deleted on the server: this device's record no longer describes anything.
                records[key] = nil
                saveSyncState()
            } catch {
                // Offline: keep what we knew.
            }
        }
    }

    /// The caption's numbers for a project that has never been synced —
    /// what the policy would send, and what it would leave: a folder walk,
    /// once per project, off the main actor.
    func summary(for capture: AppModel.CaptureProject) -> FolderSummary? {
        if let summary = summaries[capture.id] { return summary }
        guard summaryTasks[capture.id] == nil else { return nil }
        let folder = model.projectFolderURL(for: capture)
        let id = capture.id
        let policy = self.policy
        summaryTasks[id] = Task { [weak self] in
            let summary = await Task.detached(priority: .utility) { () -> FolderSummary in
                let entries = (try? PicPlaceSyncRun.listFiles(in: folder)) ?? []
                let counted = PicPlaceSyncInventory.summary(of: PicPlaceSyncInventory.classify(entries), policy: policy)
                return FolderSummary(files: counted.objects, bytes: counted.bytes,
                                     heavyFiles: policy.sendsHeavy ? 0 : counted.heavyFiles,
                                     heavyBytes: policy.sendsHeavy ? 0 : counted.heavyBytes)
            }.value
            self?.summaries[id] = summary
            self?.summaryTasks[id] = nil
        }
        return nil
    }

    // MARK: Sync

    func sync(_ capture: AppModel.CaptureProject, policy override: PicPlaceSyncPolicy? = nil) {
        sync(capture, policy: override, retriedLibrary: false)
    }

    private func sync(_ capture: AppModel.CaptureProject, policy override: PicPlaceSyncPolicy?, retriedLibrary: Bool) {
        // Filed in another library of the account on PicPlace (stage C):
        // this library neither pushes nor pulls it. The card says where it is.
        if let other = records[model.originID(of: capture)]?.elsewhereLibrary {
            LLog("picplace: not syncing \(capture.displayTitle) — it is in library \(other) on PicPlace, not this one")
            return
        }
        guard canSync, syncTasks[capture.id] == nil else { return }
        let key = model.originID(of: capture)
        let policy = override ?? self.policy
        let folder = model.projectFolderURL(for: capture)
        let tier = model.sourcesMissing(capture) ? "preview" : "original"
        let project = PicPlaceSyncRun.Project(
            serverID: key,
            folder: folder,
            name: capture.displayTitle,
            type: capture.isPhotoCapture ? "photo" : (capture.kind == .video ? "video" : "interval"),
            revision: revision(of: capture),
            capturedAt: capture.createdAt,
            policy: policy,
            originUUID: capture.derivedFromOriginID,
            manifestMaxBytes: manifestMaxBytes,
            tier: tier,
            library: serverHasLibraries ? scope : nil)
        let run = PicPlaceSyncRun(client: client, project: project, thisDeviceID: profile?.deviceID) { [weak self] progress in
            self?.progress[capture.id] = progress
        }
        progress[capture.id] = PicPlaceSyncProgress()
        summaries[capture.id] = nil
        let server = profile?.server ?? serverString
        // The poster is rendered before the run walks the folder, so the
        // walk finds it (v2 plan §3.5); the grade token says whether the one
        // on disk is current.
        let grade = model.photoGrade(for: capture)
        let posterToken = grade.cacheToken
        let posterSource = model.thumbnailURL(for: capture)
        let posterKind = model.mediaKind(for: capture)
        let lastPosterToken = records[key]?.posterToken
        syncTasks[capture.id] = Task {
            do {
                // A preview-only project's "source" IS its poster: nothing to
                // render, the file it has is the one that goes.
                if policy.sendsRecords, let posterSource, posterSource.lastPathComponent != ProjectFileRegistry.posterName {
                    _ = await PicPlacePoster.ensure(sourceURL: posterSource, kind: posterKind, grade: grade, token: posterToken,
                                                    lastToken: lastPosterToken, in: folder)
                }
                var record = try await run.run()
                record.posterToken = posterToken
                if let previous = records[key] {
                    // A push of one policy keeps what the other recorded.
                    record.serverHeavyFiles = previous.serverHeavyFiles
                    record.serverHeavyBytes = previous.serverHeavyBytes
                    record.originalsMovedAt = previous.originalsMovedAt
                    record.serverConfirmedSeen = previous.serverConfirmedSeen
                    if policy == .minimal { record.posterToken = posterToken }
                }
                record.clearFailure()
                if policy.sendsHeavy {
                    record.originalsMovedAt = Date()
                    record.serverHeavyFiles = record.files
                    record.serverHeavyBytes = record.bytes
                    record.heavyFiles = 0
                    record.heavyBytes = 0
                }
                records[key] = record
            } catch is CancellationError {
                // Cancelled by the user: the card goes back to what it was.
            } catch let error as PicPlaceAPIError where error.code == "library_unknown" && !retriedLibrary {
                // The server no longer has this library (deleted or purged
                // elsewhere): put it back by its uuid and name, then push
                // once more (asks §6 Q2).
                LLog("picplace: the server does not know library \(scope?.uuidString ?? "?") — re-creating it and retrying \(capture.displayTitle)")
                progress[capture.id] = nil
                syncTasks[capture.id] = nil
                if await ensureServerLibrary() {
                    sync(capture, policy: override, retriedLibrary: true)
                } else {
                    var record = records[key] ?? PicPlaceSyncRecord(syncedAt: .distantPast, revision: 0, files: 0, bytes: 0, uploaded: 0, alsoOn: [], server: server, lastError: nil, policy: policy.rawValue)
                    record.noteFailure("PicPlace no longer has this library, and it could not be re-created.", policy: policy)
                    records[key] = record
                    saveSyncState()
                }
                return
            } catch let error as PicPlaceAPIError where error.code == "uuid_taken" {
                // Another account holds this origin id: the project is re-minted
                // as a fork of it here and pushed under its own id (§4.4).
                LLog("picplace: \(key) is taken by another account — re-minting \(capture.displayTitle) as a fork")
                progress[capture.id] = nil
                syncTasks[capture.id] = nil
                if let forkID = try? model.forkProjectForKeepBoth(capture.id), let fork = model.capture(id: forkID) {
                    sync(fork)
                } else {
                    var record = PicPlaceSyncRecord(syncedAt: .distantPast, revision: 0, files: 0, bytes: 0, uploaded: 0, alsoOn: [], server: server, lastError: nil, policy: policy.rawValue)
                    record.lastError = "This project's id belongs to another account, and it could not be re-minted here."
                    records[key] = record
                }
                saveSyncState()
                return
            } catch {
                LLog("picplace: sync of \(capture.displayTitle) (\(key.uuidString.prefix(8)), \(policy.rawValue)) failed: \(error)")
                lastSyncFailedOffline = error is PicPlaceOfflineError
                var record = records[key] ?? PicPlaceSyncRecord(syncedAt: .distantPast, revision: 0, files: 0, bytes: 0, uploaded: 0, alsoOn: [], server: server, lastError: nil, policy: policy.rawValue)
                record.noteFailure((error as? PicPlaceAPIError)?.cardCaption
                    ?? (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription, policy: policy)
                records[key] = record
            }
            saveSyncState()
            progress[capture.id] = nil
            syncTasks[capture.id] = nil
            scheduleUsageRefresh()
        }
    }

    /// The failed pushes of projects this library still holds live.
    var failedPushes: [(originID: UUID, localID: UUID, record: PicPlaceSyncRecord)] {
        records.compactMap { origin, record in
            guard record.lastError != nil, record.policy != "pull",
                  let localID = (try? model.libraryIndex?.projectID(originID: origin)) ?? nil else { return nil }
            return (origin, localID, record)
        }
    }

    func cancelSync(_ id: UUID) {
        syncTasks[id]?.cancel()
    }

    // MARK: Originals (stage 5, §4.5)

    /// What the card offers for a project's originals.
    enum OriginalsAction: Equatable {
        /// This device holds them; PicPlace does not (or not all of them).
        case upload(files: Int, bytes: Int64)
        /// PicPlace holds them; this device does not.
        case download(files: Int, bytes: Int64)
        /// Both hold them.
        case onBothSides
    }

    func originalsAction(for capture: AppModel.CaptureProject) -> OriginalsAction? {
        guard canSync, progress[capture.id] == nil else { return nil }
        let record = records[model.originID(of: capture)]
        if isPreviewOnly(capture) {
            let files = record?.serverHeavyFiles ?? record?.heavyFiles ?? 0
            let bytes = record?.serverHeavyBytes ?? record?.heavyBytes ?? 0
            return files > 0 ? .download(files: files, bytes: bytes) : nil
        }
        guard let record, record.lastError == nil else { return nil }
        // What this device holds comes from the folder walk (cached per
        // project); the record only knows what a push left behind.
        guard let local = summary(for: capture), local.heavyFiles > 0 else { return nil }
        if let onServer = record.serverHeavyFiles, onServer >= local.heavyFiles { return .onBothSides }
        if record.originalsMovedAt != nil { return .onBothSides }
        return .upload(files: local.heavyFiles, bytes: local.heavyBytes)
    }

    /// The `source/` media and `blends/` up, by hash (`SyncPolicy.originals`).
    func uploadOriginals(_ capture: AppModel.CaptureProject) {
        sync(capture, policy: .originals)
    }

    /// The `source/` media and `blends/` down, in pages of presigned URLs;
    /// the project stops being preview-only when the last listed frame is
    /// on disk. Cancel keeps what landed; a second run skips it.
    func downloadOriginals(_ capture: AppModel.CaptureProject) {
        guard canSync, syncTasks[capture.id] == nil else { return }
        let key = model.originID(of: capture)
        let folder = model.projectFolderURL(for: capture)
        let run = PicPlaceDownloadRun(client: client, projectUUID: key.uuidString.lowercased(), folder: folder) { [weak self] progress in
            self?.progress[capture.id] = progress
        }
        progress[capture.id] = PicPlaceSyncProgress(phase: .downloading)
        let server = profile?.server ?? serverString
        syncTasks[capture.id] = Task {
            do {
                let got = try await run.run()
                var record = records[key] ?? PicPlaceSyncRecord(syncedAt: Date(), revision: revision(of: capture), files: 0, bytes: 0, uploaded: 0, alsoOn: [], server: server, lastError: nil, policy: "pull")
                record.clearFailure()
                record.originalsMovedAt = Date()
                records[key] = record
                summaries[capture.id] = nil
                model.noteOriginalsArrived(for: capture.id)
                let _: [String: [PPPresence]]? = try? await client.post("projects/\(key.uuidString.lowercased())/presence", json: ["revision": record.revision, "tier": "original"])
                LLog("picplace: downloaded the originals of \(capture.displayTitle): \(got.files) file(s), \(got.bytes) bytes")
            } catch is CancellationError {
                model.noteOriginalsArrived(for: capture.id)
            } catch {
                LLog("picplace: download of \(capture.displayTitle)'s originals failed: \(error)")
                var record = records[key] ?? PicPlaceSyncRecord(syncedAt: .distantPast, revision: 0, files: 0, bytes: 0, uploaded: 0, alsoOn: [], server: server, lastError: nil, policy: "pull")
                record.noteFailure((error as? PicPlaceAPIError)?.cardCaption ?? (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, policy: .originals)
                records[key] = record
                model.noteOriginalsArrived(for: capture.id)
            }
            saveSyncState()
            progress[capture.id] = nil
            syncTasks[capture.id] = nil
        }
    }

    /// A sync the caller waits for — the first connection pushes one
    /// project at a time.
    func syncAndWait(_ capture: AppModel.CaptureProject, policy: PicPlaceSyncPolicy? = nil) async {
        sync(capture, policy: policy)
        await syncTasks[capture.id]?.value
    }

    // MARK: Persistence

    /// The cached profiles, one per account key (`letslapse.picplace.accounts`);
    /// the single-profile key from before is folded in once.
    private static func loadProfiles() -> [String: Profile] {
        var profiles: [String: Profile] = [:]
        if let data = UserDefaults.standard.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([String: Profile].self, from: data) {
            profiles = decoded
        }
        if let data = UserDefaults.standard.data(forKey: profileKey),
           let legacy = try? JSONDecoder().decode(Profile.self, from: data) {
            if profiles[legacy.accountKey] == nil { profiles[legacy.accountKey] = legacy }
            saveProfiles(profiles)
            UserDefaults.standard.removeObject(forKey: profileKey)
        }
        return profiles
    }

    private static func saveProfiles(_ profiles: [String: Profile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
    }

    private static func loadProfile(for accountKey: String) -> Profile? {
        loadProfiles()[accountKey]
    }

    private static func saveProfile(_ profile: Profile?, for accountKey: String) {
        var profiles = loadProfiles()
        profiles[accountKey] = profile
        saveProfiles(profiles)
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
        if moved > 0 { saveSyncState() }
        LLog("picplace: migrated \(moved) of \(decoded.count) v1 sync record(s) into the library")
    }

    /// v1 kept one Keychain item; it becomes the item of the account the
    /// stored profile names, and that account becomes the session.
    private static func migrateLegacyTokens() {
        guard let legacy = PicPlaceKeychain.loadLegacy() else { return }
        defer { PicPlaceKeychain.clearLegacy() }
        // v1's single profile (folded into the per-account map by `loadProfiles`).
        guard let profile = loadProfiles().values.first(where: { PicPlaceConfiguration.host(of: legacy.server) == $0.host }) else {
            LLog("picplace: a v1 sign-in with no matching profile was dropped; sign in again")
            return
        }
        do {
            try PicPlaceKeychain.save(legacy, account: profile.accountKey)
            // The install-wide pointer; `init` moves it into the library.
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
    private func dryRun(_ target: String) {
        let capture: AppModel.CaptureProject?
        if target == "latest" {
            capture = (try? model.libraryIndex?.projects(LibraryIndex.ProjectQuery()).rows.first)??.flatMap { model.capture(id: $0.id) }
        } else {
            capture = UUID(uuidString: target).flatMap { model.capture(id: $0) }
        }
        guard let capture else { LLog("picplace dry-run: no project for \(target)"); return }
        let folder = model.projectFolderURL(for: capture)
        let policy = self.policy
        let grade = model.photoGrade(for: capture)
        let source = model.thumbnailURL(for: capture)
        let kind = model.mediaKind(for: capture)
        Task.detached(priority: .utility) {
            let entries = (try? PicPlaceSyncRun.listFiles(in: folder)) ?? []
            let items = PicPlaceSyncInventory.classify(entries)
            let summary = PicPlaceSyncInventory.summary(of: items, policy: policy)
            var byRole: [String: (Int, Int64)] = [:]
            for item in items {
                let label: String
                switch item.role {
                case .manifest: label = "manifest"
                case .bundle: label = "bundle"
                case .object(let kind): label = "object:\(kind)"
                case .heavy(let kind): label = "heavy:\(kind)"
                case .skipped(let why): label = "skipped:\(why)"
                }
                byRole[label, default: (0, 0)].0 += 1
                byRole[label, default: (0, 0)].1 += item.bytes
            }
            for (label, count) in byRole.sorted(by: { $0.key < $1.key }) {
                LLog("picplace dry-run: \(label) — \(count.0) file(s), \(count.1) bytes")
            }
            LLog("picplace dry-run: policy \(policy.rawValue) → \(summary.objects) object(s), \(summary.bytes) bytes; bundle \(summary.bundleMembers) member(s) \(summary.bundleBytes) bytes; heavy \(summary.heavyFiles) file(s) \(summary.heavyBytes) bytes; strays \(summary.strays)")
            for item in items where item.role == .bundle { LLog("picplace dry-run: bundle member \(item.relativePath) (\(item.bytes) bytes)") }
            do {
                let archive = try PicPlaceSyncInventory.buildBundle(members: items.filter { $0.role == .bundle }, in: folder)
                let bytes = (try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                LLog("picplace dry-run: bundle written at \(archive.path) — \(bytes) bytes, sha256 \((try? PicPlaceSyncRun.sha256(of: archive)) ?? "?")")
            } catch {
                LLog("picplace dry-run: bundle failed: \(error)")
            }
            if let source {
                let poster = await PicPlacePoster.ensure(sourceURL: source, kind: kind, grade: grade, token: grade.cacheToken, lastToken: nil, in: folder)
                LLog("picplace dry-run: poster \(poster?.path ?? "none")")
            }
            LLog("picplace dry-run: done")
        }
    }

    private static func stagedState(from value: String?) -> ProjectState? {
        let demo = PicPlaceSyncRecord(syncedAt: Date().addingTimeInterval(-5 * 60), revision: 1, files: 3, bytes: 2_300_000,
                                      uploaded: 3, alsoOn: ["iPad Air"], server: PicPlaceConfiguration.serverString, lastError: nil,
                                      policy: "minimal", heavyFiles: 341, heavyBytes: 4_900_000_000)
        switch value {
        case "preview-only":
            var record = demo
            record.policy = "pull"; record.uploaded = 0; record.files = 2; record.bytes = 180_000
            return .previewOnly(record)
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

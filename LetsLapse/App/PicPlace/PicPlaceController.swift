import Combine
import Foundation
import Network
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

    /// The card's one line (libraries plan §17.12): this library's projects
    /// here, how many of them PicPlace has as this library (the server's
    /// count), the originals it holds, and the gap — not on PicPlace yet,
    /// and held here but filed under other libraries (originals, or a
    /// preview edited since it was pulled; other previews are removed by
    /// the check). Nothing about other libraries by name.
    struct LibraryTally: Equatable {
        var here = 0
        var onPicPlace = 0
        var originalsOnPicPlace = 0
        var notYet = 0
        var elsewhere = 0
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
    @Published private(set) var tally: LibraryTally?
    @Published internal(set) var records: [UUID: PicPlaceSyncRecord] = [:]
    @Published internal(set) var progress: [UUID: PicPlaceSyncProgress] = [:]
    @Published internal(set) var summaries: [UUID: FolderSummary] = [:]
    // Free up space (2026-09-23, `PicPlaceFreeUp.swift`).
    /// The server's heavy assets per project from the last fresh read this
    /// session, keyed by origin id — the card's per-file truth.
    @Published internal(set) var serverHeavy: [UUID: [PicPlaceOriginalsCheck.RemoteAsset]] = [:]
    /// The renditions PicPlace holds per project, read off the index rows
    /// at every check (picture tiers, push 1; nil from a server before them):
    /// the working-copy sweep's "another device already sent it", and the
    /// grid's tile pointer.
    @Published internal(set) var serverRenditions: [UUID: PPRenditions] = [:]
    /// When a view last asked for a project's list (`askForListing`), by
    /// origin id — a screen of rows asks once.
    var listingAskedAt: [UUID: Date] = [:]
    /// This device's heavy files per project (paths and sizes, no hashes)
    /// from the last folder walk, keyed by capture id.
    @Published internal(set) var heavyListings: [UUID: [PicPlaceOriginalsCheck.LocalFile]] = [:]
    var heavyListingTasks: [UUID: Task<Void, Never>] = [:]
    /// Projects whose files are being checked or removed right now: every
    /// other transfer of them waits (a push walking a folder mid-removal
    /// would hash files as they vanish).
    @Published internal(set) var removingProjects: Set<UUID> = []
    /// What the last removal on a project did or why it did not, for the card.
    @Published internal(set) var removalNotes: [UUID: String] = [:]
    /// Settings' *Remove originals already on PicPlace*: the estimate, the
    /// run and its result.
    @Published internal(set) var freeUp = FreeUpState()
    var freeUpTask: Task<Void, Never>?
    var freeUpEstimateTask: Task<Void, Never>?
    /// What the library, its files and the sync records were when the
    /// estimate was last worked out (`freeUpEstimateKey`): the card's
    /// appearances reuse it until one of them moves (2026-09-27).
    var freeUpEstimateKeySeen: [Int]?
    /// Moves whenever the sync records, the server's heavy lists or the
    /// upload jobs change — one of the keys the free-up estimate is
    /// remembered under (`armSyncFactsRevision`).
    private(set) var syncFactsRevision = 0
    private var syncFactsObservers: Set<AnyCancellable> = []
    /// The tally's one pass in flight and whether another was asked for
    /// meanwhile (`updateTally`).
    private var tallyTask: Task<Void, Never>?
    private var tallyRequested = false

    /// What a disconnect leaves (libraries plan L23): the previews pulled
    /// from PicPlace, which stay but cannot download until the library
    /// connects again, and the projects with their originals here.
    struct DisconnectSummary: Equatable {
        var previews: Int
        var originals: Int
    }
    /// Counted off the main actor as the confirm opens
    /// (`prepareDisconnectSummary`) — never in a view body, where it read
    /// every document of the library on each redraw (2026-09-27: thirteen
    /// hangs in Settings' first fourteen seconds). Nil until the first count
    /// lands; the last count stands while a newer one is made.
    @Published private(set) var disconnectSummary: DisconnectSummary?
    private var disconnectSummaryTask: Task<Void, Never>?
    /// A person's removal from the card, per project (Cancel stops it).
    var removalTasks: [UUID: Task<Void, Never>] = [:]
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
    /// Whether a `/status` of this session has said if the server has
    /// libraries at all. Until one has, `serverHasLibraries` is not "no" but
    /// "not known" — and a library's scope must never be read as the whole
    /// account in that state (2026-10-01: an iOS launch's foreground check
    /// merged before the handshake's answer landed and pulled every other
    /// library's previews into the open one, launch after launch).
    private(set) var librariesKnown = false
    @Published private(set) var serverLibraries: [PPLibrary] = []
    /// Whether the server answers `POST /projects/assets` (2026-09-24).
    private(set) var serverListsAssetsInBatches = false
    /// PicPlace keeps each library's collections (`features["collections"]`,
    /// docs/picplace-collections-ask.md) — the collections sync's switch.
    private(set) var serverSyncsCollections = false
    /// Picture tiers (docs/picture-tiers-plan.md; the server's contract is
    /// picplace `docs/letslapse-picture-tiers.md`): the index row carries
    /// rendition pointers (`features.renditions`, push 1); the server cuts a
    /// tile from every poster (`features.tiles`, the switch Steven turns on
    /// at picplace.co once this build is on the devices); the unclaimed
    /// batch endpoints exist (`features.rendition_batches`, push 2). Every
    /// path keeps today's behaviour while its flag is false.
    private(set) var serverHasRenditions = false
    private(set) var serverHasTiles = false
    private(set) var serverHasRenditionBatches = false
    /// `features.rendition_delete` (stage 5, proposed 2026-10-03): the
    /// server lets a device delete an exempt project's leftover working
    /// copy. Off until the developer ships it; nothing is sent before.
    private(set) var serverHasRenditionDelete = false
    /// `features.md5_uploads` (sync-cost step 2): an `md5` declared at
    /// negotiate is signed into the PUT and verifies the asset at confirm.
    private(set) var serverHasMD5Uploads = false
    private(set) var serverRenditionKinds: [String] = []
    /// The renditions' share of the account's storage (`storage.renditions`,
    /// push 2) — the Settings card's "working copies on PicPlace · N GB".
    @Published private(set) var serverRenditionsFigure: PPRenditionsFigure?
    /// Posters being fetched on open (stage 3's lazy posters), by project.
    var posterFetches: Set<UUID> = []
    /// The push a few seconds after a collection changes here.
    var collectionsPushTask: Task<Void, Never>?
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
    /// Blends go up on their own as they are rendered, under the same rules
    /// as every automatic send (D1, 2026-09-25) — on by default.
    @Published var autoBlendsEnabled: Bool = PicPlaceController.librarySettings.autoBlends ?? true {
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
            try PicPlaceLibrarySettings.save(.init(autoSync: autoSyncEnabled, autoOriginals: autoOriginalsEnabled,
                                                   autoBlends: autoBlendsEnabled), root: root, device: DeviceIdentity.id)
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
    /// Why each queued or held project is in the queue — `pushIfNeeded`
    /// reads it before sending (see `PushReason`).
    var pushReasons: [UUID: PushReason] = [:]
    /// A person's press put work in the queue (their check, Resume): it runs
    /// on mobile data and with auto-sync off, as the check itself did.
    var pushQueueManual = false
    /// The run of sending the Project Syncing drawer shows, from the first
    /// project queued to the queue running dry — kept through a pause.
    @Published internal(set) var sendRun: SendRun?
    /// The projects the current run has counted, so one held and released
    /// again is not counted twice.
    var sendRunIDs: Set<UUID> = []
    /// A person paused sending in the Project Syncing drawer (2026-09-24):
    /// nothing this device sends to PicPlace moves — the queued pushes, the
    /// check's catch-ups, the originals queue — until Resume. Kept in the
    /// library's sync state, so it outlives a relaunch. Pulls, removals and
    /// a person's own per-project Sync, Upload or Download are not held.
    @Published internal(set) var sendsPaused = false
    /// A person's originals uploads, by project (2026-09-24,
    /// `PicPlaceUploadJobs.swift`) — running, paused, waiting for Wi-Fi or
    /// for the connection. Kept in the library's sync state.
    @Published internal(set) var uploadJobs: [UUID: PicPlaceUploadJob] = [:]
    /// The stop signal of every originals run in flight, by project — a
    /// job's and the originals queue's: Pause, the Wi-Fi rule and iOS's
    /// suspension stop them between files.
    var uploadStops: [UUID: PicPlaceStopSignal] = [:]
    /// Jobs a person cancelled while their run was stopping.
    var cancelledUploads: Set<UUID> = []
    /// An interrupted job's next try, and how many in a row got nowhere.
    var uploadRetryTasks: [UUID: Task<Void, Never>] = [:]
    var uploadRetryCounts: [UUID: Int] = [:]
    /// The originals queue running is a person's (`runOriginalsQueueManually`),
    /// and whether the Wi-Fi rule stopped it — it carries on when Wi-Fi is
    /// back. Settings' button no longer runs it (2026-09-27: it queues upload
    /// jobs); the path is up for removal — TODO.md.
    var originalsQueueManual = false
    /// Settings' *Queue upload* was pressed before the estimate it reads
    /// existed (the launch hook): queue once the estimate lands.
    var queueUploadsAfterEstimate = false
    /// `LL_PICPLACE_FREEUP=copies`: the stale working copies go once the
    /// estimate that finds them lands (stage 5).
    var removeStaleCopiesAfterEstimate = false
    /// The originals queue's last run was stopped between files (Pause, the
    /// Wi-Fi rule, iOS suspending the app): the walk stops too, rather than
    /// start the next project into the same stop.
    var originalsRunPaused = false
    @Published internal(set) var manualOriginalsWaiting = false
    /// The account's nearby key as this device holds it
    /// (PicPlaceNearbyKey.swift, docs/nearby-originals-plan.md §5): nil
    /// until PicPlace offers one and this device has fetched it.
    @Published internal(set) var nearbyKey: PicPlaceNearbyKey?
    /// The last `/status` said PicPlace hands out the key.
    @Published internal(set) var serverOffersNearbyKey = false
    var nearbyKeyFetch: Task<Void, Never>?
    /// When an unrecognised peer last sent this device back to `/status`.
    var nearbyStatusRereadAt: Date?
    /// Whether any network is up at all — an interrupted upload waits for it.
    var isNetworkUp = true
    /// Pushes and a check that were due while the network rule — or a
    /// pause, or PicPlace not answering — held them. Published for the
    /// drawer's "N changes waiting".
    @Published var heldPushes: Set<UUID> = []
    var heldCheck = false
    var forcedNetwork = false
    var autoTimer: Timer?
    /// Stood down for a library switch (L22): nothing re-arms, nothing runs.
    private(set) var isShutDown = false
    var originalsQueueTask: Task<Void, Never>?
    /// The walk that sends blends on their own (D1, `runBlendsQueue`).
    var blendsQueueTask: Task<Void, Never>?
    /// The working-copy sweep (picture tiers, stage 1).
    var proxyQueueTask: Task<Void, Never>?
    /// DEBUG, `LL_RENDITIONS=sweep`: the Simulator reports no battery, so a
    /// bench sweep there ignores the charger rule.
    var proxySweepIgnoresCharger = false
    /// The last renditions tally the check logged, so the line appears when
    /// the pointers move and not at every check.
    var renditionsTallyLogged: (posters: Int, tiles: Int, proxies: Int)?
    /// A running transfer's background activity, by project — its progress
    /// goes to the Lock Screen when a continued task holds the app.
    var transferActivities: [UUID: PicPlaceBackgroundActivity] = [:]
    /// The walk again once PicPlace has read back what an upload left it
    /// checking (`scheduleHeavyRecheck`).
    var heavyRecheckTask: Task<Void, Never>?
    /// Heavy sets (by digest) the blends queue found incomplete for want of
    /// something it does not send — not read again until the set moves.
    var heavySetMissing: [UUID: String] = [:]
    /// The projects whose upload PicPlace was still reading back, by
    /// capture id, with when each began to wait, and the one sweep that
    /// looks at all of them (`verifyAfterUpload`).
    var verifyPending: [UUID: Date] = [:]
    var verifySweep: Task<Void, Never>?
    /// Heavy lists the queues read ahead of the row they were on
    /// (`heavyListReadAhead`), by origin, and when the oldest was read.
    var heavyAhead: [UUID: [PPAsset]] = [:]
    var heavyAheadReadAt = Date.distantPast
    var pathMonitorBox: AnyObject?
    /// One usage refresh for a whole run of syncs, not two requests per project.
    var usageRefreshTask: Task<Void, Never>?
    /// Whether the last sync to fail did so because the server could not be
    /// reached at all — the queue stops on that rather than fail through
    /// its remaining projects one slow timeout at a time.
    var lastSyncFailedOffline = false
    /// PicPlace gave no answer at all (2026-09-29) — no route, a timeout, a
    /// certificate that isn't PicPlace's (a network intercepting it). Until
    /// this passes nothing automatic asks it anything: checks, pushes,
    /// poster catch-ups, the blends and originals walks, upload retries,
    /// usage and listing reads. What was due waits in `heldPushes`, and the
    /// first check back finds whatever differs anyway — nothing piles up. A
    /// person's press still goes; any answer, a network change or the end
    /// of the backoff (`reachabilityProbe`) opens it again.
    @Published var unreachableUntil: Date?
    /// No-answer failures in a row with the gate open — the backoff: 1, 2,
    /// 4, 8, 16, then 30 minutes.
    var unreachableStreak = 0
    /// The one look once the backoff has run out.
    var reachabilityProbe: Task<Void, Never>?
    /// What the last whole blends and originals walks saw, and when
    /// (2026-09-29): after a check that changed nothing, a walk reads every
    /// project to the same end — every three minutes, all night.
    var blendsWalkSeen: (key: WalkKey, at: Date)?
    var proxyWalkSeen: (key: WalkKey, at: Date)?
    var originalsWalkSeen: (key: WalkKey, at: Date)?
    /// The first two are legacy install-wide keys: read once into the
    /// library's `settings.json` (then removed), and still honoured from
    /// the argument domain for a run.
    static let autoSyncKey = "letslapse.picplace.autoSync"
    static let autoOriginalsKey = "letslapse.picplace.autoOriginals"
    static let wifiOnlyKey = "letslapse.picplace.wifiOnly"
    /// The server's watermark from the last index read (stage 4).
    var syncMeta = PicPlaceSyncState.Meta()

    /// Asks for the sync state to be written — soon, once. The file is one
    /// document rewritten whole (741 KB at 1,553 records), and a run of
    /// pushes or pulls asked for it once per project and more (2026-10-01:
    /// thirty call sites); the asks of a second and a half now share one
    /// write. Leaving the app, quitting and a library switch write at once
    /// (`flushSyncState`). A kill inside the window loses at most that
    /// window's records, which the file's own contract covers: this device's
    /// row in the server's `presence[]` carries the same revision.
    func saveSyncState() {
        syncStateDirty = true
        guard syncStateWrite == nil else { return }
        syncStateWrite = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.syncStateWrite = nil
            self?.flushSyncState()
        }
    }

    /// Writes the sync state now if anything asked since the last write.
    func flushSyncState() {
        syncStateWrite?.cancel()
        syncStateWrite = nil
        guard syncStateDirty else { return }
        syncStateDirty = false
        PicPlaceSyncState.save(records, meta: syncMeta, root: root)
    }

    private var syncStateDirty = false
    private var syncStateWrite: Task<Void, Never>?
    private var syncStateObservers: [NSObjectProtocol] = []

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
        // The coalesced sync-state write lands before the app can be suspended or quit.
        #if os(iOS)
        let leaving = [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification]
        #else
        let leaving = [NSApplication.willResignActiveNotification, NSApplication.willTerminateNotification]
        #endif
        syncStateObservers = leaving.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushSyncState() }
            }
        }
        binding = PicPlaceBindingRecord.read(inRoot: root)
        if binding == nil, PicPlaceBindingRecord.exists(inRoot: root) {
            LLog("picplace: \(PicPlaceBindingRecord.fileName) exists but could not be read — treating the library as unbound; the file is left as it is")
        }
        let loaded = PicPlaceSyncState.load(root: root)
        records = loaded.records
        syncMeta = loaded.meta
        sendsPaused = loaded.meta.sendsPaused ?? false
        uploadJobs = Self.loadUploadJobs(loaded.meta)
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
        #if DEBUG
        // A run with injected tokens (`LL_PICPLACE_TOKENS`, the bench) never
        // reads the Keychain: an unsigned build asking for a stored session
        // raises a SecurityAgent prompt on the person's screen and blocks
        // the launch behind it (2026-09-17, a bound scratch root).
        if ProcessInfo.processInfo.environment["LL_PICPLACE_TOKENS"] != nil, sessionKey != nil {
            LLog("picplace: injected tokens — the stored session is not read")
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
            // The two sides by origin id, so every sentence the sheet can say
            // shows: 398 originals here, 12 previews of the first library
            // here, each library's rows on the server, 12 unfiled.
            var serverRows: [UUID: UUID?] = [:]
            var demoNames: [UUID: String] = [:]
            var previews = Set<UUID>()
            for (i, library) in demo.enumerated() {
                guard let uuid = library.libraryUUID else { continue }
                demoNames[uuid] = library.displayName
                for k in 0..<library.count {
                    let origin = UUID()
                    serverRows[origin] = .some(uuid)
                    if i == 0, k < 12 { previews.insert(origin) }
                }
            }
            for _ in 0..<12 { serverRows[UUID()] = .some(nil) }
            connectOffer = ConnectOffer(
                libraries: demo,
                defaultEntry: PPLibrary(uuid: nil, name: nil, projects: .init(count: 12, byType: nil, deleted: nil), usedBytes: 0,
                                        createdBy: nil, updatedBy: nil, deletedBy: nil, createdAt: nil, updatedAt: nil, deletedAt: nil),
                suggestedName: StorageRoot.identity?.displayName ?? "Prague LetsLapse Shots",
                needsName: StorageRoot.identity?.namedByPerson != true,
                former: nil,
                originalsHere: Set((0..<398).map { _ in UUID() }),
                previewsHere: previews,
                serverRows: serverRows,
                libraryNames: demoNames,
                deviceWord: Self.deviceWord)
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
        // `LL_PICPLACE_OFFER=1|new|adopt|link:<uuid>` opens the REAL connect
        // sheet once the session is up — the numbers off the server — with
        // that target selected: the bench's way to look at the sheet before
        // pressing Connect through accessibility.
        if let raw = ProcessInfo.processInfo.environment["LL_PICPLACE_OFFER"] {
            Task { @MainActor in
                for _ in 0..<60 where !self.isSignedIn || !self.serverHasLibraries { try? await Task.sleep(nanoseconds: 500_000_000) }
                switch raw {
                case "new": self.hookInitialTarget = .new
                case "adopt": self.hookInitialTarget = .adoptDefault
                default:
                    if raw.hasPrefix("link:"), let uuid = UUID(uuidString: String(raw.dropFirst(5))) {
                        self.hookInitialTarget = self.serverLibraries.first { $0.libraryUUID == uuid }.map { .link($0) }
                    }
                }
                self.offerConnect()
            }
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
        #if DEBUG
        PicPlaceTransfer.armHooks()
        #endif
        client = PicPlaceClient(tokens: tokens, accountKey: tokensKey, signedOut: { [weak self] in
            Task { @MainActor in self?.handleSignedOutByServer() }
        }, reachability: { [weak self] answered in
            Task { @MainActor in self?.noteServerAnswered(answered) }
        })
        // The nearby key held from an earlier run: the service can find the
        // account's devices before `/status` answers — or with no internet.
        restoreNearbyKey()
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
        armSyncFactsRevision()
    }

    /// `syncFactsRevision` follows the records, the server's heavy lists and
    /// the upload jobs — what the free-up estimate's judgement reads — so a
    /// remembered estimate is known to be current or not without comparing
    /// the dictionaries themselves.
    private func armSyncFactsRevision() {
        $records.dropFirst().removeDuplicates()
            .sink { [weak self] _ in self?.syncFactsRevision &+= 1 }
            .store(in: &syncFactsObservers)
        $serverHeavy.dropFirst().removeDuplicates()
            .sink { [weak self] _ in self?.syncFactsRevision &+= 1 }
            .store(in: &syncFactsObservers)
        $uploadJobs.dropFirst().map { Set($0.keys) }.removeDuplicates()
            .sink { [weak self] _ in self?.syncFactsRevision &+= 1 }
            .store(in: &syncFactsObservers)
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
        dropNearbyKey(reason: "signed out", accountKey: key)
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
            noteNearbyKeyRefusal(error)
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
        librariesKnown = true
        serverLibraries = status.libraries ?? []
        // Not a library matter, but read off the same answer: many
        // projects' asset lists in one request — what the check asks when a
        // filing (or a pull) left posters unnoted (`settlePosters`).
        serverListsAssetsInBatches = status.features["asset_lists_batch"] == true
        serverSyncsCollections = status.features["collections"] == true
        let tiersBefore = (serverHasRenditions, serverHasTiles, serverHasRenditionBatches, serverHasRenditionDelete)
        serverHasRenditions = status.features["renditions"] == true
        serverHasTiles = status.features["tiles"] == true
        serverHasRenditionBatches = status.features["rendition_batches"] == true
        serverHasRenditionDelete = status.features["rendition_delete"] == true
        serverHasMD5Uploads = status.features["md5_uploads"] == true
        serverRenditionKinds = status.limits?.renditionKinds ?? []
        // The Settings card's row is the bound library's: its own figure
        // when `/status` lists it, else the account's (stage 5).
        let scopeUUID = scope?.uuidString.lowercased()
        serverRenditionsFigure = status.libraries?.first { $0.uuid?.lowercased() == scopeUUID }?.renditions ?? status.storage.renditions
        if tiersBefore != (serverHasRenditions, serverHasTiles, serverHasRenditionBatches, serverHasRenditionDelete) {
            // Once per change, so a production check shows what the server
            // says (picture tiers: push 1 = pointers, the tile switch; push 2
            // = the batch endpoints).
            LLog("picplace: picture tiers on \(sessionHost) — rendition pointers \(serverHasRenditions ? "on" : "off"), tiles \(serverHasTiles ? "on" : "off"), rendition batches \(serverHasRenditionBatches ? "on" : "off"), rendition delete \(serverHasRenditionDelete ? "on" : "off"), md5 uploads \(serverHasMD5Uploads ? "on" : "off")\(serverRenditionKinds.isEmpty ? "" : " (\(serverRenditionKinds.joined(separator: ", ")))")")
        }
        noteNearbyKey(status)
        #if DEBUG
        // `LL_PICPLACE_NO_BATCH=1`: behave as a server without the batched
        // read — every unnoted poster goes through the push queue (how the
        // queue's progress and Pause are exercised on the bench).
        if ProcessInfo.processInfo.environment["LL_PICPLACE_NO_BATCH"] != nil { serverListsAssetsInBatches = false }
        #endif
    }

    func noteLimits(_ status: PPStatus) {
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

    /// Returns the freshest `/status` it holds: the one given, or the one
    /// read after a repair changed the account's libraries — the only time
    /// it reads again (2026-10-01: it re-read after every call, repaired or
    /// not, which was two of the five requests of every idle check).
    @discardableResult
    func repairBindingLibraryIfMissing(_ status: PPStatus) async -> PPStatus {
        // A binding without a library is `.needsLibrary`: the person chooses
        // on the sheet (`connectLibrary(target:)` fills the binding in);
        // nothing is minted or assigned on their behalf.
        guard status.hasLibraries, canSync, let record = binding, let library = record.library else { return status }
        let uuid = library.uuid.uuidString.lowercased()
        var libraries = status.libraries ?? []
        var changed = false
        do {
            if !libraries.contains(where: { $0.libraryUUID == library.uuid }) {
                let created: PPLibraryResponse = try await client.put("libraries/\(uuid)", json: ["name": library.name, "adopt_default": false])
                LLog("picplace: library “\(library.name)” \(uuid) was not on \(sessionHost) — created (\(created.library.count) projects there)")
                libraries.append(created.library)
                changed = true
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
                    changed = true
                } else {
                    LLog("picplace: none of the account's \(unfiled) unfiled project(s) is held here — left unfiled")
                }
            }
            // The account's libraries moved: read their counts again. Nothing
            // moved: the caller's answer is still the answer.
            guard changed else { return status }
            if let refreshed: PPStatus = try? await client.get("status") {
                noteLibraries(refreshed)
                return refreshed
            }
            serverLibraries = libraries
        } catch {
            LLog("picplace: could not put the library's scope right on \(sessionHost): \(error)")
        }
        return status
    }

    /// The Settings card's "On PicPlace" line: how many of this account's
    /// projects are on the server and the bytes they take. `rows` spares
    /// the index read when the caller has just read it (the check).
    func refreshUsage(rows: [PPProject]? = nil) {
        // Not while PicPlace is silent: the card keeps its last figures, and
        // the check after its answer refreshes them (2026-09-29).
        guard isSignedIn, !isUnreachable else { return }
        Task {
            do {
                let status: PPStatus = try await client.get("status")
                noteLimits(status)
                noteLibraries(status)
                let latest = await repairBindingLibraryIfMissing(status)
                await refreshUsage(status: latest, rows: rows)
            } catch {
                // A disabled account or a revoked device ends the nearby
                // key's use here; anything else is the next read's.
                noteNearbyKeyRefusal(error)
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

    /// The same from a `/status` the caller already holds — the check's own,
    /// read at its start (2026-10-01: the check read it again here, and the
    /// repair read it a fourth time).
    func refreshUsage(status: PPStatus, rows given: [PPProject]? = nil) async {
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
            // One read of every id a live project answers to, then a set
            // lookup per server row (2026-09-29). It was one index query per
            // row, each a table scan — 1,388 of them took 0.4–0.9 s on the
            // main thread after every check (2026-09-27), then as long off
            // it. Still off the main actor: the index has its own lock.
            let candidates = scoped
            missing = await Task.detached(priority: .utility) {
                let here = (try? index.liveProjectIdentities()) ?? []
                return candidates.filter { row in
                    guard let uuid = UUID(uuidString: row.uuid) else { return true }
                    return !here.contains(uuid)
                }
            }.value
        }
        if !missing.isEmpty {
            LLog("picplace: \(missing.count) of the library's \(count) project(s) on PicPlace are not here: "
                 + missing.map { "\($0.name) (\($0.uuid.prefix(8)), \($0.type))" }.joined(separator: "; "))
        }
        usage = Usage(projects: count, bytes: bytes, notInLibrary: missing.count)
        updateTally()
    }

    /// The tally from this library's rows and records, after every usage
    /// refresh (which follows every check and the first pass). Every
    /// project's document is read for it, so it is read off the main actor
    /// (`LibraryPass`) a second after the last request — the check, the
    /// card's appearance and a photo's registration ask within a beat of
    /// each other, and one pass answers them all (2026-09-27: on the main
    /// actor it stopped the app for half a second after every photo).
    func updateTally() {
        guard usage != nil, model.libraryIndex != nil else {
            tally = nil
            tallyRequested = false
            return
        }
        tallyRequested = true
        guard tallyTask == nil else { return }
        tallyTask = Task { [weak self] in
            defer { self?.tallyTask = nil }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            while self.tallyRequested, !self.isShutDown {
                self.tallyRequested = false
                await self.computeTally()
            }
        }
    }

    /// One pass, and the counts from it against the records as they are now.
    private func computeTally() async {
        guard let snapshot = await model.libraryPass(name: "picplace tally"), let usage else { tally = nil; return }
        var t = LibraryTally(here: snapshot.rows.count, onPicPlace: usage.projects)
        for project in snapshot.projects {
            let record = records[project.originID]
            if let record, record.elsewhereLibrary != nil { t.elsewhere += 1; continue }
            if let record, record.recordsReachedServer {
                if (record.serverHeavyFiles ?? 0) > 0 || record.originalsMovedAt != nil { t.originalsOnPicPlace += 1 }
            } else if !project.sourcesMissing {
                t.notYet += 1
            }
        }
        tally = t
    }

    private func handleSignedOutByServer() {
        guard profile != nil else { return }
        for task in syncTasks.values { task.cancel() }
        syncTasks.removeAll()
        progress.removeAll()
        if let key = profile?.accountKey { Self.saveProfile(nil, for: key) }
        if let host = profile?.host { Self.setSession(nil, forHost: host) }
        dropNearbyKey(reason: "signed out by PicPlace", accountKey: profile?.accountKey)
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

    /// What the connect sheet shows: the account's libraries, this
    /// library's rows and the server's, and the name this library would
    /// take. The numbers per target come from the two sides' origin ids
    /// (libraries plan L23, L24): what goes up is what has its originals
    /// here and is on PicPlace nowhere; what arrives is what the target
    /// holds and this library does not; a preview here that the target
    /// cannot account for is removed.
    #if DEBUG
    /// `LL_PICPLACE_OFFER`'s target, copied into the offer it opens.
    var hookInitialTarget: ConnectTarget?
    #endif

    struct ConnectOffer: Equatable {
        var libraries: [PPLibrary]
        var defaultEntry: PPLibrary?
        var suggestedName: String
        var needsName: Bool
        /// The server library this folder was before — its identity carries
        /// that library's uuid (a link adopted it, a create minted it): the
        /// sheet leads with linking to it again.
        var former: PPLibrary?
        /// This library's live rows by origin id: those whose originals are
        /// here, and the previews pulled from PicPlace.
        var originalsHere: Set<UUID> = []
        var previewsHere: Set<UUID> = []
        /// The account's live rows: origin id → the library each is filed in
        /// (nil = unfiled). Absent = not on PicPlace.
        var serverRows: [UUID: UUID?] = [:]
        var libraryNames: [UUID: String] = [:]
        /// "this Mac" · "this iPhone" · "this iPad".
        var deviceWord: String = "this device"
        /// The target the sheet opens on when a launch hook chose one
        /// (`LL_PICPLACE_OFFER`); else the sheet leads with `former`.
        var initialTarget: ConnectTarget?

        /// What can go up — the projects with their originals here.
        var localCount: Int { originalsHere.count }

        struct Numbers: Equatable {
            var arrive = 0
            var alreadyHere = 0
            var goUp = 0
            var elsewhere = 0
            var evicted = 0
            /// The removed previews by the library PicPlace files them in;
            /// "" for one no longer on PicPlace.
            var evictedFrom: [String: Int] = [:]
        }

        /// The rows the target holds: none for a new library, the unfiled
        /// for the default, the library's for a link.
        private func held(by target: ConnectTarget) -> Set<UUID> {
            switch target {
            case .new: return []
            case .adoptDefault: return Set(serverRows.filter { $0.value == nil }.map(\.key))
            case .link(let library):
                guard let uuid = library.libraryUUID else { return [] }
                return Set(serverRows.filter { $0.value == uuid }.map(\.key))
            }
        }

        func numbers(for target: ConnectTarget) -> Numbers {
            let held = held(by: target)
            let here = originalsHere.union(previewsHere)
            var n = Numbers()
            n.arrive = held.subtracting(here).count
            n.alreadyHere = held.intersection(here).count
            n.goUp = originalsHere.filter { serverRows[$0] == nil }.count
            n.elsewhere = originalsHere.filter { serverRows[$0] != nil && !held.contains($0) }.count
            for origin in previewsHere where !held.contains(origin) {
                n.evicted += 1
                let name: String
                if let filed = serverRows[origin] {
                    name = filed.flatMap { libraryNames[$0] } ?? (filed == nil ? "unfiled" : "another library")
                } else {
                    name = ""
                }
                n.evictedFrom[name, default: 0] += 1
            }
            return n
        }

        /// The numbers for a target, as a sentence or three.
        func summary(for target: ConnectTarget) -> String {
            let n = numbers(for: target)
            var parts: [String] = []
            switch target {
            case .new:
                if n.goUp == 0, n.evicted == 0, n.elsewhere == 0 {
                    return "An empty library on PicPlace; captures and imports go up as you make them."
                }
            case .adoptDefault:
                let count = defaultEntry?.count ?? 0
                parts.append("The \(count) unfiled \(count == 1 ? "project" : "projects") on PicPlace become this library.")
            case .link:
                break
            }
            if n.arrive > 0 {
                let all = n.alreadyHere == 0 && n.arrive > 1 ? "All " : ""
                parts.append("\(all)\(n.arrive) \(n.arrive == 1 ? "arrives here as a preview" : "arrive here as previews"); originals download per project.")
            }
            if n.alreadyHere > 0 {
                parts.append("\(n.alreadyHere) already here \(n.alreadyHere == 1 ? "stays" : "stay") in step.")
            }
            if n.goUp > 0 {
                parts.append("\(n.goUp) here \(n.goUp == 1 ? "goes" : "go") up — records and a preview each; originals stay here until you upload them.")
            }
            if n.elsewhere > 0 {
                parts.append("\(n.elsewhere) here \(n.elsewhere == 1 ? "is" : "are") filed in other libraries on PicPlace and \(n.elsewhere == 1 ? "stays as it is" : "stay as they are").")
            }
            if n.evicted > 0 {
                let from: String
                let named = n.evictedFrom.keys.filter { !$0.isEmpty }
                if n.evictedFrom.count == 1, let only = named.first {
                    from = " of “\(only)”"
                } else if n.evictedFrom.count == 1 {
                    from = " no longer on PicPlace"
                } else {
                    from = " of other libraries"
                }
                let stay = n.evictedFrom.keys.contains("") && n.evictedFrom.count == 1 ? "" : "; they stay on PicPlace"
                parts.append("\(n.evicted) \(n.evicted == 1 ? "preview" : "previews")\(from) \(n.evicted == 1 ? "is" : "are") removed from \(deviceWord)\(stay).")
            }
            if n.arrive == 0 { parts.append("Nothing arrives.") }
            if n.goUp == 0 { parts.append("Nothing goes up.") }
            return parts.joined(separator: " ")
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
        // This library's rows by origin id — what has its originals here
        // and what is a preview pulled from PicPlace (L24: only the first
        // can go up). A project whose files simply went missing is neither.
        var originalsHere = Set<UUID>()
        var previewsHere = Set<UUID>()
        if let snapshot = await model.libraryPass(name: "picplace connect offer") {
            for project in snapshot.projects {
                if isPreviewOnly(project) {
                    previewsHere.insert(project.originID)
                } else if !project.sourcesMissing {
                    originalsHere.insert(project.originID)
                }
            }
        }
        let localCount = originalsHere.count
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
        // The account's rows and where each is filed: what the sheet says
        // per target — arrives, in step, goes up, removed — comes from these
        // and this library's, by origin id (L23, L24).
        guard let index: PPProjectIndex = try? await client.get("projects") else {
            lastConnectError = "PicPlace couldn't be reached to check what it holds. Try again."
            return
        }
        var serverRows: [UUID: UUID?] = [:]
        for row in index.projects where !row.isTombstone {
            guard let origin = UUID(uuidString: row.uuid) else { continue }
            serverRows[origin] = .some(row.libraryUUID)
        }
        var names: [UUID: String] = [:]
        for library in status.libraries ?? [] {
            if let uuid = library.libraryUUID { names[uuid] = library.displayName }
        }
        let identity = StorageRoot.identity
        connectOffer = ConnectOffer(
            libraries: libraries,
            defaultEntry: (status.libraries ?? []).first { $0.isDefault && $0.count > 0 },
            suggestedName: identity?.displayName ?? LibraryIdentity.defaultName(forRoot: root),
            needsName: identity?.namedByPerson != true,
            former: identity.flatMap { id in libraries.first { $0.libraryUUID == id.id } },
            originalsHere: originalsHere,
            previewsHere: previewsHere,
            serverRows: serverRows,
            libraryNames: names,
            deviceWord: Self.deviceWord)
        #if DEBUG
        connectOffer?.initialTarget = hookInitialTarget
        #endif
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
                        if let other = Self.otherLibraryBound(toServerLibrary: identity.id) {
                            throw PicPlaceSyncRun.Failed(caption: "\(Self.deviceWordCapitalized) already syncs “\(other.name)” (\(other.place)) as that library.")
                        }
                        let created = try await createServerLibrary(uuid: identity.id, name: identity.displayName, adoptDefault: target == .adoptDefault)
                        library = .init(uuid: created.uuid, name: identity.displayName)
                        if created.adopted > 0 {
                            initialCase = await localCountNow() == 0 ? .fresh : .merge
                        } else {
                            initialCase = .clean
                        }
                    case .link(let server):
                        guard let uuid = server.libraryUUID else { throw PicPlaceSyncRun.Failed(caption: "That library has no id.") }
                        if let other = Self.otherLibraryBound(toServerLibrary: uuid) {
                            throw PicPlaceSyncRun.Failed(caption: "\(Self.deviceWordCapitalized) already syncs “\(other.name)” (\(other.place)) as “\(server.displayName)”. One copy per library per device.")
                        }
                        // The local library becomes a copy of that one: its
                        // identity takes the server library's uuid and name.
                        try StorageRoot.adoptIdentity(id: uuid, name: server.displayName)
                        library = .init(uuid: uuid, name: server.displayName)
                        initialCase = await localCountNow() == 0 ? .fresh : .merge
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

    /// The projects here that can go up — those with their originals here
    /// (L24): a preview came from PicPlace and never goes up as new.
    private func localCountNow() async -> Int {
        guard let snapshot = await model.libraryPass(name: "picplace local count") else { return 0 }
        return snapshot.projects.filter { !$0.sourcesMissing }.count
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

    /// The account's libraries that no library on this device is a copy
    /// of — what "Add Library from PicPlace…" offers (stage C, §3.7).
    var librariesNotOnThisDevice: [PPLibrary] {
        librariesNotOnThisDevice(heldElsewhere: Set(Self.serverLibrariesHeldElsewhere().map(\.uuid)))
    }

    /// The same with the other folders' bindings already read — the phone's
    /// Libraries card reads them off the main actor with the folders
    /// (`refreshPhoneLibraries`), not in its body (2026-09-27).
    func librariesNotOnThisDevice(heldElsewhere: Set<UUID>) -> [PPLibrary] {
        guard isSignedIn, serverHasLibraries else { return [] }
        var held = heldElsewhere
        if let scope { held.insert(scope) }
        return serverLibraries.filter { !$0.isDefault && !$0.isTombstone && $0.libraryUUID.map { !held.contains($0) } == true }
    }

    /// The binding a library made from this session's account starts with.
    private func bindingTemplate() throws -> PicPlaceBindingRecord {
        guard let profile else { throw PicPlaceSyncRun.Failed(caption: "Sign in first.") }
        return PicPlaceBindingRecord(
            server: .init(url: profile.server, id: profile.serverID, environment: profile.serverEnvironment),
            user: .init(uuid: profile.userUUID, username: profile.username, name: profile.name),
            boundByDevice: DeviceIdentity.id)
    }

    #if os(iOS)
    /// A local copy of `library` under `Libraries/`, bound and pending its
    /// first pull; the caller opens it (the switch), which pulls.
    func addLibraryFromPicPlace(_ library: PPLibrary) throws -> StorageRoot.LibraryFolder {
        guard let uuid = library.libraryUUID else { throw PicPlaceSyncRun.Failed(caption: "That library has no id.") }
        return try StorageRoot.createFromPicPlace(library: .init(uuid: uuid, name: library.displayName), binding: try bindingTemplate())
    }

    /// New Library on PicPlace… (L25): the server library first — a fresh
    /// uuid, the person's name — then its folder here, bound and clean; the
    /// caller opens it.
    func createLibraryOnPicPlace(name: String) async throws -> StorageRoot.LibraryFolder {
        let template = try bindingTemplate()
        let cleaned = LibraryIdentity.cleanName(name)
        guard !cleaned.isEmpty else { throw PicPlaceSyncRun.Failed(caption: "Give the library a name.") }
        let id = UUID()
        let response: PPLibraryResponse = try await client.put("libraries/\(id.uuidString.lowercased())", json: ["name": cleaned, "adopt_default": false])
        let uuid = response.library.libraryUUID ?? id
        let folder = try StorageRoot.makeLibraryFolder(name: cleaned, id: uuid)
        var record = template
        record.library = .init(uuid: uuid, name: cleaned)
        record.boundAt = Date()
        record.initialSync = .init(state: .pending, case: .clean)
        try record.write(inRoot: folder.url)
        LLog("picplace: library “\(cleaned)” \(uuid.uuidString.lowercased()) created on \(template.server.host) and placed in Libraries/\(folder.id)")
        scheduleUsageRefresh()
        return folder
    }
    #endif

    #if os(macOS)
    /// A local copy of `library` in `container`, bound and pending its first
    /// pull; the caller switches to it (commit + relaunch).
    func addLibraryFromPicPlace(_ library: PPLibrary, in container: URL) throws -> URL {
        guard let uuid = library.libraryUUID else { throw PicPlaceSyncRun.Failed(caption: "That library has no id.") }
        let root = try StorageRoot.createFromPicPlace(library: .init(uuid: uuid, name: library.displayName), binding: try bindingTemplate(), in: container)
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

    #endif

    /// The server libraries the OTHER libraries on this device are copies
    /// of, by their bindings — the Mac's list, the phone's folders.
    static func serverLibrariesHeldElsewhere() -> [(uuid: UUID, name: String, place: String)] {
        let current = StorageRoot.current.standardizedFileURL.resolvingSymlinksInPath().path
        var held: [(uuid: UUID, name: String, place: String)] = []
        #if os(macOS)
        for entry in LibraryRegistry.entries where entry.isReachable {
            guard entry.url.standardizedFileURL.resolvingSymlinksInPath().path != current,
                  let uuid = PicPlaceBindingRecord.read(inRoot: entry.url)?.library?.uuid else { continue }
            held.append((uuid, entry.name, entry.path))
        }
        #else
        for folder in StorageRoot.libraryFolders() where folder.url.path != current {
            guard let uuid = PicPlaceBindingRecord.read(inRoot: folder.url)?.library?.uuid else { continue }
            held.append((uuid, folder.name, folder.id))
        }
        #endif
        return held
    }

    /// Another library on this device that is a copy of the same SERVER
    /// library (stage C's rule: one copy per library per device — presence
    /// is per device, and two copies would overwrite each other's).
    static func otherLibraryBound(toServerLibrary uuid: UUID) -> (name: String, place: String)? {
        serverLibrariesHeldElsewhere().first { $0.uuid == uuid }.map { ($0.name, $0.place) }
    }

    /// "This Mac" · "This iPhone" — the sentence's subject.
    @MainActor static var deviceWordCapitalized: String {
        let word = deviceWord
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    /// "this Mac" · "this iPhone" · "this iPad" — for copy about what stays here.
    @MainActor static var deviceWord: String {
        #if os(macOS)
        return "this Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "this iPad" : "this iPhone"
        #endif
    }

    /// Counts what a disconnect leaves (`DisconnectSummary`) off the main
    /// actor — the press that opens the confirm calls it, and the message
    /// fills in when the count lands.
    func prepareDisconnectSummary() {
        disconnectSummaryTask?.cancel()
        disconnectSummaryTask = Task { [weak self] in
            guard let self, let snapshot = await self.model.libraryPass(name: "picplace disconnect count") else { return }
            guard !Task.isCancelled else { return }
            var previews = 0
            var originals = 0
            for project in snapshot.projects {
                if self.isPreviewOnly(project) { previews += 1 } else if !project.sourcesMissing { originals += 1 }
            }
            self.disconnectSummary = DisconnectSummary(previews: previews, originals: originals)
            self.disconnectSummaryTask = nil
        }
    }

    /// The disconnect confirm's copy, with the numbers — the last count
    /// (`prepareDisconnectSummary`); while none has landed, it says so.
    /// Cheap: a view body builds it on every pass.
    func disconnectMessage() -> String {
        var parts = ["The library stops syncing and forgets its account and what it has synced."]
        if let n = disconnectSummary {
            if n.previews > 0 {
                parts.append("\(n.previews) \(n.previews == 1 ? "preview" : "previews") pulled from PicPlace \(n.previews == 1 ? "stays" : "stay") on \(Self.deviceWord) but cannot download until you connect it again.")
            }
            if n.originals > 0 {
                parts.append("\(n.originals) \(n.originals == 1 ? "project" : "projects") with originals here \(n.originals == 1 ? "stays as it is" : "stay as they are").")
            }
        } else {
            parts.append("Counting the library's projects…")
        }
        parts.append("Nothing changes on PicPlace. Switching libraries never needs this.")
        return parts.joined(separator: " ")
    }

    /// Stands the controller down for a library switch (libraries plan
    /// L22): every timer, monitor and task cancelled, the sync state saved,
    /// and nothing re-armed after — the next model makes its own controller
    /// over the other folder.
    func shutDown() {
        isShutDown = true
        flushSyncState()
        syncStateObservers.forEach(NotificationCenter.default.removeObserver)
        syncStateObservers = []
        autoTimer?.invalidate()
        autoTimer = nil
        (pathMonitorBox as? NWPathMonitor)?.cancel()
        pathMonitorBox = nil
        checkTask?.cancel(); checkTask = nil
        initialSyncTask?.cancel(); initialSyncTask = nil
        pushQueueTask?.cancel(); pushQueueTask = nil
        originalsQueueTask?.cancel(); originalsQueueTask = nil
        blendsQueueTask?.cancel(); blendsQueueTask = nil
        proxyQueueTask?.cancel(); proxyQueueTask = nil
        heavyRecheckTask?.cancel(); heavyRecheckTask = nil
        reachabilityProbe?.cancel(); reachabilityProbe = nil
        verifySweep?.cancel(); verifySweep = nil
        verifyPending = [:]
        usageRefreshTask?.cancel(); usageRefreshTask = nil
        tallyTask?.cancel(); tallyTask = nil
        tallyRequested = false
        disconnectSummaryTask?.cancel(); disconnectSummaryTask = nil
        syncFactsObservers.removeAll()
        for task in pendingPushes.values { task.cancel() }
        pendingPushes.removeAll()
        for task in syncTasks.values { task.cancel() }
        syncTasks.removeAll()
        for task in uploadRetryTasks.values { task.cancel() }
        uploadRetryTasks.removeAll()
        uploadStops.removeAll()
        for task in summaryTasks.values { task.cancel() }
        summaryTasks.removeAll()
        pushQueue.removeAll()
        heldPushes.removeAll()
        pushReasons.removeAll()
        pushQueueManual = false
        sendRun = nil
        sendRunIDs.removeAll()
        progress.removeAll()
        saveSyncState()
        LLog("picplace: stood down for a library switch")
    }

    /// "Disconnect this library": the binding and the sync records go; the
    /// projects stay — the previews too (L23: a later link to the same
    /// library finds them in step; a link elsewhere removes them then) —
    /// keep their origin ids, and would fork if pushed under another
    /// account (v2 plan §4.6). The session is untouched.
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
        tally = nil
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

    /// The same from a pass's facts (`LibraryPass`) — the records read now.
    func isPreviewOnly(_ project: LibraryPassProject) -> Bool {
        guard project.sourcesMissing else { return false }
        if project.hasPoster { return true }
        return records[project.originID]?.policy == "pull"
    }

    func state(for capture: AppModel.CaptureProject) -> ProjectState {
        #if DEBUG
        if let stagedState { return stagedState }
        #endif
        if let conflict = conflicts.first(where: { $0.originID == model.originID(of: capture) }) { return .conflict(conflict.kind) }
        // A removal shows as its progress to the end, even once the sources
        // it is removing have started to go.
        if removingProjects.contains(capture.id), let progress = progress[capture.id] { return .syncing(progress) }
        // A preview whose originals are coming down shows them coming — it
        // read "Preview only" with a greyed button until the last file
        // landed (2026-09-25).
        if let progress = progress[capture.id], progress.phase == .downloading { return .syncing(progress) }
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

    /// Re-read the server's view of a project the card is showing: the
    /// devices that hold a copy (Also on), and whether it is still there at all.
    func refreshProject(_ captureID: UUID) {
        // What is here is walked again whatever the session: a blend
        // rendered since the card last looked is a file PicPlace lacks.
        if progress[captureID] == nil, let capture = model.capture(id: captureID) { refreshHeavyListing(for: capture) }
        // PicPlace's list waits for PicPlace to answer (2026-09-29).
        guard canSync, !isUnreachable, let capture = model.capture(id: captureID), progress[captureID] == nil else { return }
        let key = model.originID(of: capture)
        guard records[key] != nil else { return }
        Task {
            do {
                let detail: PPProjectDetail = try await client.get("projects/\(key.uuidString.lowercased())")
                let project = detail.project
                guard var record = records[key] else { return }
                record.notePresence(project.presence, excluding: profile?.deviceID)
                let heavy = (detail.assets ?? []).filter { $0.status == "confirmed" && PicPlaceSyncInventory.isHeavy($0.name) }
                record.serverHeavyFiles = heavy.count
                record.serverHeavyBytes = heavy.reduce(0) { $0 + ($1.bytes ?? 0) }
                record.serverSourceFiles = heavy.filter { PicPlaceSyncInventory.heavyKind($0.name) == .source }.count
                // A download refused because PicPlace held nothing was
                // recorded as a failure before 2026-09-26 — never this
                // device's: cleared once PicPlace's list is read.
                if record.failedPolicy == PicPlaceSyncPolicy.originals.rawValue, let caption = record.lastError,
                   PicPlaceDownloadRun.NotThere.captions.contains(caption) {
                    record.clearFailure()
                }
                records[key] = record
                saveSyncState()
                // The per-file truth the Originals and Blends rows read.
                serverHeavy[key] = Self.remoteHeavy(detail.assets)
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

    /// An upload job's run: the originals, stopped between files by the
    /// job's Pause and the Wi-Fi rule. False when it could not start.
    func syncUploadJob(_ capture: AppModel.CaptureProject, pressed: Bool) -> Bool {
        sync(capture, policy: .originals, retriedLibrary: false, job: true, pressed: pressed)
    }

    @discardableResult
    private func sync(_ capture: AppModel.CaptureProject, policy override: PicPlaceSyncPolicy?, retriedLibrary: Bool, job: Bool = false, pressed: Bool = false) -> Bool {
        // Filed in another library of the account on PicPlace (stage C):
        // this library neither pushes nor pulls it. The card says where it is.
        if let other = records[model.originID(of: capture)]?.elsewhereLibrary {
            LLog("picplace: not syncing \(capture.displayTitle) — it is in library \(other) on PicPlace, not this one")
            if job { noteUploadRunEnded(capture.id, outcome: .failed("PicPlace files this project in another library")) }
            return true
        }
        guard canSync, syncTasks[capture.id] == nil, !removingProjects.contains(capture.id) else { return false }
        let key = model.originID(of: capture)
        let policy = override ?? self.policy
        let folder = model.projectFolderURL(for: capture)
        let tier = model.presenceTier(for: capture)
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
            library: serverHasLibraries ? scope : nil,
            bucket: serverHasRenditionBatches ? Self.bucket(for: capture.createdAt) : nil,
            replacesProxy: replacedProxyID(for: capture),
            md5Uploads: serverHasMD5Uploads)
        // Every originals run can be stopped between files (2026-09-24): a
        // job's Pause, Pause for all sending, the Wi-Fi rule, iOS about to
        // suspend the app. What finished is confirmed first.
        let stop = policy.sendsHeavy ? PicPlaceStopSignal() : nil
        let run = PicPlaceSyncRun(client: client, project: project, thisDeviceID: profile?.deviceID, assetStore: model.assetStore, stop: stop) { [weak self] progress in
            self?.progress[capture.id] = progress
            self?.transferActivities[capture.id]?.report(progress)
        }
        uploadStops[capture.id] = stop
        progress[capture.id] = PicPlaceSyncProgress()
        summaries[capture.id] = nil
        let server = profile?.server ?? serverString
        // The poster is rendered before the run walks the folder, so the
        // walk finds it (v2 plan §3.5); the grade token says whether the one
        // on disk is current.
        let grade = model.photoGrade(for: capture)
        let posterSource = model.thumbnailURL(for: capture)
        let posterToken = currentPosterToken(for: capture)
        let posterKind = model.mediaKind(for: capture)
        let lastPosterToken = records[key]?.posterToken
        // The working copy (picture tiers, stage 1): rendered beside the
        // poster when the project needs one and the one on disk is not this
        // recipe's — the walk then finds it as a `proxy` object; an exempt
        // project's stale copy is removed so nothing of it goes up. nil =
        // the project is its own working copy (D6).
        let proxyToken = currentProxyToken(for: capture)
        // The finished picture's inputs (2026-10-04): a photo's poster is the
        // grade with the masked grades, the text and shapes, the level and
        // the crop. From the originals' picture here; from the working copy
        // — drawn through the geometry alone — on a device without them, so
        // an overlay or crop edit made there reaches every Gallery and
        // PicPlace's page.
        var finished: FinishedPicture.Inputs?
        var posterFromCopy: URL?
        if policy.sendsRecords, capture.kind == .photos, posterKind != .video {
            if let posterSource, !ProjectFileRegistry.isFinishedPicture(fileName: posterSource.lastPathComponent) {
                finished = FinishedPicture.inputs(for: capture, source: posterSource, grade: grade, in: model)
            } else if model.sourcesMissing(capture), let copy = model.workingCopyURL(for: capture) {
                posterFromCopy = copy
                finished = FinishedPicture.inputs(
                    for: capture, source: copy, grade: PhotoGrade(preset: .original, adjustments: grade.adjustments.geometryOnly), in: model)
            }
        }
        syncTasks[capture.id] = Task {
            // A job a person just started — Upload, Resume, Use mobile data —
            // asks iOS to hold the app while it runs. Everything else keeps
            // the thirty seconds: an automatic sync, and a job going again on
            // its own (at launch, on a network change, a retry), which iOS
            // does not allow to ask (`PicPlaceContinuedTransfer`).
            let continued = job && pressed ? PicPlaceBackgroundActivity.Continued(
                title: "Uploading “\(capture.displayTitle)” to PicPlace", subtitle: "Starting") : nil
            let activity = PicPlaceBackgroundActivity("PicPlace sync of \(capture.displayTitle)", continued: continued) { [weak self] in
                // iOS suspends the app in a moment: an upload stops between
                // files now, keeping what reached PicPlace, and a job goes
                // again when the app is in front (background transfers: TODO).
                guard let self, let stop else { return }
                if job, self.uploadJobs[capture.id] != nil, self.uploadJobs[capture.id]?.hold == nil {
                    self.uploadJobs[capture.id]?.hold = .interrupted
                    self.uploadJobs[capture.id]?.lastError = "The app went to the background"
                }
                stop.request()
            }
            transferActivities[capture.id] = activity
            defer {
                activity.end()
                transferActivities[capture.id] = nil
            }
            // nil: no render was attempted (a preview's poster is the file it
            // has); false: the render failed, and the record must not say the
            // poster went (2026-10-03: a push that failed to render went up
            // as records alone and was never asked again).
            var posterRendered: Bool?
            do {
                // A preview-only project's "source" IS its poster: nothing to
                // render, the file it has is the one that goes.
                if policy.sendsRecords, let posterSource, !ProjectFileRegistry.isFinishedPicture(fileName: posterSource.lastPathComponent) {
                    let rendered = await PicPlacePoster.ensure(sourceURL: posterSource, kind: posterKind, grade: grade, token: posterToken,
                                                               lastToken: lastPosterToken, in: folder, finished: finished)
                    posterRendered = rendered != nil
                    if rendered != nil, lastPosterToken != posterToken { self.model.noteFilesChanged(for: capture.id) }
                    if rendered == nil { LLog("picplace: ALARM poster: could not render the poster of \(capture.displayTitle) (\(key.uuidString.prefix(8))) — the records go without it; the check asks again") }
                    if let proxyToken {
                        _ = await PicPlaceProxy.ensure(sourceURL: posterSource, grade: grade,
                                                       nameToken: PicPlaceSyncRun.proxyNameToken(for: proxyToken), in: folder)
                    } else {
                        PicPlaceProxy.removeAll(in: folder)
                        // The copy PicPlace holds of an exempt project is a
                        // leftover nobody fetches (stage 5).
                        await self.deleteServerWorkingCopy(origin: key, title: capture.displayTitle)
                    }
                } else if policy.sendsRecords, let copy = posterFromCopy, let finished {
                    // A device without the originals, holding the working
                    // copy: the poster from the copy and the records (the
                    // copy itself stays as it is — it is not re-rendered here).
                    let rendered = await PicPlacePoster.ensure(sourceURL: copy, kind: posterKind, grade: grade, token: posterToken,
                                                               lastToken: lastPosterToken, in: folder, finished: finished)
                    posterRendered = rendered != nil
                    if rendered != nil, lastPosterToken != posterToken { self.model.noteFilesChanged(for: capture.id) }
                }
                // Each blend here gets its still (`posters/<id>.jpg`, in the
                // records bundle) before the records go, so a device that
                // pulls the project shows every blend row with a picture —
                // until 2026-09-25 a still was made only when a blend left
                // this device, and a pulled row was a placeholder (D1).
                if policy.sendsRecords {
                    let here = model.blends(for: capture).filter { !model.blendFileMissing($0) }.map(\.outputFileName)
                    if !here.isEmpty { _ = await model.ensureBlendPosters(for: capture, fileNames: Set(here)) }
                }
                var record = try await run.run()
                let verifiedDigest = record.heavyDigest
                let divergent = record.divergentFiles
                let changed = record.changedFiles
                record.posterToken = posterRendered == false ? nil : posterToken
                record.proxyToken = proxyToken
                let previousRecord = records[key]
                if let previous = previousRecord {
                    // A push of one policy keeps what the other recorded.
                    record.serverHeavyFiles = previous.serverHeavyFiles
                    record.serverHeavyBytes = previous.serverHeavyBytes
                    record.serverSourceFiles = previous.serverSourceFiles
                    record.originalsMovedAt = previous.originalsMovedAt
                    record.serverConfirmedSeen = previous.serverConfirmedSeen
                    record.heavyDigest = previous.heavyDigest
                    record.removedAt = previous.removedAt
                    record.divergentFiles = previous.divergentFiles
                    record.changedFiles = previous.changedFiles
                    record.blendsDigest = previous.blendsDigest
                    if policy == .minimal { record.posterToken = posterToken; record.proxyToken = proxyToken }
                }
                record.clearFailure()
                if policy == .blends {
                    // The blends alone (D1): their own marker, and nothing of
                    // the originals' — the removal gate (`heavyDigest`), the
                    // counts of what stays here, a pull's own policy — moves.
                    record.blendsDigest = verifiedDigest
                    record.policy = previousRecord?.policy ?? record.policy
                    record.heavyFiles = previousRecord?.heavyFiles
                    record.heavyBytes = previousRecord?.heavyBytes
                    record.posterToken = previousRecord?.posterToken ?? record.posterToken
                    record.proxyToken = previousRecord?.proxyToken ?? record.proxyToken
                    serverHeavy[key] = nil
                    refreshHeavyListing(for: capture)
                } else if policy.sendsHeavy {
                    record.originalsMovedAt = Date()
                    if policy == .everything {
                        // The run counted the records and the poster too: the
                        // heavy figures are the heavy files' alone — they feed
                        // the card, the tally and the blends queue's "sent
                        // from another device" test.
                        let listing = await Task.detached(priority: .utility) { Self.heavyFiles(in: folder) }.value
                        record.serverHeavyFiles = listing.count
                        record.serverHeavyBytes = listing.reduce(Int64(0)) { $0 + $1.bytes }
                    } else {
                        record.serverHeavyFiles = record.files
                        record.serverHeavyBytes = record.bytes
                    }
                    // Every source went; the count is PicPlace's to say at
                    // the next read (the marker answers meanwhile).
                    record.serverSourceFiles = nil
                    record.heavyFiles = 0
                    record.heavyBytes = 0
                    record.heavyDigest = verifiedDigest
                    record.divergentFiles = divergent
                    record.changedFiles = changed
                    // The server's list moved: the card reads it again.
                    serverHeavy[key] = nil
                    refreshHeavyListing(for: capture)
                }
                records[key] = record
                // PicPlace reads what it received back within a minute or
                // two: until then the pill says *checking* (not *needs
                // uploading* beside "Here and on PicPlace" — Steven,
                // 2026-09-26), and this project is looked at again within
                // seconds and every minute after (`verifyAfterUpload`); the
                // blends queue's look stays the backstop.
                if policy.sendsHeavy {
                    if verifiedDigest == nil, (divergent ?? []).isEmpty {
                        records[key]?.verifyPendingSince = Date()
                        verifyAfterUpload(capture.id)
                        scheduleHeavyRecheck()
                    } else {
                        records[key]?.verifyPendingSince = nil
                    }
                }
                if job { noteUploadRunEnded(capture.id, outcome: .done) }
            } catch is PicPlaceSyncRun.Paused {
                // Stopped between files on request: what finished is on
                // PicPlace, the rest waits. Not a failure.
                if job { noteUploadRunEnded(capture.id, outcome: .paused) } else { originalsRunPaused = true }
            } catch is CancellationError {
                // Cancelled by the user: the card goes back to what it was.
                // A job's run is only cancelled from outside (a library
                // switch): it carries on next time.
                if job { noteUploadRunEnded(capture.id, outcome: .interrupted(nil)) }
            } catch let error as PicPlaceAPIError where error.code == "library_unknown" && !retriedLibrary {
                // The server no longer has this library (deleted or purged
                // elsewhere): put it back by its uuid and name, then push
                // once more (asks §6 Q2).
                LLog("picplace: the server does not know library \(scope?.uuidString ?? "?") — re-creating it and retrying \(capture.displayTitle)")
                progress[capture.id] = nil
                syncTasks[capture.id] = nil
                uploadStops[capture.id] = nil
                if await ensureServerLibrary() {
                    sync(capture, policy: override, retriedLibrary: true, job: job)
                } else {
                    if job { noteUploadRunEnded(capture.id, outcome: .failed("PicPlace no longer has this library, and it could not be re-created.")) }
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
                if job { noteUploadRunEnded(capture.id, outcome: .failed("This project's id belongs to another account")) }
                progress[capture.id] = nil
                syncTasks[capture.id] = nil
                uploadStops[capture.id] = nil
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
                let caption = (error as? PicPlaceAPIError)?.cardCaption
                    ?? (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                if job {
                    // The job carries it — its line on the card, its retry —
                    // and the project's records stay as they were.
                    noteUploadRunEnded(capture.id, outcome: Self.isUploadInterruption(error) ? .interrupted(caption) : .failed(caption))
                } else {
                    var record = records[key] ?? PicPlaceSyncRecord(syncedAt: .distantPast, revision: 0, files: 0, bytes: 0, uploaded: 0, alsoOn: [], server: server, lastError: nil, policy: policy.rawValue)
                    record.noteFailure(caption, policy: policy)
                    records[key] = record
                }
            }
            saveSyncState()
            progress[capture.id] = nil
            syncTasks[capture.id] = nil
            uploadStops[capture.id] = nil
            scheduleUsageRefresh()
            if job {
                followUpUploadJob(capture.id)
                startNextUploadJob()
            }
        }
        return true
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
        removalTasks[id]?.cancel()
    }

    // MARK: Originals (stage 5, §4.5)

    // What the card offers for a project's originals and blends is
    // `originalsStatus(for:)` (PicPlaceFreeUp.swift, 2026-09-23): per file,
    // never a count or a timestamp.

    // The card's Upload is a job that can pause and wait for Wi-Fi:
    // `uploadOriginals(_:)` in PicPlaceUploadJobs.swift (2026-09-24).

    /// The `source/` media and/or `blends/` down, in pages of presigned
    /// URLs; the project stops being preview-only when the last listed
    /// frame is on disk. Cancel keeps what landed; a second run skips it.
    /// The card's *Download originals* brings the source media and its
    /// Blends row the blends (free up space removes them separately).
    func downloadOriginals(_ capture: AppModel.CaptureProject,
                           kinds: Set<PicPlaceOriginalsCheck.Kind> = Set(PicPlaceOriginalsCheck.Kind.allCases),
                           replacing: Set<String> = [],
                           only: Set<String>? = nil) {
        guard canSync, syncTasks[capture.id] == nil, !removingProjects.contains(capture.id) else { return }
        let key = model.originID(of: capture)
        let folder = model.projectFolderURL(for: capture)
        removalNotes[capture.id] = nil
        var run = PicPlaceDownloadRun(client: client, projectUUID: key.uuidString.lowercased(), folder: folder, kinds: kinds,
                                      replacing: replacing, assetStore: model.assetStore) { [weak self] progress in
            self?.progress[capture.id] = progress
            self?.transferActivities[capture.id]?.report(progress)
        }
        run.only = only
        progress[capture.id] = PicPlaceSyncProgress(phase: .downloading)
        let server = profile?.server ?? serverString
        syncTasks[capture.id] = Task {
            var readListAgain = false
            // Every download is a person's: iOS is asked to hold the app
            // while it runs. When it cannot any longer, the download stops —
            // what landed stays, the rest comes at the next press.
            let activity = PicPlaceBackgroundActivity(
                "PicPlace download of \(capture.displayTitle)",
                continued: .init(title: "Downloading “\(capture.displayTitle)”", subtitle: "From PicPlace")
            ) { [weak self] in
                self?.syncTasks[capture.id]?.cancel()
            }
            transferActivities[capture.id] = activity
            defer {
                activity.end()
                transferActivities[capture.id] = nil
            }
            do {
                let got = try await run.run()
                var record = records[key] ?? PicPlaceSyncRecord(syncedAt: Date(), revision: revision(of: capture), files: 0, bytes: 0, uploaded: 0, alsoOn: [], server: server, lastError: nil, policy: "pull")
                record.clearFailure()
                record.originalsMovedAt = Date()
                // The copies that differed are PicPlace's now.
                if !replacing.isEmpty, let divergent = record.divergentFiles {
                    let left = divergent.filter { !replacing.contains($0) }
                    record.divergentFiles = left.isEmpty ? nil : left
                }
                records[key] = record
                summaries[capture.id] = nil
                model.noteOriginalsArrived(for: capture.id)
                refreshHeavyListing(for: capture)
                // Blends alone leave the sources where they were: the tier
                // says what this device holds of the originals.
                let tier = model.presenceTier(for: capture)
                let _: [String: [PPPresence]]? = try? await client.post("projects/\(key.uuidString.lowercased())/presence", json: ["revision": record.revision, "tier": tier])
                LLog("picplace: downloaded the \(kinds == [.blend] ? "blends" : kinds == [.source] ? "originals" : "originals and blends") of \(capture.displayTitle): \(got.files) file(s), \(got.bytes) bytes")
            } catch is CancellationError {
                model.noteOriginalsArrived(for: capture.id)
            } catch let notThere as PicPlaceDownloadRun.NotThere {
                // Nothing on PicPlace to bring — not this device's failure:
                // no error on the record. PicPlace's list is read again (below)
                // so the rows stop offering it.
                LLog("picplace: download of \(capture.displayTitle) — \(notThere.caption) Nothing to bring; not recorded as a failure")
                listingAskedAt[key] = nil
                readListAgain = true
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
            if readListAgain { askForListing(capture.id) }
        }
    }

    /// A sync the caller waits for — the first connection pushes one
    /// project at a time.
    /// What a project's poster on disk is rendered from: its grade, and the
    /// picture's quarter turns — Rotate 90° is a record, so the poster is
    /// the one thing a turn has to re-render (2026-09-24). The string a push
    /// stamps on the record, and the one a check adopts when PicPlace
    /// already holds the poster (`settlePosters`).
    func currentPosterToken(for capture: AppModel.CaptureProject) -> String {
        let source = model.thumbnailURL(for: capture)
        // A photo's poster is the finished picture (2026-10-04): the overlay
        // document's fingerprint is in the token, so text, masks and masked
        // grades re-render it as a preset does.
        let overlays = capture.kind == .photos ? model.overlaysSignature(for: capture).map { "|o\($0)" } ?? "" : ""
        return model.photoGrade(for: capture).cacheToken
            + (source.map { ProjectOrientation.shared.keySuffix(for: $0) } ?? "")
            + overlays
    }

    /// The id of the working copy PicPlace's row names when it is not the
    /// one this push renders (a re-grade): `replaces` on the new copy's
    /// negotiate retires it as the new one confirms (2026-10-03). nil when
    /// the names agree, when PicPlace names none, or when the project is its
    /// own working copy (the push then retires the copy outright).
    func replacedProxyID(for capture: AppModel.CaptureProject) -> String? {
        guard let token = currentProxyToken(for: capture),
              let pointer = serverRenditions[model.originID(of: capture)]?.proxy else { return nil }
        let expected = ProjectFileRegistry.proxyPictureName(token: PicPlaceSyncRun.proxyNameToken(for: token))
        return pointer.name == expected ? nil : pointer.id
    }

    /// The working copy's token (docs/picture-tiers-plan.md §3.2): the
    /// grade's `proxyToken` — the cache token with the crop left out — plus
    /// the project's quarter turns, as the poster's carries them: the render
    /// applies the turns, so a Rotate 90° re-renders the copy. nil when the
    /// project is its own working copy (D6) or has no picture here.
    func currentProxyToken(for capture: AppModel.CaptureProject) -> String? {
        guard model.needsProxy(for: capture), let source = model.thumbnailURL(for: capture),
              !ProjectFileRegistry.isFinishedPicture(fileName: source.lastPathComponent) else { return nil }
        return model.proxyRecipeToken(for: capture)
    }

    /// An exempt project's working copy on PicPlace (stage 5): its grade
    /// went back to nothing on a JPEG or HEIC, so the copy up there is a
    /// leftover nobody fetches. Retired through `POST assets/delete` when
    /// the server offers `rendition_delete` (picplace `0a33ec9`: rendition
    /// ids of any projects, no claim, under the push's revision rule — a
    /// device behind the records is told `stale_revision` and tries again
    /// after its next pull); until then it stays, harmless, and the next
    /// render replaces it.
    func deleteServerWorkingCopy(origin: UUID, title: String) async {
        guard serverHasRenditionDelete, let pointer = serverRenditions[origin]?.proxy else { return }
        do {
            let reply: PPRetiredAssets = try await client.post("assets/delete", json: ["assets": [["id": pointer.id]]])
            guard let row = reply.assets.first else { return }
            if row.deleted == true {
                serverRenditions[origin]?.proxy = nil
                records[origin]?.proxyToken = nil
                saveSyncState()
                LLog("picplace: retired the working copy of \(title) on PicPlace (\(pointer.name)) — the project is its own now")
            } else {
                LLog("picplace: PicPlace kept the working copy of \(title) — \(row.error ?? "?")\(row.currentRevision.map { " (server revision \($0))" } ?? "")")
            }
        } catch {
            LLog("picplace: could not retire the working copy of \(title) on PicPlace — \(Self.describe(error))")
        }
    }

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

    /// The name presence rows and the device list show: the Mac's computer
    /// name, a phone's model ("iPhone 18 Pro") where iOS only says "iPhone"
    /// (`DeviceName`, 2026-09-28).
    static var deviceName: String {
        DeviceName.current
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

    /// "0.1.0 (1) 2026-09-24 14:33" — the marketing version and build
    /// number never move between Steven's builds, so the executable's own
    /// build time says which one a device runs (the PicPlace developer could
    /// not tell, 2026-09-24).
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var line = "\(version) (\(build))"
        if let executable = Bundle.main.executableURL,
           let built = (try? executable.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            line += " \(formatter.string(from: built)) UTC"
        }
        return line
    }

    /// Tells PicPlace which build this device runs when that changed since
    /// it last said — the registration is an upsert by device key, sent at
    /// sign-in only until now.
    func reportAppVersionIfChanged() async {
        guard let key = profile?.accountKey else { return }
        let defaultsKey = "letslapse.picplace.reportedVersion.\(key)"
        let version = Self.appVersion
        guard UserDefaults.standard.string(forKey: defaultsKey) != version else { return }
        do {
            let _: [String: PPDevice] = try await client.post("device", json: [
                "device_key": DeviceIdentity.id.uuidString.lowercased(),
                "name": Self.deviceName,
                "platform": Self.platform,
                "model": Self.hardwareModel,
                "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
                "app_version": version,
            ])
            UserDefaults.standard.set(version, forKey: defaultsKey)
            LLog("picplace: told PicPlace this device runs \(version)")
        } catch {
            LLog("picplace: could not report the app version: \(Self.describe(error))")
        }
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

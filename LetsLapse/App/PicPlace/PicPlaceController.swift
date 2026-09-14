import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The app's side of PicPlace (docs/picplace-sync-v1.md): who is signed in,
/// which projects this device has pushed and how each push is going. Owned
/// by `AppModel` (`model.picplace`); the cards observe it directly.
///
/// Everything here is **device state**: the tokens name this install, the
/// sync records say what THIS device pushed and when. The server is the
/// truth for what is actually there, which the card re-reads when it appears.
@MainActor
final class PicPlaceController: ObservableObject {

    struct Profile: Codable, Equatable {
        var username: String
        var name: String?
        var userUUID: String
        var deviceID: String          // the server's id for this install
        var deviceName: String
        var server: String
    }

    struct Usage: Equatable {
        var projects: Int
        var bytes: Int64
    }

    struct FolderSummary: Equatable {
        var files: Int
        var bytes: Int64
    }

    enum ProjectState: Equatable {
        case signedOut
        case notSynced
        case changes(PicPlaceSyncRecord)
        case syncing(PicPlaceSyncProgress)
        case synced(PicPlaceSyncRecord)
        case failed(PicPlaceSyncRecord)
    }

    /// What the Projects-list pill shows; nil keeps the card quiet.
    enum ListState { case synced, syncing, failed }

    private static let profileKey = "letslapse.picplace.account"
    private static let recordsKey = "letslapse.picplace.syncStates"

    @Published private(set) var profile: Profile?
    @Published private(set) var usage: Usage?
    @Published private(set) var records: [UUID: PicPlaceSyncRecord] = [:]
    @Published private(set) var progress: [UUID: PicPlaceSyncProgress] = [:]
    @Published private(set) var summaries: [UUID: FolderSummary] = [:]
    @Published private(set) var isSigningIn = false
    @Published private(set) var lastSignInError: String?
    @Published private(set) var serverString = PicPlaceConfiguration.serverString

    private unowned let model: AppModel
    private var client: PicPlaceClient!
    private var syncTasks: [UUID: Task<Void, Never>] = [:]
    private var summaryTasks: [UUID: Task<Void, Never>] = [:]
    private let signInFlow = PicPlaceSignIn()

    #if DEBUG
    /// `LL_PICPLACE=<state>` stages every project's card in one state for
    /// screenshots, no server needed: signed-out · not-synced · changes ·
    /// syncing · synced · failed.
    private var stagedState: ProjectState?
    #endif

    init(model: AppModel) {
        self.model = model
        records = Self.loadRecords()
        profile = Self.loadProfile()
        var tokens = PicPlaceKeychain.load()
        #if DEBUG
        // `LL_PICPLACE_TOKENS=<access>:<refresh>` signs the app in with tokens
        // obtained elsewhere (the picplace repo's curl walkthrough), so a
        // sync can be driven headlessly without typing a password into the
        // consent page.
        if let injected = ProcessInfo.processInfo.environment["LL_PICPLACE_TOKENS"] {
            let parts = injected.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                tokens = PicPlaceTokens(accessToken: parts[0], refreshToken: parts[1],
                                        expiresAt: Date().addingTimeInterval(3600), server: PicPlaceConfiguration.serverString)
                try? PicPlaceKeychain.save(tokens!)
            }
        }
        stagedState = Self.stagedState(from: ProcessInfo.processInfo.environment["LL_PICPLACE"])
        // `LL_PICPLACE_SIGNIN=1|silent` presses Sign in at launch; `silent`
        // opens no browser, so a test drives the consent page itself and
        // delivers the callback URL (open -a <app> "letslapse://…").
        let signInHook = ProcessInfo.processInfo.environment["LL_PICPLACE_SIGNIN"]
        #endif
        // Tokens for another server are a sign-in to somewhere else.
        if let stored = tokens, stored.server != PicPlaceConfiguration.serverString {
            tokens = nil
            PicPlaceKeychain.clear()
            profile = nil
            Self.saveProfile(nil)
        }
        client = PicPlaceClient(tokens: tokens) { [weak self] in
            Task { @MainActor in self?.handleSignedOutByServer() }
        }
        #if DEBUG
        // `LL_PICPLACE_SIGNOUT=1` starts from a signed-out state: revokes the
        // device if one is registered and clears the Keychain and defaults —
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

    var isSignedIn: Bool { profile != nil }

    // MARK: Sign in / out

    func signIn() {
        guard !isSigningIn else { return }
        isSigningIn = true
        lastSignInError = nil
        Task {
            defer { isSigningIn = false }
            do {
                let tokens = try await signInFlow.run(server: PicPlaceConfiguration.server)
                try PicPlaceKeychain.save(tokens)
                await client.setTokens(tokens)
                try await establishProfile()
            } catch is PicPlaceSignIn.Cancelled {
                // Nothing to say: they closed it.
            } catch {
                LLog("picplace: sign-in failed: \(error)")
                lastSignInError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                PicPlaceKeychain.clear()
                await client.setTokens(nil)
            }
        }
    }

    /// Sign this device out: revoke it on the server (best effort), forget
    /// the tokens and this device's sync records. Local files are untouched.
    func signOut() {
        for task in syncTasks.values { task.cancel() }
        syncTasks.removeAll()
        progress.removeAll()
        let deviceID = profile?.deviceID
        Task {
            if let deviceID {
                let _: PPEmpty? = try? await client.delete("devices/\(deviceID)")
            }
            await client.setTokens(nil)
        }
        PicPlaceKeychain.clear()
        profile = nil
        usage = nil
        records = [:]
        Self.saveProfile(nil)
        Self.saveRecords([:])
    }

    /// Change the server (only while signed out — a token names a server).
    @discardableResult
    func setServer(_ string: String) -> Bool {
        guard !isSignedIn else { return false }
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
            LLog("picplace: could not reach \(PicPlaceConfiguration.serverHost) at launch: \(error)")
        }
    }

    /// Register this device and read the handshake; both are idempotent.
    private func establishProfile() async throws {
        let registration: [String: PPDevice] = try await client.post("device", json: [
            "device_key": DeviceIdentity.id.uuidString.lowercased(),
            "name": Self.deviceName,
            "platform": Self.platform,
            "model": Self.hardwareModel,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "app_version": Self.appVersion,
        ])
        let status: PPStatus = try await client.get("status")
        guard let device = registration["device"] else { throw PicPlaceAPIError(status: 500, code: nil, message: "PicPlace did not register this device.", claim: nil) }
        profile = Profile(username: status.user.username ?? status.user.name ?? "PicPlace",
                          name: status.user.name, userUUID: status.user.uuid,
                          deviceID: device.id, deviceName: device.name, server: PicPlaceConfiguration.serverString)
        Self.saveProfile(profile)
        await refreshUsage(status: status)
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
        lastSignInError = "PicPlace signed this device out. Sign in again."
    }

    // MARK: Project state

    func state(for capture: AppModel.CaptureProject) -> ProjectState {
        #if DEBUG
        if let stagedState { return stagedState }
        #endif
        guard isSignedIn else { return .signedOut }
        if let progress = progress[capture.id] { return .syncing(progress) }
        guard let record = records[capture.id] else { return .notSynced }
        if record.lastError != nil { return .failed(record) }
        if model.lastEdited(capture) > record.syncedAt { return .changes(record) }
        return .synced(record)
    }

    func listState(for id: UUID) -> ListState? {
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
        guard isSignedIn else { return nil }
        if progress[id] != nil { return .syncing }
        guard let record = records[id] else { return nil }
        return record.lastError == nil ? .synced : .failed
    }

    /// Re-read the server's view of a project the card is showing: the
    /// devices that hold a copy (Also on), and whether it is still there at all.
    func refreshProject(_ id: UUID) {
        guard isSignedIn, records[id] != nil, progress[id] == nil else { return }
        Task {
            do {
                let detail: PPProjectDetail = try await client.get("projects/\(id.uuidString.lowercased())")
                let project = detail.project
                guard var record = records[id] else { return }
                record.alsoOn = project.presence.compactMap(\.device).filter { $0.id != profile?.deviceID }.map(\.name)
                records[id] = record
                Self.saveRecords(records)
            } catch let error as PicPlaceAPIError where error.status == 404 {
                // Deleted on the server: this device's record no longer describes anything.
                records[id] = nil
                Self.saveRecords(records)
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
        guard isSignedIn, syncTasks[capture.id] == nil else { return }
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
        syncTasks[capture.id] = Task {
            do {
                let record = try await run.run()
                records[capture.id] = record
            } catch is CancellationError {
                // Cancelled by the user: the card goes back to what it was.
            } catch {
                LLog("picplace: sync of \(capture.id) failed: \(error)")
                var record = records[capture.id] ?? PicPlaceSyncRecord(syncedAt: .distantPast, revision: 0, files: 0, bytes: 0, uploaded: 0, alsoOn: [], server: PicPlaceConfiguration.serverString, lastError: nil)
                record.lastError = (error as? PicPlaceAPIError)?.cardCaption
                    ?? (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                records[capture.id] = record
            }
            Self.saveRecords(records)
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

    private static func loadRecords() -> [UUID: PicPlaceSyncRecord] {
        guard let data = UserDefaults.standard.data(forKey: recordsKey),
              let decoded = try? JSONDecoder().decode([String: PicPlaceSyncRecord].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    private static func saveRecords(_ records: [UUID: PicPlaceSyncRecord]) {
        let keyed = Dictionary(uniqueKeysWithValues: records.map { ($0.key.uuidString.lowercased(), $0.value) })
        if let data = try? JSONEncoder().encode(keyed) {
            UserDefaults.standard.set(data, forKey: recordsKey)
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

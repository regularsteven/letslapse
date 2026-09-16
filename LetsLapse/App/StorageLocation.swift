import Foundation
import LetsLapseKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Where the LetsLapse folder — Projects, Collections, Thumbnails,
/// CaptureLogs, Logs and the small preference sidecars — lives on disk.
///
/// Everything the app stores derives from `current`, resolved ONCE per
/// process. A root that changed mid-session would tear the library out from
/// under `AppModel`'s loaded state and the two singletons that latch their
/// file URL at first use (`CustomPresetStore`, `BlendProfileStore`) — so a
/// location change applies on relaunch, and the Settings flow ends on a
/// Relaunch button rather than pretending otherwise.
enum StorageRoot {
    /// UserDefaults key holding the nominated root path. macOS only — iOS
    /// storage is the sandbox's own Application Support, and there is nowhere
    /// else for it to be.
    static let customPathKey = "storage.libraryRootPath"

    /// `~/Library/Application Support/LetsLapse` — the root unless a custom
    /// location is nominated. (On iOS this resolves inside the app sandbox.)
    static var defaultRootURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("LetsLapse", isDirectory: true)
    }

    #if os(macOS)
    /// The top-level items that ARE the library — the set a location change
    /// carries. A custom root can be a drive's own root, full of system and
    /// unrelated folders, so moving works from this list rather than
    /// "everything in the folder". A new top-level item under the root must be
    /// added here, or a later move leaves it behind.
    static let libraryItemNames = [
        "Projects", "Collections", "Thumbnails", "SceneMasks", "CaptureLogs", "Logs",
        "Incoming",
        // The SQLite index (`LibraryIndex`): a cache, but a move that leaves
        // it behind costs a rebuild on the next launch, so it comes along.
        LibraryIndex.folderName,
        // Shape-mation videos and their index (`ShapemationStore`).
        "Shapemations",
        "blend-profiles.json", "custom_presets.json", "light_ladders.json",
        // Imported LUTs (`LUTStore`): the cubes and their index.
        "luts", "luts.json",
        // The shape detectors' score sheet (`ShapeDetectorFeedback`).
        ShapeDetectorFeedback.fileName,
        // The PicPlace binding and this library's sync records (v2 plan §3.2):
        // which account the library IS travels with it.
        PicPlaceBindingRecord.folderName,
        // The library's own identity (libraries plan L1): a moved copy is
        // the same library at a new path.
        LibraryIdentity.fileName,
    ]

    /// True when a nominated location could not be reached at launch (drive
    /// not mounted, folder gone) and this session runs on the default location
    /// instead. The setting itself is kept: reconnecting the drive and
    /// relaunching gets the library back.
    private(set) static var customRootUnavailable = false

    static var customPath: String? {
        guard let path = UserDefaults.standard.string(forKey: customPathKey), !path.isEmpty else {
            return nil
        }
        return path
    }

    /// Resolved at first touch — which is `AppModel.init` loading the library,
    /// before any view exists.
    static let current: URL = {
        let nominated: URL
        if let path = customPath {
            var isDirectory: ObjCBool = false
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
                fileManager.isWritableFile(atPath: path) {
                nominated = URL(fileURLWithPath: path, isDirectory: true)
            } else {
                customRootUnavailable = true
                LLog("storage: nominated root \(path) unreachable — using the default location this session")
                return defaultRootURL
            }
        } else {
            nominated = defaultRootURL
        }
        return followNestMarker(from: nominated)
    }()
    #endif

    /// The open library's identity (libraries plan L1), healed by
    /// `healIdentity()` once the root exists. nil until then, and for the
    /// session when the file is there but unreadable (logged, left alone).
    private(set) static var identity: LibraryIdentity?

    /// Read the identity file, or mint one for a library that predates it —
    /// called by `AppModel.loadLibrary()` right after `Projects/` exists.
    /// A fallback session (`customRootUnavailable`) leaves no marks: an
    /// identity written at the default root would turn that accidental,
    /// empty session root into a listed library.
    static func healIdentity() {
        #if os(macOS)
        if customRootUnavailable { return }
        #endif
        do {
            #if os(iOS)
            // A phone has one library and no list to name it in: the
            // device's name is its name (libraries plan L16).
            let healName = UIDevice.current.name
            #else
            let healName = ""
            #endif
            let healed = try LibraryIdentity.ensure(inRoot: current, name: healName, device: DeviceIdentity.id, appVersion: appVersionString)
            identity = healed.identity
            switch healed.healing {
            case .created:
                LLog("storage: library identity minted at \(current.path) — \(healed.identity?.id.uuidString ?? "?") “\(healed.identity?.name ?? "")”")
            case .unreadable:
                LLog("storage: \(LibraryIdentity.fileName) at \(current.path) could not be read — left as it is; this session has no library identity")
            case .existing:
                break
            }
        } catch {
            LLog("storage: could not write \(LibraryIdentity.fileName) at \(current.path): \(error)")
        }
        #if os(macOS)
        LibraryRegistry.noteOpened(root: current, identity: identity)
        LibraryRegistry.discover()
        #endif
    }

    /// Rename the open library: the identity file's `name` only — the
    /// folder keeps its own (libraries plan §2.1).
    static func renameIdentity(to name: String) throws {
        let cleaned = LibraryIdentity.cleanName(name)
        guard !cleaned.isEmpty else { return }
        var record = identity ?? LibraryIdentity(name: cleaned, createdByDevice: DeviceIdentity.id, createdWith: appVersionString)
        record.name = cleaned
        record.namedByPerson = true
        try record.write(inRoot: current)
        identity = record
        LLog("storage: library at \(current.path) renamed “\(cleaned)”")
    }

    private static var appVersionString: String? {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return nil }
        if let build = info?["CFBundleVersion"] as? String { return "\(short) (\(build))" }
        return short
    }

    #if os(macOS)
    /// True when this launch's root came from the launch arguments
    /// (`-storage.libraryRootPath <path>`, the scratch-root recipe): the
    /// setting must then never be written, or a test run would point the
    /// person's own app at a scratch folder. `commit` becomes a log line
    /// and a relaunch re-passes the root (v2 plan §6).
    static var rootCameFromArguments: Bool {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[customPathKey] != nil
    }

    /// Make `destination` the root from the next launch on. Choosing the
    /// default location clears the setting rather than storing the default's
    /// absolute path, which would go stale if the home folder ever moved.
    static func commit(destination: URL) {
        if rootCameFromArguments {
            LLog("storage: root came from the launch arguments — not persisting \(destination.path)")
            argumentRootOverride = destination
            return
        }
        if destination.standardizedFileURL.path == defaultRootURL.standardizedFileURL.path {
            UserDefaults.standard.removeObject(forKey: customPathKey)
        } else {
            UserDefaults.standard.set(destination.standardizedFileURL.path, forKey: customPathKey)
        }
    }

    /// The root a relaunch must be handed when the setting was not written
    /// (`rootCameFromArguments`).
    private(set) static var argumentRootOverride: URL?

    /// Forget an unreachable nominated location and stay on the default —
    /// Settings offers this when a launch fell back (`customRootUnavailable`),
    /// where "change location" flows can't help because the session already
    /// runs on the default root.
    static func forgetCustomPath() {
        UserDefaults.standard.removeObject(forKey: customPathKey)
        customRootUnavailable = false
    }
    #else
    static var current: URL { defaultRootURL }
    #endif

    /// Where a project arriving over the network — and, since Phase 4, a
    /// `.lapse` archive being unpacked (`ImportStaging`) — is assembled before
    /// it becomes a project.
    ///
    /// Inside the library root, NOT in `temporaryDirectory`, for two reasons.
    /// A partial transfer has to outlive the connection, the window and the app
    /// — `ImportStaging` sweeps its own `lapse-import-*` trees when untouched
    /// for 15 minutes, which is right for an archive being unpacked and fatal
    /// for 12 GB somebody is half-way through rescuing off a phone, so the
    /// transfer trees (named by capture id) get 24 hours. And being on the
    /// same volume as the library is what makes the install a rename rather
    /// than a copy, which is what keeps peak disk at 1× the project instead
    /// of 2×.
    ///
    /// `"Incoming"` is in `libraryItemNames` (macOS) so a storage-location
    /// change carries it: a half-finished transfer stranded on the old volume
    /// is exactly the silent failure that list exists to prevent.
    static var incomingRootURL: URL {
        current.appendingPathComponent("Incoming", isDirectory: true)
    }

    /// Keyed by the SOURCE project's id, so a resumed pull of the same project
    /// finds the tree it left behind.
    static func incomingURL(for captureID: UUID) -> URL {
        incomingRootURL.appendingPathComponent(captureID.uuidString, isDirectory: true)
    }
}

#if os(macOS)

// MARK: - Choosing a destination

extension StorageRoot {
    enum DestinationCheck: Equatable {
        case alreadyCurrent
        case insideCurrent
        /// The folder contains the current library, or another known one
        /// (`picplace.co/regularsteven` under a drive root): a container,
        /// not a place for a library — refuse rather than nest one in another.
        case containsLibrary(String)
        case notWritable
        /// The folder already holds a LetsLapse library — switch to it in
        /// place instead of copying ours over it. Recognised by the identity
        /// file, by documents under `Projects/`, or (until M4) by the export
        /// (libraries plan L2), never by the folder's name.
        case adopt(LibraryIdentity?)
        /// The folder holds a same-named item without being a library (a stray
        /// `Projects` folder, leftovers of an interrupted move) — refuse
        /// rather than merge into it.
        case collision(String)
        /// Nothing of ours there. What that means — a new library, or the
        /// current one moved in — is the door's decision, not this one's.
        case empty
    }

    /// What nominating `destination` would mean, decided before anything is
    /// offered. The write probe is a real write: `isWritableFile` answers for
    /// POSIX bits, not for a read-only mount. A folder that does not exist
    /// yet (the Save panel's new folder) is `.empty` when its parent is
    /// writable.
    static func check(destination: URL) -> DestinationCheck {
        let fileManager = FileManager.default
        let destinationPath = destination.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = current.standardizedFileURL.resolvingSymlinksInPath().path
        if destinationPath == rootPath { return .alreadyCurrent }
        if destinationPath.hasPrefix(rootPath + "/") { return .insideCurrent }
        if rootPath.hasPrefix(destinationPath + "/") {
            return .containsLibrary(String(rootPath.dropFirst(destinationPath.count + 1)))
        }
        for entry in LibraryRegistry.entries where entry.isReachable {
            let entryPath = entry.url.standardizedFileURL.resolvingSymlinksInPath().path
            if entryPath != destinationPath, entryPath.hasPrefix(destinationPath + "/") {
                return .containsLibrary(String(entryPath.dropFirst(destinationPath.count + 1)))
            }
        }

        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory)
        if !exists {
            let parent = destination.deletingLastPathComponent()
            let probe = parent.appendingPathComponent(".letslapse-write-probe")
            guard (try? Data("ok".utf8).write(to: probe)) != nil else { return .notWritable }
            try? fileManager.removeItem(at: probe)
            return .empty
        }
        guard isDirectory.boolValue else { return .notWritable }
        let probe = destination.appendingPathComponent(".letslapse-write-probe")
        guard (try? Data("ok".utf8).write(to: probe)) != nil else { return .notWritable }
        try? fileManager.removeItem(at: probe)

        switch LibraryIdentity.detect(root: destination) {
        case .identity(let identity): return .adopt(identity)
        case .documents, .export: return .adopt(nil)
        case .none: break
        }

        for name in libraryItemNames
        where fileManager.fileExists(atPath: destination.appendingPathComponent(name).path) {
            return .collision(name)
        }
        return .empty
    }

    /// Start a new, empty library in `destination` — the folder (made if
    /// needed), its identity, `Projects/` — register it and make it the root
    /// from the next launch (libraries plan §3.1). Nothing is copied; the
    /// current library is untouched. `loadLibrary()` bootstraps the rest on
    /// that launch.
    @discardableResult
    static func create(at destination: URL, name: String) throws -> LibraryIdentity {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let cleaned = LibraryIdentity.cleanName(name)
        let identity = LibraryIdentity(
            name: cleaned.isEmpty ? LibraryIdentity.defaultName(forRoot: destination) : cleaned,
            createdByDevice: DeviceIdentity.id, createdWith: appVersionString)
        try identity.write(inRoot: destination)
        try fileManager.createDirectory(at: destination.appendingPathComponent("Projects", isDirectory: true), withIntermediateDirectories: true)
        LibraryRegistry.register(root: destination, identity: identity)
        commit(destination: destination)
        LLog("storage: created library “\(identity.name)” \(identity.id.uuidString) at \(destination.path); active from next launch")
        return identity
    }
}

// MARK: - The known libraries (libraries plan L3)

/// The Mac's list of libraries — Settings ▸ Storage ▸ Libraries. A list,
/// not the truth: the identity file in each root is what a library IS; this
/// remembers where they were last seen so they can be switched to, and it
/// never touches a folder. Kept in `UserDefaults` (`storage.libraries`) as
/// JSON, one entry per path.
enum LibraryRegistry {
    static let key = "storage.libraries"

    struct Entry: Codable, Equatable, Identifiable {
        /// The identity file's uuid when it was readable; nil for a library
        /// that predates the file and has not been opened by this build yet.
        var libraryID: UUID?
        var path: String
        var name: String
        var lastOpenedAt: Date?

        var id: String { path }
        var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

        var isCurrent: Bool {
            url.standardizedFileURL.resolvingSymlinksInPath().path
                == StorageRoot.current.standardizedFileURL.resolvingSymlinksInPath().path
        }

        /// The folder is there and is a directory — a mounted volume, a
        /// folder nobody deleted. Cheap: one stat.
        var isReachable: Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// A scratch run's list (`-storage.libraryRootPath …`): held here, never
    /// in the defaults, so scratch folders never appear in the person's own
    /// Settings — the same guard as `StorageRoot.commit`. It starts from
    /// what is persisted, so the run still sees the real libraries.
    private static var volatileEntries: [Entry]?

    static var entries: [Entry] {
        get {
            if let volatileEntries { return volatileEntries }
            guard let data = UserDefaults.standard.data(forKey: key),
                  let decoded = try? NDJSONFile.makeDecoder().decode([Entry].self, from: data) else { return [] }
            return decoded
        }
        set {
            if StorageRoot.rootCameFromArguments {
                if volatileEntries == nil {
                    LLog("storage: root came from the launch arguments — the libraries list is kept for this run only")
                }
                volatileEntries = newValue
                return
            }
            if let data = try? NDJSONFile.makeEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    private static func standardized(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Upsert: by identity when known (a nested or moved library keeps its
    /// uuid at a new path), else by path.
    private static func upsert(root: URL, identity: LibraryIdentity?, touch: Bool) {
        var list = entries
        let path = standardized(root)
        let name = identity?.displayName ?? LibraryIdentity.defaultName(forRoot: root)
        var index = list.firstIndex { standardized($0.url) == path }
        if index == nil, let id = identity?.id {
            index = list.firstIndex { $0.libraryID == id && !$0.isReachable }
        }
        if let index {
            list[index].path = path
            if identity != nil { list[index].libraryID = identity?.id; list[index].name = name }
            if touch { list[index].lastOpenedAt = Date() }
        } else {
            list.append(Entry(libraryID: identity?.id, path: path, name: name, lastOpenedAt: touch ? Date() : nil))
        }
        entries = list
    }

    /// The open library, at launch.
    static func noteOpened(root: URL, identity: LibraryIdentity?) {
        upsert(root: root, identity: identity, touch: true)
    }

    /// A library that was created, opened from a folder panel, or found.
    static func register(root: URL, identity: LibraryIdentity?) {
        upsert(root: root, identity: identity, touch: false)
    }

    /// A library that changed path — the mover's copy, the PicPlace nest.
    static func move(from source: URL, to destination: URL) {
        var list = entries
        let from = standardized(source)
        let to = standardized(destination)
        if let index = list.firstIndex(where: { standardized($0.url) == from }) {
            list[index].path = to
            entries = list
        }
    }

    static func rename(path: String, to name: String) {
        var list = entries
        guard let index = list.firstIndex(where: { $0.path == path }) else { return }
        list[index].name = name
        entries = list
    }

    static func remove(path: String) {
        entries = entries.filter { $0.path != path }
    }

    /// Libraries this build has not been told about but can see: the default
    /// location itself, and the `<host>/<username>/` folders the PicPlace
    /// nest makes under it (v2 plan §3.3) — two levels, only folders that
    /// `detect` as libraries. Idempotent; a folder that appears later is
    /// found on the next launch.
    static func discover() {
        let fileManager = FileManager.default
        let base = StorageRoot.defaultRootURL
        var candidates = [base]
        for host in (try? fileManager.contentsOfDirectory(atPath: base.path)) ?? [] where !host.hasPrefix(".") {
            let hostURL = base.appendingPathComponent(host, isDirectory: true)
            for user in (try? fileManager.contentsOfDirectory(atPath: hostURL.path)) ?? [] where !user.hasPrefix(".") {
                candidates.append(hostURL.appendingPathComponent(user, isDirectory: true))
            }
        }
        let known = Set(entries.map { standardized($0.url) })
        for candidate in candidates where !known.contains(standardized(candidate)) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            switch LibraryIdentity.detect(root: candidate) {
            case .identity(let identity): register(root: candidate, identity: identity)
            case .documents: register(root: candidate, identity: nil)
            // An export with no document is an empty library nobody made on
            // purpose — the default root after a fallback session (plan
            // §7.4). Nothing to switch to; not listed. Opening it by hand
            // still works, and names it.
            case .export, .none: continue
            }
        }
    }
}

// MARK: - The nest marker (v2 plan §3.3, retired 2026-09-16)

extension StorageRoot {
    /// `<root>/.letslapse-nested` — written by the connect-time nest of
    /// 2026-09-14/16 before the folders moved, removed after the commit.
    /// The nest itself is retired (libraries plan L19: a library binds
    /// where it is; only folders the app creates carry the
    /// `<host>/<username>/` convention); the launch half stays for a
    /// marker a build of those two days may have left mid-flight.
    static let nestMarkerName = ".letslapse-nested"

    private struct NestMarker: Codable { var to: String }

    /// The launch half: a marker at `root` whose destination holds a
    /// `Projects/` folder means the move finished and the commit did not.
    private static func followNestMarker(from root: URL) -> URL {
        let fileManager = FileManager.default
        let marker = root.appendingPathComponent(nestMarkerName)
        guard let data = try? Data(contentsOf: marker),
              let record = try? JSONDecoder().decode(NestMarker.self, from: data) else { return root }
        let destination = URL(fileURLWithPath: record.to, isDirectory: true)
        let projects = destination.appendingPathComponent("Projects", isDirectory: true)
        guard fileManager.fileExists(atPath: projects.path) else {
            // Nothing moved: the marker is stale.
            try? fileManager.removeItem(at: marker)
            return root
        }
        // The setting is written directly: `commit` is for a running session,
        // and this is the resolution of one.
        if !rootCameFromArguments {
            UserDefaults.standard.set(destination.standardizedFileURL.path, forKey: customPathKey)
        }
        try? fileManager.removeItem(at: marker)
        LLog("storage: followed the nest marker at \(root.path) → \(destination.path)")
        return destination
    }
}

// MARK: - Moving the library

/// Copies the library to a nominated folder, byte-counted for progress, and
/// commits the new location only after every file has landed. Deliberately a
/// COPY: the old library stays where it was until the human deletes it in
/// Finder — a mover that deletes originals has to be perfect, one that
/// doesn't only has to be honest about what it left behind.
@MainActor
final class StorageMover: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case copying(copiedBytes: Int64, totalBytes: Int64, itemName: String)
        case done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    private var work: Task<Void, Never>?

    func begin(destination: URL) {
        guard phase == .idle || phase.isFailed else { return }
        phase = .preparing
        let source = StorageRoot.current
        // Holds self strongly on purpose: once copying starts it runs to its
        // commit (or its cleanup) even if the sheet that started it goes away.
        // `copyLibrary` is nonisolated async, so the walk and the copies run
        // off the main actor; only the phase writes come back to it.
        work = Task {
            let outcome = await Self.copyLibrary(from: source, to: destination) { [weak self] copied, total, item in
                let mover = self
                await MainActor.run {
                    mover?.phase = .copying(copiedBytes: copied, totalBytes: total, itemName: item)
                }
            }
            switch outcome {
            case .success:
                LibraryRegistry.move(from: source, to: destination)
                StorageRoot.commit(destination: destination)
                LLog("storage: library copied to \(destination.path); active from next launch")
                phase = .done
            case .cancelled:
                phase = .idle
            case .failure(let message):
                phase = .failed(message)
            }
        }
    }

    func cancel() {
        work?.cancel()
    }

    #if DEBUG
    /// LL_STORAGE screenshot hook — stage a phase without touching any file.
    func stagePreview(_ staged: Phase) {
        phase = staged
    }
    #endif

    private enum CopyOutcome {
        case success
        case cancelled
        case failure(String)
    }

    private nonisolated static func copyLibrary(
        from source: URL,
        to destination: URL,
        onProgress: @Sendable (Int64, Int64, String) async -> Void
    ) async -> CopyOutcome {
        let fileManager = FileManager.default

        // What moves: the known library items, wherever the source is. A
        // custom root can be a drive root full of unrelated folders, and the
        // default root can hold OTHER libraries nested under it
        // (`picplace.test/regularsteven/`) — "everything visible" would drag
        // a whole other library along (libraries plan §7.3). The known list
        // is the maintenance contract that protects both.
        let names = StorageRoot.libraryItemNames
        let items = names.filter { fileManager.fileExists(atPath: source.appendingPathComponent($0).path) }

        // Plan first, copy second: progress in real bytes, and the free-space
        // check against the real total rather than a guess.
        struct PlanEntry {
            let source: URL
            let destination: URL
            let isDirectory: Bool
            let bytes: Int64
            let topLevelName: String
        }
        // Synchronous on purpose: NSEnumerator's iteration is unavailable
        // from async contexts.
        func buildPlan() -> ([PlanEntry], Int64)? {
            var plan: [PlanEntry] = []
            var totalBytes: Int64 = 0
            for name in items {
                if Task.isCancelled { return nil }
                let itemSource = source.appendingPathComponent(name)
                let itemDestination = destination.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                fileManager.fileExists(atPath: itemSource.path, isDirectory: &isDirectory)
                guard isDirectory.boolValue else {
                    let bytes = Int64((try? itemSource.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    plan.append(.init(
                        source: itemSource, destination: itemDestination,
                        isDirectory: false, bytes: bytes, topLevelName: name))
                    totalBytes += bytes
                    continue
                }
                plan.append(.init(
                    source: itemSource, destination: itemDestination,
                    isDirectory: true, bytes: 0, topLevelName: name))
                guard let enumerator = fileManager.enumerator(
                    at: itemSource,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                    options: [.skipsHiddenFiles, .producesRelativePathURLs])
                else { continue }
                for case let entry as URL in enumerator {
                    let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    let entryDestination = itemDestination.appendingPathComponent(entry.relativePath)
                    if values?.isDirectory == true {
                        plan.append(.init(
                            source: entry, destination: entryDestination,
                            isDirectory: true, bytes: 0, topLevelName: name))
                    } else {
                        let bytes = Int64(values?.fileSize ?? 0)
                        plan.append(.init(
                            source: entry, destination: entryDestination,
                            isDirectory: false, bytes: bytes, topLevelName: name))
                        totalBytes += bytes
                    }
                }
            }
            return (plan, totalBytes)
        }
        guard let (plan, totalBytes) = buildPlan() else { return .cancelled }

        if let free = (try? destination.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage,
            free < totalBytes + 1_000_000_000 {
            return .failure(
                "Not enough space there. The library is \(LLFormat.bytes(totalBytes)) and only "
                    + "\(LLFormat.bytes(free)) is free at that location.")
        }

        // Every top-level destination is fresh (collisions were refused before
        // the sheet was offered), so on cancel or failure removing exactly
        // these removes everything this move created and nothing else.
        let createdTopLevel = Set(plan.map(\.topLevelName))
            .map { destination.appendingPathComponent($0) }
            .filter { !fileManager.fileExists(atPath: $0.path) }
        func cleanUp() {
            for url in createdTopLevel {
                try? fileManager.removeItem(at: url)
            }
        }

        var copiedBytes: Int64 = 0
        var lastReport = Date.distantPast
        for entry in plan {
            if Task.isCancelled {
                cleanUp()
                return .cancelled
            }
            do {
                if entry.isDirectory {
                    try fileManager.createDirectory(at: entry.destination, withIntermediateDirectories: true)
                    continue
                }
                try fileManager.copyItem(at: entry.source, to: entry.destination)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                // A file that vanished between planning and copying (a log
                // rotating, a cache sweep) is not worth abandoning the move.
                LLog("storage: skipped vanished \(entry.source.lastPathComponent)")
                continue
            } catch {
                cleanUp()
                return .failure(
                    "Couldn't copy \(entry.source.lastPathComponent): \(error.localizedDescription)")
            }
            copiedBytes += entry.bytes
            if Date().timeIntervalSince(lastReport) > 0.2 {
                lastReport = Date()
                await onProgress(copiedBytes, totalBytes, entry.source.lastPathComponent)
            }
        }
        await onProgress(totalBytes, totalBytes, "")
        return .success
    }
}

extension StorageMover.Phase {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - Relaunch

enum AppRelaunch {
    private static var began = false

    /// Quit and reopen. `open` runs from a detached shell that waits for this
    /// process to actually exit, so the new instance can't race the old one's
    /// single-window scene.
    ///
    /// Call this with no sheet presented: NSApp.terminate sent during a sheet
    /// presentation is silently swallowed (the Relaunch button dismisses
    /// first for exactly that reason). If terminate is refused or deferred
    /// anyway, the fallback below exits hard — the helper is already waiting
    /// on this pid, the setting is committed, and nothing in this flow has
    /// unsaved work to lose.
    static func relaunchNow() {
        guard !began else { return }
        began = true
        UserDefaults.standard.synchronize()
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        // A scratch-root run (`-storage.libraryRootPath …`) never wrote the
        // setting, so the new instance is handed its root the same way — the
        // moved one when a nest just happened, else the one this run had.
        var open = "/usr/bin/open \"\(bundlePath)\""
        if StorageRoot.rootCameFromArguments {
            let root = (StorageRoot.argumentRootOverride ?? StorageRoot.current).path
            open += " --args -\(StorageRoot.customPathKey) \"\(root)\" -ApplePersistenceIgnoreState YES"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; \(open)",
        ]
        try? process.run()
        NSApplication.shared.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            exit(0)
        }
    }
}

#endif

import Foundation
import LetsLapseKit
#if os(macOS)
import AppKit
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
        case notWritable
        /// The folder already holds a LetsLapse library — offer to switch to
        /// it in place instead of copying ours over it.
        case adopt
        /// The folder holds a same-named item without being a library (a stray
        /// `Projects` folder, leftovers of an interrupted move) — refuse
        /// rather than merge into it.
        case collision(String)
        case move
    }

    /// What nominating `destination` would mean, decided before anything is
    /// offered. The write probe is a real write: `isWritableFile` answers for
    /// POSIX bits, not for a read-only mount.
    static func check(destination: URL) -> DestinationCheck {
        let fileManager = FileManager.default
        let destinationPath = destination.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = current.standardizedFileURL.resolvingSymlinksInPath().path
        if destinationPath == rootPath { return .alreadyCurrent }
        if destinationPath.hasPrefix(rootPath + "/") { return .insideCurrent }

        let probe = destination.appendingPathComponent(".letslapse-write-probe")
        guard (try? Data("ok".utf8).write(to: probe)) != nil else { return .notWritable }
        try? fileManager.removeItem(at: probe)

        let manifest = destination
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent("library.json")
        if fileManager.fileExists(atPath: manifest.path) { return .adopt }

        for name in libraryItemNames
        where fileManager.fileExists(atPath: current.appendingPathComponent(name).path)
            && fileManager.fileExists(atPath: destination.appendingPathComponent(name).path) {
            return .collision(name)
        }
        return .move
    }
}

// MARK: - Nesting the library under its PicPlace account (v2 plan §3.3)

extension StorageRoot {
    /// `<root>/.letslapse-nested` — written before the folders move, removed
    /// after the setting is committed. A launch that finds it (the app died
    /// in between) follows it, so a half-done nest is never an empty gallery.
    static let nestMarkerName = ".letslapse-nested"

    private struct NestMarker: Codable { var to: String }

    /// Where a library bound to `username` on `host` lives: inside the
    /// current root, named for humans (the binding file is the identity).
    static func nestedRoot(host: String, username: String) -> URL {
        current.appendingPathComponent(host, isDirectory: true).appendingPathComponent(username, isDirectory: true)
    }

    /// Already `…/<host>/<username>`: nothing to move, the binding is
    /// written in place.
    static func isNested(host: String, username: String) -> Bool {
        let root = current.standardizedFileURL
        return root.lastPathComponent == username && root.deletingLastPathComponent().lastPathComponent == host
    }

    enum NestError: LocalizedError {
        case destinationOccupied(String)
        var errorDescription: String? {
            switch self {
            case .destinationOccupied(let path): return "\(path) already exists and is not empty."
            }
        }
    }

    /// Moves the library items into `<root>/<host>/<username>/`, writes the
    /// binding there and commits the new root. Same volume by construction,
    /// so every item is a rename. Call with the persister refusing writes
    /// and the lock released; relaunch right after.
    static func nest(host: String, username: String, binding: PicPlaceBindingRecord) throws {
        let fileManager = FileManager.default
        let source = current
        let destination = nestedRoot(host: host, username: username)
        if fileManager.fileExists(atPath: destination.path) {
            let contents = (try? fileManager.contentsOfDirectory(atPath: destination.path)) ?? []
            if !contents.filter({ $0 != ".DS_Store" }).isEmpty { throw NestError.destinationOccupied(destination.path) }
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = source.appendingPathComponent(nestMarkerName)
        try JSONEncoder().encode(NestMarker(to: destination.path)).write(to: marker, options: .atomic)
        for name in libraryItemNames {
            let from = source.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: from.path) else { continue }
            let to = destination.appendingPathComponent(name)
            if fileManager.fileExists(atPath: to.path) { try fileManager.removeItem(at: to) }
            try fileManager.moveItem(at: from, to: to)
        }
        try binding.write(inRoot: destination)
        commit(destination: destination)
        try? fileManager.removeItem(at: marker)
        LLog("storage: library nested at \(destination.path)")
    }

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

        // What moves: the known library items — or everything visible when the
        // source is the default root, which contains nothing but ours. (A
        // custom root can be a drive root full of unrelated folders; the known
        // list is what protects those from being dragged along on a move back.)
        let names: [String]
        if source.standardizedFileURL.path == StorageRoot.defaultRootURL.standardizedFileURL.path {
            names = (try? fileManager.contentsOfDirectory(atPath: source.path))?
                .filter { !$0.hasPrefix(".") } ?? []
        } else {
            names = StorageRoot.libraryItemNames
        }
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

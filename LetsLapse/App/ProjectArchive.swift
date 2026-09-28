import Foundation
import LetsLapseKit
import UniformTypeIdentifiers

// The manifest at the root of a `.lapse` archive is the project's own
// `project.json` (`ProjectDocument`, data model Phase 2) — the file that
// lives in the project folder, archived with the rest of it, not a manifest
// synthesised for the trip.

enum ProjectArchiveError: LocalizedError {
    case notAProjectArchive
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .notAProjectArchive:
            return "This file isn't a LetsLapse project archive."
        case .unsupportedVersion(let version):
            return "This archive needs a newer version of LetsLapse (format \(version))."
        }
    }
}

/// Project-archive conventions; the byte-level transport lives in the Kit
/// (`DirectoryArchive`) where it is round-trip tested.
enum ProjectArchive {
    static let fileExtension = "lapse"

    /// The launch's safety net (2026-09-28): every `.lapse` at the top of the
    /// temporary directory older than `age` is removed. `exportProject`
    /// writes its archive there — a full second copy of the project — and
    /// the share sheet deletes it when it closes; a sheet that never opened
    /// (the screen went away mid-export), a crash, or a debug export left the
    /// rest behind, several GB of them over time. A day is far past any share
    /// still using one. Off the main thread; logs what it freed.
    static func sweepStaleExports(olderThan age: TimeInterval = 24 * 60 * 60) {
        DispatchQueue.global(qos: .utility).async {
            let temp = FileManager.default.temporaryDirectory
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: temp, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
            let cutoff = Date().addingTimeInterval(-age)
            var removed = 0
            var bytes: Int64 = 0
            for item in items where item.pathExtension.lowercased() == fileExtension {
                guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let modified = values.contentModificationDate, modified < cutoff else { continue }
                if (try? FileManager.default.removeItem(at: item)) != nil {
                    removed += 1
                    bytes += Int64(values.fileSize ?? 0)
                }
            }
            if removed > 0 {
                LLog("export: removed \(removed) stale .lapse archive(s) from tmp — \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
            }
        }
    }

    /// The project subfolders that travel — the ONE definition, read by the
    /// installer (`AppModel.installStagedProject`) and by the transfer's file
    /// enumerator (`ProjectTransferServer`).
    ///
    /// Anything outside this list is silently dropped at install. Before this
    /// was one constant that was merely a comment's worth of coupling; with a
    /// network path it is worse — a subfolder that misses the list would be
    /// sent over the wire, for however many minutes that takes, and then
    /// deleted on arrival. A new project subfolder must be added here.
    // `luts` (2026-09-08): a project graded with a LUT preset carries its own
    // copy of the cube, so the far side can render it without the sender's
    // LUT store — see `LUTStore.ensureCopy` and docs/presets-lut-spike.md §4.4.
    // Since 2026-09-13 the list is DERIVED from the Kit's `ProjectFileRegistry`
    // — the one table of per-project files — so a new subfolder is registered
    // once, with its class and whether it travels, and every list that reads
    // the registry (this one, the clone, the audit) agrees.
    static let transferableSubfolders = ProjectFileRegistry.travellingSubfolders

    /// The project's top-level FILES that travel, on the same terms as the
    /// subfolders above and read by the same two places.
    ///
    /// A separate list because the two are moved differently — a subfolder
    /// arrives whole, a file arrives on its own — and because forgetting one
    /// fails silently in the same way: overlays.json (the text overlays and
    /// their mask dials) was dropped at install until 2026-08-31, so an
    /// AirDropped project arrived with its text gone and had to be re-typed
    /// on the far side. `project.json` is NOT here: the registry keeps it out
    /// of this list because the installer reads and re-keys it, never moves it.
    // `assets.ndjson` (the per-asset records: hashes and metadata layers) and
    // `metadata.json` (the project-level record) joined on 2026-09-13.
    static let transferableFiles = ProjectFileRegistry.travellingRootFiles

    static func write(contentsOf directory: URL, to archiveURL: URL) throws {
        try DirectoryArchive.write(contentsOf: directory, to: archiveURL)
    }

    /// See `DirectoryArchive.extract` — the hooks run on the archiver's worker
    /// threads, and `shouldContinue` returning false throws `.cancelled`.
    static func extract(
        _ archiveURL: URL,
        to directory: URL,
        shouldContinue: (@Sendable () -> Bool)? = nil,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) throws {
        try DirectoryArchive.extract(
            archiveURL, to: directory, shouldContinue: shouldContinue, progress: progress)
    }

    /// True for anything that looks like a project archive by name. Deliberately
    /// extension-only: the type declaration is what Launch Services matches on,
    /// and a file dragged in from a volume that lost its metadata should still
    /// be *tried* — `extract` rejects a fake soon enough.
    static func isArchive(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == fileExtension
    }
}

extension UTType {
    /// The exported type declared in `App/Info.plist`. Changing the identifier
    /// in one place without the other silently stops Finder handing `.lapse`
    /// files to the app.
    static let lapseProject = UTType(
        exportedAs: "com.regularsteven.letslapse.project", conformingTo: .data)
}

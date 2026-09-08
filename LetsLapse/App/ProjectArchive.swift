import Foundation
import LetsLapseKit
import UniformTypeIdentifiers

/// The manifest at the root of a portable `.lapse` project archive, beside
/// the project folder's `source/` and `blends/` trees.
struct ProjectArchiveManifest: Codable {
    var formatVersion: Int = 1
    var capture: AppModel.CaptureProject
    var blends: [AppModel.BlendProject]
}

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
    static let transferableSubfolders = ["source", "blends", "notes", "masks", "fonts", "luts"]

    /// The project's top-level FILES that travel, on the same terms as the
    /// subfolders above and read by the same two places.
    ///
    /// A separate list because the two are moved differently — a subfolder
    /// arrives whole, a file arrives on its own — and because forgetting one
    /// fails silently in the same way: overlays.json (the text overlays and
    /// their mask dials) was dropped at install until 2026-08-31, so an
    /// AirDropped project arrived with its text gone and had to be re-typed
    /// on the far side. `project.json` is NOT here: the manifest is written
    /// by the sender and re-keyed by the installer, never moved.
    static let transferableFiles = ["overlays.json"]

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

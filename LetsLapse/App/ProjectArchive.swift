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
    static let transferableSubfolders = ["source", "blends", "notes"]

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

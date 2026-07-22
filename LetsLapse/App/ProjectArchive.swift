import Foundation
import LetsLapseKit

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

    static func write(contentsOf directory: URL, to archiveURL: URL) throws {
        try DirectoryArchive.write(contentsOf: directory, to: archiveURL)
    }

    static func extract(_ archiveURL: URL, to directory: URL) throws {
        try DirectoryArchive.extract(archiveURL, to: directory)
    }
}

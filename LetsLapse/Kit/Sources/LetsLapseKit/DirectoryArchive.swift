import Foundation
import AppleArchive
import System

public enum DirectoryArchiveError: LocalizedError {
    case streamSetupFailed

    public var errorDescription: String? {
        switch self {
        case .streamSetupFailed: return "Couldn't open the archive."
        }
    }
}

/// Apple Archive (lzfse) read/write for whole directories — the transport
/// under `.lapse` project archives. Both ends are LetsLapse builds, so the
/// platform-native archiver beats adding a zip dependency.
public enum DirectoryArchive {
    /// Archives `directory`'s contents (not the directory node itself).
    public static func write(contentsOf directory: URL, to archiveURL: URL) throws {
        try? FileManager.default.removeItem(at: archiveURL)
        guard let writeStream = ArchiveByteStream.fileStream(
            path: FilePath(archiveURL.path),
            mode: .writeOnly,
            options: [.create, .truncate],
            permissions: FilePermissions(rawValue: 0o644)) else {
            throw DirectoryArchiveError.streamSetupFailed
        }
        defer { try? writeStream.close() }
        guard let compressStream = ArchiveByteStream.compressionStream(using: .lzfse, writingTo: writeStream) else {
            throw DirectoryArchiveError.streamSetupFailed
        }
        defer { try? compressStream.close() }
        guard let encodeStream = ArchiveStream.encodeStream(writingTo: compressStream) else {
            throw DirectoryArchiveError.streamSetupFailed
        }
        defer { try? encodeStream.close() }
        try encodeStream.writeDirectoryContents(
            archiveFrom: FilePath(directory.path),
            keySet: .defaultForArchive)
    }

    public static func extract(_ archiveURL: URL, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let readStream = ArchiveByteStream.fileStream(
            path: FilePath(archiveURL.path),
            mode: .readOnly,
            options: [],
            permissions: FilePermissions(rawValue: 0o644)) else {
            throw DirectoryArchiveError.streamSetupFailed
        }
        defer { try? readStream.close() }
        guard let decompressStream = ArchiveByteStream.decompressionStream(readingFrom: readStream) else {
            throw DirectoryArchiveError.streamSetupFailed
        }
        defer { try? decompressStream.close() }
        guard let decodeStream = ArchiveStream.decodeStream(readingFrom: decompressStream) else {
            throw DirectoryArchiveError.streamSetupFailed
        }
        defer { try? decodeStream.close() }
        guard let extractStream = ArchiveStream.extractStream(
            extractingTo: FilePath(directory.path),
            flags: [.ignoreOperationNotPermitted]) else {
            throw DirectoryArchiveError.streamSetupFailed
        }
        defer { try? extractStream.close() }
        _ = try ArchiveStream.process(readingFrom: decodeStream, writingTo: extractStream)
    }
}

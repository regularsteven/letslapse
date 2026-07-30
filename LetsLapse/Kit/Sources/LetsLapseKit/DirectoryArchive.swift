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
        guard let compressStream = ArchiveByteStream.compressionStream(using: .lzfse, writingTo: writeStream) else {
            try? writeStream.close()
            throw DirectoryArchiveError.streamSetupFailed
        }
        guard let encodeStream = ArchiveStream.encodeStream(writingTo: compressStream) else {
            try? compressStream.close()
            try? writeStream.close()
            throw DirectoryArchiveError.streamSetupFailed
        }

        // AppleArchive buffers and flushes on worker threads, so a full disk
        // (or any other write failure) surfaces from `close()` rather than from
        // the write call. Close all three in order whatever happens — leaking
        // them would leak the file descriptor — then rethrow the first failure
        // so a truncated archive is never reported as a success.
        var failure: Error?
        do {
            try encodeStream.writeDirectoryContents(
                archiveFrom: FilePath(directory.path),
                keySet: .defaultForArchive)
        } catch {
            failure = error
        }
        let closers: [() throws -> Void] = [encodeStream.close, compressStream.close, writeStream.close]
        for close in closers {
            do {
                try close()
            } catch {
                if failure == nil { failure = error }
            }
        }
        if let failure {
            try? FileManager.default.removeItem(at: archiveURL)
            throw failure
        }
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

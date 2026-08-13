import Foundation
import AppleArchive
import System

public enum DirectoryArchiveError: LocalizedError {
    case streamSetupFailed
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .streamSetupFailed: return "Couldn't open the archive."
        case .cancelled: return "The archive was cancelled."
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

    /// Restores an archive written by `write(contentsOf:to:)`.
    ///
    /// A whole project is gigabytes, so extraction reports what it has written
    /// and can be stopped part-way. Both hooks run on AppleArchive's own worker
    /// threads — possibly several at once — so they must be safe to call
    /// concurrently. `progress` is handed the running total of *payload* bytes
    /// written (file contents; directory nodes and metadata contribute nothing),
    /// which is what a caller comparing against the archive's own file size
    /// wants. Returning `false` from `shouldContinue` throws
    /// `DirectoryArchiveError.cancelled` rather than leaving the caller to
    /// interpret an opaque AppleArchive failure; the partial tree is the
    /// caller's to delete.
    public static func extract(
        _ archiveURL: URL,
        to directory: URL,
        shouldContinue: (@Sendable () -> Bool)? = nil,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) throws {
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

        let tally = ExtractionTally(directory: directory, report: progress)
        // `.cancel` aborts the run from inside AppleArchive, which surfaces as a
        // generic error out of `process`; the flag is what tells the two apart.
        let stopped = Cancellation()
        let filter: ArchiveHeader.EntryFilter? =
            (shouldContinue == nil && progress == nil) ? nil : { message, path, data in
                if let shouldContinue, !shouldContinue() {
                    stopped.stop()
                    return .cancel
                }
                switch message {
                case .extractBegin:
                    if case .header(let header)? = data { tally.willExtract(path, header: header) }
                case .extractEnd:
                    tally.didExtract(path)
                default:
                    break
                }
                return .ok
            }

        guard let extractStream = ArchiveStream.extractStream(
            extractingTo: FilePath(directory.path),
            selectUsing: filter,
            flags: [.ignoreOperationNotPermitted]) else {
            throw DirectoryArchiveError.streamSetupFailed
        }
        defer { try? extractStream.close() }
        do {
            _ = try ArchiveStream.process(readingFrom: decodeStream, writingTo: extractStream)
        } catch {
            throw stopped.isStopped ? DirectoryArchiveError.cancelled : error
        }
        if stopped.isStopped { throw DirectoryArchiveError.cancelled }
    }
}

/// A cancellation latch readable from any thread — set inside the entry filter,
/// read once the archive pump has unwound.
private final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

/// Counts payload bytes as entries land, from the entry filter's worker threads.
///
/// Sizes are taken from each entry's `DAT` field at `extractBegin` and only
/// added at `extractEnd`, so the total never claims bytes that aren't on disk
/// yet. An entry whose header carries no `DAT` (a directory, a symlink, or an
/// archive that stored its payload some other way) is measured from the file
/// itself instead, so the tally still moves rather than silently sitting at zero.
private final class ExtractionTally: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let report: (@Sendable (Int64) -> Void)?
    private var pending: [String: Int64] = [:]
    private var written: Int64 = 0

    init(directory: URL, report: (@Sendable (Int64) -> Void)?) {
        self.directory = directory
        self.report = report
    }

    func willExtract(_ path: FilePath, header: ArchiveHeader) {
        guard report != nil else { return }
        guard case .blob(_, let size, _)? = header.field(forKey: ArchiveHeader.FieldKey("DAT")) else { return }
        lock.lock()
        pending[path.string] = Int64(size)
        lock.unlock()
    }

    func didExtract(_ path: FilePath) {
        guard let report else { return }
        lock.lock()
        let size = pending.removeValue(forKey: path.string) ?? Self.sizeOnDisk(directory, path)
        written += size
        let total = written
        lock.unlock()
        report(total)
    }

    private static func sizeOnDisk(_ directory: URL, _ path: FilePath) -> Int64 {
        let url = directory.appendingPathComponent(path.string)
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return Int64(size ?? 0)
    }
}

import CryptoKit
import Foundation

/// Whole-file SHA-256, streamed — the content identity of every source frame
/// and blend output (`assets.ndjson`), and what an upload will verify.
///
/// Whole-file rather than an image-data digest, by decision (Phase 1 spec
/// W5): our DNG writer emits no `NewRawImageDigest`, Lightroom is being
/// retired, and the whole file is what moves between devices. An image-data
/// digest can join the record as a second field later without a migration.
public enum AssetHash {

    public static let prefix = "sha256:"

    /// `"sha256:<64 hex>"` of the file at `url`, read in 1 MB chunks so a 47
    /// MB DNG never sits in memory whole.
    ///
    /// POSIX `read(2)` into one reusable buffer, on purpose. The first
    /// version used `FileHandle.read(upToCount:)`, whose chunks come back as
    /// autoreleased `NSData` — and the backfill walks a whole project inside
    /// one dispatch block, so nothing drained them: hashing a 2315-frame DNG
    /// project on 2026-09-13 pushed ~25 GB into the pool, the Mac went into
    /// swap six seconds into the walk, and the app died on the next decode.
    /// A plain buffer allocates nothing per chunk. `F_NOCACHE` keeps a
    /// one-pass read of a 25 GB project from evicting everything else from
    /// the unified buffer cache.
    public static func sha256(of url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            if count == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
        }
        return prefix + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(of data: Data) -> String {
        prefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func posixError() -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
    }
}

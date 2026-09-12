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
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return prefix + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(of data: Data) -> String {
        prefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

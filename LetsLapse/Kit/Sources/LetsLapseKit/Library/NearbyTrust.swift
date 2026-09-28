import CryptoKit
import Foundation

/// Nearby originals (docs/nearby-originals-plan.md §5): what two devices of
/// one PicPlace account derive from the account's nearby key — the TLS
/// pre-shared key their link is encrypted with, and the tag each announces
/// itself with on the local network. The key itself never leaves the device:
/// everything that crosses the network is derived here, with HKDF-SHA256
/// under one purpose-scoped salt.
///
/// Pure and deterministic. `NearbyTrustTests` pins the bytes with vectors
/// computed by an independent implementation, so another client (or a
/// probe) derives the same key from the same inputs.
public enum NearbyTrust {

    /// Scopes every derivation to this purpose — the HKDF salt.
    public static let salt = "com.regularsteven.letslapse.nearby.v1"

    /// A key PicPlace hands out is 32 random bytes.
    public static let keyLength = 32

    /// How many bytes of the daily HMAC the tag keeps.
    public static let tagLength = 8

    /// The key as `GET /nearby/key` sends it — base64url without padding
    /// (43 characters); padded or standard base64 is read too. nil for
    /// anything that is not exactly 32 bytes.
    public static func decodeKey(_ text: String) -> Data? {
        var base64 = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64), data.count == keyLength else { return nil }
        return data
    }

    /// The link's TLS pre-shared key: this account on this server install.
    /// Two devices that disagree on any of the three cannot complete the
    /// handshake.
    public static func psk(key: Data, serverID: String, userUUID: String) -> Data {
        derive(key: key, info: "tls-psk|\(serverID.lowercased())|\(userUUID.lowercased())")
    }

    /// The tag a device carries in its Bonjour TXT record on `day` (UTC):
    /// the first 8 bytes of an HMAC over the date under the `discovery`
    /// subkey, base64url. It changes daily, so it cannot follow a device
    /// from one day to the next, and only a device holding the key can
    /// tell whose it is.
    public static func discoveryTag(key: Data, day: Date) -> String {
        let subkey = SymmetricKey(data: derive(key: key, info: "discovery"))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(dayString(day).utf8), using: subkey)
        return base64url(Data(mac).prefix(tagLength))
    }

    /// Whether `tag` is this key's — today's, yesterday's or tomorrow's, so
    /// two clocks either side of midnight still recognise each other.
    public static func accepts(tag: String, key: Data, now: Date = Date()) -> Bool {
        [-1.0, 0, 1].contains { offset in
            discoveryTag(key: key, day: now.addingTimeInterval(offset * 86_400)) == tag
        }
    }

    /// "2026-09-28" — the UTC date the tag is made over.
    public static func dayString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// A project-relative path a peer may name: relative, inside the
    /// project folder, no `..`, no empty or hidden components. The serving
    /// device checks every requested path with this before it resolves it
    /// — and then that it names one of the project's heavy files.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".." && !component.hasPrefix(".")
        }
    }

    static func derive(key: Data, info: String) -> Data {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: key),
            salt: Data(salt.utf8),
            info: Data(info.utf8),
            outputByteCount: 32)
        return derived.withUnsafeBytes { Data($0) }
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

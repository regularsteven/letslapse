import Foundation
import Security

/// The tokens PicPlace issued to THIS install for THIS server. Access tokens
/// are short-lived and refreshed silently; refresh tokens rotate on every
/// use, so what is stored here is always the latest pair.
struct PicPlaceTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var server: String

    var isExpiringSoon: Bool { expiresAt.timeIntervalSinceNow < 60 }
}

/// Generic-password items in the Keychain, this device only (never synced
/// to other devices — a token names an install, like `DeviceIdentity`).
///
/// **One item per account** (v2 plan §3.2): the item's account attribute is
/// `PicPlaceBindingRecord.accountKey` — `<host>|<user uuid>` — so a Mac
/// with a `picplace.test` library and a `picplace.co` library switches
/// sessions with its libraries without a second sign-in. v1 kept a single
/// item under `"tokens"`; `loadLegacy`/`clearLegacy` migrate it once.
enum PicPlaceKeychain {

    private static let legacyAccount = "tokens"

    static func load(account: String) -> PicPlaceTokens? {
        var query = baseQuery(account: account, dataProtection: true)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecMissingEntitlement || status == errSecParam {
            var legacy = baseQuery(account: account, dataProtection: false)
            legacy[kSecReturnData as String] = true
            legacy[kSecMatchLimit as String] = kSecMatchLimitOne
            status = SecItemCopyMatching(legacy as CFDictionary, &item)
        }
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(PicPlaceTokens.self, from: data)
    }

    static func save(_ tokens: PicPlaceTokens, account: String) throws {
        let data = try JSONEncoder().encode(tokens)
        var status = write(data, account: account, dataProtection: true)
        if status == errSecMissingEntitlement || status == errSecParam {
            status = write(data, account: account, dataProtection: false)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not store the PicPlace sign-in (Keychain \(status))."])
        }
    }

    static func clear(account: String) {
        SecItemDelete(baseQuery(account: account, dataProtection: true) as CFDictionary)
        SecItemDelete(baseQuery(account: account, dataProtection: false) as CFDictionary)
    }

    /// v1's single item, if this install still has one.
    static func loadLegacy() -> PicPlaceTokens? { load(account: legacyAccount) }
    static func clearLegacy() { clear(account: legacyAccount) }

    private static func write(_ data: Data, account: String, dataProtection: Bool) -> OSStatus {
        let query = baseQuery(account: account, dataProtection: dataProtection)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            return SecItemAdd(add as CFDictionary, nil)
        }
        return status
    }

    private static func baseQuery(account: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PicPlaceConfiguration.keychainService,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS)
        // The data-protection keychain behaves like iOS's: no login-keychain
        // prompts, no sharing across apps. Available to a signed app; an
        // unsigned one falls back to the login keychain above.
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return query
    }
}

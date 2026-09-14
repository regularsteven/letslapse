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

/// One generic-password item in the Keychain, this device only (never
/// synced to other devices — a token names an install, like `DeviceIdentity`).
enum PicPlaceKeychain {

    private static let account = "tokens"

    static func load() -> PicPlaceTokens? {
        var query = baseQuery(dataProtection: true)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecMissingEntitlement || status == errSecParam {
            var legacy = baseQuery(dataProtection: false)
            legacy[kSecReturnData as String] = true
            legacy[kSecMatchLimit as String] = kSecMatchLimitOne
            status = SecItemCopyMatching(legacy as CFDictionary, &item)
        }
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(PicPlaceTokens.self, from: data)
    }

    static func save(_ tokens: PicPlaceTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        var status = write(data, dataProtection: true)
        if status == errSecMissingEntitlement || status == errSecParam {
            status = write(data, dataProtection: false)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not store the PicPlace sign-in (Keychain \(status))."])
        }
    }

    static func clear() {
        SecItemDelete(baseQuery(dataProtection: true) as CFDictionary)
        SecItemDelete(baseQuery(dataProtection: false) as CFDictionary)
    }

    private static func write(_ data: Data, dataProtection: Bool) -> OSStatus {
        let query = baseQuery(dataProtection: dataProtection)
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

    private static func baseQuery(dataProtection: Bool) -> [String: Any] {
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

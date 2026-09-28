import Foundation
import LetsLapseKit

// MARK: - The account's nearby key (2026-09-28)
//
// docs/nearby-originals-plan.md §5, docs/picplace-nearby-key-ask.md. A
// secret only this account's signed-in devices can read: the devices derive
// their link's TLS key and their discovery tag from it (`NearbyTrust`), so
// they recognise each other on a local network with no pairing code.
//
// PicPlace says it has one (`features.nearby_key`, `nearby.key_id` in
// `/status` — the id, never the key); this device fetches the key when the
// id differs from the one it holds, keeps it in the Keychain beside the
// tokens, and drops it at sign-out, when PicPlace signs the device out or
// refuses the account, and when PicPlace stops offering it. A key not
// confirmed by `/status` for 30 days is not used (the device may have been
// revoked meanwhile). Nothing here runs against a server that doesn't offer
// the key — the feature is dormant until it does.

/// The key as this device holds it.
struct PicPlaceNearbyKey: Codable, Equatable {
    var keyID: String
    var key: Data
    /// When a `/status` last named this key as the account's current one.
    var confirmedAt: Date
    /// The account it belongs to (`<host>|<user uuid>`).
    var accountKey: String
    /// DEBUG: staged by `LL_NEARBY_KEY` — never stored, never refreshed.
    var isStaged = false

    static let maxUnconfirmed: TimeInterval = 30 * 24 * 3600

    /// Usable: staged, or confirmed within 30 days.
    var isFresh: Bool { isStaged || Date().timeIntervalSince(confirmedAt) < Self.maxUnconfirmed }
}

extension PicPlaceController {

    private static func nearbyKeychainAccount(_ accountKey: String) -> String { accountKey + "|nearby" }

    /// Read off every `/status` (through `noteLibraries`): whether PicPlace
    /// offers the key, and whether the one held here is still current.
    func noteNearbyKey(_ status: PPStatus) {
        if nearbyKey?.isStaged == true { return }
        serverOffersNearbyKey = status.offersNearbyKey
        guard let profile else { return }
        guard status.offersNearbyKey else {
            if nearbyKey != nil { dropNearbyKey(reason: "PicPlace no longer offers it", accountKey: profile.accountKey) }
            return
        }
        if var held = nearbyKey, held.accountKey == profile.accountKey,
           let current = status.nearby?.keyId, held.keyID == current {
            held.confirmedAt = Date()
            nearbyKey = held
            storeNearbyKey(held)
            return
        }
        fetchNearbyKey()
    }

    /// `GET /nearby/key` — minted on PicPlace by the first ask.
    func fetchNearbyKey() {
        guard nearbyKeyFetch == nil, let account = profile?.accountKey else { return }
        nearbyKeyFetch = Task { [weak self] in
            guard let self else { return }
            defer { self.nearbyKeyFetch = nil }
            do {
                let response: PPNearbyKeyResponse = try await self.client.get("nearby/key")
                guard self.profile?.accountKey == account else { return }
                guard let key = NearbyTrust.decodeKey(response.nearby.key) else {
                    LLog("nearby: PicPlace sent a key that is not 32 bytes of base64url — not used")
                    return
                }
                let held = PicPlaceNearbyKey(keyID: response.nearby.keyId, key: key, confirmedAt: Date(), accountKey: account)
                let changed = self.nearbyKey?.keyID != held.keyID
                self.nearbyKey = held
                self.storeNearbyKey(held)
                if changed { LLog("nearby: key \(held.keyID) held for \(account)") }
            } catch {
                self.noteNearbyKeyRefusal(error)
                LLog("nearby: could not fetch the key: \(Self.describe(error))")
            }
        }
    }

    /// A refusal that ends the key's use here (PicPlace's answer §6): a
    /// revoked device, a disabled account — which revokes nothing, so its
    /// key would otherwise keep working — or the key switched off
    /// (`404 nearby_key_disabled`). Anything else waits for the next
    /// `/status`.
    func noteNearbyKeyRefusal(_ error: Error) {
        guard let refused = error as? PicPlaceAPIError, nearbyKey?.isStaged != true,
              ["device_revoked", "account_not_enabled", "nearby_key_disabled"].contains(refused.code ?? "") else { return }
        dropNearbyKey(reason: refused.code ?? "refused", accountKey: profile?.accountKey)
    }

    /// Forgets the key here and in the Keychain.
    func dropNearbyKey(reason: String, accountKey: String?) {
        nearbyKeyFetch?.cancel()
        nearbyKeyFetch = nil
        if let account = accountKey ?? nearbyKey?.accountKey, nearbyKey?.isStaged != true {
            PicPlaceKeychain.clear(account: Self.nearbyKeychainAccount(account))
        }
        if nearbyKey != nil { LLog("nearby: key dropped — \(reason)") }
        nearbyKey = nil
    }

    /// A tag on the network this device's key doesn't recognise: another
    /// account's device, or one of this account's holding a newer key. One
    /// `/status` read, at most every ten minutes, tells which.
    func nearbyKeyMayBeStale() {
        guard nearbyKey?.isStaged != true, isSignedIn else { return }
        if let last = nearbyStatusRereadAt, Date().timeIntervalSince(last) < 600 { return }
        nearbyStatusRereadAt = Date()
        refreshUsage()
    }

    /// At launch: the key an earlier run held — or, in a DEBUG run,
    /// `LL_NEARBY_KEY=<base64url>[:<key id>]`, a key staged with no server
    /// (two instances given the same key trust each other).
    func restoreNearbyKey() {
        #if DEBUG
        if let staged = ProcessInfo.processInfo.environment["LL_NEARBY_KEY"] {
            let parts = staged.split(separator: ":", maxSplits: 1).map(String.init)
            guard let key = parts.first.flatMap(NearbyTrust.decodeKey) else {
                LLog("nearby: LL_NEARBY_KEY is not a 32-byte base64url key — nothing staged")
                return
            }
            nearbyKey = PicPlaceNearbyKey(keyID: parts.count > 1 ? parts[1] : "staged", key: key,
                                          confirmedAt: Date(), accountKey: "staged", isStaged: true)
            serverOffersNearbyKey = true
            LLog("nearby: key staged by LL_NEARBY_KEY (\(nearbyKey?.keyID ?? "")) — PicPlace not asked")
            return
        }
        // A bench run with injected tokens never reads the Keychain: an
        // unsigned build raises a SecurityAgent prompt on the person's
        // screen (2026-09-17, 2026-09-23).
        if ProcessInfo.processInfo.environment["LL_PICPLACE_TOKENS"] != nil { return }
        #endif
        guard let account = profile?.accountKey,
              let data = PicPlaceKeychain.loadData(account: Self.nearbyKeychainAccount(account)),
              let stored = try? JSONDecoder().decode(PicPlaceNearbyKey.self, from: data),
              stored.accountKey == account else { return }
        nearbyKey = stored
    }

    private func storeNearbyKey(_ key: PicPlaceNearbyKey) {
        guard !key.isStaged else { return }
        #if DEBUG
        if ProcessInfo.processInfo.environment["LL_PICPLACE_TOKENS"] != nil { return }
        #endif
        do {
            try PicPlaceKeychain.saveData(try JSONEncoder().encode(key), account: Self.nearbyKeychainAccount(key.accountKey))
        } catch {
            LLog("nearby: could not keep the key in the Keychain: \(error.localizedDescription)")
        }
    }
}

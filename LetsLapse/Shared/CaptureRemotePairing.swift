import Foundation
import CryptoKit
import Network

/// The shared secret behind the TLS-PSK handshake, and where it comes from.
///
/// The threat this exists for is mundane and real: this channel starts and
/// stops recordings on a camera over the LAN, and without pairing any process
/// on the network could drive it. The code is shown on the camera and typed on
/// the Mac, so possession of the screen is what grants control.
///
/// The code itself is never the PSK. It is stretched with HKDF first, so a
/// six-digit secret isn't handed straight to TLS as key material.
enum CaptureRemotePairing {
    /// Six digits: long enough that guessing is pointless against a listener
    /// that drops a peer on a failed handshake, short enough to read off a
    /// window-mounted iPad and type once.
    static func generateCode() -> String {
        let value = UInt32.random(in: 0..<1_000_000)
        return String(format: "%06u", value)
    }

    /// Stable id for a pairing, advertised in TXT so a Mac holding a stored key
    /// can tell whether that key still applies to this camera. Derived from the
    /// code, so it changes whenever the code is regenerated, and reveals
    /// nothing about it.
    static func pairingID(code: String) -> String {
        let digest = SHA256.hash(data: Data(code.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The camera remote's salt, and the default everywhere — every existing
    /// call site keeps its wire behaviour bit-identical.
    static let captureRemoteSalt = "com.regularsteven.letslapse.remote.v1"
    private static let info = Data("tls-psk".utf8)

    /// HKDF-SHA256 over the code. Both ends derive this independently; it never
    /// crosses the network.
    ///
    /// `salt` scopes the key to one purpose. A second channel on the same LAN
    /// — the library transfer — derives a different PSK from the same six
    /// digits, so a code minted for one cannot be replayed against the other
    /// even if it is read off a screen and typed into the wrong field.
    static func derivedKey(code: String, salt: String = captureRemoteSalt) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
            salt: Data(salt.utf8),
            info: info,
            outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    /// TLS parameters for both ends of the link.
    ///
    /// Two specifics, both established by spike rather than by documentation:
    /// PSK under TLS 1.3 uses the ordinary AEAD suites, NOT the legacy
    /// `TLS_PSK_WITH_*` ones; and a mismatched key surfaces as `-9846 bad MAC`
    /// on the first read rather than as a clean handshake failure, so callers
    /// must treat a read error during setup as "wrong code", not "network
    /// glitch".
    /// `salt` and `identity` scope the handshake to a purpose — see
    /// `derivedKey`. `bulkTransfer` swaps the control link's twitchy keepalive
    /// for one a 40-minute file pull over congested 2.4 GHz can survive, and
    /// leaves Nagle on (bulk chunks fill segments by themselves).
    static func parameters(
        code: String,
        salt: String = captureRemoteSalt,
        identity: String = "letslapse-remote",
        bulkTransfer: Bool = false
    ) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let keyData = derivedKey(code: code, salt: salt)
        let identityData = Data(identity.utf8)
        let keyDD = keyData.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityDD = identityData.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            tls.securityProtocolOptions,
            keyDD as __DispatchData,
            identityDD as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions,
            tls_ciphersuite_t.AES_128_GCM_SHA256)
        sec_protocol_options_set_min_tls_protocol_version(
            tls.securityProtocolOptions, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        if bulkTransfer {
            // Right for a control link, wrong for bulk: 5/2/2 tears down a
            // healthy transfer the moment a congested network stalls it.
            tcp.keepaliveIdle = 20
            tcp.keepaliveCount = 3
            tcp.keepaliveInterval = 5
        } else {
            // A window-mounted iPad that drops off Wi-Fi should surface as
            // unreachable promptly, rather than leaving the Mac showing a live
            // link to nothing.
            tcp.keepaliveIdle = 5
            tcp.keepaliveCount = 2
            tcp.keepaliveInterval = 2
            tcp.noDelay = true
        }

        return NWParameters(tls: tls, tcp: tcp)
    }
}

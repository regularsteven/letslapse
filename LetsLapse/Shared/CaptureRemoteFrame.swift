import Foundation

/// One message on a byte-stream transport.
///
/// `WatchMessageKey` stays the vocabulary — `body` is exactly the dictionary
/// WatchConnectivity carries, so `applyState` and the receiver's `handle` need
/// no changes. The envelope adds only what a stream needs and WC gave us free:
///
/// - **`id`** correlates a reply with its command. `sendMessage(_:replyHandler:)`
///   did this for us; over one socket we have to carry it.
/// - **`kind`** separates a reply from an unsolicited push. Without it, a state
///   push landing mid-flight would be indistinguishable from an accept — and
///   the remote applies optimistic state on accepts, so it would act on a
///   command the camera never ran.
struct CaptureRemoteFrame {
    enum Kind: String {
        case command
        case reply
        /// Unsolicited state snapshot. Carries `id: 0` — it answers nothing.
        case push
    }

    var id: UInt32
    var kind: Kind
    var body: [String: Any]

    static func push(_ body: [String: Any]) -> CaptureRemoteFrame {
        CaptureRemoteFrame(id: 0, kind: .push, body: body)
    }
}

// MARK: - Wire format

/// 4-byte big-endian length, then that many bytes of JSON. Deliberately not
/// `NWProtocolFramer`: the framing is three lines, and a framer would put this
/// logic somewhere the CLI prover can't reach.
enum CaptureRemoteCoder {
    /// Refuse absurd lengths rather than trying to allocate them. A paired peer
    /// never sends anything close; an unpaired one can't get this far past TLS.
    static let maxFrameBytes = 1 << 20

    enum CoderError: Error {
        case malformedJSON
        case oversizedFrame(Int)
    }

    static func encode(_ frame: CaptureRemoteFrame) throws -> Data {
        let object: [String: Any] = [
            "id": frame.id,
            "kind": frame.kind.rawValue,
            "body": frame.body
        ]
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CoderError.malformedJSON
        }
        let payload = try JSONSerialization.data(withJSONObject: object)
        guard payload.count <= maxFrameBytes else {
            throw CoderError.oversizedFrame(payload.count)
        }
        var length = UInt32(payload.count).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(payload)
        return out
    }

    static func decodeLength(_ header: Data) throws -> Int {
        let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard length > 0, length <= maxFrameBytes else {
            throw CoderError.oversizedFrame(length)
        }
        return length
    }

    static func decode(_ payload: Data) throws -> CaptureRemoteFrame {
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let rawKind = object["kind"] as? String,
              let kind = CaptureRemoteFrame.Kind(rawValue: rawKind),
              let body = object["body"] as? [String: Any] else {
            throw CoderError.malformedJSON
        }
        // A missing id is only ever valid on a push, which answers nothing.
        let id = (object["id"] as? UInt32) ?? UInt32(object["id"] as? Int ?? 0)
        return CaptureRemoteFrame(id: id, kind: kind, body: body)
    }
}

// MARK: - Service

enum CaptureRemoteService {
    /// Must also be listed in `NSBonjourServices` in the partial App/Info.plist.
    /// That key is an ARRAY, so it cannot be an `INFOPLIST_KEY_*` build setting
    /// — Xcode's generator silently emits an empty dict for those, and browsing
    /// then finds nothing with no error to explain why.
    static let type = "_letslapse-remote._tcp"

    /// TXT record keys advertised alongside the service, so the picker can name
    /// a camera and say whether it's shooting before you connect to it.
    enum TXTKey {
        static let deviceName = "name"
        static let model = "model"
        static let recordingState = "rec"
        /// Identifies the pairing this camera currently expects, so a Mac that
        /// already holds a key knows whether it still applies.
        static let pairingID = "pid"
    }
}

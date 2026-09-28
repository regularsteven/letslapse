import Foundation

// MARK: - Nearby originals: the words on the wire (2026-09-28)
//
// docs/nearby-originals-plan.md §6–7. The link carries the project
// transfer's frames (`PTFrame`, `PTCoder`, `PTFrameReader`: a type byte, a
// big-endian length, JSON control bodies or raw file bytes) with a
// vocabulary of its own. The file stream is the transfer's, unchanged — the
// serving side runs `ProjectTransferServer.pump`, so `fileBegin`, `ack` and
// `error` are the transfer's own messages and a `cancel` frame stops it.
//
// Every connection opens with `hello` both ways. Then either `holdings`
// (which of these projects do you hold?) or `requestFiles` (send me these
// files of this project). A query link closes after its answer; an import
// link after `filesDone` or an error.

enum NearbyKind: String, Codable {
    case hello
    case holdings
    case holdingsReply
    case requestFiles
    case filesReady
    // The transfer's own, sent by its pump and read by its client.
    case fileBegin
    case ack
    case filesDone
    case error
}

/// Who is at the other end. The TLS handshake already proved the account
/// (the pre-shared key is derived from its key, server id and user uuid);
/// these are checked again and kept for the words: "Import originals from
/// iPhone 18 Pro", "Sending originals to Steve's MacBook Pro".
struct NearbyHello: Codable, Equatable {
    var kind = NearbyKind.hello.rawValue
    var version: Int
    var serverID: String
    var userUUID: String
    /// PicPlace's id for the device (`profile.deviceID`).
    var deviceID: String
    /// `DeviceName.current`.
    var name: String
    /// `macos` · `ios` · `ipados`.
    var platform: String
}

/// "Which of these projects do you hold?" — by origin id, the only id two
/// devices share (a transferred copy's local id differs).
struct NearbyHoldingsQuery: Codable {
    var kind = NearbyKind.holdings.rawValue
    var originIDs: [UUID]
}

/// One project's answer. A project the serving device doesn't hold, isn't
/// on PicPlace, or isn't in its open library is left out.
struct NearbyHoldingsRow: Codable, Equatable {
    var originID: UUID
    /// Every original the project lists is here (a clip by any encoding).
    var hasAllOriginals: Bool
    var originalsBytes: Int64?
    /// The blend files here, project-relative (`blends/<id>.mov`).
    var blendFiles: [String]
    /// Why nothing can be sent right now ("That device is shooting right
    /// now."), or nil.
    var busy: String?
}

struct NearbyHoldingsReply: Codable {
    var kind = NearbyKind.holdingsReply.rawValue
    var rows: [NearbyHoldingsRow]
}

/// "Send me these files of this project." Each original lists the files
/// that can stand for it — a clip's encodings; the serving device sends the
/// first it holds. Blends by file name.
struct NearbyRequestFiles: Codable {
    var kind = NearbyKind.requestFiles.rawValue
    var originID: UUID
    var originals: [[String]]
    var blends: [String]
}

/// One file the serving device is about to send, with the SHA-256 its own
/// `assets.ndjson` recorded for it — the asker's own record wins where it
/// has one (plan N8).
struct NearbyFileEntry: Codable, Equatable {
    var relativePath: String
    var byteCount: Int64
    var sha256: String?
}

struct NearbyFilesReady: Codable {
    var kind = NearbyKind.filesReady.rawValue
    var originID: UUID
    var files: [NearbyFileEntry]

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.byteCount } }
}

struct NearbyFilesDone: Codable {
    var kind = NearbyKind.filesDone.rawValue
    var originID: UUID
}

/// What the asking device shows for a project: a device that holds all of
/// what is missing, and what to call it.
struct NearbyOffer: Equatable {
    /// The peer's Bonjour instance name — how the service finds it again.
    var peerID: String
    var deviceName: String
    var platform: String
}

enum NearbyCoding {
    /// Reads a control frame's `kind`.
    static func kind(of payload: Data) -> NearbyKind? {
        (try? PTCoder.decoder.decode(PTEnvelope.self, from: payload)).flatMap { NearbyKind(rawValue: $0.kind) }
    }
}

// A Watch is a remote, never a library, so nothing here belongs in the watch
// build — the same rule (and the same guard) as `CaptureRemoteListener`.
#if !os(watchOS)
import Foundation
import Network

/// Moving a whole project — 1 to 20 GB of DNGs, ProRes and notes — from the
/// device that shot it to the one that will finish it, over the local network,
/// with no `.lapse` written on either side.
///
/// Deliberately **not** an extension of `CaptureRemoteCoder`. That format is a
/// bare 4-byte length with nowhere to put a type discriminator, and its 1 MB
/// cap lives inside `decodeLength` where every existing reader depends on it.
/// This keeps the same *shape* — big-endian length prefix, JSON bodies — so
/// the two read alike, and adds the one byte that lets raw file bytes share
/// the socket with control messages.
///
/// ```
/// ┌────────┬──────────────┬───────────────┐
/// │ 1 byte │ 4 bytes BE   │ length bytes  │
/// │ type   │ payload len  │ payload       │
/// └────────┴──────────────┴───────────────┘
/// ```
enum ProjectTransferService {
    /// Distinct from `_letslapse-remote._tcp` on purpose: serving a library and
    /// driving a shutter are different grants with different lifetimes, and a
    /// client browsing for one must never find the other.
    ///
    /// Must also be listed in the `NSBonjourServices` **array** in
    /// `App/Info.plist`. That key cannot be an `INFOPLIST_KEY_*` build setting
    /// — Xcode's generator silently emits an empty value for arrays, and
    /// browsing then finds nothing with no error to explain why.
    static let type = "_letslapse-xfer._tcp"

    /// The protocol version both ends carry, so a mismatch is a sentence
    /// rather than a hang.
    static let version = 1

    /// Purpose-scoped pairing salt: a code minted for the camera remote cannot
    /// be replayed against the library, and vice versa.
    static let pairingSalt = "com.regularsteven.letslapse.transfer.v1"

    enum TXTKey {
        static let deviceName = "name"
        static let model = "model"
        static let pairingID = "pid"
        /// How many projects this device is offering, so a picker can say so
        /// before anybody types a code.
        static let projectCount = "n"
        static let version = "v"
    }
}

// MARK: - Framing

enum PTFrameType: UInt8 {
    /// JSON control message. `kind` names it; see the structs below.
    case control = 0x01
    /// Raw bytes of the file currently open. No JSON, no base64 — the whole
    /// point of a second frame type.
    case data = 0x02
    /// Client → server, valid at any time including mid-stream. Empty payload.
    case cancel = 0x03
}

struct PTFrame {
    var type: PTFrameType
    var payload: Data
}

enum PTCoderError: LocalizedError {
    case unknownFrameType(UInt8)
    case oversizedFrame(type: UInt8, bytes: Int)
    case shortHeader
    case unknownControlKind(String)

    var errorDescription: String? {
        switch self {
        case .unknownFrameType(let raw):
            return "Unknown transfer frame type \(raw)."
        case .oversizedFrame(let type, let bytes):
            return "Transfer frame of type \(type) is \(bytes) bytes, which is too large."
        case .shortHeader:
            return "Truncated transfer frame header."
        case .unknownControlKind(let kind):
            return "Unknown transfer message “\(kind)”."
        }
    }
}

enum PTCoder {
    static let headerBytes = 5

    /// Control frames stay small, but a list reply carries one small JPEG per
    /// project — 40 projects of ~40 KB base64 is comfortably inside this and
    /// nowhere near a data chunk.
    static let maxControlBytes = 8 << 20
    /// Sized for the send pump, not for a limit anybody should hit: the server
    /// reads a file in chunks of at most this and each one is a frame.
    static let maxDataBytes = 16 << 20
    /// What the server actually reads per chunk. Smaller than the cap so a
    /// cancel latch is checked often enough to feel immediate.
    static let chunkBytes = 4 << 20

    /// How far ahead of the client's acknowledgement the server may run.
    ///
    /// **This, not the send completion, is the backpressure.** The obvious
    /// design — a semaphore signalled from `NWConnection.send`'s
    /// `.contentProcessed` — does not work: that completion fires when the
    /// framework has TAKEN the bytes, not when they have drained, so
    /// Network.framework happily accepts a whole transfer into its own queue.
    /// Measured on an iPhone 16 Pro over USB (2026-08-27): the app's
    /// `phys_footprint` tracked bytes sent one for one — 4.00 GB sent, 4097 MB
    /// resident — until memory warnings arrived and the system throttled the
    /// process from 41 MB/s to 0.2 MB/s. A simulator never shows this; the
    /// payloads are too small and the memory is the Mac's.
    ///
    /// 32 MB is about 0.8 s of buffer at the ~41 MB/s a cabled iPhone
    /// sustains, which is enough that the wire never starves waiting on an
    /// ack round trip, and small enough to be irrelevant to a phone's memory.
    static let ackWindowBytes: Int64 = 32 << 20
    /// The client acks at least this often, so the window is refreshed in
    /// quarters rather than all at once.
    static let ackIntervalBytes: Int64 = 8 << 20

    static func cap(for type: PTFrameType) -> Int {
        switch type {
        case .control: return maxControlBytes
        case .data: return maxDataBytes
        case .cancel: return 0
        }
    }

    static func frame(_ type: PTFrameType, payload: Data) throws -> Data {
        guard payload.count <= cap(for: type) else {
            throw PTCoderError.oversizedFrame(type: type.rawValue, bytes: payload.count)
        }
        var out = Data(capacity: headerBytes + payload.count)
        out.append(type.rawValue)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// A JSON control frame, ready to hand to `NWConnection.send`.
    static func control<Message: Encodable>(_ message: Message) throws -> Data {
        try frame(.control, payload: encoder.encode(message))
    }

    static func cancelFrame() -> Data {
        // Cannot throw: an empty payload is inside every cap.
        (try? frame(.cancel, payload: Data())) ?? Data([PTFrameType.cancel.rawValue, 0, 0, 0, 0])
    }

    /// Type and payload length off a 5-byte header.
    static func decodeHeader(_ header: Data) throws -> (type: PTFrameType, length: Int) {
        guard header.count == headerBytes else { throw PTCoderError.shortHeader }
        let raw = header[header.startIndex]
        guard let type = PTFrameType(rawValue: raw) else {
            throw PTCoderError.unknownFrameType(raw)
        }
        let length = Int(header.dropFirst().withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self).bigEndian
        })
        guard length >= 0, length <= cap(for: type) else {
            throw PTCoderError.oversizedFrame(type: raw, bytes: length)
        }
        return (type, length)
    }

    /// ISO-8601 dates on both ends: `ProjectArchiveManifest` is written that
    /// way and a project's `createdAt` has to survive the trip unchanged.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - Control vocabulary

/// Every control message names itself. Read off the envelope first, then the
/// concrete type is decoded from the same bytes — so an unrecognised kind is a
/// sentence rather than a decode failure with no explanation in it.
enum PTKind: String, Codable {
    // Client → server
    case listProjects
    case requestTransfer
    case cancel
    /// One project's picker tile, asked for only when its row is on screen.
    case requestThumbnail
    /// "I have written this many payload bytes." The flow-control signal —
    /// see `PTCoder.ackWindowBytes` for why the transport cannot provide one.
    case ack
    // Server → client
    case listReply
    case transferReady
    case fileBegin
    case transferDone
    case thumbnail
    case error
}

/// The one field every control message has. Decoded on its own so the reader
/// can dispatch before it knows the shape of the body.
struct PTEnvelope: Codable {
    var kind: String

    var messageKind: PTKind? { PTKind(rawValue: kind) }
}

// Client → server

struct PTListRequest: Codable {
    var kind = PTKind.listProjects.rawValue
}

struct PTTransferRequest: Codable {
    var kind = PTKind.requestTransfer.rawValue
    var captureID: UUID
}

struct PTCancelRequest: Codable {
    var kind = PTKind.cancel.rawValue
}

/// Cumulative payload bytes the client has written to disk. Cumulative rather
/// than incremental so a dropped or reordered ack costs nothing — the server
/// only ever compares it against how far ahead it has run.
struct PTAck: Codable {
    var kind = PTKind.ack.rawValue
    var bytesReceived: Int64
}

/// "Draw me this row." Sent only for rows the human can actually see.
struct PTThumbnailRequest: Codable {
    var kind = PTKind.requestThumbnail.rawValue
    var captureID: UUID
}

// Server → client

/// One row in the client's picker. Everything here is cheap to produce except
/// `totalBytes`, which walks a directory tree — so the server sizes once per
/// arm and caches.
struct PTProjectInfo: Codable, Identifiable, Equatable {
    var captureID: UUID
    var name: String?
    var createdAt: Date
    var frameCount: Int
    /// Uncompressed, which is also exactly what will cross the wire: there is
    /// no compression on the payload path, so for once the progress bar's
    /// denominator is the truth rather than an estimate.
    var totalBytes: Int64
    var id: UUID { captureID }
}

/// Metadata only — **no images**.
///
/// They used to ride along, and on a real library that was the wrong trade
/// twice over: the whole catalogue travels in ONE control frame, so images had
/// to share a budget; and the serving device only has a cached tile for assets
/// a grid has actually drawn, so most rows arrived blank anyway (measured on a
/// 293-project phone: 62 of 293). Tiles are now fetched per visible row with
/// `requestThumbnail`, which is both cheaper for a big library and the only way
/// a row that was never cached can ever be drawn.
struct PTListReply: Codable {
    var kind = PTKind.listReply.rawValue
    var projects: [PTProjectInfo]
}

/// One file in the job, named relative to the project folder. `project.json`
/// is the first entry and is generated in memory — it never exists on the
/// serving device's disk.
struct PTFileEntry: Codable, Equatable {
    var relativePath: String
    var byteCount: Int64
}

/// The whole shape of the job, before a payload byte moves.
struct PTTransferReady: Codable {
    var kind = PTKind.transferReady.rawValue
    var captureID: UUID
    var files: [PTFileEntry]

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.byteCount } }
}

/// Announces the file whose data frames follow. The client opens `<path>.part`
/// on this and renames it on the next `fileBegin` or on `transferDone` — the
/// rename is the commit, so a truncated file is never mistaken for a whole one.
struct PTFileBegin: Codable {
    var kind = PTKind.fileBegin.rawValue
    var file: PTFileEntry
}

struct PTTransferDone: Codable {
    var kind = PTKind.transferDone.rawValue
    var captureID: UUID
}

/// A picker tile. `data` is nil when the serving device has nothing to draw and
/// could not make one — a project whose source files have gone, say. The client
/// keeps the placeholder and does not ask again.
struct PTThumbnailReply: Codable {
    var kind = PTKind.thumbnail.rawValue
    var captureID: UUID
    var data: Data?
}

struct PTError: Codable, Error {
    var kind = PTKind.error.rawValue
    var code: String
    var message: String

    enum Code {
        static let busy = "busy"
        static let notFound = "notFound"
        static let cancelled = "cancelled"
        static let storageFull = "storageFull"
        static let readFailed = "readFailed"
        static let unsupported = "unsupported"
    }

    static func busy(_ message: String) -> PTError {
        PTError(code: Code.busy, message: message)
    }

    static func notFound() -> PTError {
        PTError(code: Code.notFound, message: "That project is no longer on the other device.")
    }
}

// MARK: - Reading frames off a connection

/// The receive half, shared by both ends.
///
/// Callback-based and `nonisolated` on purpose: `NWConnection`'s completions
/// arrive on its own queue, and a 16 GB transfer must not hop to the main
/// actor once per chunk. Callers marshal what they need to.
enum PTFrameReader {
    enum ReadError: LocalizedError {
        case closed
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .closed: return "The other device closed the connection."
            case .transport(let message): return message
            }
        }
    }

    /// Reads exactly one frame. Never re-arms itself — the caller decides
    /// whether to keep reading, which is what lets a receive loop stop
    /// cleanly mid-stream.
    static func receive(
        on connection: NWConnection,
        completion: @escaping @Sendable (Result<PTFrame, Error>) -> Void
    ) {
        connection.receive(
            minimumIncompleteLength: PTCoder.headerBytes,
            maximumLength: PTCoder.headerBytes
        ) { header, _, isComplete, error in
            if let error {
                completion(.failure(ReadError.transport(error.localizedDescription)))
                return
            }
            guard let header, header.count == PTCoder.headerBytes else {
                completion(.failure(isComplete ? ReadError.closed : ReadError.transport("Short read")))
                return
            }
            let decoded: (type: PTFrameType, length: Int)
            do {
                decoded = try PTCoder.decodeHeader(header)
            } catch {
                completion(.failure(error))
                return
            }
            // A zero-length payload is legal (cancel), and asking
            // `NWConnection` for zero bytes is not — it never completes.
            guard decoded.length > 0 else {
                completion(.success(PTFrame(type: decoded.type, payload: Data())))
                return
            }
            connection.receive(
                minimumIncompleteLength: decoded.length,
                maximumLength: decoded.length
            ) { body, _, isComplete, error in
                if let error {
                    completion(.failure(ReadError.transport(error.localizedDescription)))
                    return
                }
                guard let body, body.count == decoded.length else {
                    completion(.failure(isComplete ? ReadError.closed : ReadError.transport("Short read")))
                    return
                }
                completion(.success(PTFrame(type: decoded.type, payload: body)))
            }
        }
    }
}
#endif

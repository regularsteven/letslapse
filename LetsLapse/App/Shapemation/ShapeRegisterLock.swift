import Foundation
import LetsLapseKit

// Why a project's `shapes.json` is read-only for this build (WP0b, gap map
// 2026-09-19). The file travels byte-for-byte between devices on PicPlace,
// .lapse and device transfer, and the devices do not all run the same build:
// an older build that rewrote a register it could not fully read would strip
// the newer build's shapes, and the stripped file would sync back. So every
// writer — the Masks tab's shape tools, Find shapes, the found-shape clear —
// asks `ShapeRegister.read` first and stands down on either answer here.
// Never edit-and-lose: a locked project keeps its file exactly as it came.
//
// The explanatory chip that tells the person WHY the tools stood down is a
// later design-first pass; until then the lock only disables what it must
// (the ＋ Shape menu, the drags, the writers) and says so in the log.

/// The two answers from `ShapeRegister.read` that forbid a write.
enum ShapeRegisterLock: Equatable, Sendable {
    /// Written by a build whose `formatVersion` is above ours.
    case tooNew(version: Int)
    /// A file at our version that would not decode.
    case unreadable(String)

    /// Nil for `.none` and `.register` — the outcomes a writer may follow with a save.
    init?(_ outcome: ShapeRegister.ReadOutcome) {
        switch outcome {
        case .none, .register: return nil
        case .tooNew(let version): self = .tooNew(version: version)
        case .unreadable(let why): self = .unreadable(why)
        }
    }

    /// The lock `save` raised at the write: the file changed under a writer
    /// that had read it (a PicPlace pull mid-edit). Nil for any other error.
    init?(_ error: Error) {
        switch error as? ShapeRegister.WriteRefused {
        case .tooNew(let version)?: self = .tooNew(version: version)
        case .unreadable(let why)?: self = .unreadable(why)
        case nil: return nil
        }
    }

    /// What the chip will say, when it exists.
    var message: String {
        switch self {
        case .tooNew: return "Shapes written by a newer LetsLapse"
        case .unreadable: return "Shapes couldn't be read"
        }
    }

    /// The short state for a list row.
    var rowState: String {
        switch self {
        case .tooNew: return "newer LetsLapse"
        case .unreadable: return "unreadable"
        }
    }

    /// The log line, one per project a writer passed over.
    func logLine(for title: String) -> String {
        switch self {
        case .tooNew(let version):
            return "shapes: \(title) written by a newer LetsLapse (version \(version)) — left as it is"
        case .unreadable(let why):
            return "shapes: \(title)'s register could not be read — left as it is (\(why))"
        }
    }
}

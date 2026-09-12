import Foundation

/// The rule a serial writer applies to the snapshots queued for it: a
/// snapshot lands only when its version is above the last one written.
///
/// Why: the library manifest used to have two writers — a synchronous one
/// on the main actor and a queued one on a utility queue — with no ordering
/// between them, so a queued OLDER snapshot could land after a newer
/// synchronous write and put a deleted blend back on disk (Part 1 R3).
/// With one queue and this gate, a snapshot minted earlier than one already
/// on disk is dropped, whichever order the queue happens to see them in.
///
/// Pure and small so it can be tested without a disk: `VersionGateTests`.
public struct VersionGate: Equatable, Sendable {

    /// The version of the newest snapshot written so far; 0 before any.
    public private(set) var lastWritten: Int = 0

    public init() {}

    /// True — and records it — when `version` is newer than anything written.
    /// Equal is dropped too: the same snapshot never needs writing twice.
    public mutating func admit(_ version: Int) -> Bool {
        guard version > lastWritten else { return false }
        lastWritten = version
        return true
    }
}

/// Mints the monotonically increasing versions a `VersionGate` compares.
/// One per writer, owned by whoever snapshots (the main actor, for the
/// library).
public struct VersionCounter: Sendable {
    private var next = 0
    public init() {}
    public mutating func mint() -> Int {
        next += 1
        return next
    }
}

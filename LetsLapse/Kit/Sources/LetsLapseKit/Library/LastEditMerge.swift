import Foundation

/// Two copies of a set of documents — this device's and PicPlace's — merged
/// one document at a time: the side whose last change is later wins, a
/// deletion (a tombstone) being a change like any other (connected asset
/// states D3, 2026-09-25: a library's collections travel between devices).
///
/// Pure: the caller hands over each document's identity, last edit and
/// tombstone; the answer is which side each identity takes, and whether the
/// merged set differs from either side — what has to be written here, and
/// what has to go back up.
public enum LastEditMerge {

    /// One document's identity and the two moments that matter.
    public struct Stamp<ID: Hashable>: Equatable {
        public var id: ID
        public var modifiedAt: Date?
        public var deletedAt: Date?

        public init(id: ID, modifiedAt: Date?, deletedAt: Date?) {
            self.id = id
            self.modifiedAt = modifiedAt
            self.deletedAt = deletedAt
        }

        /// The document's last change: an edit or its deletion, whichever
        /// came later. A document that was never stamped counts as oldest.
        var lastChange: Date {
            max(modifiedAt ?? .distantPast, deletedAt ?? .distantPast)
        }
    }

    public enum Side: Equatable {
        case local
        case remote
    }

    public struct Outcome<ID: Hashable>: Equatable {
        /// Which side each identity takes.
        public var choices: [ID: Side]
        /// The merged set differs from this device's: write it here.
        public var localChanged: Bool
        /// The merged set differs from PicPlace's: send it up.
        public var remoteChanged: Bool
    }

    /// Merges `local` and `remote`. A document on one side only is kept
    /// from that side (new there, or never seen by the other). A document
    /// on both goes to the later change — an edit after a deletion brings it
    /// back — and to PicPlace's copy on a tie, so two devices settle on one
    /// answer. `equal` says whether two copies of one document already agree
    /// (then nothing is sent or written for it).
    public static func merge<ID: Hashable>(
        local: [Stamp<ID>],
        remote: [Stamp<ID>],
        equal: (ID) -> Bool
    ) -> Outcome<ID> {
        var choices: [ID: Side] = [:]
        var localChanged = false
        var remoteChanged = false
        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localIDs = Set(local.map(\.id))
        for mine in local {
            guard let theirs = remoteByID[mine.id] else {
                choices[mine.id] = .local
                remoteChanged = true
                continue
            }
            if equal(mine.id) {
                choices[mine.id] = .remote
                continue
            }
            if mine.lastChange > theirs.lastChange {
                choices[mine.id] = .local
                remoteChanged = true
            } else {
                choices[mine.id] = .remote
                localChanged = true
            }
        }
        for theirs in remote where !localIDs.contains(theirs.id) {
            choices[theirs.id] = .remote
            localChanged = true
        }
        return Outcome(choices: choices, localChanged: localChanged, remoteChanged: remoteChanged)
    }
}

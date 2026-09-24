import CryptoKit
import Foundation

/// Whether the heavy files a device holds for a project — its source media
/// and its blends — are on PicPlace, file by file: the one test every door
/// that lets a device forget them goes through (the project card's *Remove
/// originals* and *Remove blends*, Settings' *Remove originals already on
/// PicPlace*, a library's *Remove from this iPhone*).
///
/// A file passes only when the server lists an asset at the same path,
/// **confirmed**, at the **same size**, with the **same SHA-256**, and
/// **verified** — PicPlace has read its copy back and found those bytes.
/// Never on a count and never on a timestamp: until 2026-09-23 the card's
/// "Here and on PicPlace" was `serverHeavyFiles >= local` or "originals were
/// uploaded once", so a blend rendered after the upload read as on PicPlace
/// while it existed only here — and the library's Remove trusted the same
/// test.
///
/// Verified (2026-09-24, the PicPlace developer's answer to the free-up
/// asks): picplace.co's storage accepts a PUT whose bytes do not match the
/// signed checksum, so PicPlace reads every upload back, usually within a
/// minute or two of its confirm, and only then marks the asset `verified`.
/// Until then a confirmed asset is PicPlace's word, not yet proof.
/// (picplace.test's storage checks at the PUT, so its assets are verified
/// at confirm.)
///
/// Pure: the caller lists the folder, supplies the hashes it has (the
/// capture-time ones in `assets.ndjson` where the size still matches, else
/// computed) and the server's asset list from a fresh `GET /projects/{uuid}`.
public enum PicPlaceOriginalsCheck {

    /// Which half of the heavy set a file belongs to — `source/` media or
    /// `blends/` — the two things a person removes separately.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case source
        case blend
    }

    /// One heavy file on this device.
    public struct LocalFile: Equatable, Sendable {
        /// The path within the project folder — `source/frame-00042.dng`,
        /// `blends/<uuid>.mp4` — the name the server keys the asset by.
        public var name: String
        public var kind: Kind
        public var bytes: Int64
        /// Hex SHA-256 of the whole file, with or without the `sha256:`
        /// prefix; nil when it has not been hashed.
        public var sha256: String?

        public init(name: String, kind: Kind, bytes: Int64, sha256: String? = nil) {
            self.name = name
            self.kind = kind
            self.bytes = bytes
            self.sha256 = sha256
        }
    }

    /// One asset the server lists for the project.
    public struct RemoteAsset: Equatable, Sendable {
        public var name: String
        /// nil while pending — the server has not received the bytes.
        public var bytes: Int64?
        public var sha256: String?
        public var isConfirmed: Bool
        /// PicPlace has read its copy back and found the declared SHA-256
        /// (the asset's `verified`). False when a server does not say.
        public var isVerified: Bool

        public init(name: String, bytes: Int64?, sha256: String?, isConfirmed: Bool, isVerified: Bool = false) {
            self.name = name
            self.bytes = bytes
            self.sha256 = sha256
            self.isConfirmed = isConfirmed
            self.isVerified = isVerified
        }
    }

    /// Why a file is not safe to let go of.
    public enum Problem: String, Equatable, Sendable {
        /// PicPlace lists no asset at that path.
        case notOnPicPlace
        /// Negotiated, never confirmed — the upload did not finish.
        case notConfirmed
        /// PicPlace's copy is another size.
        case sizeDiffers
        /// Same size, different content.
        case contentDiffers
        /// This device has no hash for the file, so the content cannot be compared.
        case notHashed
        /// PicPlace holds the same bytes by its own account but has not yet
        /// read its copy back — "still checking", usually a minute or two
        /// after the upload. The one problem that goes away by waiting.
        case notVerified
    }

    public struct Finding: Equatable, Sendable {
        public var file: LocalFile
        public var problem: Problem

        public init(file: LocalFile, problem: Problem) {
            self.file = file
            self.problem = problem
        }
    }

    /// The answer for a set of local files.
    public struct Verdict: Equatable, Sendable {
        /// Files PicPlace holds byte for byte.
        public var verified: [LocalFile] = []
        /// Files it does not, and why.
        public var findings: [Finding] = []

        public init(verified: [LocalFile] = [], findings: [Finding] = []) {
            self.verified = verified
            self.findings = findings
        }

        /// True when every file checked is on PicPlace.
        public var passes: Bool { findings.isEmpty }

        /// True when nothing is missing or different and PicPlace is only
        /// still checking some of the files — no upload would help; waiting
        /// will.
        public var awaitsVerification: Bool {
            !findings.isEmpty && findings.allSatisfy { $0.problem == .notVerified }
        }

        /// Whether every file of `kind` is on PicPlace (true when there are none).
        public func passes(_ kind: Kind) -> Bool { !findings.contains { $0.file.kind == kind } }

        public func verified(_ kind: Kind) -> [LocalFile] { verified.filter { $0.kind == kind } }
        public func findings(_ kind: Kind) -> [Finding] { findings.filter { $0.file.kind == kind } }

        /// How many findings of each problem, for a caption.
        public func counts(of kind: Kind? = nil) -> [Problem: Int] {
            var counts: [Problem: Int] = [:]
            for finding in findings where kind == nil || finding.file.kind == kind {
                counts[finding.problem, default: 0] += 1
            }
            return counts
        }
    }

    /// The full test: every local file against the server's list.
    ///
    /// Several rows for one path (a v1 push, a re-negotiation) pass when any
    /// confirmed row matches; the problem reported is the closest miss.
    /// Server assets with no local file are not this test's business — a
    /// blend deleted here but kept there is PicPlace's to keep.
    public static func verify(_ local: [LocalFile], against remote: [RemoteAsset]) -> Verdict {
        let byName = Dictionary(grouping: remote, by: \.name)
        var verdict = Verdict()
        for file in local {
            guard let rows = byName[file.name], !rows.isEmpty else {
                verdict.findings.append(Finding(file: file, problem: .notOnPicPlace))
                continue
            }
            let confirmed = rows.filter(\.isConfirmed)
            guard !confirmed.isEmpty else {
                verdict.findings.append(Finding(file: file, problem: .notConfirmed))
                continue
            }
            let sized = confirmed.filter { $0.bytes == file.bytes }
            guard !sized.isEmpty else {
                verdict.findings.append(Finding(file: file, problem: .sizeDiffers))
                continue
            }
            guard let localHash = normalized(file.sha256) else {
                verdict.findings.append(Finding(file: file, problem: .notHashed))
                continue
            }
            let matching = sized.filter { normalized($0.sha256) == localHash }
            if matching.contains(where: \.isVerified) {
                verdict.verified.append(file)
            } else if !matching.isEmpty {
                verdict.findings.append(Finding(file: file, problem: .notVerified))
            } else {
                verdict.findings.append(Finding(file: file, problem: .contentDiffers))
            }
        }
        return verdict
    }

    /// The cheap test, for a label: the local files PicPlace does NOT list
    /// at the same path and size as a confirmed asset. Hashes are the full
    /// test's; a label only has to be honest about what is missing.
    ///
    /// `verifiedOnly` counts only assets PicPlace has read back — what the
    /// set's marker (`heavyDigest`) and the space estimate need, since the
    /// marker is what a library's *Remove from this iPhone* trusts.
    public static func notCovered(_ local: [LocalFile], by remote: [RemoteAsset], verifiedOnly: Bool = false) -> [LocalFile] {
        var confirmed: [String: Set<Int64>] = [:]
        for asset in remote where asset.isConfirmed && (asset.isVerified || !verifiedOnly) {
            if let bytes = asset.bytes { confirmed[asset.name, default: []].insert(bytes) }
        }
        return local.filter { !(confirmed[$0.name]?.contains($0.bytes) ?? false) }
    }

    /// A marker for a heavy set — SHA-256 over its `name<TAB>bytes` lines,
    /// sorted — stored when the set was last seen confirmed AND verified on
    /// PicPlace (`notCovered(verifiedOnly: true)`), so a
    /// later look can tell "the same files" from "something was added,
    /// removed or rewritten" without asking the server. Order-free; hashes
    /// are not part of it (the full test re-reads them before anything is
    /// removed).
    public static func digest(_ files: [LocalFile]) -> String {
        let lines = files.map { "\($0.name)\t\($0.bytes)" }.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(lines.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Of the files that differ from PicPlace's copies, the ones PicPlace
    /// provably holds as they were first recorded: its confirmed copy's
    /// SHA-256 equals the hash `assets.ndjson` recorded at capture (or
    /// import), and this device's file no longer does. Only those may be
    /// replaced by a download — when PicPlace's copy is the odd one out,
    /// replacing this device's would throw the original away.
    public static func replaceable(_ names: [String], recorded: [String: String],
                                   current: [String: String], remote: [RemoteAsset]) -> [String] {
        let confirmed = Dictionary(grouping: remote.filter(\.isConfirmed), by: \.name)
        return names.filter { name in
            guard let original = normalized(recorded[name]) else { return false }
            if let here = normalized(current[name]), here == original { return false }
            return confirmed[name]?.contains { normalized($0.sha256) == original } ?? false
        }
    }

    /// `sha256:` stripped, lowercased; nil for nothing usable.
    public static func normalized(_ hash: String?) -> String? {
        guard var hash, !hash.isEmpty else { return nil }
        if hash.hasPrefix(AssetHash.prefix) { hash.removeFirst(AssetHash.prefix.count) }
        hash = hash.lowercased()
        return hash.count == 64 && hash.allSatisfy(\.isHexDigit) ? hash : nil
    }
}

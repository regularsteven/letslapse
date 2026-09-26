import Foundation

/// What one device holds of a project — its originals, each of its blends,
/// and the preview that stands in for both (docs/connected-asset-states-plan.md
/// §3.1). The one answer every control that needs a file reads: the editor's
/// groups, New blended clip, a blend row's play, a collection member, an
/// export — and the prompt that offers to fetch what is missing, with its
/// size.
///
/// Pure: the caller walks the project folder once (relative path → bytes),
/// lists what the project says it is made of, and hands over the sizes
/// `assets.ndjson` recorded, so a file that is not here still has a size.
public struct ProjectHoldings: Equatable, Sendable {

    /// One original the project lists — a frame, a photo, a movie clip. A
    /// clip converted to another codec has several files (its encodings);
    /// any one of them makes the clip here, as it does for playback.
    public struct Original: Equatable, Sendable {
        /// The logical name, project-relative (`source/frame-0042.dng`).
        public var name: String
        /// The files that can stand for it — `[name]` for a frame, every
        /// encoding for a clip.
        public var files: [String]
        public var isHere: Bool
        /// What bringing it back costs: the recorded sizes of its files
        /// that are not here. nil when a size was never recorded.
        public var missingBytes: Int64?
    }

    /// One blend's file (`blends/<id>.<ext>`).
    public struct Blend: Equatable, Sendable {
        public var id: UUID
        public var fileName: String
        public var isHere: Bool
        /// The recorded size, else the file's own when it is here.
        public var bytes: Int64?
    }

    /// What the brief calls a device's tier, as a person reads it.
    public enum Tier: String, Sendable, CaseIterable {
        /// Pixel edits and new blends can happen here.
        case originals
        /// The originals are elsewhere; at least one blend's file is here.
        case blends
        /// Only the records and the preview.
        case preview
    }

    /// What a capability needs from this device.
    public struct Need: Hashable, Sendable {
        public var originals: Bool
        public var blendIDs: Set<UUID>

        public init(originals: Bool = false, blendIDs: Set<UUID> = []) {
            self.originals = originals
            self.blendIDs = blendIDs
        }

        public static let nothing = Need()
        public static let originals = Need(originals: true)
        public static func blends(_ ids: Set<UUID>) -> Need { Need(blendIDs: ids) }

        public func union(_ other: Need) -> Need {
            Need(originals: originals || other.originals, blendIDs: blendIDs.union(other.blendIDs))
        }
    }

    /// What is missing for a need: the originals and blends not here, how
    /// many files, and what they weigh.
    public struct Shortfall: Equatable, Sendable {
        /// Originals not here (by logical name), in the project's order.
        public var originals: [String]
        public var originalsTotal: Int
        /// Blends whose file is not here.
        public var blendIDs: [UUID]
        /// The files a download would bring, project-relative.
        public var fileNames: [String]
        /// The recorded bytes of those files — a floor when `bytesAreComplete`
        /// is false (some sizes were never recorded).
        public var bytes: Int64
        public var bytesAreComplete: Bool

        public var needsOriginals: Bool { !originals.isEmpty }
        public var needsBlends: Bool { !blendIDs.isEmpty }
        /// True when some originals are here and some are not — a download
        /// that stopped part way, say.
        public var isPartial: Bool { needsOriginals && originals.count < originalsTotal }
    }

    public var originals: [Original]
    public var blends: [Blend]
    /// A Photo capture is edited on its picture — its stack when it has one
    /// (a JPEG burst), else the photo itself. Nil for every other project.
    public var pictureBlendID: UUID?
    /// `poster.jpg` is here.
    public var hasPreview: Bool
    /// The fingerprint of the heavy files on this device — every source
    /// file and blend, by path and size — the way PicPlace's backed-up
    /// marker is (`PicPlaceOriginalsCheck.digest`; the digest of nothing
    /// when nothing heavy is here). Set by the app, which knows which files
    /// are heavy; nil when not computed.
    public var localHeavyDigest: String?
    /// How many heavy files are here.
    public var localHeavyFiles = 0
    /// The same fingerprint over the blends alone — what PicPlace's
    /// blends marker (`blendsDigest`) is compared with.
    public var localBlendsDigest: String?

    public init(originals: [Original], blends: [Blend], pictureBlendID: UUID?, hasPreview: Bool) {
        self.originals = originals
        self.blends = blends
        self.pictureBlendID = pictureBlendID
        self.hasPreview = hasPreview
    }

    /// Builds the answer from what the project lists and what the folder
    /// holds.
    ///
    /// - Parameters:
    ///   - originals: each logical original with the files that can stand
    ///     for it (a clip's encodings; a frame's own name).
    ///   - blends: each live blend's id and file.
    ///   - pictureBlendID: a Photo capture's stack, when it has one.
    ///   - present: the folder's files, project-relative path → bytes.
    ///   - recordedBytes: `assets.ndjson`'s sizes by name.
    ///   - hasPreview: `poster.jpg` is here.
    public init(originals: [(name: String, files: [String])],
                blends: [(id: UUID, fileName: String)],
                pictureBlendID: UUID?,
                present: [String: Int64],
                recordedBytes: [String: Int64],
                hasPreview: Bool) {
        self.originals = originals.map { original in
            let files = original.files.isEmpty ? [original.name] : original.files
            let isHere = files.contains { present[$0] != nil }
            var missing: Int64? = 0
            if !isHere {
                // Every encoding PicPlace may hold comes back; a clip whose
                // sizes were never recorded is priced by its logical name.
                let sizes = files.map { recordedBytes[$0] }
                if sizes.contains(where: { $0 != nil }) {
                    missing = sizes.compactMap { $0 }.reduce(0, +)
                } else {
                    missing = recordedBytes[original.name]
                }
            }
            return Original(name: original.name, files: files, isHere: isHere, missingBytes: missing)
        }
        self.blends = blends.map { blend in
            let here = present[blend.fileName]
            return Blend(id: blend.id, fileName: blend.fileName, isHere: here != nil,
                         bytes: recordedBytes[blend.fileName] ?? here)
        }
        self.pictureBlendID = pictureBlendID
        self.hasPreview = hasPreview
    }

    // MARK: - Reading

    public var originalsHere: Int { originals.filter(\.isHere).count }

    /// Every original is here — vacuously true for a project that lists
    /// none, which is what `sourcesMissing` has always said of it.
    public var hasAllOriginals: Bool { originals.allSatisfy(\.isHere) }

    public func blend(_ id: UUID) -> Blend? { blends.first { $0.id == id } }

    public func hasBlend(_ id: UUID) -> Bool { blend(id)?.isHere ?? false }

    public var blendsHere: Int { blends.filter(\.isHere).count }

    /// The blends here other than a Photo capture's picture — which is
    /// its original, not one of its blends.
    public var otherBlendsHere: Int { blends.filter { $0.isHere && $0.id != pictureBlendID }.count }

    /// What a pixel edit needs: a Photo capture's picture, every original
    /// otherwise.
    public var pictureNeed: Need {
        pictureBlendID.map { Need.blends([$0]) } ?? .originals
    }

    public var tier: Tier {
        if shortfall(for: pictureNeed) == nil { return .originals }
        if blends.contains(where: \.isHere) { return .blends }
        return .preview
    }

    /// What is missing for `need`, or nil when everything it needs is here.
    /// A blend the project no longer lists is not waited for.
    public func shortfall(for need: Need) -> Shortfall? {
        let missingOriginals = need.originals ? originals.filter { !$0.isHere } : []
        let missingBlends = blends.filter { need.blendIDs.contains($0.id) && !$0.isHere }
        guard !missingOriginals.isEmpty || !missingBlends.isEmpty else { return nil }

        var files: [String] = []
        var bytes: Int64 = 0
        var complete = true
        for original in missingOriginals {
            files.append(contentsOf: original.files)
            if let size = original.missingBytes { bytes += size } else { complete = false }
        }
        for blend in missingBlends {
            files.append(blend.fileName)
            if let size = blend.bytes { bytes += size } else { complete = false }
        }
        return Shortfall(
            originals: missingOriginals.map(\.name),
            originalsTotal: originals.count,
            blendIDs: missingBlends.map(\.id),
            fileNames: files,
            bytes: bytes,
            bytesAreComplete: complete)
    }
}

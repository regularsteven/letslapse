import Foundation

/// The one table of every file a project folder can hold beside its media —
/// what it is, where it sits, whether it is a fact the run wrote or a decision
/// a person made, and whether it travels with the project.
///
/// Why one table: a per-project file has to be known to five different lists
/// (the archive's transferable set, the registration copy list, the DNG-clone
/// copy list, the storage card and the audit), and until 2026-09-12 each list
/// knew its own subset — `dng-archive.json` was in none of the first three and
/// was lost on every import (docs/data-model-audit-2026-09-06.md §4.3). A file
/// that is not registered here is a file some path will drop.
///
/// `ProjectArchive.transferableFiles` and `.transferableSubfolders` in the app
/// are derived from this table; the audit's sidecar-presence report walks it.
public struct ProjectFile: Equatable, Sendable {

    /// Where the file sits inside `Projects/<id>/`.
    public enum Location: String, Sendable {
        /// Beside the media, in `source/` — the rule is "capture-time records
        /// in `source/`, edit-time records at the root" (Part 1 §6.3).
        case source
        /// At the project root.
        case root
    }

    /// What kind of record it is — the class decides whether it syncs and
    /// whether it needs change tracking (Part 3 §2).
    public enum Class: String, Sendable {
        /// Written once by the run; immutable afterwards.
        case captureFact
        /// A person's decisions; revisioned.
        case edit
        /// Rebuildable from an edit plus the originals.
        case derived
    }

    /// The name inside its location. A directory carries a trailing slash.
    public let name: String
    public let location: Location
    public let `class`: Class
    /// True when the item is a folder rather than a file.
    public let isDirectory: Bool
    /// True when a `.lapse` archive and a network transfer carry it. Everything
    /// under `source/` travels because the folder travels whole; a root item
    /// travels only if it is listed.
    public let travels: Bool
    /// True when the file is appended to on the capture hot path (NDJSON,
    /// line at a time) rather than written at finalise.
    public let isHotPath: Bool

    public init(
        _ name: String, at location: Location, class kind: Class,
        isDirectory: Bool = false, travels: Bool, isHotPath: Bool = false
    ) {
        self.name = name
        self.location = location
        self.class = kind
        self.isDirectory = isDirectory
        self.travels = travels
        self.isHotPath = isHotPath
    }

    /// True for an entry whose `name` holds one `*` — a family of files the
    /// run writes with a number or a stamp in the name (`frame-*.json`).
    /// Patterns classify files (`matches`, `entry(forRelativePath:)`); they
    /// are not audited for presence and name no single file to copy.
    public var isPattern: Bool { name.contains("*") }

    /// Whether `fileName` (no directory part) is this entry: equal for a
    /// plain entry, prefix + suffix around the one `*` for a pattern.
    public func matches(fileName: String) -> Bool {
        guard isPattern else { return fileName == name }
        let parts = name.split(separator: "*", maxSplits: 1, omittingEmptySubsequences: false)
        let prefix = String(parts[0]), suffix = parts.count > 1 ? String(parts[1]) : ""
        return fileName.count >= prefix.count + suffix.count && fileName.hasPrefix(prefix) && fileName.hasSuffix(suffix)
    }

    /// The path relative to the project folder.
    public var relativePath: String {
        switch location {
        case .source: return "source/\(name)"
        case .root: return name
        }
    }
}

public enum ProjectFileRegistry {

    /// The per-asset record file — one line per source frame and blend
    /// output: name, bytes, whole-file hash, and (since Milestone 1 of the
    /// data-model work) the `imported` and `edited` metadata layers.
    public static let assetRecordsName = "assets.ndjson"

    /// The project-level metadata record (`{schemaVersion, project:
    /// {imported, edited}}`) — the record the Gallery panel edits for a whole
    /// interval shoot, and the one a Photo project's panel edits outright.
    public static let projectMetadataName = "metadata.json"

    /// The project's own record — `{formatVersion, capture, blends}` — the
    /// document that will be the truth once `library.json` becomes an index
    /// (data model Phase 2; `ProjectDocumentFormat`). It travels FIRST in an
    /// archive and a transfer, and the installer reads and re-keys it rather
    /// than moving it into place, which is why `travellingRootFiles` leaves
    /// it out.
    public static let projectDocumentName = "project.json"

    /// `poster.jpg` — the project's graded poster frame (v2 plan §3.5).
    public static let posterName = "poster.jpg"

    /// `scene-analysis.json` — what the on-device vision pass said about the
    /// project's thumbnail frame (`SceneAnalysisRecord`): Auto rename & tag's
    /// cached Stage A, keyed by the frame it looked at, so the second run —
    /// a tag today, a name next month — costs no second pass.
    public static let sceneAnalysisName = "scene-analysis.json"

    public static let all: [ProjectFile] = [
        // Capture-time records, beside the media.
        ProjectFile("frames.timestamps", at: .source, class: .captureFact, travels: true, isHotPath: true),
        ProjectFile("frames.exposure", at: .source, class: .captureFact, travels: true, isHotPath: true),
        ProjectFile("capture_log.json", at: .source, class: .captureFact, travels: true),
        ProjectFile("sequence.json", at: .source, class: .captureFact, travels: true),
        // The ramp engine's legacy experiment document, named for the last
        // frame (`frame-05661.json`, up to 8 MB), and the live-blend logs —
        // written once at finish; carried by the PicPlace records bundle
        // (v2 plan §3.4) like the other capture sidecars.
        ProjectFile("frame-*.json", at: .source, class: .captureFact, travels: true),
        ProjectFile("liveblend-*.json", at: .source, class: .captureFact, travels: true),
        // Derived measurements beside the media. `framing.json` also carries
        // the `stabilisation` block, which is user intent.
        ProjectFile("framing.json", at: .source, class: .derived, travels: true),
        ProjectFile("frames.whitebalance", at: .source, class: .derived, travels: true),
        ProjectFile("documents.json", at: .source, class: .edit, travels: true),
        // Edit-time records at the root.
        ProjectFile("overlays.json", at: .root, class: .edit, travels: true),
        ProjectFile("shapes.json", at: .root, class: .edit, travels: true),
        ProjectFile(assetRecordsName, at: .root, class: .edit, travels: true),
        ProjectFile(projectMetadataName, at: .root, class: .edit, travels: true),
        ProjectFile(projectDocumentName, at: .root, class: .edit, travels: true),
        // The project's graded poster frame (~1280 px JPEG), rendered by the
        // device that pushes the project to PicPlace (v2 plan §3.5) and the
        // tile a fresh device shows before the sources are on it. Derived:
        // any device holding the sources can render it again.
        ProjectFile(posterName, at: .root, class: .derived, travels: true),
        // The vision pass's record. Derived — any device holding the frame
        // can run the model again — but it is the expensive kind of derived,
        // so it travels: a shoot analysed once is analysed for every copy.
        ProjectFile(sceneAnalysisName, at: .root, class: .derived, travels: true),
        ProjectFile("notes/", at: .root, class: .edit, isDirectory: true, travels: true),
        ProjectFile("masks/", at: .root, class: .edit, isDirectory: true, travels: true),
        ProjectFile("fonts/", at: .root, class: .edit, isDirectory: true, travels: true),
        // `luts/` — the library's cubes, materialised into the folder only
        // for an export or a transfer (docs/lut-library-assets.md §2.3), and
        // the legacy per-project copies from before 2026-09-18. Derived,
        // since the library store holds the bytes, and NOT travelling: a
        // sync classifies a copy as skipped, the installer never moves the
        // folder into a project (it folds the cubes into the store), and
        // the archive and the transfer carry it explicitly for the trip.
        ProjectFile("luts/", at: .root, class: .derived, isDirectory: true, travels: false),
        // The DNG-archive ledger: the only cross-project provenance link a
        // clone keeps. Not carried by an archive or a transfer today (the
        // manifest's `derivedFromOriginID` is what will travel instead).
        ProjectFile("dng-archive.json", at: .root, class: .captureFact, travels: false),
        // Renders.
        ProjectFile("blends/", at: .root, class: .derived, isDirectory: true, travels: true),
        ProjectFile("source/", at: .root, class: .captureFact, isDirectory: true, travels: true),
    ]

    /// The root-level FILES an archive and a transfer carry as files — what
    /// `ProjectArchive.transferableFiles` reads. The project document is not
    /// among them although it travels: it is the manifest the far side
    /// installs FROM (read, re-keyed, then written afresh by the first
    /// persist), never a file moved into place as it arrived.
    public static var travellingRootFiles: [String] {
        all.filter { $0.location == .root && !$0.isDirectory && $0.travels && $0.name != projectDocumentName }
            .map(\.name)
    }

    /// The subfolders an archive and a transfer carry — what
    /// `ProjectArchive.transferableSubfolders` reads. `source` first, then
    /// `blends`: the two the installer and the clone treat specially.
    public static var travellingSubfolders: [String] {
        all.filter { $0.location == .root && $0.isDirectory && $0.travels }
            .map { String($0.name.dropLast()) }
    }

    /// The sidecars the audit reports presence for, per project — every
    /// registered file that is not a media folder and names one file.
    public static var auditedSidecars: [ProjectFile] {
        all.filter { !($0.isDirectory && ["source/", "blends/", "masks/", "fonts/", "luts/"].contains($0.name)) && !$0.isPattern }
    }

    /// The entry that governs a file at `relativePath` inside a project
    /// folder: an exact root name or pattern; a `source/` sidecar's own
    /// entry; otherwise the folder entry the path sits under — `masks/sky.png`
    /// → `masks/`, and a media frame or anything deeper under `source/` →
    /// `source/` itself, a render → `blends/`. nil for a stray: a root file
    /// or a folder the table does not know.
    public static func entry(forRelativePath relativePath: String) -> ProjectFile? {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, !first.isEmpty else { return nil }
        if parts.count == 1 {
            return all.first { $0.location == .root && !$0.isDirectory && $0.matches(fileName: first) }
        }
        if first == "source", parts.count == 2,
           let sidecar = all.first(where: { $0.location == .source && $0.matches(fileName: parts[1]) }) {
            return sidecar
        }
        return all.first { $0.location == .root && $0.isDirectory && $0.name == first + "/" }
    }
}

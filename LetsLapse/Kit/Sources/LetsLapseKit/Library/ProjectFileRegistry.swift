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

    public static let all: [ProjectFile] = [
        // Capture-time records, beside the media.
        ProjectFile("frames.timestamps", at: .source, class: .captureFact, travels: true, isHotPath: true),
        ProjectFile("frames.exposure", at: .source, class: .captureFact, travels: true, isHotPath: true),
        ProjectFile("capture_log.json", at: .source, class: .captureFact, travels: true),
        ProjectFile("sequence.json", at: .source, class: .captureFact, travels: true),
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
        ProjectFile("notes/", at: .root, class: .edit, isDirectory: true, travels: true),
        ProjectFile("masks/", at: .root, class: .edit, isDirectory: true, travels: true),
        ProjectFile("fonts/", at: .root, class: .edit, isDirectory: true, travels: true),
        ProjectFile("luts/", at: .root, class: .edit, isDirectory: true, travels: true),
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
    /// registered file that is not a media folder.
    public static var auditedSidecars: [ProjectFile] {
        all.filter { !($0.isDirectory && ["source/", "blends/", "masks/", "fonts/", "luts/"].contains($0.name)) }
    }
}

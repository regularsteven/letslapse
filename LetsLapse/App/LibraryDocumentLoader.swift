import Foundation
import LetsLapseKit

/// Reads the library from the project folders (data model M1: the truth
/// flips). Every `Projects/<id>/project.json` and every
/// `Projects/.trash/<id>/project.json`, decoded one by one, plus
/// `Collections/collections.json` — what `lapse audit --rebuild-index`
/// reads to reconstruct the manifest, read here by the app itself instead
/// of the manifest. `library.json` is no longer decoded on this path; it is
/// the generated compatibility export the persister writes afterwards.
///
/// Two rules decide what a document means, both Phase 4's:
///
/// - **The folder's place is the truth about deletion.** A document under
///   `Projects/<id>/` is a live project whatever its tombstone says — a
///   delete tombstones the document *before* moving the folder, so a
///   tombstoned document in a live folder is either a delete the process did
///   not live to finish or a folder someone dragged back out of `.trash` by
///   hand, and only the second of those is worth deciding for: it comes back
///   live, blends and all, rather than being swept straight back. A document
///   under `.trash/<id>/` is deleted; one that somehow lacks its stamp is
///   given one now, so the 30-day clock starts today rather than having run
///   out.
/// - **A document that will not decode is left exactly where it is.** It is
///   reported, its folder is excluded from every launch pass (the folder
///   reconciliation would otherwise register it as "Recovered" from its
///   media and the next persist would overwrite the document), and the
///   person hears about it. Nothing here moves or writes a file.
///
/// Per document rather than through one manifest decode so that one bad
/// document costs one project, not the library (Part 1 R1's blast radius).
struct LibraryDocumentLoader {

    struct Loaded {
        var captures: [AppModel.CaptureProject] = []
        var deletedCaptures: [AppModel.CaptureProject] = []
        var blends: [AppModel.BlendProject] = []
        var deletedBlends: [AppModel.BlendProject] = []
        /// Nil when there is no collections document — a library from
        /// before Phase 4 wrote one; the caller falls back to the manifest.
        var collections: [LapseCollection]?
        var deletedCollections: [LapseCollection] = []

        /// Every document exactly as it was decoded — what is on disk —
        /// so the document writer can be seeded with it and a persist
        /// before the launch pass rewrites only what actually changed.
        var onDisk: [ProjectDocument] = []

        var documentsRead = 0
        var documentsInTrash = 0
        /// Live folders whose tombstoned document came back live.
        var restored: [UUID] = []
        /// Trash folders whose document had no `deletedAt` and was stamped.
        var stampedInTrash: [UUID] = []
        /// Folders whose document exists but could not be decoded, with why.
        var unreadable: [(folder: String, reason: String)] = []
        /// Live UUID folders with no document at all — the folder
        /// reconciliation's material (a manifest record, media, or nothing).
        var liveFoldersWithoutDocument: [UUID] = []

        var unreadableFolders: Set<UUID> {
            Set(unreadable.compactMap { UUID(uuidString: $0.folder) })
        }
    }

    /// The load, off the main actor's shoulders but synchronous: the launch
    /// needs the arrays before anything looks at them.
    static func load(projectsRoot: URL, collectionsURL: URL) -> Loaded {
        var loaded = Loaded()
        let fm = FileManager.default
        let decoder = ProjectDocumentFormat.makeDecoder()
        let trash = projectsRoot.appendingPathComponent(".trash", isDirectory: true)

        for (container, inTrash) in [(projectsRoot, false), (trash, true)] {
            let names = ((try? fm.contentsOfDirectory(atPath: container.path)) ?? []).sorted()
            for name in names {
                guard !name.hasPrefix("."), let id = UUID(uuidString: name) else { continue }
                let folder = container.appendingPathComponent(name, isDirectory: true)
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                let url = ProjectDocumentFormat.url(inProjectFolder: folder)
                guard fm.fileExists(atPath: url.path) else {
                    if !inTrash { loaded.liveFoldersWithoutDocument.append(id) }
                    continue
                }
                let document: ProjectDocument
                do {
                    // One autorelease pool per file: the data is released
                    // before the next document is read (Phase 1 W5's lesson).
                    document = try autoreleasepool {
                        try decoder.decode(ProjectDocument.self, from: try Data(contentsOf: url))
                    }
                } catch {
                    loaded.unreadable.append((inTrash ? ".trash/\(name)" : name, "\(error)"))
                    continue
                }
                guard document.capture.id == id else {
                    // A document filed under another project's folder is not
                    // this folder's record; the audit reports it as misfiled.
                    loaded.unreadable.append((inTrash ? ".trash/\(name)" : name,
                                              "its capture id \(document.capture.id.uuidString.prefix(8)) is not the folder's"))
                    continue
                }
                loaded.documentsRead += 1
                loaded.onDisk.append(document)
                adopt(document, inTrash: inTrash, into: &loaded)
            }
        }

        loaded.captures.sort { $0.createdAt > $1.createdAt }
        loaded.blends.sort { $0.createdAt > $1.createdAt }

        if let data = try? Data(contentsOf: collectionsURL) {
            do {
                let document = try decoder.decode(CollectionsDocument.self, from: data)
                // Oldest first — a collection list reads in creation order.
                loaded.collections = document.collections.filter { $0.deletedAt == nil }.sorted { $0.createdAt < $1.createdAt }
                loaded.deletedCollections = document.collections.filter { $0.deletedAt != nil }
            } catch {
                LLog("library: collections document could not be decoded (\(error)) — falling back to the manifest's copy")
            }
        }
        return loaded
    }

    /// One document into the arrays, under the two rules above. The two
    /// Swift-level equivalents of the manifest's step-4 migration run here
    /// too — an origin for a record that has none, and no `.json` name
    /// among the frames — so a document written by another tool (the
    /// Lightroom migration, a hand) is complete the way the app's own are.
    private static func adopt(_ document: ProjectDocument, inTrash: Bool, into loaded: inout Loaded) {
        var capture = document.capture
        capture.sourceFileNames.removeAll { $0.hasSuffix(".json") }
        if capture.originID == nil { capture.originID = capture.importedFromID ?? capture.id }

        if inTrash {
            loaded.documentsInTrash += 1
            if capture.deletedAt == nil {
                capture.deletedAt = Date()
                capture.deletedBy = DeviceIdentity.id
                loaded.stampedInTrash.append(capture.id)
            }
            loaded.deletedCaptures.append(capture)
            for blend in document.blends {
                var tombstone = blend
                if tombstone.deletedAt == nil {
                    tombstone.deletedAt = capture.deletedAt
                    tombstone.deletedBy = capture.deletedBy
                }
                loaded.deletedBlends.append(tombstone)
            }
            return
        }

        let restored = capture.deletedAt != nil
        if restored {
            capture.deletedAt = nil
            capture.deletedBy = nil
            loaded.restored.append(capture.id)
        }
        loaded.captures.append(capture)
        for blend in document.blends {
            if restored {
                // The delete tombstoned every blend with the project; the
                // restore undoes it the same way.
                loaded.blends.append(blend.undeleted)
            } else if blend.deletedAt == nil {
                loaded.blends.append(blend)
            } else {
                loaded.deletedBlends.append(blend)
            }
        }
    }
}

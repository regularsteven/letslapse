import Foundation
import LetsLapseKit

/// The launch walk (data model M3): every project folder against the index,
/// one `stat` each, with a read only for a document the index does not
/// know as it is on disk.
///
/// M1 read every document at launch to fill three arrays; M3 has no arrays,
/// so the launch's job is only to make sure the index — what the lists ask
/// — says what the folders say. For each UUID folder under `Projects/` and
/// `Projects/.trash/` that holds a `project.json`:
///
/// - the index's row is **current** when it names the same folder and the
///   same modification date: nothing is read; the asset and shape rows are
///   refreshed if their files are newer;
/// - otherwise the document is read, M1's two rules applied — a document
///   under `Projects/` is live whatever its tombstone says (a delete
///   tombstones the document before moving the folder, so a tombstoned
///   document in a live folder is a folder someone dragged back out of
///   `.trash`), a document under `.trash/` is deleted and given a date if it
///   lacks one — written back if a rule changed it, and indexed; a document
///   that will not decode is reported, left exactly as it is and excluded
///   from every later pass (the folder reconciliation would otherwise
///   re-register it from its media and the next persist overwrite it);
/// - a row whose folder has gone is removed.
///
/// A fresh index (no rows — the first launch with one, or one thrown away)
/// is rebuilt whole from the files first, the JSON-level way the `lapse`
/// CLI does it; the walk then finds everything current bar the rule
/// violations, which the rows themselves reveal.
///
/// The two Swift-level equivalents of the manifest's step-4 migration ride
/// along on every read — an origin for a record that has none, and no
/// `.json` name among the frames — so a document written by another tool
/// (the Lightroom migration, a hand) is complete the way the app's own are.
///
/// The walk runs on the persister's queue as one block per folder
/// (`steps(…)`), never on the main thread: the lists render from the index
/// as it was while the walk brings it up to date (a whole rebuild takes 8 s
/// on the Mac library's 57 k asset rows), and a write queued meanwhile —
/// a registration, a delete — lands between two steps rather than after
/// the whole walk. `Outcome` is a class for that reason: the steps
/// accumulate into it in order, and the completion reads it once.
struct LibraryReconciler {

    final class Outcome: @unchecked Sendable {
        var walked = 0
        var current = 0
        var indexed = 0
        var rewritten = 0
        var removed = 0
        var indexRebuilt = false
        var sidecars = ProjectDocumentWriter.Outcome()
        /// Live folders whose tombstoned document came back live.
        var restored: [UUID] = []
        /// Trash folders whose document had no `deletedAt` and was stamped.
        var stamped: [UUID] = []
        /// Folders whose document exists but could not be decoded, with why.
        var unreadable: [(folder: String, reason: String)] = []
        /// Live UUID folders with no document at all — the folder
        /// reconciliation's material (a manifest record, media, or nothing).
        var liveFoldersWithoutDocument: [UUID] = []
        var seconds: Double = 0
        fileprivate var seen = Set<UUID>()
        fileprivate let started = Date()

        var unreadableFolders: Set<UUID> {
            Set(unreadable.compactMap { UUID(uuidString: $0.folder.replacingOccurrences(of: ".trash/", with: "")) })
        }
    }

    /// Whether any project folder, live or trash, holds a document — the
    /// one question that decides between the walk and the manifest
    /// bootstrap. Stops at the first.
    static func hasAnyDocument(projectsRoot: URL) -> Bool {
        let fm = FileManager.default
        let trash = projectsRoot.appendingPathComponent(".trash", isDirectory: true)
        for container in [projectsRoot, trash] {
            for name in (try? fm.contentsOfDirectory(atPath: container.path)) ?? [] where !name.hasPrefix(".") && UUID(uuidString: name) != nil {
                let url = ProjectDocumentFormat.url(inProjectFolder: container.appendingPathComponent(name, isDirectory: true))
                if fm.fileExists(atPath: url.path) { return true }
            }
        }
        return false
    }

    /// The walk as blocks for a serial queue: the rebuild of a fresh index
    /// first, one block per folder, and the finish (rows whose folder has
    /// gone) last. The caller enqueues them in order and reads `outcome`
    /// in the block after the last.
    static func steps(projectsRoot: URL, index: LibraryIndex?, writer: ProjectDocumentWriter, outcome: Outcome) -> [() -> Void] {
        let fm = FileManager.default
        let trash = projectsRoot.appendingPathComponent(".trash", isDirectory: true)
        var steps: [() -> Void] = []

        steps.append {
            if let index, let counts = try? index.counts(), counts.projects + counts.deletedProjects == 0 {
                do {
                    let built = try index.rebuild(fromProjectsFolder: projectsRoot)
                    outcome.indexRebuilt = true
                    LLog(String(format: "index: rebuilt from the files — %d projects · %d blends · %d assets in %.2f s", built.projects, built.blends, built.assets, built.seconds))
                } catch {
                    LLog("index: rebuild failed: \(error)")
                }
            }
        }

        for (container, inTrash) in [(projectsRoot, false), (trash, true)] {
            let names = ((try? fm.contentsOfDirectory(atPath: container.path)) ?? []).sorted()
            for name in names {
                guard !name.hasPrefix("."), let id = UUID(uuidString: name) else { continue }
                let folder = container.appendingPathComponent(name, isDirectory: true)
                steps.append {
                    step(id: id, name: name, folder: folder, inTrash: inTrash, index: index, writer: writer, outcome: outcome)
                }
            }
        }

        steps.append {
            if let index {
                do {
                    for id in try index.projectIDs().subtracting(outcome.seen) {
                        try index.removeProject(id: id)
                        outcome.removed += 1
                    }
                } catch {
                    LLog("index: could not drop the rows of folders that have gone: \(error)")
                }
            }
            outcome.seconds = Date().timeIntervalSince(outcome.started)
        }
        return steps
    }

    /// One folder against the index.
    private static func step(id: UUID, name: String, folder: URL, inTrash: Bool, index: LibraryIndex?, writer: ProjectDocumentWriter, outcome: Outcome) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        let url = ProjectDocumentFormat.url(inProjectFolder: folder)
        guard fm.fileExists(atPath: url.path) else {
            if !inTrash { outcome.liveFoldersWithoutDocument.append(id) }
            return
        }
        outcome.walked += 1

        // Current, and no rule the row itself shows to be broken?
        if let index, writer.isCurrent(id: id, at: url), let row = try? index.project(id: id) {
            let violation = (row.deletedAt != nil && !inTrash) || (row.deletedAt == nil && inTrash)
            if !violation {
                outcome.seen.insert(id)
                outcome.current += 1
                writer.refreshSidecars(id: id, folder: folder, outcome: &outcome.sidecars)
                return
            }
        }

        var document: ProjectDocument
        do {
            document = try autoreleasepool {
                try ProjectDocumentFormat.makeDecoder().decode(ProjectDocument.self, from: try Data(contentsOf: url))
            }
        } catch {
            outcome.unreadable.append((inTrash ? ".trash/\(name)" : name, "\(error)"))
            // Out of the index too: a document nobody can read is not a
            // record the lists should show (M1 kept it out of the arrays).
            try? index?.removeProject(id: id)
            return
        }
        guard document.capture.id == id else {
            outcome.unreadable.append((inTrash ? ".trash/\(name)" : name,
                                       "its capture id \(document.capture.id.uuidString.prefix(8)) is not the folder's"))
            try? index?.removeProject(id: id)
            return
        }
        outcome.seen.insert(id)
        let applied = applyRules(to: &document, inTrash: inTrash)
        if applied.restored { outcome.restored.append(id) }
        if applied.stamped { outcome.stamped.append(id) }
        var data: Data?
        if applied.changed {
            do {
                data = try writer.write(document, to: url)
                outcome.rewritten += 1
            } catch {
                LLog("reconcile: could not write \(name.prefix(8)) back: \(error)")
            }
        }
        if index != nil {
            let bytes = data ?? (try? Data(contentsOf: url)) ?? Data()
            writer.index(bytes, at: url, id: id, outcome: &outcome.sidecars)
            outcome.indexed += 1
        }
    }

    /// M1's rules on one document, and the step-4 equivalents. Returns
    /// whether anything changed.
    static func applyRules(to document: inout ProjectDocument, inTrash: Bool) -> (restored: Bool, stamped: Bool, changed: Bool) {
        let before = document
        var restored = false
        var stamped = false
        document.capture.sourceFileNames.removeAll { $0.hasSuffix(".json") }
        if document.capture.originID == nil {
            document.capture.originID = document.capture.importedFromID ?? document.capture.id
        }
        if inTrash {
            if document.capture.deletedAt == nil {
                document.capture.deletedAt = Date()
                document.capture.deletedBy = DeviceIdentity.id
                stamped = true
            }
            for i in document.blends.indices where document.blends[i].deletedAt == nil {
                document.blends[i].deletedAt = document.capture.deletedAt
                document.blends[i].deletedBy = document.capture.deletedBy
            }
        } else if document.capture.deletedAt != nil {
            document.capture.deletedAt = nil
            document.capture.deletedBy = nil
            // The delete tombstoned every blend with the project; the
            // restore undoes it the same way.
            document.blends = document.blends.map(\.undeleted)
            restored = true
        }
        return (restored, stamped, document != before)
    }
}

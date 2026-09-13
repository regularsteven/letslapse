import Foundation
import LetsLapseKit

/// One project's whole record as one document: its capture entry and every
/// blend entry that belongs to it. On disk it is `Projects/<id>/project.json`
/// (data model Phase 2, `ProjectDocumentFormat`); at the root of a `.lapse`
/// archive and first on the wire it is the manifest the far side installs
/// from — the same document, read from disk rather than synthesised.
struct ProjectDocument: Codable, Equatable {
    var formatVersion: Int = ProjectDocumentFormat.current
    var capture: AppModel.CaptureProject
    var blends: [AppModel.BlendProject]
}

/// Writes `project.json` for every project a persisted manifest changed.
///
/// Runs on the `LibraryPersister`'s queue, after `library.json` has landed:
/// the persister hands it the manifest it just wrote, and it compares every
/// project's document against the last one it wrote (`Equatable`, cheap —
/// the snapshots share their arrays) and rewrites only those that differ.
/// That is what "every persist that touches a project also writes its
/// document" means without threading project ids through the seventy
/// persist sites: a grade tick rewrites one small file, a persist that
/// changed nothing rewrites none.
///
/// A document goes where its folder is: `Projects/<id>/` for a live
/// project, `Projects/.trash/<id>/` for a tombstoned one whose folder has
/// already moved. It never creates a folder — a record with no folder (the
/// audit's "records with no folder") has nowhere to put a document, and
/// making one would turn a dangling record into an empty project.
///
/// `reconcile` is the one-time launch pass: with no memory of what was
/// written before, it compares each document's bytes against the file on
/// disk, writes the missing and the stale, and seeds the cache so the first
/// persist after launch does not rewrite every document again.
final class ProjectDocumentWriter {

    private let projectsRoot: URL
    private var lastWritten: [UUID: ProjectDocument] = [:]

    init(projectsRoot: URL) {
        self.projectsRoot = projectsRoot
    }

    struct Outcome {
        var written = 0
        var unchanged = 0
        /// Records with no folder to write into.
        var homeless = 0
        var failed = 0
    }

    /// The documents a manifest describes, one per capture (live and
    /// tombstoned), each with the blends whose `captureID` is its own.
    static func documents(in manifest: AppModel.LibraryManifest) -> [ProjectDocument] {
        var blendsByCapture: [UUID: [AppModel.BlendProject]] = [:]
        for blend in manifest.blends { blendsByCapture[blend.captureID, default: []].append(blend) }
        return manifest.captures.map { capture in
            ProjectDocument(capture: capture, blends: blendsByCapture[capture.id] ?? [])
        }
    }

    /// After a persist: every document that differs from the last one
    /// written goes to disk. Called on the persister's queue.
    @discardableResult
    func sync(_ manifest: AppModel.LibraryManifest) -> Outcome {
        var outcome = Outcome()
        var seen = Set<UUID>()
        for document in Self.documents(in: manifest) {
            let id = document.capture.id
            seen.insert(id)
            if lastWritten[id] == document {
                outcome.unchanged += 1
                continue
            }
            guard let url = documentURL(for: document.capture) else {
                outcome.homeless += 1
                continue
            }
            do {
                try write(document, to: url)
                lastWritten[id] = document
                outcome.written += 1
            } catch {
                outcome.failed += 1
                LLog("project document: could not write \(url.path): \(error)")
            }
        }
        // A purged project's entry would otherwise live on in memory for
        // the rest of the session.
        lastWritten = lastWritten.filter { seen.contains($0.key) }
        return outcome
    }

    /// At launch: brings every document on disk up to the manifest, byte
    /// for byte, and remembers what is there. Called on the persister's
    /// queue so no persist can overtake it.
    @discardableResult
    func reconcile(_ manifest: AppModel.LibraryManifest) -> Outcome {
        var outcome = Outcome()
        let encoder = ProjectDocumentFormat.makeEncoder()
        for document in Self.documents(in: manifest) {
            guard let url = documentURL(for: document.capture) else {
                outcome.homeless += 1
                continue
            }
            do {
                let data = try encoder.encode(document)
                if let existing = try? Data(contentsOf: url), existing == data {
                    outcome.unchanged += 1
                } else {
                    try data.write(to: url, options: .atomic)
                    outcome.written += 1
                }
                lastWritten[document.capture.id] = document
            } catch {
                outcome.failed += 1
                LLog("project document: could not reconcile \(url.path): \(error)")
            }
        }
        return outcome
    }

    /// Where a project's document lives, or nil when it has no folder.
    private func documentURL(for capture: AppModel.CaptureProject) -> URL? {
        let folder = projectsRoot.appendingPathComponent(capture.id.uuidString, isDirectory: true)
        if isDirectory(folder) { return ProjectDocumentFormat.url(inProjectFolder: folder) }
        if capture.deletedAt != nil {
            let trashed = projectsRoot.appendingPathComponent(".trash", isDirectory: true)
                .appendingPathComponent(capture.id.uuidString, isDirectory: true)
            if isDirectory(trashed) { return ProjectDocumentFormat.url(inProjectFolder: trashed) }
        }
        return nil
    }

    private func write(_ document: ProjectDocument, to url: URL) throws {
        try ProjectDocumentFormat.makeEncoder().encode(document).write(to: url, options: .atomic)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }
}

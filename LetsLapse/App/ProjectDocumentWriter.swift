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
///
/// The index (Phase 3) follows the documents: every document written is
/// handed to `LibraryIndex` as the bytes that landed, a project dropped
/// from the manifest is removed, and the launch pass brings the index up
/// to the files — a fresh database is rebuilt whole, an existing one is
/// checked project by project against the documents' and the asset
/// records' modification dates.
final class ProjectDocumentWriter {

    private let projectsRoot: URL
    private let index: LibraryIndex?
    private var lastWritten: [UUID: ProjectDocument] = [:]

    init(projectsRoot: URL, index: LibraryIndex?) {
        self.projectsRoot = projectsRoot
        self.index = index
    }

    struct Outcome {
        var written = 0
        var unchanged = 0
        /// Records with no folder to write into.
        var homeless = 0
        var failed = 0
        /// Index rows written (projects) and re-indexed asset files.
        var indexed = 0
        var assetsReindexed = 0
        var indexRebuilt = false
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
                let data = try write(document, to: url)
                lastWritten[id] = document
                outcome.written += 1
                index(data, at: url, id: id, outcome: &outcome)
            } catch {
                outcome.failed += 1
                LLog("project document: could not write \(url.path): \(error)")
            }
        }
        // A purged project's entry would otherwise live on in memory for
        // the rest of the session — and its rows in the index.
        for id in lastWritten.keys where !seen.contains(id) {
            do { try index?.removeProject(id: id) } catch { LLog("index: could not remove \(id.uuidString.prefix(8)): \(error)") }
        }
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
        // A database with nothing in it (first launch with the index, or
        // one thrown away) is rebuilt whole from the files once the
        // documents are current; otherwise each project is checked below.
        let freshIndex = (try? index?.counts()).map { $0.projects + $0.deletedProjects == 0 } ?? false
        var seen = Set<UUID>()
        for document in Self.documents(in: manifest) {
            let id = document.capture.id
            seen.insert(id)
            guard let url = documentURL(for: document.capture) else {
                outcome.homeless += 1
                continue
            }
            do {
                let data = try encoder.encode(document)
                if let existing = try? Data(contentsOf: url), existing == data {
                    outcome.unchanged += 1
                    if !freshIndex { checkIndex(data, at: url, id: id, outcome: &outcome) }
                } else {
                    try data.write(to: url, options: .atomic)
                    outcome.written += 1
                    if !freshIndex { index(data, at: url, id: id, outcome: &outcome) }
                }
                lastWritten[id] = document
            } catch {
                outcome.failed += 1
                LLog("project document: could not reconcile \(url.path): \(error)")
            }
        }
        guard let index else { return outcome }
        do {
            if freshIndex, !seen.isEmpty {
                let built = try index.rebuild(fromProjectsFolder: projectsRoot)
                outcome.indexed = built.projects
                outcome.assetsReindexed = built.projects
                outcome.indexRebuilt = true
            } else {
                // Rows for projects the manifest no longer has (purged, or
                // a folder that arrived without a record).
                for id in try index.projectIDs().subtracting(seen) {
                    try index.removeProject(id: id)
                }
            }
        } catch {
            LLog("index: launch reconciliation failed: \(error)")
        }
        return outcome
    }

    // MARK: - The index

    /// A document that just landed goes into the index as it is, with the
    /// file's modification date so the next launch can tell it is current.
    private func index(_ data: Data, at url: URL, id: UUID, outcome: inout Outcome) {
        guard let index else { return }
        do {
            try index.upsertProject(documentData: data, folder: relativeFolder(of: url), documentModifiedAt: modificationDate(url))
            outcome.indexed += 1
            reindexAssetsIfStale(id: id, folder: url.deletingLastPathComponent(), outcome: &outcome)
        } catch {
            LLog("index: could not index \(id.uuidString.prefix(8)): \(error)")
        }
    }

    /// An unchanged document is re-indexed only when the index has no row
    /// for it or the row predates the file — a stat and a primary-key read.
    private func checkIndex(_ data: Data, at url: URL, id: UUID, outcome: inout Outcome) {
        guard let index else { return }
        let onDisk = modificationDate(url)
        if let indexed = index.documentModifiedAt(projectID: id), let onDisk, abs(indexed.timeIntervalSince(onDisk)) < 0.001 {
            reindexAssetsIfStale(id: id, folder: url.deletingLastPathComponent(), outcome: &outcome)
            return
        }
        self.index(data, at: url, id: id, outcome: &outcome)
    }

    /// The asset rows follow `assets.ndjson` and `metadata.json` by date.
    private func reindexAssetsIfStale(id: UUID, folder: URL, outcome: inout Outcome) {
        guard let index else { return }
        let files = [AssetRecords.url(inProjectFolder: folder), ProjectMetadata.url(inProjectFolder: folder)]
        let newest = files.compactMap(modificationDate).max()
        guard let newest else { return }
        if let indexed = index.assetsIndexedAt(projectID: id), indexed >= newest { return }
        do {
            try index.reindexAssets(projectID: id, inProjectFolder: folder)
            outcome.assetsReindexed += 1
        } catch {
            LLog("index: could not re-index assets of \(id.uuidString.prefix(8)): \(error)")
        }
    }

    private func relativeFolder(of documentURL: URL) -> String {
        let folder = documentURL.deletingLastPathComponent()
        let prefix = projectsRoot.standardizedFileURL.path + "/"
        let path = folder.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : folder.lastPathComponent
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
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

    @discardableResult
    private func write(_ document: ProjectDocument, to url: URL) throws -> Data {
        let data = try ProjectDocumentFormat.makeEncoder().encode(document)
        try data.write(to: url, options: .atomic)
        return data
    }

    private func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }
}

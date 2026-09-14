import Foundation
import LetsLapseKit

/// One project's whole record as one document: its capture entry and every
/// blend entry that belongs to it. On disk it is `Projects/<id>/project.json`
/// (data model Phase 2, `ProjectDocumentFormat`) — since M1 the truth of the
/// project, since M3 the only place the app holds it; at the root of a
/// `.lapse` archive and first on the wire it is the manifest the far side
/// installs from — the same document, read from disk rather than synthesised.
struct ProjectDocument: Codable, Equatable {
    var formatVersion: Int = ProjectDocumentFormat.current
    var capture: AppModel.CaptureProject
    var blends: [AppModel.BlendProject]
}

/// Every collection, tombstoned ones included, as one document —
/// `<root>/Collections/collections.json` (Phase 4). Collections span
/// projects and so have no per-project document; without this file a
/// manifest rebuilt from the project folders would come back without them.
struct CollectionsDocument: Codable, Equatable {
    var formatVersion: Int = ProjectDocumentFormat.collectionsFormat
    var collections: [LapseCollection]
}

/// Writes one project's `project.json` and keeps its index rows current
/// (M3: per document — the manifest-shaped `sync` and `reconcile` of
/// Phase 2 are gone with the arrays they walked).
///
/// The index (Phase 3) follows the documents: every document written is
/// handed to `LibraryIndex` as the bytes that landed, with the file's
/// modification date so the next launch can tell it is current and the
/// project's folder so the one classification the document cannot settle
/// (the scanner sidecar) can be read once; the asset rows follow
/// `assets.ndjson` and `metadata.json` by date, the shape counts
/// `shapes.json`.
final class ProjectDocumentWriter {

    private let projectsRoot: URL
    private let index: LibraryIndex?

    init(projectsRoot: URL, index: LibraryIndex?) {
        self.projectsRoot = projectsRoot
        self.index = index
    }

    struct Outcome {
        /// Index rows written (projects), and re-indexed asset files and
        /// shape registers.
        var indexed = 0
        var assetsReindexed = 0
        var shapesReindexed = 0
    }

    /// The document's bytes, atomically at `url`.
    @discardableResult
    func write(_ document: ProjectDocument, to url: URL) throws -> Data {
        let data = try ProjectDocumentFormat.makeEncoder().encode(document)
        try data.write(to: url, options: .atomic)
        return data
    }

    /// The collections document, atomically.
    func writeCollections(_ document: CollectionsDocument, to url: URL) throws {
        let data = try ProjectDocumentFormat.makeEncoder().encode(document)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - The index

    /// A document that just landed (or was just read) goes into the index
    /// as it is.
    func index(_ data: Data, at url: URL, id: UUID, outcome: inout Outcome) {
        guard let index else { return }
        let folder = url.deletingLastPathComponent()
        do {
            try index.upsertProject(documentData: data, folder: relativeFolder(of: url), documentModifiedAt: modificationDate(url), projectFolderURL: folder)
            outcome.indexed += 1
            reindexAssetsIfStale(id: id, folder: folder, outcome: &outcome)
            reindexShapesIfStale(id: id, folder: folder, outcome: &outcome)
        } catch {
            LLog("index: could not index \(id.uuidString.prefix(8)): \(error)")
        }
    }

    /// Whether the index's row for the project is the file at `url`: the
    /// same folder and the same modification date (a stat and a primary-
    /// key read, no decode).
    func isCurrent(id: UUID, at url: URL) -> Bool {
        guard let index, let onDisk = modificationDate(url),
              let indexed = index.documentModifiedAt(projectID: id), abs(indexed.timeIntervalSince(onDisk)) < 0.001,
              let folder = try? index.folder(of: id), folder == relativeFolder(of: url) else { return false }
        return true
    }

    /// The asset and shape rows brought up to their files by date, for a
    /// project whose document row is current.
    func refreshSidecars(id: UUID, folder: URL, outcome: inout Outcome) {
        reindexAssetsIfStale(id: id, folder: folder, outcome: &outcome)
        reindexShapesIfStale(id: id, folder: folder, outcome: &outcome)
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

    /// The shape counts follow `shapes.json` by date (M2): re-counted when
    /// the register is newer than the count, or when it has gone since.
    private func reindexShapesIfStale(id: UUID, folder: URL, outcome: inout Outcome) {
        guard let index else { return }
        let register = modificationDate(ShapeRegister.url(inProjectFolder: folder))
        let counted = index.shapesIndexedAt(projectID: id)
        switch (register, counted) {
        case (nil, nil): return
        case (let file?, let at?) where at >= file: return
        default: break
        }
        do {
            try index.reindexShapes(projectID: id, inProjectFolder: folder)
            outcome.shapesReindexed += 1
        } catch {
            LLog("index: could not re-count shapes of \(id.uuidString.prefix(8)): \(error)")
        }
    }

    func relativeFolder(of documentURL: URL) -> String {
        let folder = documentURL.deletingLastPathComponent()
        let prefix = projectsRoot.standardizedFileURL.path + "/"
        let path = folder.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : folder.lastPathComponent
    }

    /// Through a fresh URL every time: a `URL` caches its resource values,
    /// and an atomic `Data.write` has already stat'ed the destination
    /// through the one it was given — so reading the date back through that
    /// same value returns the PREVIOUS file's stamp (measured 2026-09-13:
    /// seven of eight documents re-indexed on the next launch for exactly
    /// this reason).
    func modificationDate(_ url: URL) -> Date? {
        (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

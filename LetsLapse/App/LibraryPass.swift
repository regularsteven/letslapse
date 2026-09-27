import Foundation
import LetsLapseKit

// MARK: - A whole-library read off the main actor (2026-09-27)
//
// Several passes ask the same question of every project in the library —
// which are here, which are previews, what each is called on PicPlace, when
// each was last edited. Each one read every document through the store on
// the main actor (with 1,335 projects and a cache of 512, a full decode per
// project per pass) and made a file check per project, so the main thread
// stopped for 0.5–1.5 s after every photo, after every PicPlace check and
// whenever Settings was open (docs/performance-baseline-plan.md, measured
// on the 18 Pro with Instruments). This is the one door those passes now
// go through: the index and the store are read from a detached task (both
// are lock-protected), each document once and without disturbing the
// store's cache (`ProjectStore.peekDocument`), and the answer comes back to
// the main actor as plain values. The records the passes compare against —
// the sync records, the usage, the jobs — are still read on the main actor,
// where they live, once the pass has landed.

/// One project's facts as a pass reads them — the same derivations
/// `AppModel` and `PicPlaceController` make on the main actor, computed from
/// the document off it.
struct LibraryPassProject: Sendable {
    let id: UUID
    /// `AppModel.originID(of:)`.
    let originID: UUID
    let deletedAt: Date?
    let isPhotoCapture: Bool
    let displayTitle: String
    /// `AppModel.sourcesMissing(_:)`.
    let sourcesMissing: Bool
    /// `AppModel.posterURL(for:) != nil`.
    let hasPoster: Bool
    /// `AppModel.lastEdited(_:)`.
    let lastEdited: Date
    /// `AppModel.projectFolderURL(for:)`.
    let folder: URL

    /// `PicPlaceController.revision(of:)` — the last edit in milliseconds.
    var revision: Int { Int((lastEdited.timeIntervalSince1970 * 1000).rounded()) }
}

/// What one pass read.
struct LibraryPassSnapshot: Sendable {
    /// The index's rows for the query, in its order — every project it
    /// lists, whether or not its document could be read.
    let rows: [LibraryIndex.ProjectRow]
    /// The facts of every row whose document could be read, in the same order.
    let projects: [LibraryPassProject]
    /// Projects whose frames the pass walked and found whole — tickets for
    /// `source(for:)` once the main actor accepts them.
    let framesValidated: Set<UUID>
    let seconds: Double

    var byID: [UUID: LibraryPassProject] {
        Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

enum LibraryPass {
    /// Every live project, as the passes always asked (`limit = 100_000`).
    static var everyProject: LibraryIndex.ProjectQuery {
        var query = LibraryIndex.ProjectQuery()
        query.limit = 100_000
        return query
    }

    /// The read itself — any thread. `framesValidated` are the main actor's
    /// tickets: a project in the set has had every frame found this session
    /// and is not walked again, exactly as `source(for:)` spares it.
    nonisolated static func read(index: LibraryIndex, store: ProjectStore, projectsRoot: URL,
                                 query: LibraryIndex.ProjectQuery, framesValidated: Set<UUID>) -> LibraryPassSnapshot {
        let started = Date()
        let rows = (try? index.projects(query).rows) ?? []
        var projects: [LibraryPassProject] = []
        projects.reserveCapacity(rows.count)
        var validated = Set<UUID>()
        for row in rows {
            guard let document = autoreleasepool(invoking: { store.peekDocument(id: row.id) }) else { continue }
            let capture = document.capture
            let folder = projectsRoot.appendingPathComponent(row.id.uuidString, isDirectory: true)
            let sources = AppModel.sourcesMissing(capture: capture, folder: folder, framesValidated: framesValidated.contains(row.id))
            if sources.walkedWhole { validated.insert(row.id) }
            let live = document.blends.filter { $0.deletedAt == nil }.sorted { $0.createdAt > $1.createdAt }
            projects.append(LibraryPassProject(
                id: row.id,
                originID: AppModel.originID(of: capture),
                deletedAt: capture.deletedAt,
                isPhotoCapture: capture.isPhotoCapture,
                displayTitle: capture.displayTitle,
                sourcesMissing: sources.missing,
                hasPoster: AppModel.hasPoster(inProjectFolder: folder),
                lastEdited: AppModel.lastEdited(capture: capture, blends: live),
                folder: folder))
        }
        return LibraryPassSnapshot(rows: rows, projects: projects, framesValidated: validated,
                                   seconds: Date().timeIntervalSince(started))
    }
}

extension AppModel {

    /// Reads every project the index lists for `query` off the main actor
    /// and hands back their facts; nil without an index. `name` is the
    /// caller's — the signpost's interval and the console line. The frames
    /// the pass found whole become `source(for:)`'s tickets, unless a file
    /// changed anywhere meanwhile.
    func libraryPass(_ query: LibraryIndex.ProjectQuery = LibraryPass.everyProject, name: StaticString) async -> LibraryPassSnapshot? {
        guard let index = libraryIndex else { return nil }
        let store = self.store
        let root = projectsFolderURL
        let validated = validatedSourceFramesSnapshot
        let revision = filesRevision
        let signpost = LLPerf.begin(name)
        let snapshot = await Task.detached(priority: .utility) {
            LibraryPass.read(index: index, store: store, projectsRoot: root, query: query, framesValidated: validated)
        }.value
        LLPerf.end(name, signpost)
        noteSourceFramesValidated(snapshot.framesValidated, filesRevision: revision)
        LLog(String(format: "%@: %d of %d project(s) read in %.2f s off main%@", "\(name)", snapshot.projects.count, snapshot.rows.count,
                    snapshot.seconds, snapshot.framesValidated.isEmpty ? "" : " (\(snapshot.framesValidated.count) frame walks)"))
        return snapshot
    }

    // MARK: The derivations, off the main actor

    /// `sourcesMissing(_:)` for a document read anywhere: `source(for:)`'s
    /// own rule, step for step. A photo-kind capture is missing when it
    /// lists no frame or any listed frame is not on disk (`framesValidated`
    /// spares the walk, as the ticket does on the main actor; `walkedWhole`
    /// says this call walked every frame and found it, so the caller may
    /// hand the project back as a ticket). A video capture is missing when
    /// any clip has no surviving encoding, when its `sequence.json` will not
    /// read, or when it lists no clip at all. A capture that lists no source
    /// file is never missing.
    nonisolated static func sourcesMissing(capture: CaptureProject, folder: URL, framesValidated: Bool) -> (missing: Bool, walkedWhole: Bool) {
        guard !capture.sourceFileNames.isEmpty else { return (false, false) }
        let clipNames = capture.sourceFileNames.filter { !$0.hasSuffix(".json") }
        let fileManager = FileManager.default
        switch capture.kind {
        case .photos:
            // `.photos(urls)` answers `urls.first`: nil when no frame is listed.
            guard !clipNames.isEmpty else { return (true, false) }
            if framesValidated { return (false, false) }
            for name in clipNames where !fileManager.fileExists(atPath: folder.appendingPathComponent(name, isDirectory: false).path) {
                return (true, false)
            }
            return (false, true)
        case .video:
            // `activeEncodingURL`: the stored encodings once the clip has been
            // converted, else the original itself — one of them must be here.
            for name in clipNames {
                let stored = capture.clipEncodings?[name] ?? []
                let files = stored.isEmpty ? [name] : stored.map(\.fileName)
                guard files.contains(where: { fileManager.fileExists(atPath: folder.appendingPathComponent($0).path) }) else {
                    return (true, false)
                }
            }
            let metadataURL = folder.appendingPathComponent("source/sequence.json")
            if fileManager.fileExists(atPath: metadataURL.path) {
                do {
                    let data = try Data(contentsOf: metadataURL)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    _ = try decoder.decode(LiveCaptureSequence.self, from: data)
                } catch {
                    return (true, false)
                }
            }
            // `.liveSequence` answers its first segment, `.video` its first
            // clip: nil — a throw — with no clip listed.
            return (clipNames.isEmpty, false)
        }
    }

    /// `posterURL(for:) != nil` for a folder — `Projects/<id>/poster.jpg`.
    nonisolated static func hasPoster(inProjectFolder folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(ProjectFileRegistry.posterName).path)
    }

    /// `lastEdited(_:)` from a document read anywhere. `blends` are the live
    /// ones.
    nonisolated static func lastEdited(capture: CaptureProject, blends: [BlendProject]) -> Date {
        if let modifiedAt = capture.modifiedAt { return modifiedAt }
        return blends.map(\.createdAt).max() ?? capture.createdAt
    }
}

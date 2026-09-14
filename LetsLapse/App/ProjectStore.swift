import Foundation
import LetsLapseKit

/// The records, read from their documents when asked for (data model M3).
///
/// Since M1 the truth of a project is its `project.json`; since M2 the
/// lists ask the index which projects to show. What remained was three
/// arrays the launch filled from every document so that a screen could
/// say `captures.first { $0.id == … }`. This is what replaces them: one
/// document at a time, read from disk the first time a screen asks for it
/// and kept in a bounded cache — the newest-touched 512 — so memory
/// follows what the person looks at, not how many projects the library
/// holds (Part 2 §5's cliff).
///
/// Every write goes through the persister first and the cache second: a
/// document that could not be written is not what the app then believes
/// it holds. A queued write (a grade tick) is cached at once and reported
/// once if it fails, the way the persister always reported.
///
/// A blend lives inside its project's document. `blend(id:)` finds the
/// project through the owners this session has seen, else the index.
final class ProjectStore: @unchecked Sendable {

    static let capacity = 512

    private let projectsRoot: URL
    private let index: LibraryIndex?
    private let persister: LibraryPersister
    private let lock = NSRecursiveLock()
    private var cache: [UUID: ProjectDocument] = [:]
    /// Least recently touched first.
    private var recency: [UUID] = []
    private var owners: [UUID: UUID] = [:]

    /// Folders whose document exists but would not decode (M1's rule):
    /// never read as a record, never written over. Set by the launch walk.
    var unreadable: Set<UUID> = []

    /// Stamps what a record derives before it is written — the preset
    /// state a fresh registration has no stored answer for, which the
    /// manifest's persist used to stamp on every snapshot.
    var beforeWrite: ((inout AppModel.CaptureProject) -> Void)?

    init(projectsRoot: URL, index: LibraryIndex?, persister: LibraryPersister) {
        self.projectsRoot = projectsRoot
        self.index = index
        self.persister = persister
    }

    // MARK: - Reading

    /// The project's whole document — from the cache, else from its file.
    func document(id: UUID) -> ProjectDocument? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[id] {
            touch(id)
            return cached
        }
        guard !unreadable.contains(id), let document = read(id: id) else { return nil }
        remember(document)
        return document
    }

    func capture(id: UUID) -> AppModel.CaptureProject? {
        document(id: id)?.capture
    }

    /// The project's live blends, newest first — what `blends(for:)`
    /// always answered.
    func blends(for id: UUID) -> [AppModel.BlendProject] {
        (document(id: id)?.blends ?? []).filter { $0.deletedAt == nil }.sorted { $0.createdAt > $1.createdAt }
    }

    /// The project's blends as stored, tombstoned ones included.
    func allBlends(for id: UUID) -> [AppModel.BlendProject] {
        document(id: id)?.blends ?? []
    }

    /// A live blend by id, through its project.
    func blend(id: UUID) -> AppModel.BlendProject? {
        guard let owner = owner(ofBlend: id) else { return nil }
        return document(id: owner)?.blends.first { $0.id == id && $0.deletedAt == nil }
    }

    /// The project a blend belongs to.
    func owner(ofBlend blendID: UUID) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        if let known = owners[blendID] { return known }
        guard let found = try? index?.projectID(forBlend: blendID) else { return nil }
        owners[blendID] = found
        return found
    }

    /// Whether a live record exists for the id — the cache, the index or
    /// the folder, without decoding when one of the first two knows.
    func exists(id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[id] { return cached.capture.deletedAt == nil }
        if let index, let row = try? index.project(id: id) { return row.deletedAt == nil }
        return document(id: id)?.capture.deletedAt == nil
    }

    // MARK: - Writing

    enum StoreError: LocalizedError {
        case noSuchProject(UUID)
        var errorDescription: String? {
            switch self {
            case .noSuchProject(let id): return "Project \(id.uuidString.prefix(8)) is not in the library."
            }
        }
    }

    /// Changes one project's document and writes it: `waiting` returns
    /// once it is on disk (a registration, a delete, an export about to
    /// read the file); otherwise the write is queued and the cache holds
    /// the new state at once. Throws when the project does not exist or —
    /// waiting — when the write failed, in which case the cache is untouched.
    @discardableResult
    func update(_ id: UUID, waiting: Bool = true, _ change: (inout ProjectDocument) -> Void) throws -> ProjectDocument {
        lock.lock(); defer { lock.unlock() }
        guard var document = self.document(id: id) else { throw StoreError.noSuchProject(id) }
        change(&document)
        beforeWrite?(&document.capture)
        try persister.persist(document, in: folderURL(for: id), version: persister.mint(), waiting: waiting)
        remember(document)
        return document
    }

    /// A new project's document, written where its folder already is.
    func insert(_ document: ProjectDocument, waiting: Bool = true) throws {
        lock.lock(); defer { lock.unlock() }
        var document = document
        beforeWrite?(&document.capture)
        try persister.persist(document, in: folderURL(for: document.capture.id), version: persister.mint(), waiting: waiting)
        remember(document)
    }

    /// The project is gone from the library (purged, or a rolled-back
    /// registration): out of the cache, its row out of the index.
    func remove(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        forget(id: id)
        persister.removeProject(id: id)
    }

    /// Out of the cache only — the next read finds the file wherever the
    /// index says it is now.
    func forget(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if let document = cache.removeValue(forKey: id) {
            for blend in document.blends { owners[blend.id] = nil }
        }
        recency.removeAll { $0 == id }
    }

    /// The project's folder moved (into or out of `.trash/`): the index
    /// row follows, the cache keeps the document.
    func noteFolderMoved(id: UUID, toTrash: Bool) {
        let folder = toTrash ? ".trash/\(id.uuidString)" : id.uuidString
        do { try index?.setFolder(folder, of: id) } catch { LLog("index: could not move \(id.uuidString.prefix(8))'s row: \(error)") }
    }

    /// Where the project's document is: as the index says, else the live
    /// folder when it exists, else the trash folder when that does, else
    /// the live folder (a registration whose folder was just made).
    func folderURL(for id: UUID) -> URL {
        if let index, let relative = ((try? index.folder(of: id)) ?? nil) {
            return projectsRoot.appendingPathComponent(relative, isDirectory: true)
        }
        let live = projectsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: live.path) { return live }
        let trashed = projectsRoot.appendingPathComponent(".trash", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: trashed.path) { return trashed }
        return live
    }

    // MARK: - The cache

    private func read(id: UUID) -> ProjectDocument? {
        let url = ProjectDocumentFormat.url(inProjectFolder: folderURL(for: id))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return autoreleasepool {
            do {
                let data = try Data(contentsOf: url)
                return try ProjectDocumentFormat.makeDecoder().decode(ProjectDocument.self, from: data)
            } catch {
                LLog("store: could not read \(id.uuidString.prefix(8))'s document: \(error)")
                return nil
            }
        }
    }

    private func remember(_ document: ProjectDocument) {
        let id = document.capture.id
        cache[id] = document
        for blend in document.blends { owners[blend.id] = id }
        touch(id)
        while recency.count > Self.capacity, let oldest = recency.first {
            recency.removeFirst()
            if let gone = cache.removeValue(forKey: oldest) {
                for blend in gone.blends { owners[blend.id] = nil }
            }
        }
    }

    private func touch(_ id: UUID) {
        if let at = recency.lastIndex(of: id) { recency.remove(at: at) }
        recency.append(id)
    }
}

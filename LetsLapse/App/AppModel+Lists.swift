import Foundation
import LetsLapseKit

/// The lists' question, as the screens ask it (data model M2): the sort and
/// its direction, the kind filter, the typed words and the lit chips, whether
/// scans are in, and the Gallery's SHAPES rows. One value, so the Projects
/// list, the Gallery, their empty states and their counts all ask the index
/// the same thing — and so the answer can be remembered until the index or
/// the question changes.
struct ProjectListQuery: Hashable {
    var sort: ProjectSort
    var ascending: Bool
    var filter: CaptureFilter
    var query: SceneQuery
    /// Scans belong to the list exactly when they have no tab of their own.
    var listsScans: Bool
    var shapes: Set<ShapeFilter> = []

    /// The same question in the index's terms — `CaptureFilter.matches` as
    /// a category, `ProjectsView.sorted` as a sort with its ties, the chips
    /// as tags every project must carry, the words as FTS prefixes.
    var indexQuery: LibraryIndex.ProjectQuery {
        var q = LibraryIndex.ProjectQuery()
        switch sort {
        case .capture: q.sort = .created
        case .added: q.sort = .added
        case .edit: q.sort = .edited
        case .size: q.sort = .size
        }
        q.ascending = ascending
        switch filter {
        case .all: q.category = nil
        case .photos: q.category = .photo
        case .interval: q.category = .interval
        case .video: q.category = .video
        case .scans: q.category = .scan
        }
        q.excludeScans = !listsScans
        q.tags = query.tags.sorted()
        q.text = query.text
        q.shapes = Set(shapes.map { row in
            switch row {
            case .ellipse: return ShapeRow.ellipse
            case .rectangle: return .rectangle
            case .square: return .square
            case .empty: return .none
            }
        })
        return q
    }

    /// The question with nothing switched on — what "is the library empty"
    /// and the filter counts are measured against.
    var base: ProjectListQuery {
        ProjectListQuery(sort: sort, ascending: ascending, filter: .all, query: .empty, listsScans: listsScans)
    }
}

extension LibraryIndex.ProjectRow: Identifiable {}

extension AppModel {

    // MARK: - One record by id

    /// One project's record, by id — the one way a screen gets a record it
    /// was handed the id of (M2): its document, through the store's cache
    /// (M3).
    func capture(id: UUID) -> CaptureProject? {
        store.capture(id: id)
    }

    /// One live blend's record, by id, through its project's document.
    func blend(id: UUID) -> BlendProject? {
        store.blend(id: id)
    }

    // MARK: - The lists

    /// The rows a list renders, in order — id, name, kind, dates, counts:
    /// what a grid or a timeline needs to lay itself out without a record
    /// (M3) — or nil when the library has no index to ask. Remembered per
    /// question until the index changes.
    func listRows(for query: ProjectListQuery) -> [LibraryIndex.ProjectRow]? {
        guard let index = libraryIndex else { return nil }
        if let cached = listCache[query], cached.revision == indexRevision { return cached.rows }
        do {
            var indexQuery = query.indexQuery
            indexQuery.limit = Int(Int32.max)
            let rows = try index.projects(indexQuery).rows
            listCache[query] = (indexRevision, rows)
            return rows
        } catch {
            LLog("index: list query failed (\(error))")
            return nil
        }
    }

    /// The ids a list renders, in order, or nil when the library has no
    /// index to ask.
    func projectIDs(for query: ProjectListQuery) -> [UUID]? {
        listRows(for: query)?.map(\.id)
    }

    /// The tag chips present among the projects a list question matches —
    /// the Gallery sidebar's chips, which narrow with the filter, the words
    /// and the rows — in the taxonomy's order, custom tags after.
    func tagChips(for query: ProjectListQuery) -> [String]? {
        guard let index = libraryIndex else { return nil }
        do {
            let present = Set(try index.tagCounts(query.indexQuery).map(\.tag))
            let custom = present.filter(SceneMetadata.isCustom)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            return SceneMetadata.orderedTaxonomy.filter(present.contains) + custom
        } catch {
            LLog("index: tag query failed (\(error))")
            return nil
        }
    }

    /// The records behind `projectIDs(for:)`, in the same order; a project
    /// the index lists but whose document cannot be read is skipped rather
    /// than shown blank.
    func projects(for query: ProjectListQuery) -> [CaptureProject]? {
        projectIDs(for: query)?.compactMap { capture(id: $0) }
    }

    /// Whether the list's base — every project it could show, nothing
    /// switched on — is empty. Nil without an index.
    func libraryIsEmpty(for query: ProjectListQuery) -> Bool? {
        projectIDs(for: query.base).map(\.isEmpty)
    }

    /// How many projects each kind filter would show, counted after the
    /// search and the chips have had their say — the filter bar's numbers.
    func listCounts(for query: ProjectListQuery, filters: [CaptureFilter]) -> [CaptureFilter: Int]? {
        guard let index = libraryIndex else { return nil }
        do {
            let counts = try index.categoryCounts(query.indexQuery)
            return filters.reduce(into: [:]) { result, filter in
                switch filter {
                case .all: result[filter] = counts.values.reduce(0, +)
                case .photos: result[filter] = counts[.photo] ?? 0
                case .interval: result[filter] = counts[.interval] ?? 0
                case .video: result[filter] = counts[.video] ?? 0
                case .scans: result[filter] = counts[.scan] ?? 0
                }
            }
        } catch {
            LLog("index: count query failed (\(error))")
            return nil
        }
    }

    /// The tag chips: the taxonomy's tags present in the list's base, in
    /// the taxonomy's own order, then the hand-typed ones alphabetically —
    /// `presentSceneTags`'s rule over the index's counts. Nil without one.
    func tagChips(listsScans: Bool) -> [String]? {
        guard let index = libraryIndex else { return nil }
        do {
            let present = Set(try index.tagCounts(excludingScans: !listsScans).map(\.tag))
            let custom = present.filter(SceneMetadata.isCustom)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            return SceneMetadata.orderedTaxonomy.filter(present.contains) + custom
        } catch {
            LLog("index: tag query failed (\(error))")
            return nil
        }
    }

    /// How many live projects the library holds — the index's count (M3).
    var liveProjectCount: Int {
        (try? libraryIndex?.storageTotals().liveProjects) ?? 0
    }

    // MARK: - Whole-library reads that are not lists (M3)

    /// The live project ids the index answers for a query, newest capture
    /// first unless the query says otherwise. Empty without an index.
    func liveProjectIDs(_ query: LibraryIndex.ProjectQuery = LibraryIndex.ProjectQuery()) -> [UUID] {
        (try? libraryIndex?.projectIDs(query)) ?? []
    }

    /// The records behind `liveProjectIDs`, one document each — for the few
    /// passes that want several records in hand (a builder's candidates, a
    /// storage list); a list never does.
    func liveCaptures(_ query: LibraryIndex.ProjectQuery = LibraryIndex.ProjectQuery()) -> [CaptureProject] {
        liveProjectIDs(query).compactMap { capture(id: $0) }
    }

    /// The newest live project that satisfies `test` — documents are read
    /// newest first until one does, so the common case reads one.
    func newestCapture(_ query: LibraryIndex.ProjectQuery = LibraryIndex.ProjectQuery(),
                       where test: (CaptureProject) -> Bool = { _ in true }) -> CaptureProject? {
        for id in liveProjectIDs(query) {
            if let capture = capture(id: id), test(capture) { return capture }
        }
        return nil
    }

    /// The index changed under the lists: forget every remembered answer.
    /// Called on the main actor by the persister's and the asset store's
    /// callbacks.
    func noteIndexChanged() {
        indexRevision &+= 1
        listCache.removeAll()
    }
}

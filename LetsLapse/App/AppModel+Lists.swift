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

extension AppModel {

    // MARK: - One record by id

    /// One project's record, by id — the one way a screen gets a record it
    /// was handed the id of (M2). Backed by the loaded arrays for now; M3
    /// puts the per-project document cache behind the same name.
    func capture(id: UUID) -> CaptureProject? {
        guard let index = captureIndexByID[id], captures.indices.contains(index), captures[index].id == id else {
            return captures.first { $0.id == id }
        }
        return captures[index]
    }

    /// One blend's record, by id.
    func blend(id: UUID) -> BlendProject? {
        blends.first { $0.id == id }
    }

    // MARK: - The lists

    /// The ids a list renders, in order, or nil when the library has no
    /// index to ask (the screens then sort and filter the arrays as they
    /// did before M2). Remembered per question until the index changes.
    func projectIDs(for query: ProjectListQuery) -> [UUID]? {
        guard let index = libraryIndex else { return nil }
        if let cached = listCache[query], cached.revision == indexRevision { return cached.ids }
        do {
            let ids = try index.projectIDs(query.indexQuery)
            listCache[query] = (indexRevision, ids)
            return ids
        } catch {
            LLog("index: list query failed (\(error)) — falling back to the arrays")
            return nil
        }
    }

    /// The records behind `projectIDs(for:)`, in the same order; a project
    /// the index lists but the arrays do not know yet (a row landing ahead
    /// of the model) is skipped rather than shown blank.
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

    /// The index changed under the lists: forget every remembered answer.
    /// Called on the main actor by the persister's and the asset store's
    /// callbacks.
    func noteIndexChanged() {
        indexRevision &+= 1
        listCache.removeAll()
    }
}

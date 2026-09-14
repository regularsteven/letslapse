import Foundation

#if DEBUG
/// The list screens' launch hooks (data model M2's verification rig):
/// `LL_FILTER=all|photos|interval|video|scans` selects the kind filter,
/// `LL_QUERY=<words>` fills the search field, `LL_CHIPS=tag,tag` lights
/// tag chips, and `LL_DUMP_ORDER=1` logs the ids a list rendered, in
/// order, so the order under every sort can be diffed as text before and
/// after a change rather than read off a screenshot. Sort keys need no
/// hook: `-projects.sortKey`, `-projects.sortAscending`, `-gallery.sortKey`
/// and `-gallery.sortAscending` are `@AppStorage` and take launch arguments.
enum ListDebugHooks {
    static var filter: CaptureFilter? {
        guard let raw = ProcessInfo.processInfo.environment["LL_FILTER"] else { return nil }
        return CaptureFilter.allCases.first { $0.rawValue.lowercased() == raw.lowercased() }
    }

    static var queryText: String? {
        ProcessInfo.processInfo.environment["LL_QUERY"]
    }

    static var chips: Set<String>? {
        guard let raw = ProcessInfo.processInfo.environment["LL_CHIPS"] else { return nil }
        return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    static var dumpsOrder: Bool {
        ProcessInfo.processInfo.environment["LL_DUMP_ORDER"] != nil
    }

    /// One line per render that changed the order: `order <screen> <sort>
    /// <asc|desc> filter=<f> query="…" chips=<…> total=<n>: id,id,…`.
    static func dump(screen: String, sort: String, ascending: Bool, filter: CaptureFilter, query: SceneQuery, ids: [UUID]) {
        guard dumpsOrder else { return }
        LLog("order \(screen) \(sort) \(ascending ? "asc" : "desc") filter=\(filter.rawValue) query=\"\(query.text)\" chips=\(query.tags.sorted().joined(separator: ",")) total=\(ids.count): "
             + ids.map { String($0.uuidString.prefix(8)) }.joined(separator: ","))
    }
}
#endif

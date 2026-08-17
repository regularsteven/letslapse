import Foundation

/// One document inside a scan: a named run of pages the operator meant as a
/// single thing.
///
/// A scanner session is a *sitting*, not a document — someone sits down with a
/// pile of receipts and photographs all of them in one go. Before this the two
/// were the same object, so a sitting that produced eleven separate receipts
/// exported as one eleven-page thing that no filing system anywhere wants.
///
/// Pages are held by **number**, never by position: pages keep their numbers
/// when one is deleted (see `AppModel.deleteScanPage`), so a set of twelve
/// missing its third is 1, 2, 4…12 and an index-based group would silently
/// re-point at the wrong photograph the first time anything was thrown away.
struct ScanDocument: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    /// "Document 1" until someone renames it. Kept as a stored string rather
    /// than derived from the position, because the whole point of a name is
    /// that it survives the thing next to it moving.
    var name: String
    /// 1-based page numbers, in the order they belong in the document.
    var pageIndices: [Int]
    var createdAt: Date

    init(id: UUID = UUID(), name: String, pageIndices: [Int], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.pageIndices = pageIndices
        self.createdAt = createdAt
    }

    var pageCountLine: String {
        pageIndices.count == 1 ? "1 page" : "\(pageIndices.count) pages"
    }
}

/// A document paired with the pages it actually resolved to — what the detail
/// screen draws a section from.
struct ScanDocumentSection: Identifiable, Equatable {
    let document: ScanDocument
    let pages: [ScanPage]

    var id: UUID { document.id }
}

// MARK: - Sidecar

/// `documents.json`, beside the frames and the timestamp sidecar.
///
/// **Purely additive.** A session with no file is one document containing every
/// page, which is exactly what every scan made before this existed is — so the
/// absence of the file is a meaningful, correct answer rather than a migration
/// waiting to happen. Nothing reads a group without going through
/// `resolve(_:pageNumbers:)`, which is what keeps that promise in one place.
enum ScanDocumentStore {

    static let fileName = "documents.json"

    /// The id the implicit "everything is one document" group takes.
    ///
    /// **Fixed, not fresh.** `resolve` is called on every load, and a
    /// synthesized group with a new `UUID()` each time is a group whose
    /// identity changes under anything holding it — a rename in flight, a set
    /// of ticked documents in the export sheet, a "move page here" that then
    /// matches nothing and silently does nothing. One constant makes those
    /// comparisons true. Two sessions sharing it is not a collision: the id is
    /// only ever compared within one session.
    static let implicitID = UUID(uuidString: "5CA00000-0000-4000-A000-00000000D0C1")!

    static func url(in sessionFolder: URL) -> URL {
        sessionFolder.appendingPathComponent(fileName)
    }

    /// What the file says, unresolved — an empty array when there is no file,
    /// which the resolver reads as "one implicit document".
    static func load(from sessionFolder: URL) -> [ScanDocument] {
        let file = url(in: sessionFolder)
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ScanDocument].self, from: data)) ?? []
    }

    /// Writes the groups, or removes the file when there is nothing left to say
    /// — a session that has been flattened back to one document should look
    /// like one that never had groups, not like one carrying an empty list.
    static func save(_ documents: [ScanDocument], to sessionFolder: URL) throws {
        let file = url(in: sessionFolder)
        guard documents.count > 1 else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: sessionFolder, withIntermediateDirectories: true)
        try encoder.encode(documents).write(to: file, options: .atomic)
    }

    /// The groups as they apply to the pages that are really there.
    ///
    /// Three repairs, all of them silent on purpose — none of these states is
    /// the operator's fault or their problem:
    ///
    /// * a page number a group claims but the session no longer holds (deleted)
    ///   is dropped;
    /// * a group left with no pages is dropped;
    /// * a page no group claims is appended to the last group — the case a
    ///   crash mid-run leaves behind, and the one a page recovered by some
    ///   later repair would produce. Losing it from the screen entirely would
    ///   be much worse than filing it at the end.
    ///
    /// With no groups at all the answer is a single document holding every
    /// page, so callers never have to special-case the flat session.
    static func resolve(_ documents: [ScanDocument], pageNumbers: [Int]) -> [ScanDocument] {
        let available = Set(pageNumbers)
        var claimed = Set<Int>()
        var resolved: [ScanDocument] = []
        for document in documents {
            var pages: [Int] = []
            for number in document.pageIndices
            where available.contains(number) && !claimed.contains(number) {
                pages.append(number)
                claimed.insert(number)
            }
            guard !pages.isEmpty else { continue }
            var copy = document
            copy.pageIndices = pages
            resolved.append(copy)
        }
        let unclaimed = pageNumbers.filter { !claimed.contains($0) }
        if !unclaimed.isEmpty {
            if resolved.isEmpty {
                resolved = [ScanDocument(
                    id: implicitID, name: defaultName(index: 0), pageIndices: unclaimed)]
            } else {
                resolved[resolved.count - 1].pageIndices.append(contentsOf: unclaimed)
            }
        }
        return resolved
    }

    /// "Document 3" — the name a newly opened group takes.
    ///
    /// Counted off the **highest number already used**, not off the group
    /// count: closing document 2 and opening another should give "Document 3",
    /// and a set where one group was renamed "Invoices" should not hand its
    /// number out again.
    static func nextName(after documents: [ScanDocument]) -> String {
        let used = documents.compactMap { document -> Int? in
            guard document.name.hasPrefix("Document ") else { return nil }
            return Int(document.name.dropFirst("Document ".count))
        }
        return "Document \((used.max() ?? documents.count) + 1)"
    }

    static func defaultName(index: Int) -> String { "Document \(index + 1)" }

    /// Builds the groups a finished run produced, from the page numbers that
    /// opened each one.
    ///
    /// `starts` is the capture screen's record: the page number that began each
    /// document. Anything before the first start (there shouldn't be, but a
    /// mis-ordered signal must not lose a page) joins the first group.
    static func build(starts: [Int], pageNumbers: [Int]) -> [ScanDocument] {
        let pages = pageNumbers.sorted()
        guard !pages.isEmpty else { return [] }
        let boundaries = starts.sorted().filter { $0 > (pages.first ?? 1) }
        var groups: [[Int]] = [[]]
        for number in pages {
            if boundaries.contains(number), !(groups.last?.isEmpty ?? true) {
                groups.append([])
            }
            groups[groups.count - 1].append(number)
        }
        let stamp = Date()
        return groups.filter { !$0.isEmpty }.enumerated().map { index, pages in
            ScanDocument(
                name: defaultName(index: index), pageIndices: pages, createdAt: stamp)
        }
    }
}

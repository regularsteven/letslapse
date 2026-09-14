import Foundation

/// `lapse audit --rebuild-index` (data model Phase 2): reconstructs a
/// `library.json` from the per-project `project.json` documents and diffs it
/// against the real one, record by record, after both are put into one
/// canonical form. An empty diff is the acceptance test for the dual write —
/// and, from Phase 3 on, the proof that deleting the index loses nothing.
///
/// JSON-level like the audit (`JSONSerialization`, no app types), so it runs
/// against any root and still reads what a strict decoder would refuse.
/// The one piece of schema it needs is `ProjectDocumentFormat.dateKeys`:
/// the manifest writes dates as seconds since 2001 and the documents as
/// ISO-8601, so both sides are canonicalised to the document's string form
/// — which rounds to the millisecond, the precision Part 1 §7 set for this
/// comparison — before they are compared.
///
/// Documents are read from `Projects/<id>/project.json` and, for tombstoned
/// projects, from `Projects/.trash/<id>/project.json`: a deleted project's
/// folder carries its own tombstone into the trash, so the rebuild can
/// reproduce the manifest's deleted records too. Collections span projects
/// and have no per-project document; they are carried over from the real
/// index verbatim (Phase 3 gives them their own file).
///
/// Nothing here writes unless asked (`rebuiltManifest`).
public struct LibraryIndexRebuild {

    public struct Difference: Equatable, CustomStringConvertible {
        /// `capture <id>` or `blend <id>`.
        public var record: String
        /// The key path inside the record (`adjustments.exposure`,
        /// `sourceFileNames[3]`), or `""` for the whole record.
        public var path: String
        public var index: String
        public var document: String

        public init(record: String, path: String, index: String, document: String) {
            self.record = record
            self.path = path
            self.index = index
            self.document = document
        }

        public var description: String {
            "\(record) · \(path.isEmpty ? "(record)" : path): index \(index) · document \(document)"
        }
    }

    public struct Report {
        public var root: String
        public var indexReadable = false
        public var indexError: String?
        public var documentsRead = 0
        public var documentsInTrash = 0
        /// `<folder>: <why>` for every document that could not be read.
        public var unreadableDocuments: [String] = []
        /// Folders under `Projects/` (live and trash) with no document at all.
        public var foldersWithoutDocument: [String] = []
        /// Documents whose `capture.id` is not the folder they sit in.
        public var misfiledDocuments: [String] = []
        public var documentFormatVersions: [Int: Int] = [:]

        public var indexCaptures = 0
        public var indexBlends = 0
        public var rebuiltCaptures = 0
        public var rebuiltBlends = 0

        /// Records in the index with no document behind them.
        public var onlyInIndex: [String] = []
        /// Records in documents that the index does not list.
        public var onlyInDocuments: [String] = []
        public var differences: [Difference] = []
        /// True when `Collections/collections.json` exists and was compared.
        public var collectionsDocumentRead = false
        public var indexCollections = 0
        public var documentCollections = 0

        /// True when the index and the documents describe the same records.
        public var identical: Bool {
            indexReadable && onlyInIndex.isEmpty && onlyInDocuments.isEmpty && differences.isEmpty
        }
    }

    // MARK: - Running

    /// `root` may be the storage root (holding `Projects/`) or `Projects/`.
    public static func run(root: URL) -> Report {
        let projects = projectsFolder(under: root)
        var report = Report(root: root.path)

        // 1. The real index.
        var indexCaptures: [String: [String: Any]] = [:]
        var indexBlends: [String: [String: Any]] = [:]
        switch readIndex(at: projects.appendingPathComponent("library.json")) {
        case .success(let object):
            report.indexReadable = true
            for capture in object["captures"] as? [[String: Any]] ?? [] {
                guard let id = recordID(capture) else { continue }
                indexCaptures[id] = capture
            }
            for blend in object["blends"] as? [[String: Any]] ?? [] {
                guard let id = recordID(blend) else { continue }
                indexBlends[id] = blend
            }
        case .failure(let error):
            report.indexError = error.localizedDescription
        }
        report.indexCaptures = indexCaptures.count
        report.indexBlends = indexBlends.count

        // 2. The documents.
        let documents = readDocuments(in: projects, report: &report)
        var rebuiltCaptures: [String: [String: Any]] = [:]
        var rebuiltBlends: [String: [String: Any]] = [:]
        for document in documents {
            rebuiltCaptures[document.captureID] = document.capture
            for blend in document.blends {
                guard let id = recordID(blend) else { continue }
                rebuiltBlends[id] = blend
            }
        }
        report.rebuiltCaptures = rebuiltCaptures.count
        report.rebuiltBlends = rebuiltBlends.count

        // 3. The diff, in canonical form.
        guard report.indexReadable else { return report }
        compare(kind: "capture", index: indexCaptures, documents: rebuiltCaptures, report: &report)
        compare(kind: "blend", index: indexBlends, documents: rebuiltBlends, report: &report)

        // 4. Collections, when they have their own document.
        var documentCollections: [String: [String: Any]] = [:]
        if let documented = readCollectionsDocument(root: projects.deletingLastPathComponent()) {
            report.collectionsDocumentRead = true
            for collection in documented {
                guard let id = recordID(collection) else { continue }
                documentCollections[id] = collection
            }
            report.documentCollections = documentCollections.count
        }
        if case .success(let object) = readIndex(at: projects.appendingPathComponent("library.json")) {
            var indexCollections: [String: [String: Any]] = [:]
            for collection in object["collections"] as? [[String: Any]] ?? [] {
                guard let id = recordID(collection) else { continue }
                indexCollections[id] = collection
            }
            report.indexCollections = indexCollections.count
            if report.collectionsDocumentRead {
                compare(kind: "collection", index: indexCollections, documents: documentCollections, report: &report)
            }
        }
        return report
    }

    /// The collections in `<root>/Collections/collections.json`, or nil when
    /// there is no such file (or it does not parse).
    static func readCollectionsDocument(root: URL) -> [[String: Any]]? {
        let url = ProjectDocumentFormat.collectionsURL(inRoot: root)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["collections"] as? [[String: Any]] ?? []
    }

    /// The manifest the documents describe, encoded the way the app encodes
    /// `library.json` (sorted keys, seconds-since-2001 dates): what a Phase 4
    /// repair would put in place of an unreadable index, and what
    /// `--rebuild-index --out` hands an older build or a tool. Marked
    /// `"generated": true` like every export the app writes since M1.
    /// Collections come from their own document; the schema counter from
    /// the real index when it is readable.
    public static func rebuiltManifest(root: URL) throws -> Data {
        let projects = projectsFolder(under: root)
        var report = Report(root: root.path)
        let documents = readDocuments(in: projects, report: &report)
        var collections: [Any] = []
        var schema = ManifestMigrations.current
        // The collections' own document first (Phase 4); the index's copy
        // only for a library from before it existed.
        if let documented = readCollectionsDocument(root: projects.deletingLastPathComponent()) {
            collections = documented.map { manifestDates(in: $0, keys: ProjectDocumentFormat.collectionDateKeys) }
        } else if case .success(let object) = readIndex(at: projects.appendingPathComponent("library.json")) {
            collections = object["collections"] as? [Any] ?? []
        }
        if case .success(let object) = readIndex(at: projects.appendingPathComponent("library.json")) {
            schema = max(schema, object["gradingSchemaVersion"] as? Int ?? 0)
        }
        // The app's own order: live captures newest first, then the
        // tombstones; blends the same way.
        func seconds(_ record: [String: Any], _ key: String) -> Double {
            (record[key] as? NSNumber)?.doubleValue ?? 0
        }
        let captures = documents.map { manifestRecord($0.capture) }
        let blends = documents.flatMap { $0.blends.map(manifestRecord) }
        func ordered(_ records: [[String: Any]]) -> [[String: Any]] {
            let live = records.filter { $0["deletedAt"] == nil }.sorted { seconds($0, "createdAt") > seconds($1, "createdAt") }
            let gone = records.filter { $0["deletedAt"] != nil }
            return live + gone
        }
        let manifest: [String: Any] = [
            "captures": ordered(captures),
            "blends": ordered(blends),
            "collections": collections,
            "gradingSchemaVersion": schema,
            // A rebuilt manifest is by definition a generated one (M1).
            LibraryExportFormat.generatedKey: true,
        ]
        return try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Canonical form and diff

    /// A record with every date key, at any depth, in the document's string
    /// form, whichever encoding it arrived in. Dates already written as
    /// strings are re-formatted through the same formatter, so a whole-
    /// second stamp and a millisecond stamp of the same instant agree.
    public static func canonical(_ record: [String: Any]) -> [String: Any] {
        let keys = ProjectDocumentFormat.dateKeys.union(ProjectDocumentFormat.collectionDateKeys)
        return canonicalDates(in: record, keys: keys) as? [String: Any] ?? record
    }

    private static func canonicalDates(in value: Any, keys: Set<String>) -> Any {
        if let object = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, inner) in object {
                if keys.contains(key) {
                    if let number = inner as? NSNumber, !(inner is Bool) {
                        out[key] = ProjectDocumentFormat.documentDate(fromManifestSeconds: number.doubleValue)
                        continue
                    } else if let text = inner as? String,
                              let seconds = ProjectDocumentFormat.manifestSeconds(fromDocumentDate: text) {
                        out[key] = ProjectDocumentFormat.documentDate(fromManifestSeconds: seconds)
                        continue
                    }
                }
                out[key] = canonicalDates(in: inner, keys: keys)
            }
            return out
        }
        if let list = value as? [Any] { return list.map { canonicalDates(in: $0, keys: keys) } }
        return value
    }

    /// A document record as the manifest writes it: date strings under
    /// `keys`, at any depth, back to seconds since 2001.
    static func manifestDates(in record: [String: Any], keys: Set<String>) -> [String: Any] {
        manifestDates(in: record as Any, keys: keys) as? [String: Any] ?? record
    }

    private static func manifestDates(in value: Any, keys: Set<String>) -> Any {
        if let object = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, inner) in object {
                if keys.contains(key), let text = inner as? String,
                   let seconds = ProjectDocumentFormat.manifestSeconds(fromDocumentDate: text) {
                    out[key] = seconds
                } else {
                    out[key] = manifestDates(in: inner, keys: keys)
                }
            }
            return out
        }
        if let list = value as? [Any] { return list.map { manifestDates(in: $0, keys: keys) } }
        return value
    }

    /// A capture or blend document record as the manifest writes it.
    static func manifestRecord(_ record: [String: Any]) -> [String: Any] {
        manifestDates(in: record, keys: ProjectDocumentFormat.dateKeys)
    }

    /// Every leaf that differs between two JSON values, by key path.
    public static func differences(between index: Any?, and document: Any?, record: String, path: String = "")
        -> [Difference]
    {
        var found: [Difference] = []
        diff(index, document, record: record, path: path, into: &found)
        return found
    }

    private static func diff(_ a: Any?, _ b: Any?, record: String, path: String, into found: inout [Difference]) {
        switch (a, b) {
        case (nil, nil):
            return
        case (let x as [String: Any], let y as [String: Any]):
            for key in Set(x.keys).union(y.keys).sorted() {
                diff(x[key], y[key], record: record, path: path.isEmpty ? key : "\(path).\(key)", into: &found)
            }
        case (let x as [Any], let y as [Any]):
            if x.count != y.count {
                found.append(Difference(record: record, path: path, index: "\(x.count) items", document: "\(y.count) items"))
                return
            }
            for (offset, pair) in zip(x, y).enumerated() {
                diff(pair.0, pair.1, record: record, path: "\(path)[\(offset)]", into: &found)
            }
        default:
            if !leafEqual(a, b) {
                found.append(Difference(record: record, path: path, index: describe(a), document: describe(b)))
            }
        }
    }

    private static func leafEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case (let x as NSNumber, let y as NSNumber): return numbersEqual(x, y)
        case (let x as String, let y as String): return x == y
        case (is NSNull, is NSNull): return true
        default: return false
        }
    }

    /// Integers compare exactly. Fractions compare to a relative 1e-9:
    /// `JSONSerialization` spells a double with 17 digits and reads a
    /// 17-digit literal back as an `NSDecimalNumber` whose `doubleValue` is
    /// off in the last place, so the same slider value can arrive as
    /// `-0.093221605` from one encoder and `-0.093221604999999999` from the
    /// other. No edit moves a value by a billionth.
    private static func numbersEqual(_ x: NSNumber, _ y: NSNumber) -> Bool {
        if x == y { return true }
        let a = x.doubleValue, b = y.doubleValue
        let integral = a == a.rounded() && b == b.rounded() && abs(a) < 9e15 && abs(b) < 9e15
        if integral { return a == b }
        return abs(a - b) <= 1e-9 * max(abs(a), abs(b), 1)
    }

    private static func describe(_ value: Any?) -> String {
        guard let value else { return "absent" }
        if value is NSNull { return "null" }
        if let text = value as? String { return "\"\(text)\"" }
        if let number = value as? NSNumber { return number.stringValue }
        if let list = value as? [Any] { return "\(list.count) items" }
        if let object = value as? [String: Any] { return "{\(object.keys.sorted().joined(separator: ","))}" }
        return "\(value)"
    }

    // MARK: - Reading

    struct Document {
        /// The folder name under `Projects/` or `Projects/.trash/`.
        var folder: String
        var inTrash: Bool
        var captureID: String
        var capture: [String: Any]
        var blends: [[String: Any]]
    }

    /// `root` is the storage root when it holds a `Projects/` folder, and
    /// the `Projects/` folder itself otherwise — the manifest's presence is
    /// not the test, because the repair path runs exactly when the manifest
    /// has just been moved aside.
    static func projectsFolder(under root: URL) -> URL {
        let nested = root.appendingPathComponent("Projects", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return nested
        }
        return root
    }

    static func readIndex(at url: URL) -> Result<[String: Any], Error> {
        do {
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return .success(object)
        } catch {
            return .failure(error)
        }
    }

    static func recordID(_ record: [String: Any]) -> String? {
        (record["id"] as? String)?.uppercased()
    }

    /// Every document under `Projects/<id>/` and `Projects/.trash/<id>/`.
    static func readDocuments(in projects: URL, report: inout Report) -> [Document] {
        var documents: [Document] = []
        let fm = FileManager.default
        let trash = projects.appendingPathComponent(".trash", isDirectory: true)
        for (container, inTrash) in [(projects, false), (trash, true)] {
            let names = ((try? fm.contentsOfDirectory(atPath: container.path)) ?? [])
                .filter { !$0.hasPrefix(".") && $0 != "library.json" && UUID(uuidString: $0) != nil }
                .sorted()
            for name in names {
                let folder = container.appendingPathComponent(name, isDirectory: true)
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                let url = ProjectDocumentFormat.url(inProjectFolder: folder)
                guard fm.fileExists(atPath: url.path) else {
                    report.foldersWithoutDocument.append(inTrash ? ".trash/\(name)" : name)
                    continue
                }
                do {
                    let data = try Data(contentsOf: url)
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let capture = object["capture"] as? [String: Any],
                          let captureID = recordID(capture) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    let version = object["formatVersion"] as? Int ?? 0
                    report.documentFormatVersions[version, default: 0] += 1
                    if captureID != name.uppercased() { report.misfiledDocuments.append(name) }
                    documents.append(Document(
                        folder: name, inTrash: inTrash, captureID: captureID, capture: capture,
                        blends: object["blends"] as? [[String: Any]] ?? []))
                    report.documentsRead += 1
                    if inTrash { report.documentsInTrash += 1 }
                } catch {
                    report.unreadableDocuments.append("\(inTrash ? ".trash/" : "")\(name): \(error.localizedDescription)")
                }
            }
        }
        return documents
    }

    private static func compare(
        kind: String, index: [String: [String: Any]], documents: [String: [String: Any]], report: inout Report
    ) {
        for id in Set(index.keys).union(documents.keys).sorted() {
            let name = "\(kind) \(id)"
            switch (index[id], documents[id]) {
            case (let a?, nil):
                _ = a
                report.onlyInIndex.append(name)
            case (nil, let b?):
                _ = b
                report.onlyInDocuments.append(name)
            case (let a?, let b?):
                report.differences.append(contentsOf: differences(between: canonical(a), and: canonical(b), record: name))
            case (nil, nil):
                break
            }
        }
    }

    // MARK: - Rendering

    public static func text(_ r: Report) -> String {
        var lines: [String] = []
        lines.append("lapse audit --rebuild-index · \(r.root)")
        lines.append("  index: \(r.indexReadable ? "decoded" : "UNREADABLE (\(r.indexError ?? "?"))") · captures \(r.indexCaptures) · blends \(r.indexBlends)")
        let versions = r.documentFormatVersions.sorted { $0.key < $1.key }.map { "v\($0.key) ×\($0.value)" }.joined(separator: ", ")
        lines.append("  documents: \(r.documentsRead) read (\(r.documentsInTrash) in .trash) · captures \(r.rebuiltCaptures) · blends \(r.rebuiltBlends)" + (versions.isEmpty ? "" : " · \(versions)"))
        if !r.unreadableDocuments.isEmpty {
            lines.append("  unreadable documents: \(r.unreadableDocuments.count)")
            for line in r.unreadableDocuments.prefix(8) { lines.append("      \(line)") }
        }
        if !r.foldersWithoutDocument.isEmpty {
            lines.append("  folders with no document: \(r.foldersWithoutDocument.count)  [" + r.foldersWithoutDocument.prefix(5).joined(separator: ", ") + (r.foldersWithoutDocument.count > 5 ? ", …" : "") + "]")
        }
        if !r.misfiledDocuments.isEmpty {
            lines.append("  documents whose capture id is not their folder: \(r.misfiledDocuments.count)  [" + r.misfiledDocuments.prefix(5).joined(separator: ", ") + "]")
        }
        lines.append("")
        lines.append("diff (index vs documents, canonical form)")
        lines.append("  only in the index: \(r.onlyInIndex.count)" + list(r.onlyInIndex))
        lines.append("  only in the documents: \(r.onlyInDocuments.count)" + list(r.onlyInDocuments))
        if r.collectionsDocumentRead {
            lines.append("  collections: \(r.indexCollections) in the index · \(r.documentCollections) in Collections/collections.json")
        }
        lines.append("  differing records: \(Set(r.differences.map(\.record)).count) · differing fields: \(r.differences.count)")
        for difference in r.differences.prefix(24) { lines.append("      \(difference)") }
        if r.differences.count > 24 { lines.append("      … \(r.differences.count - 24) more") }
        lines.append("")
        lines.append(r.identical ? "REBUILD IDENTICAL" : "REBUILD DIFFERS")
        return lines.joined(separator: "\n")
    }

    public static func json(_ r: Report) throws -> Data {
        let payload: [String: Any] = [
            "root": r.root,
            "index": ["readable": r.indexReadable, "error": r.indexError ?? "", "captures": r.indexCaptures, "blends": r.indexBlends] as [String: Any],
            "documents": [
                "read": r.documentsRead, "inTrash": r.documentsInTrash,
                "captures": r.rebuiltCaptures, "blends": r.rebuiltBlends,
                "unreadable": r.unreadableDocuments, "foldersWithoutDocument": r.foldersWithoutDocument,
                "misfiled": r.misfiledDocuments,
                "formatVersions": Dictionary(uniqueKeysWithValues: r.documentFormatVersions.map { (String($0.key), $0.value) }),
            ] as [String: Any],
            "collections": ["documentRead": r.collectionsDocumentRead, "index": r.indexCollections, "document": r.documentCollections] as [String: Any],
            "diff": [
                "onlyInIndex": r.onlyInIndex,
                "onlyInDocuments": r.onlyInDocuments,
                "differences": r.differences.map { ["record": $0.record, "path": $0.path, "index": $0.index, "document": $0.document] },
                "identical": r.identical,
            ] as [String: Any],
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    private static func list(_ items: [String]) -> String {
        items.isEmpty ? "" : "  [" + items.prefix(6).joined(separator: ", ") + (items.count > 6 ? ", …" : "") + "]"
    }
}

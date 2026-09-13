import XCTest
@testable import LetsLapseKit

/// The SQLite index over a synthetic tree of project documents and asset
/// records: rebuilt from the files, paged, sorted, filtered, searched, kept
/// current one document at a time — and thrown away without loss.
final class LibraryIndexTests: XCTestCase {

    private var root: URL!
    private var projects: URL { root.appendingPathComponent("Projects", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projects.appendingPathComponent(".trash"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func id(_ n: Int) -> String { String(format: "%08X-0000-4000-8000-000000000000", n) }

    @discardableResult
    private func writeProject(
        _ n: Int, kind: String = "photos", name: String? = nil, created: Double, added: Double? = nil,
        modified: Double? = nil, frames: Int = 3, size: Int? = nil, tags: [String]? = nil, elements: [String]? = nil,
        deleted: Double? = nil, blends: Int = 0, captureMode: String? = nil, inTrash: Bool = false
    ) throws -> URL {
        var capture: [String: Any] = [
            "id": id(n), "kind": kind, "createdAt": ProjectDocumentFormat.documentDate(fromManifestSeconds: created),
            "originalName": "\(frames) photos", "mode": kind == "video" ? "Video" : "Photo",
            "sourceFileNames": (1...frames).map { "source/frame-\($0).dng" }, "originID": id(n),
            "sourceWidth": 4032, "sourceHeight": 3024, "presetState": ["kind": "original"],
        ]
        if let name { capture["name"] = name }
        if let added { capture["addedAt"] = ProjectDocumentFormat.documentDate(fromManifestSeconds: added) }
        if let modified { capture["modifiedAt"] = ProjectDocumentFormat.documentDate(fromManifestSeconds: modified) }
        if let size { capture["sizeBytes"] = size }
        if let tags { capture["sceneTags"] = tags }
        if let elements { capture["sceneElements"] = elements }
        if let deleted { capture["deletedAt"] = ProjectDocumentFormat.documentDate(fromManifestSeconds: deleted) }
        if let captureMode { capture["captureMode"] = captureMode }
        let blendRecords: [[String: Any]] = (0..<blends).map { b in
            ["id": String(format: "%08X-%04X-4000-8000-000000000000", n, b), "captureID": id(n), "kind": "video",
             "createdAt": ProjectDocumentFormat.documentDate(fromManifestSeconds: created + Double(b)),
             "outputFileName": "blends/\(b).mp4", "summary": "\(b)", "linearLight": true, "useRamp": false,
             "rampStart": 0, "rampEnd": 0, "curve": "linear", "warp": ["bounds": [], "speeds": [], "seams": []]]
        }
        let folder = (inTrash ? projects.appendingPathComponent(".trash") : projects).appendingPathComponent(id(n), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let object: [String: Any] = ["formatVersion": 2, "capture": capture, "blends": blendRecords]
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: ProjectDocumentFormat.url(inProjectFolder: folder))
        return folder
    }

    private func writeAssets(in folder: URL, _ records: [AssetRecord], project: ProjectMetadata? = nil) throws {
        for record in records { try AssetRecords.append(record, to: AssetRecords.url(inProjectFolder: folder)) }
        if let project { try project.write(inProjectFolder: folder) }
    }

    private func openIndex() throws -> LibraryIndex {
        try LibraryIndex(at: LibraryIndex.url(inRoot: root))
    }

    private func writeLibrary() throws {
        try writeProject(1, name: "Charles Bridge at night", created: 100, added: 500, modified: 900, size: 30, tags: ["urban", "skyWeather"], elements: ["bridge", "river"], blends: 2)
        try writeProject(2, kind: "video", name: "Tram switch", created: 200, added: 400, size: 10, tags: ["urban", "vehicles"], blends: 1)
        try writeProject(3, created: 300, added: 300, modified: 950, size: 20, tags: ["water"])
        try writeProject(4, created: 50, added: 600, size: 40, captureMode: "scanner")
        try writeProject(5, created: 400, deleted: 999, inTrash: true)
        let folder = projects.appendingPathComponent(id(3))
        var frame = AssetRecord(name: "source/frame-1.dng")
        frame.bytes = 100; frame.hash = "sha256:aa"
        var imported = AssetMetadata()
        imported.title = "Vltava dusk"; imported.rating = 5; imported.keywords = ["dusk", "prague"]
        imported.camera = AssetMetadata.Camera(); imported.camera?.make = "SONY"; imported.camera?.model = "ILCE-7M4"
        frame.imported = imported
        var other = AssetRecord(name: "source/frame-2.dng")
        other.bytes = 100
        var projectMeta = ProjectMetadata()
        var edited = AssetMetadata(); edited.caption = "Evening on the river"; edited.location = AssetMetadata.Location(); edited.location?.city = "Prague"
        projectMeta.edited = edited
        try writeAssets(in: folder, [frame, other], project: projectMeta)
    }

    // MARK: - Tests

    func testRebuildIndexesEveryDocumentAndAssetFile() throws {
        try writeLibrary()
        let index = try openIndex()
        let outcome = try index.rebuild(fromProjectsFolder: projects)
        XCTAssertEqual(outcome.projects, 5)
        XCTAssertEqual(outcome.blends, 3)
        XCTAssertEqual(outcome.assets, 2)
        XCTAssertEqual(outcome.unreadableDocuments, [])
        let counts = try index.counts()
        XCTAssertEqual(counts, LibraryIndex.Counts(projects: 4, deletedProjects: 1, blends: 3, assets: 2, hashedAssets: 1, searchRows: 6))
        XCTAssertNotNil(index.meta("builtAt"))
        let verification = try index.verify(againstProjectsFolder: projects)
        XCTAssertTrue(verification.consistent)
        XCTAssertEqual(verification.documents, 5)
        // The trashed project is indexed under its trash folder.
        XCTAssertEqual(try index.project(id: UUID(uuidString: id(5))!)?.folder, ".trash/\(id(5))")
        XCTAssertNotNil(try index.project(id: UUID(uuidString: id(5))!)?.deletedAt)
    }

    func testPagesSortsAndFilters() throws {
        try writeLibrary()
        let index = try openIndex()
        try index.rebuild(fromProjectsFolder: projects)

        var query = LibraryIndex.ProjectQuery()
        query.limit = 2
        var page = try index.projects(query)
        XCTAssertEqual(page.total, 4)
        XCTAssertEqual(page.rows.map(\.id.uuidString), [id(3), id(2)], "newest capture first, deleted excluded")
        query.offset = 2
        page = try index.projects(query)
        XCTAssertEqual(page.rows.map(\.id.uuidString), [id(1), id(4)])
        XCTAssertEqual(page.offset, 2)

        query = LibraryIndex.ProjectQuery(); query.sort = .added; query.ascending = true
        XCTAssertEqual(try index.projects(query).rows.map(\.id.uuidString), [id(3), id(2), id(1), id(4)])
        query = LibraryIndex.ProjectQuery(); query.sort = .size
        XCTAssertEqual(try index.projects(query).rows.map(\.id.uuidString), [id(4), id(1), id(3), id(2)])
        query = LibraryIndex.ProjectQuery(); query.sort = .modified
        // Modified falls back to created for the never-edited.
        XCTAssertEqual(try index.projects(query).rows.map(\.id.uuidString), [id(3), id(1), id(2), id(4)])
        query = LibraryIndex.ProjectQuery(); query.sort = .name; query.ascending = true
        XCTAssertEqual(try index.projects(query).rows.map(\.displayName), ["3 photos", "3 photos", "Charles Bridge at night", "Tram switch"])

        query = LibraryIndex.ProjectQuery(); query.kind = "video"
        XCTAssertEqual(try index.projects(query).rows.map(\.id.uuidString), [id(2)])
        query = LibraryIndex.ProjectQuery(); query.scanner = true
        XCTAssertEqual(try index.projects(query).rows.map(\.id.uuidString), [id(4)])
        query = LibraryIndex.ProjectQuery(); query.scanner = false
        XCTAssertEqual(try index.projects(query).total, 3)
        query = LibraryIndex.ProjectQuery(); query.tags = ["urban"]
        XCTAssertEqual(try index.projects(query).rows.map(\.id.uuidString), [id(2), id(1)])
        query.tags = ["urban", "vehicles"]
        XCTAssertEqual(try index.projects(query).rows.map(\.id.uuidString), [id(2)], "every chip must be on the project")
        query = LibraryIndex.ProjectQuery(); query.includeDeleted = true
        XCTAssertEqual(try index.projects(query).total, 5)

        let row = try XCTUnwrap(try index.project(id: UUID(uuidString: id(1))!))
        XCTAssertEqual(row.blendCount, 2)
        XCTAssertEqual(row.frameCount, 3)
        XCTAssertEqual(row.sceneTags, ["urban", "skyWeather"])
        XCTAssertEqual(row.createdAt.timeIntervalSinceReferenceDate, 100, accuracy: 0.001)
        XCTAssertEqual(try index.tagCounts().map { "\($0.tag):\($0.count)" }, ["urban:2", "skyWeather:1", "vehicles:1", "water:1"])
    }

    func testFullTextSearchOverProjectsAndAssets() throws {
        try writeLibrary()
        let index = try openIndex()
        try index.rebuild(fromProjectsFolder: projects)

        // Name, element, tag — and prefix matching.
        XCTAssertEqual(try index.search("charles").map(\.projectID.uuidString), [id(1)])
        XCTAssertEqual(Set(try index.search("riv").map(\.projectID.uuidString)), [id(1), id(3)], "prefix matching")
        XCTAssertEqual(Set(try index.search("river").map(\.projectID.uuidString)), [id(1), id(3)], "the element on 1, the project caption on 3")
        XCTAssertEqual(try index.search("urban vehicles").map(\.projectID.uuidString), [id(2)], "every word must match")
        // An asset's imported title and keywords reach the search.
        let hits = try index.search("vltava")
        XCTAssertEqual(hits.map(\.kind), ["asset"])
        XCTAssertEqual(hits.first?.id, "source/frame-1.dng")
        XCTAssertEqual(hits.first?.projectID.uuidString, id(3))
        XCTAssertEqual(Set(try index.search("prague").map(\.kind)), ["project", "asset"], "the project's edited city and the frame's keyword")
        XCTAssertEqual(try index.search("   "), [])
        XCTAssertEqual(try index.search("\"quoted\" OR (weird"), [], "operators are quoted away, never a syntax error")

        var query = LibraryIndex.ProjectQuery()
        query.text = "vltava"
        XCTAssertEqual(try index.projects(query).rows.map(\.id.uuidString), [id(3)], "a text query on the page lists the asset's project")
        query.text = "tram"; query.kind = "photos"
        XCTAssertEqual(try index.projects(query).total, 0, "filters and text combine")
    }

    func testAssetRowsCarryTheResolvedRecord() throws {
        try writeLibrary()
        let index = try openIndex()
        try index.rebuild(fromProjectsFolder: projects)
        let row = try XCTUnwrap(try index.project(id: UUID(uuidString: id(3))!))
        XCTAssertNil(row.title, "the project record has no title of its own")
        // The frame with a title of its own has a row, and that row carries
        // the project's edited caption as its fallback; the frame with
        // nothing of its own has no row — the project's row speaks for it.
        let hits = try index.search("evening")
        XCTAssertEqual(hits.map(\.kind).sorted(), ["asset", "project"])
        XCTAssertEqual(hits.first { $0.kind == "asset" }?.id, "source/frame-1.dng")
        XCTAssertEqual(try index.search("ilce").map(\.kind), ["asset"], "the camera is searchable")
    }

    func testIncrementalUpsertAndRemoveKeepTheIndexCurrent() throws {
        try writeLibrary()
        let index = try openIndex()
        try index.rebuild(fromProjectsFolder: projects)

        // A new document, handed over as bytes.
        let folder = try writeProject(6, name: "Sunset over Vyšehrad", created: 1000, tags: ["skyWeather"])
        let data = try Data(contentsOf: ProjectDocumentFormat.url(inProjectFolder: folder))
        try index.upsertProject(documentData: data, folder: id(6), documentModifiedAt: Date(timeIntervalSinceReferenceDate: 5))
        XCTAssertEqual(try index.counts().projects, 5)
        XCTAssertEqual(try index.search("vysehrad").map(\.projectID.uuidString), [id(6)], "diacritics fold")
        XCTAssertEqual(index.documentModifiedAt(projectID: UUID(uuidString: id(6))!)?.timeIntervalSinceReferenceDate, 5)

        // A renamed document replaces the row and the search text.
        try writeProject(6, name: "Dawn over Vyšehrad", created: 1000, tags: ["skyWeather"])
        try index.upsertProject(documentData: Data(contentsOf: ProjectDocumentFormat.url(inProjectFolder: folder)), folder: id(6))
        XCTAssertEqual(try index.search("sunset"), [])
        XCTAssertEqual(try index.search("dawn").map(\.projectID.uuidString), [id(6)])
        XCTAssertEqual(try index.counts().searchRows, 7)

        // Assets arrive later and re-index on their own.
        XCTAssertNil(index.assetsIndexedAt(projectID: UUID(uuidString: id(6))!))
        var frame = AssetRecord(name: "source/frame-1.dng")
        frame.bytes = 1; frame.hash = "sha256:bb"
        var edited = AssetMetadata(); edited.title = "First light"
        frame.edited = edited
        try writeAssets(in: folder, [frame])
        XCTAssertEqual(try index.reindexAssets(projectID: UUID(uuidString: id(6))!, inProjectFolder: folder), 1)
        XCTAssertNotNil(index.assetsIndexedAt(projectID: UUID(uuidString: id(6))!))
        XCTAssertEqual(try index.search("first light").first?.kind, "asset")
        // Re-indexing the assets keeps the project's own document fields.
        XCTAssertEqual(try index.project(id: UUID(uuidString: id(6))!)?.name, "Dawn over Vyšehrad")

        // Removal takes every row with it.
        try index.removeProject(id: UUID(uuidString: id(6))!)
        XCTAssertEqual(try index.counts().projects, 4)
        XCTAssertEqual(try index.search("dawn"), [])
        XCTAssertEqual(try index.search("first light"), [])
        XCTAssertNil(try index.project(id: UUID(uuidString: id(6))!))
    }

    func testDeletingTheDatabaseLosesNothing() throws {
        try writeLibrary()
        let index = try openIndex()
        try index.rebuild(fromProjectsFolder: projects)
        var query = LibraryIndex.ProjectQuery(); query.includeDeleted = true; query.sort = .name; query.ascending = true
        let before = try index.projects(query)
        let beforeHits = try index.search("prague")
        let beforeCounts = try index.counts()

        let url = index.url
        try FileManager.default.removeItem(at: url)
        for sibling in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + sibling))
        }
        let fresh = try LibraryIndex(at: url)
        XCTAssertEqual(try fresh.counts().projects, 0)
        try fresh.rebuild(fromProjectsFolder: projects)
        XCTAssertEqual(try fresh.projects(query), before)
        XCTAssertEqual(try fresh.search("prague"), beforeHits)
        XCTAssertEqual(try fresh.counts(), beforeCounts)
    }

    func testUnreadableDocumentIsReportedAndSkipped() throws {
        try writeLibrary()
        let torn = projects.appendingPathComponent(id(9), isDirectory: true)
        try FileManager.default.createDirectory(at: torn, withIntermediateDirectories: true)
        try Data("{\"capture\": {".utf8).write(to: ProjectDocumentFormat.url(inProjectFolder: torn))
        let index = try openIndex()
        let outcome = try index.rebuild(fromProjectsFolder: projects)
        XCTAssertEqual(outcome.projects, 5)
        XCTAssertEqual(outcome.unreadableDocuments.count, 1)
        XCTAssertTrue(outcome.unreadableDocuments[0].hasPrefix(id(9)))
    }

    func testFTSQueryShape() {
        XCTAssertNil(LibraryIndex.ftsQuery(""))
        XCTAssertEqual(LibraryIndex.ftsQuery("night bridge"), "\"night\"* AND \"bridge\"*")
        XCTAssertEqual(LibraryIndex.ftsQuery("say \"hi\", there"), "\"say\"* AND \"hi\"* AND \"there\"*")
    }
}

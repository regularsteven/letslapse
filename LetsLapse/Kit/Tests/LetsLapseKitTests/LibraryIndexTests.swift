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
        _ n: Int, kind: String = "photos", mode: String? = nil, name: String? = nil, created: Double, added: Double? = nil,
        modified: Double? = nil, frames: Int = 3, size: Int? = nil, tags: [String]? = nil, elements: [String]? = nil,
        deleted: Double? = nil, blends: Int = 0, blendCreated: [Double]? = nil, captureMode: String? = nil, inTrash: Bool = false
    ) throws -> URL {
        var capture: [String: Any] = [
            "id": id(n), "kind": kind, "createdAt": ProjectDocumentFormat.documentDate(fromManifestSeconds: created),
            "originalName": "\(frames) photos", "mode": mode ?? (kind == "video" ? "Video" : "Photo"),
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
             "createdAt": ProjectDocumentFormat.documentDate(fromManifestSeconds: blendCreated?[b] ?? created + Double(b)),
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

    // MARK: - M2: what the lists ask

    private func uuid(_ n: Int) -> UUID { UUID(uuidString: id(n))! }

    /// One project per category, the four ways a scan can be one included.
    private func writeCategories() throws {
        try writeProject(1, mode: ProjectModes.photo, created: 100, tags: ["skyWeather"])
        try writeProject(2, mode: ProjectModes.importedPhoto, created: 200)
        try writeProject(3, mode: "Interval · DNG", created: 300, tags: ["lightTrails", "skyWeather"])
        try writeProject(4, kind: "video", mode: ProjectModes.importedVideo, created: 400)
        try writeProject(5, mode: "Interval · DNG", created: 500, tags: ["water"], captureMode: ProjectModes.scannerCaptureMode)
        try writeProject(6, mode: ProjectModes.scanner, created: 600)
        // Older than both markers: only its sidecar says what it is.
        let folder = try writeProject(7, mode: "Interval · JPEG", created: 700, tags: ["water"])
        let source = folder.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let writer = try XCTUnwrap(FrameTimestampWriter(directory: source))
        let quad = NormalizedQuad(topLeft: .init(x: 0.1, y: 0.1), topRight: .init(x: 0.9, y: 0.1),
                                  bottomLeft: .init(x: 0.1, y: 0.9), bottomRight: .init(x: 0.9, y: 0.9), confidence: 0.9)
        writer.append(FrameTimestamps.Entry(frame: 1, captureTime: Date(), shutter: 0.01, iso: 100))
        writer.append(FrameTimestamps.Entry(frame: 2, captureTime: Date(), shutter: 0.01, iso: 100, rectangle: quad))
        writer.close()
    }

    func testCategoriesFollowTheAppsRules() throws {
        try writeCategories()
        let index = try openIndex()
        try index.rebuild(fromProjectsFolder: projects)
        let categories = try (1...7).map { try XCTUnwrap(try index.project(id: uuid($0))).category }
        XCTAssertEqual(categories, [.photo, .photo, .interval, .video, .scan, .scan, .scan])

        var query = LibraryIndex.ProjectQuery()
        XCTAssertEqual(try index.categoryCounts(query), [.photo: 2, .interval: 1, .video: 1, .scan: 3])
        query.category = .scan
        XCTAssertEqual(try index.projectIDs(query).map(\.uuidString), [id(7), id(6), id(5)])
        query = LibraryIndex.ProjectQuery(); query.excludeScans = true
        XCTAssertEqual(try index.projectIDs(query).map(\.uuidString), [id(4), id(3), id(2), id(1)])
        XCTAssertEqual(try index.categoryCounts(query), [.photo: 2, .interval: 1, .video: 1])
        query.category = .interval
        XCTAssertEqual(try index.projectIDs(query).map(\.uuidString), [id(3)])
        // The chips: a tag only scans carry has no chip when scans are out.
        XCTAssertEqual(try index.tagCounts().map(\.tag), ["skyWeather", "water", "lightTrails"])
        XCTAssertEqual(try index.tagCounts(excludingScans: true).map(\.tag), ["skyWeather", "lightTrails"])

        // The sidecar verdict is kept on the row: a re-index of the document
        // without the folder keeps the scan a scan.
        let data = try Data(contentsOf: ProjectDocumentFormat.url(inProjectFolder: projects.appendingPathComponent(id(7))))
        try index.upsertProject(documentData: data, folder: id(7))
        XCTAssertEqual(try index.project(id: uuid(7))?.category, .scan)
        // And a project that never had the folder passed stays what its
        // document says until it does.
        let data3 = try Data(contentsOf: ProjectDocumentFormat.url(inProjectFolder: projects.appendingPathComponent(id(3))))
        try index.removeProject(id: uuid(3))
        try index.upsertProject(documentData: data3, folder: id(3))
        XCTAssertEqual(try index.project(id: uuid(3))?.category, .interval)
    }

    func testEditSortFallsBackToTheNewestBlendThenTheCapture() throws {
        try writeProject(1, created: 100, modified: 150)            // edited 150
        try writeProject(2, created: 200, blends: 2, blendCreated: [210, 900]) // edited 900 — the newest blend
        try writeProject(3, created: 300)                           // edited 300 — the capture
        let index = try openIndex()
        try index.rebuild(fromProjectsFolder: projects)
        var query = LibraryIndex.ProjectQuery(); query.sort = .edited
        XCTAssertEqual(try index.projectIDs(query).map(\.uuidString), [id(2), id(3), id(1)])
        XCTAssertEqual(try index.project(id: uuid(2))?.editedAt?.timeIntervalSinceReferenceDate, 900)
        query.ascending = true
        XCTAssertEqual(try index.projectIDs(query).map(\.uuidString), [id(1), id(3), id(2)])
    }

    func testSizeSortsUnmeasuredBelowMeasuredAndTiesTurnWithTheSort() throws {
        try writeProject(1, created: 100, size: 0)
        try writeProject(2, created: 200)          // unmeasured: −1
        try writeProject(3, created: 300, size: 5)
        try writeProject(4, created: 300, size: 5) // a twin: same size, same capture date
        let index = try openIndex()
        try index.rebuild(fromProjectsFolder: projects)
        var query = LibraryIndex.ProjectQuery(); query.sort = .size
        XCTAssertEqual(try index.projectIDs(query).map(\.uuidString), [id(4), id(3), id(1), id(2)], "descending: twins by id descending, unmeasured last")
        query.ascending = true
        XCTAssertEqual(try index.projectIDs(query).map(\.uuidString), [id(2), id(1), id(3), id(4)], "ascending: the mirror image")
        query = LibraryIndex.ProjectQuery(); query.sort = .created
        XCTAssertEqual(try index.projectIDs(query).map(\.uuidString), [id(4), id(3), id(2), id(1)])
        query.ascending = true
        XCTAssertEqual(try index.projectIDs(query).map(\.uuidString), [id(1), id(2), id(3), id(4)])
        // Edit ties: the capture order runs against the sort.
        try writeProject(5, created: 500, modified: 1000)
        try writeProject(6, created: 600, modified: 1000)
        try index.rebuild(fromProjectsFolder: projects)
        query = LibraryIndex.ProjectQuery(); query.sort = .edited
        XCTAssertEqual(Array(try index.projectIDs(query).map(\.uuidString).prefix(2)), [id(5), id(6)], "descending Edit, equal dates: older capture first")
        query.ascending = true
        XCTAssertEqual(Array(try index.projectIDs(query).map(\.uuidString).suffix(2)), [id(6), id(5)], "ascending Edit, equal dates: newer capture first")
    }

    func testTagLabelsAreSearchableAndPrefixesMatch() throws {
        try writeProject(1, name: "Charles Bridge", created: 100, tags: ["skyWeather", "lightTrails"], elements: ["bridge"])
        try writeProject(2, name: "Tram", created: 200, tags: ["urban"])
        let index = try openIndex()
        try index.rebuild(fromProjectsFolder: projects)
        func found(_ text: String) throws -> [String] {
            var query = LibraryIndex.ProjectQuery(); query.text = text
            return try index.projectIDs(query).map(\.uuidString)
        }
        XCTAssertEqual(try found("weather"), [id(1)], "the chip label's second word")
        XCTAssertEqual(try found("sky"), [id(1)])
        XCTAssertEqual(try found("light trails"), [id(1)])
        XCTAssertEqual(try found("Sky & weather"), [id(1)], "the chip label as typed — '&' is not a term")
        XCTAssertNil(LibraryIndex.ftsQuery("& — ·"), "nothing to search for")
        XCTAssertEqual(try found("skyWeather"), [id(1)], "the raw value still works")
        XCTAssertEqual(try found("brid"), [id(1)], "a prefix")
        XCTAssertEqual(try found("idge"), [], "a mid-word substring no longer matches — by decision")
        XCTAssertEqual(try found("urb charles"), [], "every word must land on the same project")
        XCTAssertEqual(try found("urban"), [id(2)])
    }

    func testShapeRowsCountTheRegister() throws {
        let one = try writeProject(1, created: 100)
        try writeProject(2, created: 200)
        let three = try writeProject(3, created: 300)
        func shape(_ kind: DetectedShape.Kind, aspect: Double = 1) -> DetectedShape {
            let corners = kind == .quad ? [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.2 + 0.4 * aspect, y: 0.2),
                                           CGPoint(x: 0.2 + 0.4 * aspect, y: 0.6), CGPoint(x: 0.2, y: 0.6)] : nil
            return DetectedShape(kind: kind, centre: CGPoint(x: 0.5, y: 0.5), majorAxis: 0.4 * aspect, minorAxis: 0.4,
                                 rotation: 0, corners: corners, confidence: 1, nativeDiameterPx: 400, source: .manual)
        }
        let representative = ShapeRegister.Representative(relativePath: "source/frame-1.dng", source: .sourceFrame, width: 1000, height: 1000)
        try ShapeRegister(representative: representative, shapes: [shape(.ellipse), shape(.quad, aspect: 1), shape(.quad, aspect: 2.5)])
            .save(inProjectFolder: one)
        try ShapeRegister(representative: representative, shapes: []).save(inProjectFolder: three)
        let index = try openIndex()
        try index.rebuild(fromProjectsFolder: projects)
        func rows(_ shapes: Set<ShapeRow>) throws -> [String] {
            var query = LibraryIndex.ProjectQuery(); query.shapes = shapes; query.ascending = true
            return try index.projectIDs(query).map(\.uuidString)
        }
        XCTAssertEqual(try rows([.ellipse]), [id(1)])
        XCTAssertEqual(try rows([.square]), [id(1)])
        XCTAssertEqual(try rows([.rectangle]), [id(1)])
        XCTAssertEqual(try rows([.ellipse, .rectangle]), [id(1)], "rows narrow")
        XCTAssertEqual(try rows([.none]), [id(2), id(3)], "no register, or an empty one")
        XCTAssertNotNil(index.shapesIndexedAt(projectID: uuid(1)))
        // The editor removes every shape: the one project is re-counted.
        try ShapeRegister(representative: representative, shapes: []).save(inProjectFolder: one)
        try index.reindexShapes(projectID: uuid(1), inProjectFolder: one)
        XCTAssertEqual(try rows([.none]), [id(1), id(2), id(3)])
        // A document re-index keeps the counts.
        try index.reindexShapes(projectID: uuid(3), inProjectFolder: three)
        try ShapeRegister(representative: representative, shapes: [shape(.ellipse)]).save(inProjectFolder: three)
        try index.reindexShapes(projectID: uuid(3), inProjectFolder: three)
        let data = try Data(contentsOf: ProjectDocumentFormat.url(inProjectFolder: three))
        try index.upsertProject(documentData: data, folder: id(3))
        XCTAssertEqual(try rows([.ellipse]), [id(3)])
    }

    func testWithBlendsAndOriginLookup() throws {
        try writeProject(1, created: 100, blends: 1)
        try writeProject(2, created: 200)
        let index = try openIndex()
        try index.rebuild(fromProjectsFolder: projects)
        var query = LibraryIndex.ProjectQuery(); query.withBlends = true
        XCTAssertEqual(try index.projectIDs(query).map(\.uuidString), [id(1)])
        XCTAssertEqual(try index.projectID(originID: uuid(2)), uuid(2), "its own origin")
        XCTAssertNil(try index.projectID(originID: uuid(9)))
        XCTAssertEqual(try index.projects(LibraryIndex.ProjectQuery()).rows.map(\.id), try index.projectIDs(LibraryIndex.ProjectQuery()), "the page and the ids agree")
    }

    /// M3: the whole-library questions the app used to answer by walking
    /// its arrays.
    func testWholeLibraryQuestions() throws {
        try writeProject(1, kind: "video", created: 100, size: 30, blends: 2)   // fps/duration absent → probe
        try writeProject(2, created: 200, modified: 250, size: 20)              // photos, has width
        try writeProject(3, created: 300)                                      // unmeasured
        try writeProject(4, created: 400, size: 5, deleted: 900, blends: 1, inTrash: true)
        let index = try openIndex()
        try index.rebuild(fromProjectsFolder: projects)

        XCTAssertEqual(try index.liveProjectIDs().map(\.uuidString), [id(3), id(2), id(1)])
        XCTAssertEqual(try index.projectID(forBlend: UUID(uuidString: String(format: "%08X-%04X-4000-8000-000000000000", 1, 1))!), uuid(1))
        XCTAssertNil(try index.projectID(forBlend: uuid(9)))
        XCTAssertEqual(try index.folder(of: uuid(4)), ".trash/\(id(4))")
        XCTAssertEqual(try index.folder(of: uuid(2)), id(2))
        XCTAssertNil(try index.folder(of: uuid(9)))

        let totals = try index.storageTotals()
        XCTAssertEqual(totals, LibraryIndex.StorageTotals(liveBytes: 50, unmeasured: 1, liveProjects: 3, deletedProjects: 1, deletedBlends: 0))
        XCTAssertEqual(try index.deletedProjects().map { ($0.id, $0.folder) }.map { "\($0.0.uuidString):\($0.1)" }, ["\(id(4)):.trash/\(id(4))"])
        XCTAssertEqual(try index.deletedBlendsInLiveProjects(), [])

        let probe = try index.projectsNeedingProbe()
        XCTAssertEqual(probe.video.map(\.uuidString), [id(1)], "a video with no fps or duration")
        XCTAssertEqual(probe.photos, [], "every still has its dimensions")
        // Unmeasured, and measured before the last edit.
        XCTAssertEqual(Set(try index.projectsNeedingSizeMeasurement().map(\.uuidString)), [id(3), id(2), id(1)], "no size_measured_at anywhere yet")
    }

    func testFTSQueryShape() {
        XCTAssertNil(LibraryIndex.ftsQuery(""))
        XCTAssertEqual(LibraryIndex.ftsQuery("night bridge"), "\"night\"* AND \"bridge\"*")
        XCTAssertEqual(LibraryIndex.ftsQuery("say \"hi\", there"), "\"say\"* AND \"hi\"* AND \"there\"*")
    }
}

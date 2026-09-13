import XCTest
import SQLite3
@testable import LetsLapseKit

/// The Lightroom migration against a synthetic catalogue with the real
/// table shapes: one root folder that IS a LetsLapse project's `source/`,
/// one standalone folder holding the IPTC fixture JPEG and a file the
/// catalogue lists but the disk does not have.
final class LightroomMigrationTests: XCTestCase {

    private var root: URL!
    private var projects: URL { root.appendingPathComponent("Projects", isDirectory: true) }
    private var catalogueURL: URL { root.appendingPathComponent("test.lrcat") }
    private var standalone: URL { root.appendingPathComponent("Pictures", isDirectory: true) }
    private let projectID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: standalone, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var fixtureJPEG: URL {
        get throws {
            try XCTUnwrap(Bundle.module.url(forResource: "metadata-demo", withExtension: "jpg"))
        }
    }

    /// A LetsLapse project with two frames, one of which is the fixture JPEG.
    private func writeProject() throws -> URL {
        let folder = projects.appendingPathComponent(projectID.uuidString, isDirectory: true)
        let source = folder.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try fixtureJPEG, to: source.appendingPathComponent("frame-00001.jpg"))
        try Data(count: 10).write(to: source.appendingPathComponent("frame-00002.jpg"))
        let capture: [String: Any] = [
            "id": projectID.uuidString, "kind": "photos", "createdAt": "2026-08-31T20:00:00.000Z",
            "originalName": "2 photos", "mode": "Interval · Imported",
            "sourceFileNames": ["source/frame-00001.jpg", "source/frame-00002.jpg"], "originID": projectID.uuidString,
        ]
        try JSONSerialization.data(withJSONObject: ["formatVersion": 2, "capture": capture, "blends": []])
            .write(to: ProjectDocumentFormat.url(inProjectFolder: folder))
        return folder
    }

    /// The catalogue: Lightroom's own table and column names, the subset
    /// the reader touches.
    private func writeCatalogue(sourceFolder: URL) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(catalogueURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        func run(_ sql: String) {
            var message: UnsafeMutablePointer<CChar>?
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, &message), SQLITE_OK, message.map { String(cString: $0) } ?? "")
        }
        run("""
            CREATE TABLE Adobe_images (id_local INTEGER PRIMARY KEY, rootFile INTEGER, captureTime TEXT, rating REAL, pick REAL, colorLabels TEXT, fileFormat TEXT, fileWidth INTEGER, fileHeight INTEGER);
            CREATE TABLE AgLibraryFile (id_local INTEGER PRIMARY KEY, folder INTEGER, baseName TEXT, extension TEXT, idx_filename TEXT);
            CREATE TABLE AgLibraryFolder (id_local INTEGER PRIMARY KEY, rootFolder INTEGER, pathFromRoot TEXT);
            CREATE TABLE AgLibraryRootFolder (id_local INTEGER PRIMARY KEY, absolutePath TEXT, name TEXT);
            CREATE TABLE AgLibraryIPTC (id_local INTEGER PRIMARY KEY, image INTEGER, caption TEXT, copyright TEXT);
            CREATE TABLE AgHarvestedIptcMetadata (id_local INTEGER PRIMARY KEY, image INTEGER, cityRef INTEGER, copyrightState INTEGER, countryRef INTEGER, creatorRef INTEGER, isoCountryCodeRef INTEGER, locationRef INTEGER, stateRef INTEGER);
            CREATE TABLE AgInternedIptcCity (id_local INTEGER PRIMARY KEY, value TEXT);
            CREATE TABLE AgInternedIptcCountry (id_local INTEGER PRIMARY KEY, value TEXT);
            CREATE TABLE AgInternedIptcCreator (id_local INTEGER PRIMARY KEY, value TEXT);
            CREATE TABLE AgInternedIptcIsoCountryCode (id_local INTEGER PRIMARY KEY, value TEXT);
            CREATE TABLE AgInternedIptcLocation (id_local INTEGER PRIMARY KEY, value TEXT);
            CREATE TABLE AgInternedIptcState (id_local INTEGER PRIMARY KEY, value TEXT);
            CREATE TABLE AgLibraryKeyword (id_local INTEGER PRIMARY KEY, name TEXT, lc_name TEXT, parent INTEGER);
            CREATE TABLE AgLibraryKeywordImage (id_local INTEGER PRIMARY KEY, image INTEGER, tag INTEGER);
            CREATE TABLE AgHarvestedExifMetadata (id_local INTEGER PRIMARY KEY, image INTEGER, aperture REAL, cameraModelRef INTEGER, focalLength REAL, gpsLatitude REAL, gpsLongitude REAL, hasGPS INTEGER, isoSpeedRating REAL, lensRef INTEGER, shutterSpeed REAL);
            CREATE TABLE AgInternedExifCameraModel (id_local INTEGER PRIMARY KEY, value TEXT);
            CREATE TABLE AgInternedExifLens (id_local INTEGER PRIMARY KEY, value TEXT);
            CREATE TABLE AgLibraryCollection (id_local INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE AgLibraryCollectionImage (id_local INTEGER PRIMARY KEY, collection INTEGER, image INTEGER);
            """)
        run("""
            INSERT INTO AgLibraryRootFolder VALUES (1, '\(sourceFolder.path)/', 'source');
            INSERT INTO AgLibraryRootFolder VALUES (2, '\(standalone.path)/', 'Pictures');
            INSERT INTO AgLibraryFolder VALUES (10, 1, '');
            INSERT INTO AgLibraryFolder VALUES (20, 2, '');
            INSERT INTO AgLibraryFile VALUES (100, 10, 'frame-00001', 'jpg', 'frame-00001.jpg');
            INSERT INTO AgLibraryFile VALUES (101, 10, 'frame-00002', 'jpg', 'frame-00002.jpg');
            INSERT INTO AgLibraryFile VALUES (102, 10, 'frame-00003', 'jpg', 'frame-00003.jpg');
            INSERT INTO AgLibraryFile VALUES (200, 20, 'demo', 'jpg', 'demo.jpg');
            INSERT INTO AgLibraryFile VALUES (201, 20, 'gone', 'jpg', 'gone.jpg');
            INSERT INTO Adobe_images VALUES (1000, 100, '2026-08-31T20:29:30', 5, 1, NULL, 'JPG', 4000, 3000);
            INSERT INTO Adobe_images VALUES (1001, 101, '2026-08-31T20:29:35', 0, 0, NULL, 'JPG', 4000, 3000);
            INSERT INTO Adobe_images VALUES (1002, 102, '2026-08-31T20:29:40', 3, 0, NULL, 'JPG', 4000, 3000);
            INSERT INTO Adobe_images VALUES (2000, 200, '2026-06-01T10:00:00', 4, 0, NULL, 'JPG', 1000, 750);
            INSERT INTO Adobe_images VALUES (2001, 201, '2026-06-02T10:00:00', 2, 0, NULL, 'JPG', 1000, 750);
            INSERT INTO AgLibraryIPTC VALUES (1, 1000, 'Charles Bridge at night', 'Steven Wright 2026');
            INSERT INTO AgInternedIptcCreator VALUES (1, 'Steven Wright');
            INSERT INTO AgInternedIptcCity VALUES (1, 'Prague');
            INSERT INTO AgInternedIptcCountry VALUES (1, 'Czech Republic');
            INSERT INTO AgInternedIptcIsoCountryCode VALUES (1, 'CZ');
            INSERT INTO AgInternedIptcLocation VALUES (1, 'Mala Strana');
            INSERT INTO AgInternedIptcState VALUES (1, 'Prague');
            INSERT INTO AgHarvestedIptcMetadata VALUES (1, 1000, 1, 1, 1, 1, 1, 1, 1);
            INSERT INTO AgLibraryKeyword VALUES (1, 'dusk', 'dusk', NULL);
            INSERT INTO AgLibraryKeyword VALUES (2, 'Bridge', 'bridge', NULL);
            INSERT INTO AgLibraryKeywordImage VALUES (1, 1000, 1);
            INSERT INTO AgLibraryKeywordImage VALUES (2, 1000, 2);
            INSERT INTO AgLibraryKeywordImage VALUES (3, 2000, 1);
            INSERT INTO AgInternedExifCameraModel VALUES (1, 'ILCE-7M4');
            INSERT INTO AgInternedExifLens VALUES (1, 'Viltrox 28mm F4.5 FE');
            INSERT INTO AgHarvestedExifMetadata VALUES (1, 1001, 4.33985, 1, 28, 50.0897, 14.4116, 1, 100, 1, -1.678072);
            INSERT INTO AgLibraryCollection VALUES (1, 'Day 0');
            INSERT INTO AgLibraryCollectionImage VALUES (1, 1, 1000);
            INSERT INTO AgLibraryCollectionImage VALUES (2, 1, 2000);
            """)
    }

    // MARK: - Tests

    func testCatalogueReaderSeesEveryStatement() throws {
        let folder = try writeProject()
        try writeCatalogue(sourceFolder: folder.appendingPathComponent("source"))
        let catalogue = try LightroomCatalogue(at: catalogueURL)
        XCTAssertEqual(try catalogue.imageCount(), 5)
        XCTAssertEqual(try catalogue.rootFolders().count, 2)
        let images = try catalogue.images()
        XCTAssertEqual(images.count, 5)
        let bridge = try XCTUnwrap(images.first { $0.id == 1000 })
        XCTAssertEqual(bridge.fileName, "frame-00001.jpg")
        XCTAssertEqual(bridge.rating, 5)
        XCTAssertEqual(bridge.caption, "Charles Bridge at night")
        XCTAssertEqual(bridge.copyright, "Steven Wright 2026")
        XCTAssertEqual(bridge.creator, "Steven Wright")
        XCTAssertEqual(bridge.city, "Prague")
        XCTAssertEqual(bridge.countryCode, "CZ")
        XCTAssertEqual(bridge.location, "Mala Strana")
        XCTAssertEqual(bridge.copyrightState, 1)
        XCTAssertEqual(bridge.keywords, ["Bridge", "dusk"])
        let exif = try XCTUnwrap(images.first { $0.id == 1001 })
        XCTAssertEqual(exif.cameraModel, "ILCE-7M4")
        XCTAssertEqual(exif.lens, "Viltrox 28mm F4.5 FE")
        XCTAssertEqual(try XCTUnwrap(exif.aperture), 4.5, accuracy: 0.01, "APEX Av → f-number")
        XCTAssertEqual(try XCTUnwrap(exif.shutterSeconds), 3.2, accuracy: 0.01, "APEX Tv → seconds")
        XCTAssertEqual(exif.gpsLatitude, 50.0897)
        XCTAssertEqual(try catalogue.collections().map(\.name), ["Day 0"])
        // Nothing was written beside the catalogue.
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogueURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogueURL.path + "-journal"))
    }

    func testPlanAttachesProjectFramesAndCreatesTheRest() throws {
        let folder = try writeProject()
        try writeCatalogue(sourceFolder: folder.appendingPathComponent("source"))
        try FileManager.default.copyItem(at: try fixtureJPEG, to: standalone.appendingPathComponent("demo.jpg"))
        let catalogue = try LightroomCatalogue(at: catalogueURL)
        let options = LightroomMigration.Options(root: root)
        let plan = try LightroomMigration.plan(catalogue: catalogue, options: options)
        XCTAssertEqual(plan.attaches.map(\.image.id), [1000, 1001, 1002])
        XCTAssertEqual(plan.attaches.map(\.fileExists), [true, true, false])
        XCTAssertEqual(plan.creates.map(\.id), [2000])
        XCTAssertEqual(plan.skipped.map(\.image.id), [2001])
        XCTAssertTrue(plan.skipped[0].why.hasPrefix("file not found"))
        XCTAssertEqual(plan.pinnedProjects, [projectID])
        XCTAssertEqual(plan.collectionsByImage[1000], ["Day 0"])
        XCTAssertEqual(LightroomMigration.projectID(inSourceFolderPath: "/Volumes/letslapse/Projects/\(projectID.uuidString)/source/"), projectID)
        XCTAssertNil(LightroomMigration.projectID(inSourceFolderPath: "/Volumes/letslapse/Source_SONY/"))
    }

    func testApplyWritesRecordsAndProjectsAndIsIdempotent() throws {
        let folder = try writeProject()
        try writeCatalogue(sourceFolder: folder.appendingPathComponent("source"))
        try FileManager.default.copyItem(at: try fixtureJPEG, to: standalone.appendingPathComponent("demo.jpg"))
        let catalogue = try LightroomCatalogue(at: catalogueURL)
        let options = LightroomMigration.Options(root: root)

        // A dry run writes nothing.
        var dry = options
        dry.dryRun = true
        let dryReport = try LightroomMigration.apply(try LightroomMigration.plan(catalogue: catalogue, options: dry), options: dry, catalogueName: "test")
        XCTAssertEqual(dryReport.attached, 2)
        XCTAssertEqual(dryReport.created, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AssetRecords.url(inProjectFolder: folder).path))
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: projects.path))?.count, 1)

        let report = try LightroomMigration.apply(try LightroomMigration.plan(catalogue: catalogue, options: options), options: options, catalogueName: "test")
        XCTAssertEqual(report.attached, 2)
        XCTAssertEqual(report.attachMissingFile, 1)
        XCTAssertEqual(report.created, 1)
        XCTAssertEqual(report.createFailed, [])
        XCTAssertEqual(report.projectRecordsWritten, 1)

        // The attached frame: the catalogue over the file. The fixture JPEG
        // carries its own title ("White Corner, black Corner"), which the
        // catalogue does not own; its caption, rating and keywords are the
        // catalogue's; the collection is a keyword.
        let records = AssetRecords.load(inProjectFolder: folder)
        let frame = try XCTUnwrap(records["source/frame-00001.jpg"])
        XCTAssertEqual(frame.importedSource, "catalogue")
        XCTAssertEqual(frame.imported?.title, "White Corner, black Corner")
        XCTAssertEqual(frame.imported?.caption, "Charles Bridge at night")
        XCTAssertEqual(frame.imported?.rating, 5)
        XCTAssertEqual(frame.imported?.keywords, ["Bridge", "dusk", "Day 0"])
        XCTAssertEqual(frame.imported?.location?.city, "Prague")
        XCTAssertEqual(frame.imported?.location?.sublocation, "Mala Strana")
        XCTAssertEqual(frame.imported?.rightsStatus, .copyrighted)
        XCTAssertNil(frame.hash, "the app's backfill hashes; the tool does not")
        let second = try XCTUnwrap(records["source/frame-00002.jpg"])
        XCTAssertEqual(second.imported?.camera?.model, "ILCE-7M4")
        XCTAssertEqual(try XCTUnwrap(second.imported?.exposure?.seconds), 3.2, accuracy: 0.01)
        XCTAssertEqual(second.imported?.captured, "2026-08-31T20:29:35")
        XCTAssertEqual(second.imported?.dimensions?.width, 4000, "the catalogue's size when the file has none")
        XCTAssertNil(records["source/frame-00003.jpg"], "a file the catalogue lists but the folder lacks gets no record")
        XCTAssertNotNil(ProjectMetadata.load(inProjectFolder: folder)?.imported)

        // The created project: a folder the app adopts.
        let created = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: projects.path).first {
            $0 != projectID.uuidString && UUID(uuidString: $0) != nil })
        let createdFolder = projects.appendingPathComponent(created, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: createdFolder.appendingPathComponent("source/demo.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: standalone.appendingPathComponent("demo.jpg").path), "the original stays")
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: ProjectDocumentFormat.url(inProjectFolder: createdFolder))) as? [String: Any])
        let capture = try XCTUnwrap(document["capture"] as? [String: Any])
        XCTAssertEqual(capture["id"] as? String, created)
        XCTAssertEqual(capture["originID"] as? String, created)
        XCTAssertEqual(capture["kind"] as? String, "photos")
        XCTAssertEqual(capture["mode"] as? String, "Photo · Imported")
        XCTAssertEqual(capture["sourceFileNames"] as? [String], ["source/demo.jpg"])
        // The catalogue's zoneless capture time, read in the local zone as
        // every photo tool reads it.
        XCTAssertEqual(ProjectDocumentFormat.manifestSeconds(fromDocumentDate: try XCTUnwrap(capture["createdAt"] as? String)),
                       AssetMetadata.parseISO8601("2026-06-01T10:00:00")?.timeIntervalSinceReferenceDate)
        XCTAssertNotNil(capture["sourceWidth"])
        let tags = try XCTUnwrap(capture["sceneTags"] as? [String])
        XCTAssertTrue(tags.contains("dusk") && tags.contains("Day 0"), "\(tags)")
        let createdRecords = AssetRecords.load(inProjectFolder: createdFolder)
        let asset = try XCTUnwrap(createdRecords["source/demo.jpg"])
        XCTAssertNotNil(asset.hash)
        XCTAssertEqual(asset.imported?.rating, 4)
        XCTAssertEqual(asset.imported?.title, "White Corner, black Corner")
        XCTAssertNotNil(ProjectMetadata.load(inProjectFolder: createdFolder)?.imported)
        // The migration log names the pin and the actions.
        let log = NDJSONFile.decode(LightroomMigration.LogEntry.self, from: try Data(contentsOf: LightroomMigration.logURL(root: root)))
        XCTAssertEqual(log.filter { $0.kind == "pinned" }.map(\.project), [projectID])
        XCTAssertEqual(log.filter { $0.kind == "created" }.count, 1)
        XCTAssertEqual(log.filter { $0.kind == "attached" }.count, 2)

        // A second run creates nothing new and rewrites no record.
        let again = try LightroomMigration.apply(try LightroomMigration.plan(catalogue: catalogue, options: options), options: options, catalogueName: "test")
        XCTAssertEqual(again.created, 0)
        XCTAssertEqual(again.attached, 0)
        XCTAssertEqual(again.attachedUnchanged, 2)
        XCTAssertEqual((try FileManager.default.contentsOfDirectory(atPath: projects.path)).filter { UUID(uuidString: $0) != nil }.count, 2)
        XCTAssertEqual(AssetRecords.load(inProjectFolder: folder).count, 2)
        // And the rebuild/audit see a consistent tree of documents.
        XCTAssertEqual(LibraryIndexRebuild.run(root: root).documentsRead, 2)
    }

    func testRefusesWhileTheAppHoldsTheLibrary() throws {
        let folder = try writeProject()
        try writeCatalogue(sourceFolder: folder.appendingPathComponent("source"))
        let lock = LibraryLockRecord(pid: ProcessInfo.processInfo.processIdentifier == 1 ? 2 : 1, host: LibraryLockRecord.thisHost,
                                     build: "test", deviceID: UUID(), takenAt: Date(), heartbeatAt: Date())
        try lock.write(projectsRoot: projects)
        let catalogue = try LightroomCatalogue(at: catalogueURL)
        let options = LightroomMigration.Options(root: root)
        let plan = try LightroomMigration.plan(catalogue: catalogue, options: options)
        XCTAssertThrowsError(try LightroomMigration.apply(plan, options: options, catalogueName: "test"))
        var forced = options
        forced.force = true
        XCTAssertNoThrow(try LightroomMigration.apply(plan, options: forced, catalogueName: "test"))
        // A stale lock does not block.
        var stale = lock
        stale.heartbeatAt = Date().addingTimeInterval(-3600)
        try stale.write(projectsRoot: projects)
        XCTAssertNoThrow(try LightroomMigration.apply(plan, options: options, catalogueName: "test"))
    }
}

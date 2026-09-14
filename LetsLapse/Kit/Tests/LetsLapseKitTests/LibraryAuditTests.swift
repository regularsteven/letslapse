import XCTest
@testable import LetsLapseKit

/// A synthetic tree with every inconsistency class, and the report it must
/// produce.
final class LibraryAuditTests: XCTestCase {

    private var root: URL!
    private var projects: URL { root.appendingPathComponent("Projects", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeProject(_ id: String, files: [String], blends: [String] = []) throws -> URL {
        let folder = projects.appendingPathComponent(id, isDirectory: true)
        for name in files {
            let url = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: 100).write(to: url)
        }
        for name in blends {
            let url = folder.appendingPathComponent("blends/\(name)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: 200).write(to: url)
        }
        return folder
    }

    private func writeManifest(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: projects.appendingPathComponent("library.json"))
    }

    func testEveryInconsistencyClassIsCounted() throws {
        let good = "11111111-1111-1111-1111-111111111111"
        let missingFrame = "22222222-2222-2222-2222-222222222222"
        let orphan = "33333333-3333-3333-3333-333333333333"
        let noFolder = "44444444-4444-4444-4444-444444444444"
        let emptyFolder = "55555555-5555-5555-5555-555555555555"
        let blendID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let ghostBlend = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

        let goodFolder = try makeProject(good, files: ["source/frame-00001.dng", "source/frame-00002.dng", "source/frames.timestamps", "shapes.json"],
                                         blends: ["\(blendID).mp4", "unlisted.mp4"])
        _ = try makeProject(missingFrame, files: ["source/frame-00001.dng", "source/extra.dng"])
        _ = try makeProject(orphan, files: ["source/frame-00001.dng"])
        _ = try makeProject(emptyFolder, files: ["source/capture_log.json"])
        // A hash line for one of the good project's frames, and a stale one.
        try AssetRecords.append({ var r = AssetRecord(name: "source/frame-00001.dng"); r.bytes = 100; r.hash = "sha256:x"; return r }(),
                                to: AssetRecords.url(inProjectFolder: goodFolder))
        try AssetRecords.append({ var r = AssetRecord(name: "source/frame-00002.dng"); r.bytes = 5; r.hash = "sha256:y"; return r }(),
                                to: AssetRecords.url(inProjectFolder: goodFolder))

        try writeManifest([
            "gradingSchemaVersion": 3,
            "captures": [
                ["id": good, "kind": "photos", "sourceFileNames": ["source/frame-00001.dng", "source/frame-00002.dng", "source/frame-00003.json"],
                 "originID": good, "importedFromID": noFolder],
                ["id": missingFrame, "kind": "photos", "sourceFileNames": ["source/frame-00001.dng", "source/frame-00002.dng"]],
                ["id": noFolder, "kind": "photos", "sourceFileNames": ["source/frame-00001.dng"]],
                ["id": emptyFolder, "kind": "photos", "sourceFileNames": ["source/frame-00001.dng"]],
                ["id": "66666666-6666-6666-6666-666666666666", "kind": "photos", "sourceFileNames": [], "deletedAt": 800000000],
            ],
            "blends": [
                ["id": blendID, "captureID": good, "outputFileName": "blends/\(blendID).mp4"],
                ["id": ghostBlend, "captureID": good, "outputFileName": "blends/\(ghostBlend).png"],
                ["id": "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", "captureID": "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD", "outputFileName": "blends/x.mp4"],
            ],
            "collections": [],
        ])

        let report = LibraryAudit.run(root: root)
        XCTAssertTrue(report.manifestDecoded)
        XCTAssertEqual(report.gradingSchemaVersion, 3)
        XCTAssertEqual(report.captureCount, 4, "the tombstone is not live")
        XCTAssertEqual(report.tombstonedCaptures, 1)
        XCTAssertEqual(report.blendCount, 3)
        XCTAssertEqual(report.projectFolderCount, 4)
        XCTAssertEqual(report.orphanFolders, [orphan])
        XCTAssertEqual(report.recordsWithoutFolder, [noFolder])
        XCTAssertEqual(report.recordsOverEmptyFolder, [emptyFolder])
        XCTAssertEqual(report.missingListedFileCount, 3, "frame-00003.json, frame-00002 of the second, frame-00001 of the empty")
        XCTAssertEqual(report.unlistedMediaCount, 1)
        XCTAssertEqual(report.unlistedMedia.first?.examples, ["extra.dng"])
        XCTAssertEqual(report.jsonNameCount, 1)
        XCTAssertEqual(report.unlistedBlendFileCount, 1)
        XCTAssertEqual(report.unlistedBlendFiles.first?.examples, ["unlisted.mp4"])
        XCTAssertEqual(report.blendRecordsMissingFileCount, 1)
        XCTAssertEqual(report.blendRecordsWithoutCapture, 1)
        XCTAssertEqual(report.sidecarPresence["source/frames.timestamps"], 1)
        XCTAssertEqual(report.sidecarPresence["source/capture_log.json"], 1)
        XCTAssertEqual(report.sidecarPresence["shapes.json"], 1)
        XCTAssertEqual(report.sidecarPresence["assets.ndjson"], 1)
        XCTAssertEqual(report.capturesWithOriginID, 1)
        XCTAssertEqual(report.distinctOriginIDs, 1)
        XCTAssertEqual(report.capturesWithImportedFromID, 1)
        XCTAssertEqual(report.importedFromResolvedLocally, 1)
        // Hashes: the good project's two frames + its one real blend file;
        // one hashed, one stale.
        XCTAssertEqual(report.assetCount, 2 + 1 + 1, "two frames, one blend and the second project's one present frame")
        XCTAssertEqual(report.hashedAssetCount, 1)
        XCTAssertEqual(report.staleAssetRecords, 1)
        XCTAssertEqual(report.projectsWithAssetRecords, 1)
        XCTAssertFalse(report.consistent)

        let json = try JSONSerialization.jsonObject(with: try LibraryAudit.json(report)) as? [String: Any]
        XCTAssertEqual((json?["consistency"] as? [String: Any])?["consistent"] as? Bool, false)
        XCTAssertEqual(((json?["hashes"] as? [String: Any])?["hashed"] as? Int), 1)
        XCTAssertTrue(LibraryAudit.text(report).contains("AUDIT INCONSISTENT"))
    }

    func testCleanLibraryIsConsistentAndTrashIsMeasured() throws {
        let id = "11111111-1111-1111-1111-111111111111"
        _ = try makeProject(id, files: ["source/frame-00001.dng"])
        try writeManifest(["captures": [["id": id, "kind": "photos", "sourceFileNames": ["source/frame-00001.dng"]]], "blends": [], "collections": []])
        let trash = projects.appendingPathComponent(".trash/deleted-1", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try Data(count: 300).write(to: trash.appendingPathComponent("frame.dng"))

        let report = LibraryAudit.run(root: root)
        XCTAssertTrue(report.consistent, LibraryAudit.text(report))
        XCTAssertEqual(report.trashFolders, 1)
        XCTAssertEqual(report.trashBytes, 300)
        XCTAssertEqual(report.orphanFolders, [], ".trash is not an orphan")

        // Pointing at Projects/ itself works too.
        XCTAssertTrue(LibraryAudit.run(root: projects).consistent)
    }

    func testUnreadableManifestIsReportedNotThrown() throws {
        try Data("{not json".utf8).write(to: projects.appendingPathComponent("library.json"))
        try Data("{}".utf8).write(to: projects.appendingPathComponent("library.json.unreadable-2026-09-13"))
        let report = LibraryAudit.run(root: root)
        XCTAssertFalse(report.manifestDecoded)
        XCTAssertNotNil(report.manifestError)
        XCTAssertEqual(report.unreadableManifests, ["library.json.unreadable-2026-09-13"])
        XCTAssertFalse(report.consistent)
    }

    /// M1: the manifest is a generated export, and the copy of the last
    /// pre-switch manifest is listed as kept — neither is an inconsistency.
    func testGeneratedExportAndPreSwitchCopyAreReported() throws {
        let id = "11111111-1111-1111-1111-111111111111"
        _ = try makeProject(id, files: ["source/frame-00001.dng"])
        let captures: [[String: Any]] = [["id": id, "kind": "photos", "sourceFileNames": ["source/frame-00001.dng"]]]
        try writeManifest(["captures": captures, "blends": [], "collections": []])
        var report = LibraryAudit.run(root: root)
        XCTAssertFalse(report.manifestGenerated, "a manifest without the marker is a pre-switch one")
        XCTAssertTrue(report.consistent)

        try writeManifest(["captures": captures, "blends": [], "collections": [], "generated": true])
        try Data("{}".utf8).write(to: projects.appendingPathComponent("library.json.pre-switch-20260914-070000"))
        report = LibraryAudit.run(root: root)
        XCTAssertTrue(report.manifestGenerated)
        XCTAssertEqual(report.preSwitchManifests, ["library.json.pre-switch-20260914-070000"])
        XCTAssertEqual(report.unreadableManifests, [])
        XCTAssertTrue(report.consistent, LibraryAudit.text(report))
        XCTAssertTrue(LibraryAudit.text(report).contains("generated export"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryAudit.json(report)) as? [String: Any])
        XCTAssertEqual((json["manifest"] as? [String: Any])?["generated"] as? Bool, true)
    }
}

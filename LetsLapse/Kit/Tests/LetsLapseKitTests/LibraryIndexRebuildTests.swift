import XCTest
@testable import LetsLapseKit

/// The Phase 2 acceptance instrument on a synthetic tree: an index and the
/// documents that agree with it, and every way they can stop agreeing.
final class LibraryIndexRebuildTests: XCTestCase {

    private var root: URL!
    private var projects: URL { root.appendingPathComponent("Projects", isDirectory: true) }

    private let live = "11111111-1111-1111-1111-111111111111"
    private let gone = "22222222-2222-2222-2222-222222222222"
    private let blendA = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let blendB = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rebuild-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projects.appendingPathComponent(".trash"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    /// The manifest form: seconds since 2001, full precision.
    private func indexCapture(_ id: String, deleted: Bool = false) -> [String: Any] {
        var record: [String: Any] = [
            "id": id, "kind": "photos", "createdAt": 810899371.0, "addedAt": 810901537.476734,
            "originalName": "3 photos", "mode": "Photo",
            "sourceFileNames": ["source/a.dng", "source/b.dng"],
            "adjustments": ["v": 2, "exposure": 0.25, "contrast": 0],
            "presetState": ["kind": "original"],
            "sourceWidth": 4032, "sourceHeight": 3024,
            "originID": id,
        ]
        if deleted { record["deletedAt"] = 810912150.335635 }
        return record
    }

    private func indexBlend(_ id: String, capture: String) -> [String: Any] {
        [
            "id": id, "captureID": capture, "kind": "video", "createdAt": 810905000.5,
            "outputFileName": "blends/\(id).mp4", "summary": "10 frames", "linearLight": true,
            "useRamp": false, "rampStart": 0, "rampEnd": 0, "curve": "linear",
            "warp": ["bounds": [0, 10], "speeds": [1.0], "seams": []],
        ]
    }

    /// The document form of the same record: ISO-8601 dates to the millisecond.
    private func documentForm(_ record: [String: Any]) -> [String: Any] {
        var out = record
        for key in ProjectDocumentFormat.dateKeys {
            if let seconds = record[key] as? Double {
                out[key] = ProjectDocumentFormat.documentDate(fromManifestSeconds: seconds)
            }
        }
        return out
    }

    private func writeIndex(captures: [[String: Any]], blends: [[String: Any]]) throws {
        let object: [String: Any] = ["captures": captures, "blends": blends, "collections": [], "gradingSchemaVersion": 4]
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: projects.appendingPathComponent("library.json"))
    }

    private func writeDocument(capture: [String: Any], blends: [[String: Any]], inTrash: Bool = false) throws {
        let id = capture["id"] as! String
        let folder = (inTrash ? projects.appendingPathComponent(".trash") : projects).appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let object: [String: Any] = [
            "formatVersion": ProjectDocumentFormat.current,
            "capture": documentForm(capture), "blends": blends.map(documentForm),
        ]
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: ProjectDocumentFormat.url(inProjectFolder: folder))
    }

    private func writeAgreeingTree() throws {
        try writeIndex(
            captures: [indexCapture(live), indexCapture(gone, deleted: true)],
            blends: [indexBlend(blendA, capture: live), indexBlend(blendB, capture: gone)])
        try writeDocument(capture: indexCapture(live), blends: [indexBlend(blendA, capture: live)])
        try writeDocument(capture: indexCapture(gone, deleted: true), blends: [indexBlend(blendB, capture: gone)], inTrash: true)
    }

    // MARK: - Tests

    func testAgreeingTreeIsIdentical() throws {
        try writeAgreeingTree()
        let report = LibraryIndexRebuild.run(root: root)
        XCTAssertTrue(report.indexReadable)
        XCTAssertEqual(report.documentsRead, 2)
        XCTAssertEqual(report.documentsInTrash, 1)
        XCTAssertEqual(report.rebuiltCaptures, 2)
        XCTAssertEqual(report.rebuiltBlends, 2)
        XCTAssertEqual(report.differences, [])
        XCTAssertEqual(report.onlyInIndex, [])
        XCTAssertEqual(report.onlyInDocuments, [])
        XCTAssertTrue(report.identical, LibraryIndexRebuild.text(report))
        XCTAssertEqual(report.documentFormatVersions, [2: 2])
    }

    func testStorageRootOrProjectsFolderBothWork() throws {
        try writeAgreeingTree()
        XCTAssertTrue(LibraryIndexRebuild.run(root: projects).identical)
    }

    func testOneChangedFieldIsOneDifference() throws {
        try writeAgreeingTree()
        var changed = indexCapture(live)
        changed["adjustments"] = ["v": 2, "exposure": 0.5, "contrast": 0]
        try writeIndex(captures: [changed, indexCapture(gone, deleted: true)],
                       blends: [indexBlend(blendA, capture: live), indexBlend(blendB, capture: gone)])
        let report = LibraryIndexRebuild.run(root: root)
        XCTAssertFalse(report.identical)
        XCTAssertEqual(report.differences.count, 1)
        XCTAssertEqual(report.differences.first?.record, "capture \(live)")
        XCTAssertEqual(report.differences.first?.path, "adjustments.exposure")
        XCTAssertEqual(report.differences.first?.index, "0.5")
        XCTAssertEqual(report.differences.first?.document, "0.25")
    }

    func testMissingDocumentAndExtraDocumentAreListed() throws {
        try writeAgreeingTree()
        try FileManager.default.removeItem(at: projects.appendingPathComponent(".trash/\(gone)"))
        let extra = "33333333-3333-3333-3333-333333333333"
        try writeDocument(capture: indexCapture(extra), blends: [])
        let report = LibraryIndexRebuild.run(root: root)
        XCTAssertEqual(report.onlyInIndex, ["capture \(gone)", "blend \(blendB)"])
        XCTAssertEqual(report.onlyInDocuments, ["capture \(extra)"])
        XCTAssertEqual(report.differences, [])
        XCTAssertFalse(report.identical)
    }

    func testFolderWithoutDocumentAndUnreadableDocumentAreReported() throws {
        try writeAgreeingTree()
        let bare = "44444444-4444-4444-4444-444444444444"
        try FileManager.default.createDirectory(at: projects.appendingPathComponent(bare), withIntermediateDirectories: true)
        let torn = "55555555-5555-5555-5555-555555555555"
        try FileManager.default.createDirectory(at: projects.appendingPathComponent(torn), withIntermediateDirectories: true)
        try Data("{\"formatVersion\": 2, \"capture\": {".utf8)
            .write(to: ProjectDocumentFormat.url(inProjectFolder: projects.appendingPathComponent(torn)))
        let report = LibraryIndexRebuild.run(root: root)
        XCTAssertEqual(report.foldersWithoutDocument, [bare])
        XCTAssertEqual(report.unreadableDocuments.count, 1)
        XCTAssertTrue(report.unreadableDocuments[0].hasPrefix(torn))
        // Neither disturbs the records that do agree.
        XCTAssertTrue(report.identical)
    }

    func testArrayLengthAndOrderDifferencesAreCaught() throws {
        try writeAgreeingTree()
        var reordered = indexCapture(live)
        reordered["sourceFileNames"] = ["source/b.dng", "source/a.dng"]
        try writeIndex(captures: [reordered, indexCapture(gone, deleted: true)],
                       blends: [indexBlend(blendA, capture: live), indexBlend(blendB, capture: gone)])
        var report = LibraryIndexRebuild.run(root: root)
        XCTAssertEqual(report.differences.map(\.path), ["sourceFileNames[0]", "sourceFileNames[1]"])

        var shorter = indexCapture(live)
        shorter["sourceFileNames"] = ["source/a.dng"]
        try writeIndex(captures: [shorter, indexCapture(gone, deleted: true)],
                       blends: [indexBlend(blendA, capture: live), indexBlend(blendB, capture: gone)])
        report = LibraryIndexRebuild.run(root: root)
        XCTAssertEqual(report.differences.map(\.path), ["sourceFileNames"])
        XCTAssertEqual(report.differences.first?.index, "1 items")
    }

    func testCanonicalDatesAgreeToTheMillisecond() {
        // The manifest's microseconds round to the document's milliseconds…
        let fromSeconds = LibraryIndexRebuild.canonical(["createdAt": 810901537.476734])
        XCTAssertEqual(fromSeconds["createdAt"] as? String, "2026-09-12T10:25:37.477Z")
        // …a whole-second archive stamp gains its `.000`…
        let fromPlain = LibraryIndexRebuild.canonical(["createdAt": "2026-09-12T10:25:37Z"])
        XCTAssertEqual(fromPlain["createdAt"] as? String, "2026-09-12T10:25:37.000Z")
        // …a document stamp is left as it is, and a non-date key is untouched.
        let fromDocument = LibraryIndexRebuild.canonical(["createdAt": "2026-09-12T10:25:37.477Z", "sourceFPS": 30])
        XCTAssertEqual(fromDocument["createdAt"] as? String, "2026-09-12T10:25:37.477Z")
        XCTAssertEqual(fromDocument["sourceFPS"] as? Int, 30)
        // Both encodings of one instant compare equal.
        XCTAssertEqual(LibraryIndexRebuild.differences(
            between: fromSeconds, and: fromDocument.filter { $0.key == "createdAt" }, record: "x"), [])
    }

    func testRebuiltManifestIsTheAppsEncoding() throws {
        try writeAgreeingTree()
        let data = try LibraryIndexRebuild.rebuiltManifest(root: root)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let captures = try XCTUnwrap(object["captures"] as? [[String: Any]])
        XCTAssertEqual(captures.count, 2)
        // Live first, tombstones after; dates back to seconds since 2001, to
        // the millisecond.
        XCTAssertEqual(captures[0]["id"] as? String, live)
        XCTAssertEqual(captures[1]["id"] as? String, gone)
        XCTAssertEqual(captures[0]["addedAt"] as? Double ?? 0, 810901537.477, accuracy: 0.0005)
        XCTAssertNil(captures[0]["deletedAt"])
        XCTAssertNotNil(captures[1]["deletedAt"])
        XCTAssertEqual(object["gradingSchemaVersion"] as? Int, 4)
        XCTAssertEqual((object["blends"] as? [[String: Any]])?.count, 2)
        // The rebuilt manifest, put in place of the real one, is identical
        // to the documents it came from.
        try data.write(to: projects.appendingPathComponent("library.json"))
        XCTAssertTrue(LibraryIndexRebuild.run(root: root).identical)
    }

    func testUnreadableIndexIsReportedNotDiffed() throws {
        try writeAgreeingTree()
        try Data("{".utf8).write(to: projects.appendingPathComponent("library.json"))
        let report = LibraryIndexRebuild.run(root: root)
        XCTAssertFalse(report.indexReadable)
        XCTAssertFalse(report.identical)
        XCTAssertEqual(report.documentsRead, 2)
        XCTAssertEqual(report.differences, [])
    }

    func testDocumentFormatCoding() throws {
        struct Record: Codable, Equatable { var createdAt: Date; var name: String }
        let stamp = Date(timeIntervalSinceReferenceDate: 810901537.476734)
        let data = try ProjectDocumentFormat.makeEncoder().encode(Record(createdAt: stamp, name: "source/a.dng"))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"2026-09-12T10:25:37.477Z\""), text)
        XCTAssertTrue(text.contains("source/a.dng"), "slashes are not escaped")
        let back = try ProjectDocumentFormat.makeDecoder().decode(Record.self, from: data)
        XCTAssertEqual(back.createdAt.timeIntervalSinceReferenceDate, 810901537.477, accuracy: 0.0005)
        // A format-1 archive manifest — plain `.iso8601` — reads too.
        let plain = Data("{\"createdAt\":\"2026-09-12T10:25:37Z\",\"name\":\"x\"}".utf8)
        XCTAssertEqual(try ProjectDocumentFormat.makeDecoder().decode(Record.self, from: plain).createdAt.timeIntervalSinceReferenceDate,
                       810901537, accuracy: 0.0005)
    }
}

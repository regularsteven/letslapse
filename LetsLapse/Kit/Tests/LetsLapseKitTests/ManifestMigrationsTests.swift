import XCTest
@testable import LetsLapseKit

/// W4: the v4 step on the real key shapes of Part 1 §3.1, and every
/// tolerance the JSON-level pattern promises.
final class ManifestMigrationsTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("migrations-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(for id: String) -> URL? { root.appendingPathComponent(id, isDirectory: true) }

    private let captured = "11111111-1111-1111-1111-111111111111"
    private let imported = "22222222-2222-2222-2222-222222222222"
    private let sender = "99999999-9999-9999-9999-999999999999"
    private let clone = "33333333-3333-3333-3333-333333333333"

    /// A v3 manifest as the app writes one: seconds-since-2001 dates, sorted
    /// keys, `presetState`, a ramp shoot's `sequence.json` among the frames
    /// and the misregistered experiment log.
    private func v3Fixture() -> [String: Any] {
        [
            "gradingSchemaVersion": 3,
            "captures": [
                [
                    "id": captured, "kind": "photos", "createdAt": 810405132.88284, "addedAt": 810405132.88284,
                    "originalName": "212 photos", "mode": "Interval · DNG",
                    "sourceFileNames": ["source/frame-00001.dng", "source/frame-00002.dng", "source/frame-00003.json"],
                    "presetState": ["kind": "named", "id": "natural"],
                    "selectedPreset": "Natural", "sourceWidth": 4032, "sourceHeight": 3024,
                    "adjustments": ["v": 2, "exposure": 0.25, "contrast": 0, "whiteMired": 12.5],
                ] as [String: Any],
                [
                    "id": imported, "kind": "video", "createdAt": 800000000.0, "addedAt": 810000000.0,
                    "originalName": "Ramp capture", "mode": "Ramp capture · 2 ramp intervals",
                    "sourceFileNames": ["source/segment-000.mov", "source/segment-001.mov", "source/sequence.json"],
                    "importedFromID": sender, "sourceFPS": 30, "sourceSegmentFPS": ["segment-000.mov": 29.97],
                ] as [String: Any],
                [
                    "id": clone, "kind": "photos", "createdAt": 810405132.88284, "addedAt": 810500000.0,
                    "originalName": "212 photos", "mode": "Interval · DNG", "name": "212 photos · lossy DNG",
                    "sourceFileNames": ["source/frame-00001.dng", "source/frame-00002.dng"],
                ] as [String: Any],
            ],
            "blends": [
                ["id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", "captureID": captured, "kind": "video",
                 "createdAt": 810405200.0, "outputFileName": "blends/AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA.mp4",
                 "summary": "10:1", "linearLight": true, "useRamp": false, "rampStart": 1, "rampEnd": 1, "curve": "linear"] as [String: Any],
            ],
            "collections": [] as [Any],
        ]
    }

    private func bytes(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func capture(_ id: String, in manifest: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap((manifest["captures"] as? [[String: Any]])?.first { $0["id"] as? String == id })
    }

    func testV3BecomesTheExpectedV4() throws {
        // The clone's ledger names the captured project as its parent.
        let cloneFolder = try XCTUnwrap(folder(for: clone))
        try FileManager.default.createDirectory(at: cloneFolder, withIntermediateDirectories: true)
        try bytes(["sourceProjectID": captured, "strategy": "lossy"]).write(to: cloneFolder.appendingPathComponent("dng-archive.json"))

        let outcome = try ManifestMigrations.apply(to: try bytes(v3Fixture()), projectFolder: folder(for:))
        XCTAssertEqual(outcome.version, 4)
        XCTAssertFalse(outcome.log.isEmpty)
        let migrated = try object(outcome.data)
        XCTAssertEqual(migrated["gradingSchemaVersion"] as? Int, 4)

        let shot = try capture(captured, in: migrated)
        XCTAssertEqual(shot["originID"] as? String, captured, "a capture's origin is its own id")
        XCTAssertNil(shot["originDeviceID"], "never invented")
        XCTAssertNil(shot["derivedFromOriginID"])
        XCTAssertEqual(shot["sourceFileNames"] as? [String], ["source/frame-00001.dng", "source/frame-00002.dng"], "the .json frame is gone")
        XCTAssertEqual((shot["adjustments"] as? [String: Any])?["whiteMired"] as? Double, 12.5, "untouched keys survive")
        XCTAssertEqual(shot["createdAt"] as? Double, 810405132.88284, "dates keep their value")

        let received = try capture(imported, in: migrated)
        XCTAssertEqual(received["originID"] as? String, sender, "a one-hop import's origin is the sender's id")
        XCTAssertEqual(received["importedFromID"] as? String, sender, "the transport history stays")
        XCTAssertEqual(received["sourceFileNames"] as? [String], ["source/segment-000.mov", "source/segment-001.mov"],
                       "sequence.json is a .json name too — it comes off the FRAME list (the app resolves it by name)")

        let derived = try capture(clone, in: migrated)
        XCTAssertEqual(derived["originID"] as? String, clone)
        XCTAssertEqual(derived["derivedFromOriginID"] as? String, captured, "the ledger's parent, by origin")

        // Blends and collections pass through untouched.
        XCTAssertEqual((migrated["blends"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((migrated["collections"] as? [Any])?.count, 0)

        // Running it again is a no-op: v4 passes through byte for byte.
        let again = try ManifestMigrations.apply(to: outcome.data, projectFolder: folder(for:))
        XCTAssertEqual(again.data, outcome.data)
        XCTAssertTrue(again.log.isEmpty)
    }

    func testFutureVersionPassesThroughUntouched() throws {
        var fixture = v3Fixture()
        fixture["gradingSchemaVersion"] = 99
        fixture["somethingNewer"] = ["a": 1]
        let data = try bytes(fixture)
        let outcome = try ManifestMigrations.apply(to: data, projectFolder: folder(for:))
        XCTAssertEqual(outcome.data, data)
        XCTAssertEqual(outcome.version, 99)
        XCTAssertTrue(outcome.log.isEmpty)
    }

    func testOlderThanSwiftStepsChangesContentButNotTheCounter() throws {
        var fixture = v3Fixture()
        fixture["gradingSchemaVersion"] = 2
        let outcome = try ManifestMigrations.apply(to: try bytes(fixture), projectFolder: folder(for:))
        let migrated = try object(outcome.data)
        XCTAssertEqual(migrated["gradingSchemaVersion"] as? Int, 2, "the app's addedAt stamp still has to run")
        XCTAssertEqual(try capture(captured, in: migrated)["originID"] as? String, captured)
        XCTAssertEqual(try capture(captured, in: migrated)["sourceFileNames"] as? [String], ["source/frame-00001.dng", "source/frame-00002.dng"])
        XCTAssertTrue(outcome.log.contains { $0.contains("left at 2") })

        // No version key at all reads as 0 and behaves the same.
        fixture["gradingSchemaVersion"] = nil
        let unversioned = try ManifestMigrations.apply(to: try bytes(fixture), projectFolder: folder(for:))
        XCTAssertNil(try object(unversioned.data)["gradingSchemaVersion"])
        XCTAssertEqual(try capture(imported, in: try object(unversioned.data))["originID"] as? String, sender)
    }

    func testExistingOriginIsKeptAndAMissingLedgerLeavesNoLink() throws {
        var fixture = v3Fixture()
        var captures = fixture["captures"] as! [[String: Any]]
        captures[0]["originID"] = "77777777-7777-7777-7777-777777777777"
        fixture["captures"] = captures
        let migrated = try object(try ManifestMigrations.apply(to: try bytes(fixture), projectFolder: folder(for:)).data)
        XCTAssertEqual(try capture(captured, in: migrated)["originID"] as? String, "77777777-7777-7777-7777-777777777777")
        XCTAssertNil(try capture(clone, in: migrated)["derivedFromOriginID"], "no dng-archive.json on disk → nothing assigned")

        // A ledger whose parent is not in this manifest assigns nothing either.
        let cloneFolder = try XCTUnwrap(folder(for: clone))
        try FileManager.default.createDirectory(at: cloneFolder, withIntermediateDirectories: true)
        try bytes(["sourceProjectID": "DEADBEEF-0000-0000-0000-000000000000"]).write(to: cloneFolder.appendingPathComponent("dng-archive.json"))
        let migrated2 = try object(try ManifestMigrations.apply(to: try bytes(fixture), projectFolder: folder(for:)).data)
        XCTAssertNil(try capture(clone, in: migrated2)["derivedFromOriginID"])
    }

    func testRandomRemovalOfAnyOptionalKeyNeverThrows() throws {
        let fixture = v3Fixture()
        let captures = fixture["captures"] as! [[String: Any]]
        let optionalKeys = ["addedAt", "originalName", "mode", "sourceFileNames", "presetState", "selectedPreset",
                            "sourceWidth", "sourceHeight", "adjustments", "importedFromID", "sourceFPS",
                            "sourceSegmentFPS", "name", "id", "kind", "createdAt"]
        for key in optionalKeys {
            var stripped = fixture
            stripped["captures"] = captures.map { capture in
                var copy = capture
                copy[key] = nil
                return copy
            }
            XCTAssertNoThrow(try ManifestMigrations.apply(to: try bytes(stripped), projectFolder: folder(for:)), "removing \(key)")
        }
        for topLevel in ["blends", "collections", "captures"] {
            var stripped = fixture
            stripped[topLevel] = nil
            XCTAssertNoThrow(try ManifestMigrations.apply(to: try bytes(stripped), projectFolder: folder(for:)), "removing \(topLevel)")
        }
        // A capture that is not even an object is skipped, not fatal.
        var odd = fixture
        odd["captures"] = ["not an object", 42]
        XCTAssertNoThrow(try ManifestMigrations.apply(to: try bytes(odd), projectFolder: folder(for:)))
    }

    func testNotAJSONObjectThrows() {
        XCTAssertThrowsError(try ManifestMigrations.apply(to: Data("[1,2]".utf8), projectFolder: folder(for:)))
        XCTAssertThrowsError(try ManifestMigrations.apply(to: Data("{not json".utf8), projectFolder: folder(for:)))
    }
}

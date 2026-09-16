import XCTest
@testable import LetsLapseKit

final class SceneAnalysisRecordTests: XCTestCase {

    private func scratchFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("scene-analysis-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testRoundTripsThroughTheProjectFolder() throws {
        let folder = scratchFolder()
        let id = UUID()
        let record = SceneAnalysisRecord(
            assetID: id, sourceFrameID: "source/frame-00012.dng", engine: .vision,
            producedAt: Date(timeIntervalSince1970: 1_800_000_000),
            labels: [.init(identifier: "waterfall", confidence: 0.91), .init(identifier: "outdoor", confidence: 0.99)],
            hasText: true, faceCount: 2)
        try record.write(inProjectFolder: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("scene-analysis.json").path))
        let loaded = try XCTUnwrap(SceneAnalysisRecord.load(inProjectFolder: folder))
        XCTAssertEqual(loaded, record)
        XCTAssertNil(loaded.sceneText, "Vision describes nothing")
        XCTAssertEqual(loaded.recognisedText, [])
    }

    func testCacheKeyIsAssetFrameAndSchema() throws {
        let folder = scratchFolder()
        let id = UUID()
        let record = SceneAnalysisRecord(
            assetID: id, sourceFrameID: "blends/stack.jpg", engine: .gemma,
            labels: [.init(identifier: "urban", confidence: 0.8)], sceneText: "Dusk in Prague with river")
        try record.write(inProjectFolder: folder)

        XCTAssertNotNil(SceneAnalysisRecord.current(inProjectFolder: folder, assetID: id, sourceFrameID: "blends/stack.jpg"))
        XCTAssertNil(SceneAnalysisRecord.current(inProjectFolder: folder, assetID: id, sourceFrameID: "source/frame-00001.dng"),
                     "a changed thumbnail frame invalidates")
        XCTAssertNil(SceneAnalysisRecord.current(inProjectFolder: folder, assetID: UUID(), sourceFrameID: "blends/stack.jpg"),
                     "another project's record never answers")

        var stale = record
        stale.schemaVersion = SceneAnalysisRecord.currentSchema - 1
        try stale.write(inProjectFolder: folder)
        XCTAssertNil(SceneAnalysisRecord.current(inProjectFolder: folder, assetID: id, sourceFrameID: "blends/stack.jpg"),
                     "an older schema invalidates en masse")

        // The engine is NOT part of the key: a Vision record stays current after Gemma is installed.
        var vision = record
        vision.engine = .vision
        try vision.write(inProjectFolder: folder)
        XCTAssertEqual(SceneAnalysisRecord.current(inProjectFolder: folder, assetID: id, sourceFrameID: "blends/stack.jpg")?.engine, .vision)
    }

    func testUnreadableRecordIsAMiss() throws {
        let folder = scratchFolder()
        try Data("not json".utf8).write(to: SceneAnalysisRecord.url(inProjectFolder: folder))
        XCTAssertNil(SceneAnalysisRecord.load(inProjectFolder: folder))
        XCTAssertNil(SceneAnalysisRecord.current(inProjectFolder: folder, assetID: UUID(), sourceFrameID: "x"))
    }

    func testRegisteredAsATravellingDerivedSidecar() {
        let entry = ProjectFileRegistry.entry(forRelativePath: SceneAnalysisRecord.fileName)
        XCTAssertEqual(entry?.class, .derived)
        XCTAssertEqual(entry?.travels, true)
        XCTAssertTrue(ProjectFileRegistry.travellingRootFiles.contains(SceneAnalysisRecord.fileName))
    }
}

final class SceneTagReconcilerTests: XCTestCase {

    private let taxonomy = ["water", "skyWeather", "urban", "nature", "landmark", "people",
                            "vehicles", "lightTrails", "animals", "construction", "interior", "event"]

    func testExactMatchIsCaseAndDiacriticInsensitive() {
        let existing = taxonomy + ["Rooftops", "Šumava"]
        XCTAssertEqual(SceneTagReconciler.reconcile("URBAN", existing: existing), .existing("urban"))
        XCTAssertEqual(SceneTagReconciler.reconcile("rooftops", existing: existing), .existing("Rooftops"))
        XCTAssertEqual(SceneTagReconciler.reconcile("Sumava", existing: existing), .existing("Šumava"))
        XCTAssertEqual(SceneTagReconciler.reconcile("  sky &   weather ", existing: existing), .existing("skyWeather"),
                       "the chip label names the stored value")
        XCTAssertEqual(SceneTagReconciler.reconcile("Light trails", existing: existing), .existing("lightTrails"))
    }

    func testAliasMapsToTheTaxonomyValue() {
        XCTAssertEqual(SceneTagReconciler.reconcile("building", existing: taxonomy), .existing("urban"))
        XCTAssertEqual(SceneTagReconciler.reconcile("Sky", existing: taxonomy), .existing("skyWeather"))
        XCTAssertEqual(SceneTagReconciler.reconcile("river", existing: taxonomy), .existing("water"))
        // Even in a library that has never used the value, the taxonomy is existing by definition.
        XCTAssertEqual(SceneTagReconciler.reconcile("clouds", existing: ["Rooftops"]), .existing("skyWeather"))
    }

    func testOtherwiseNewWithFirstLetterRaised() {
        XCTAssertEqual(SceneTagReconciler.reconcile("waterfront", existing: taxonomy), .new("Waterfront"))
        XCTAssertEqual(SceneTagReconciler.reconcile("sunset", existing: taxonomy), .new("Sunset"),
                       "a subject in its own right is not folded into the taxonomy")
        XCTAssertEqual(SceneTagReconciler.reconcile("mossy  rocks", existing: taxonomy), .new("Mossy rocks"))
        XCTAssertNil(SceneTagReconciler.reconcile("   ", existing: taxonomy))
        // No fuzzy matching: a proper noun one letter off an existing tag stays its own tag.
        XCTAssertEqual(SceneTagReconciler.reconcile("Karlin", existing: taxonomy + ["Karlín"]), .existing("Karlín"),
                       "diacritics fold")
        XCTAssertEqual(SceneTagReconciler.reconcile("Karlina", existing: taxonomy + ["Karlín"]), .new("Karlina"))
    }

    func testListDropsDuplicatesAndAppliedTags() {
        let resolved = SceneTagReconciler.reconcile(
            ["building", "Urban", "city", "waterfront", "Waterfront", "water", "river"],
            existing: taxonomy, applied: ["water"])
        XCTAssertEqual(resolved.map(\.tag), ["urban", "Waterfront"])
        XCTAssertEqual(resolved.map(\.isNew), [false, true])
    }
}

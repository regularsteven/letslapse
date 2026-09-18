import XCTest
@testable import LetsLapseKit

final class ProjectFileRegistryTests: XCTestCase {

    func testPatternsMatchTheirFamilyOnly() {
        let ramp = ProjectFile("frame-*.json", at: .source, class: .captureFact, travels: true)
        XCTAssertTrue(ramp.isPattern)
        XCTAssertTrue(ramp.matches(fileName: "frame-05661.json"))
        XCTAssertTrue(ramp.matches(fileName: "frame-.json"))
        XCTAssertFalse(ramp.matches(fileName: "frame-05661.dng"))
        XCTAssertFalse(ramp.matches(fileName: "xframe-1.json"))
        XCTAssertFalse(ramp.matches(fileName: "frame.json"), "the prefix and suffix must both fit")
        let plain = ProjectFile("capture_log.json", at: .source, class: .captureFact, travels: true)
        XCTAssertFalse(plain.isPattern)
        XCTAssertTrue(plain.matches(fileName: "capture_log.json"))
        XCTAssertFalse(plain.matches(fileName: "capture_log.json.bak"))
    }

    func testEntryForRelativePathClassifiesEveryShape() throws {
        XCTAssertEqual(ProjectFileRegistry.entry(forRelativePath: "assets.ndjson")?.class, .edit)
        XCTAssertEqual(ProjectFileRegistry.entry(forRelativePath: "poster.jpg")?.class, .derived)
        XCTAssertEqual(ProjectFileRegistry.entry(forRelativePath: "dng-archive.json")?.travels, false)
        XCTAssertNil(ProjectFileRegistry.entry(forRelativePath: "frame-00001-graded.jpg"), "a stray at the root")
        XCTAssertNil(ProjectFileRegistry.entry(forRelativePath: ".DS_Store"))

        XCTAssertEqual(ProjectFileRegistry.entry(forRelativePath: "source/capture_log.json")?.location, .source)
        XCTAssertEqual(ProjectFileRegistry.entry(forRelativePath: "source/frame-02754.json")?.name, "frame-*.json")
        XCTAssertEqual(ProjectFileRegistry.entry(forRelativePath: "source/liveblend-20260906-182606.json")?.name, "liveblend-*.json")
        XCTAssertEqual(ProjectFileRegistry.entry(forRelativePath: "source/frame-02754.dng")?.name, "source/", "a media frame is governed by the folder")
        XCTAssertEqual(ProjectFileRegistry.entry(forRelativePath: "source/nested/deeper.json")?.name, "source/", "sidecars sit one level down; deeper is the folder's")

        let masks = try XCTUnwrap(ProjectFileRegistry.entry(forRelativePath: "masks/sky.png"))
        XCTAssertEqual(masks.name, "masks/")
        XCTAssertEqual(masks.class, .edit)
        XCTAssertEqual(ProjectFileRegistry.entry(forRelativePath: "blends/clip.mov")?.class, .derived)
        let lut = try XCTUnwrap(ProjectFileRegistry.entry(forRelativePath: "luts/terra.cube"))
        XCTAssertEqual(lut.name, "luts/")
        XCTAssertEqual(lut.class, .derived, "the library store holds the bytes; a copy in a project is derived")
        XCTAssertFalse(lut.travels, "a cube is a library asset — materialised for the trip, never sent by a sync")
        XCTAssertNil(ProjectFileRegistry.entry(forRelativePath: "exports/x.mov"), "an unregistered folder")
    }

    func testAuditAndTransferListsIgnorePatternsAndCarryThePoster() {
        XCTAssertFalse(ProjectFileRegistry.auditedSidecars.contains { $0.isPattern })
        XCTAssertTrue(ProjectFileRegistry.travellingRootFiles.contains(ProjectFileRegistry.posterName))
        XCTAssertFalse(ProjectFileRegistry.travellingRootFiles.contains(ProjectFileRegistry.projectDocumentName))
        XCTAssertFalse(ProjectFileRegistry.travellingRootFiles.contains { $0.contains("*") })
        XCTAssertFalse(ProjectFileRegistry.travellingSubfolders.contains("luts"), "the installer folds an arriving luts/ into the store; it never moves it")
        XCTAssertTrue(ProjectFileRegistry.travellingSubfolders.contains("source"))
        XCTAssertTrue(ProjectFileRegistry.travellingSubfolders.contains("blends"))
    }
}

final class DirectoryArchiveDeterminismTests: XCTestCase {
    func testContentOnlyArchivesAreByteIdenticalAcrossWrites() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("aar-determinism-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let tree = base.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("source"), withIntermediateDirectories: true)
        try Data("{\"a\":1}\n".utf8).write(to: tree.appendingPathComponent("assets.ndjson"))
        try Data(repeating: 7, count: 100_000).write(to: tree.appendingPathComponent("source/frames.timestamps"))

        let first = base.appendingPathComponent("first.aar")
        try DirectoryArchive.write(contentsOf: tree, to: first, fields: .contentOnly)
        // Touch the tree's times the way a re-staging would (new links, new dirs).
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: tree.appendingPathComponent("assets.ndjson").path)
        let second = base.appendingPathComponent("second.aar")
        try DirectoryArchive.write(contentsOf: tree, to: second, fields: .contentOnly)
        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: second), "content-only archives depend on the bytes alone")

        let restored = base.appendingPathComponent("restored", isDirectory: true)
        try DirectoryArchive.extract(second, to: restored)
        XCTAssertEqual(try Data(contentsOf: restored.appendingPathComponent("assets.ndjson")), Data("{\"a\":1}\n".utf8))
        XCTAssertEqual(try Data(contentsOf: restored.appendingPathComponent("source/frames.timestamps")).count, 100_000)
    }
}

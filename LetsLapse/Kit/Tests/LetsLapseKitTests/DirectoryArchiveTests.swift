import XCTest
@testable import LetsLapseKit

final class DirectoryArchiveTests: XCTestCase {
    /// Round trip a nested directory tree byte-for-byte — the transport under
    /// project share/import.
    func testRoundTripsNestedDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-test-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source-tree", isDirectory: true)
        let archive = root.appendingPathComponent("tree.lapse")
        let restored = root.appendingPathComponent("restored", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("source"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("blends"), withIntermediateDirectories: true)
        let manifest = Data("{\"formatVersion\":1}".utf8)
        var frame = Data(count: 300_000)
        for index in 0..<frame.count { frame[index] = UInt8(index % 251) }
        try manifest.write(to: source.appendingPathComponent("project.json"))
        try frame.write(to: source.appendingPathComponent("source/frame-00001.dng"))
        try Data("blend".utf8).write(to: source.appendingPathComponent("blends/render.mp4"))

        try DirectoryArchive.write(contentsOf: source, to: archive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        try DirectoryArchive.extract(archive, to: restored)

        XCTAssertEqual(try Data(contentsOf: restored.appendingPathComponent("project.json")), manifest)
        XCTAssertEqual(try Data(contentsOf: restored.appendingPathComponent("source/frame-00001.dng")), frame)
        XCTAssertEqual(
            try Data(contentsOf: restored.appendingPathComponent("blends/render.mp4")),
            Data("blend".utf8))
    }

    func testExtractRejectsGarbage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-garbage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bogus = root.appendingPathComponent("bogus.lapse")
        try Data("not an archive at all".utf8).write(to: bogus)
        XCTAssertThrowsError(try DirectoryArchive.extract(bogus, to: root.appendingPathComponent("out")))
    }
}

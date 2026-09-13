import XCTest
@testable import LetsLapseKit

final class AssetHashTests: XCTestCase {

    func testKnownVector() throws {
        // FIPS 180-2 "abc".
        XCTAssertEqual(
            AssetHash.sha256(of: Data("abc".utf8)),
            "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hash-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        XCTAssertEqual(try AssetHash.sha256(of: url), AssetHash.sha256(of: Data("abc".utf8)))
    }

    func testStreamsAcrossChunkBoundaries() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hash-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        // Three MB plus a tail, so the 1 MB chunking is exercised.
        var bytes = Data(count: 3 * (1 << 20) + 17)
        for index in stride(from: 0, to: bytes.count, by: 4099) { bytes[index] = UInt8(index % 251) }
        try bytes.write(to: url)
        XCTAssertEqual(try AssetHash.sha256(of: url), AssetHash.sha256(of: bytes))
    }

    func testEmptyFileAndMissingFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hash-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)
        XCTAssertEqual(
            try AssetHash.sha256(of: url),
            "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let missing = url.deletingLastPathComponent().appendingPathComponent("hash-missing-\(UUID().uuidString).bin")
        XCTAssertThrowsError(try AssetHash.sha256(of: missing)) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(ENOENT))
        }
    }
}

/// The per-asset record file: append, latest-wins, torn last line,
/// compaction through a temp file.
final class AssetRecordsTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("assets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func record(_ name: String, bytes: Int64, hash: String? = nil, title: String? = nil) -> AssetRecord {
        var record = AssetRecord(name: name)
        record.bytes = bytes
        record.hash = hash
        record.hashedAt = hash == nil ? nil : Date(timeIntervalSince1970: 1_800_000_000)
        if let title {
            var imported = AssetMetadata()
            imported.title = title
            record.imported = imported
            record.importedSource = "file"
        }
        return record
    }

    func testRoundTripAppendAndLoad() throws {
        let url = AssetRecords.url(inProjectFolder: folder)
        try AssetRecords.append(record("source/a.dng", bytes: 10, hash: "sha256:aa", title: "A"), to: url)
        try AssetRecords.append(record("blends/b.mp4", bytes: 20, hash: "sha256:bb"), to: url)
        let loaded = AssetRecords.load(inProjectFolder: folder)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded["source/a.dng"]?.hash, "sha256:aa")
        XCTAssertEqual(loaded["source/a.dng"]?.imported?.title, "A")
        XCTAssertEqual(loaded["source/a.dng"]?.hashedAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(loaded.ordered.map(\.name), ["source/a.dng", "blends/b.mp4"])

        // Line shape: one object per line, sorted keys, the plain field names.
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix(#"{"bytes":10,"hash":"sha256:aa","hashedAt":"2027-01-15T08:00:00.000Z","imported":{"title":"A"},"importedSource":"file","name":"source/a.dng"}"#), String(lines[0]))
    }

    func testLatestLineWinsAndCompactionKeepsOnePerName() throws {
        let url = AssetRecords.url(inProjectFolder: folder)
        try AssetRecords.append(record("source/a.dng", bytes: 10), to: url)
        try AssetRecords.append(record("source/b.dng", bytes: 11), to: url)
        var edited = record("source/a.dng", bytes: 10, hash: "sha256:aa")
        edited.edited = { var m = AssetMetadata(); m.rating = 5; return m }()
        edited.editedAt = ["rating": Date(timeIntervalSince1970: 1_800_000_100)]
        try AssetRecords.append(edited, to: url)

        var loaded = AssetRecords.load(from: url)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded["source/a.dng"]?.hash, "sha256:aa")
        XCTAssertEqual(loaded["source/a.dng"]?.edited?.rating, 5)
        XCTAssertTrue(loaded["source/a.dng"]?.isEdited(.rating) == true)
        XCTAssertTrue(AssetRecords.needsCompaction(at: url))

        try loaded.compact(to: url)
        XCTAssertFalse(AssetRecords.needsCompaction(at: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count, 2)
        loaded = AssetRecords.load(from: url)
        XCTAssertEqual(loaded["source/a.dng"]?.edited?.rating, 5)
        XCTAssertEqual(loaded.ordered.map(\.name), ["source/a.dng", "source/b.dng"])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).allSatisfy { !$0.contains(".rewrite-") },
                      "the temp file is gone after replaceItemAt")

        loaded.remove("source/b.dng")
        XCTAssertEqual(loaded.ordered.map(\.name), ["source/a.dng"])
    }

    func testTornLastLineIsSkipped() throws {
        let url = AssetRecords.url(inProjectFolder: folder)
        try AssetRecords.append(record("source/a.dng", bytes: 10, hash: "sha256:aa"), to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"name":"source/b.dng","bytes":1"#.utf8))
        try handle.close()
        let loaded = AssetRecords.load(from: url)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertNotNil(loaded["source/a.dng"])
        // And appending after a torn line lands on its own line.
        try AssetRecords.append(record("source/c.dng", bytes: 12), to: url)
        XCTAssertEqual(AssetRecords.load(from: url).count, 2)
    }

    func testMissingFileIsEmptyAndNamesNeedingHash() throws {
        XCTAssertTrue(AssetRecords.load(inProjectFolder: folder).isEmpty)
        let source = folder.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(count: 10).write(to: source.appendingPathComponent("a.dng"))
        try Data(count: 11).write(to: source.appendingPathComponent("b.dng"))
        var records = AssetRecords()
        records.put(record("source/a.dng", bytes: 10, hash: "sha256:aa"))
        records.put(record("source/b.dng", bytes: 99, hash: "sha256:stale"))
        let needing = records.namesNeedingHash(among: ["source/a.dng", "source/b.dng", "source/missing.dng"], in: folder)
        XCTAssertEqual(needing, ["source/b.dng"], "a stale size re-hashes; a missing file is not a job")
    }

    func testProjectMetadataRoundTrip() throws {
        var metadata = ProjectMetadata()
        metadata.imported = { var m = AssetMetadata(); m.creator = ["Steven Wright"]; return m }()
        metadata.edited = { var m = AssetMetadata(); m.title = "Edited"; return m }()
        metadata.editedAt = ["title": Date(timeIntervalSince1970: 1_800_000_000)]
        try metadata.write(inProjectFolder: folder)
        let loaded = try XCTUnwrap(ProjectMetadata.load(inProjectFolder: folder))
        XCTAssertEqual(loaded, metadata)
        XCTAssertEqual(loaded.schemaVersion, 1)
        XCTAssertNil(ProjectMetadata.load(inProjectFolder: folder.appendingPathComponent("nope")))
    }
}

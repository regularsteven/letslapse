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

    /// The import sheet's progress bar is only honest if the tally reaches the
    /// payload's real size — no more, no less.
    func testExtractReportsPayloadBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-progress-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("tree", isDirectory: true)
        let archive = root.appendingPathComponent("tree.lapse")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("source"), withIntermediateDirectories: true)
        var payload: Int64 = 0
        for index in 0..<4 {
            // Random-ish bytes: lzfse must not shrink these to nothing, or the
            // test would pass on an archive with no work in it.
            var frame = Data(count: 200_000)
            for byte in 0..<frame.count { frame[byte] = UInt8((byte &* (index &+ 7)) % 251) }
            try frame.write(to: source.appendingPathComponent("source/frame-\(index).dng"))
            payload += Int64(frame.count)
        }

        try DirectoryArchive.write(contentsOf: source, to: archive)

        let reported = Reported()
        try DirectoryArchive.extract(
            archive,
            to: root.appendingPathComponent("out"),
            progress: { reported.record($0) })

        XCTAssertEqual(reported.last, payload)
        XCTAssertTrue(reported.isMonotonic, "progress went backwards: \(reported.values)")
    }

    /// Cancelling has to be distinguishable from failing — the sheet says
    /// different things — and it must actually stop the pump.
    func testExtractCancels() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-cancel-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("tree", isDirectory: true)
        let archive = root.appendingPathComponent("tree.lapse")
        let out = root.appendingPathComponent("out")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for index in 0..<20 {
            try Data(count: 100_000).write(to: source.appendingPathComponent("frame-\(index).dng"))
        }
        try DirectoryArchive.write(contentsOf: source, to: archive)

        // Stops after the first entry is seen, so the run is genuinely cut short.
        let seen = Reported()
        XCTAssertThrowsError(
            try DirectoryArchive.extract(
                archive,
                to: out,
                shouldContinue: { seen.count < 1 },
                progress: { _ in seen.record(1) })
        ) { error in
            XCTAssertEqual(error as? DirectoryArchiveError, .cancelled)
        }

        let restored = (try? FileManager.default.contentsOfDirectory(atPath: out.path))?.count ?? 0
        XCTAssertLessThan(restored, 20, "cancel didn't stop the extraction")
    }
}

/// Collects the progress callbacks, which arrive on AppleArchive's worker
/// threads.
private final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [Int64] = []

    func record(_ value: Int64) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }

    var last: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return values.last ?? 0
    }

    var isMonotonic: Bool {
        lock.lock()
        defer { lock.unlock() }
        return zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }
    }
}

import XCTest
@testable import LetsLapseKit

final class PicPlaceBindingTests: XCTestCase {

    private func scratchRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("picplace-binding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func record(url: String = "https://picplace.test", id: String? = nil) -> PicPlaceBindingRecord {
        PicPlaceBindingRecord(
            server: .init(url: url, id: id, environment: id == nil ? nil : "local"),
            user: .init(uuid: "2A5D1F0C-7B3E-4E7A-9C11-0A1B2C3D4E5F", username: "regularsteven", name: "Steven Wright"),
            boundAt: Date(timeIntervalSince1970: 1_789_000_000.25),
            boundByDevice: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            initialSync: .init(state: .pending, case: .clean))
    }

    func testRoundTripThroughTheFile() throws {
        let root = try scratchRoot()
        XCTAssertNil(PicPlaceBindingRecord.read(inRoot: root))
        XCTAssertFalse(PicPlaceBindingRecord.exists(inRoot: root))

        let written = record()
        try written.write(inRoot: root)
        XCTAssertTrue(PicPlaceBindingRecord.exists(inRoot: root))
        XCTAssertEqual(PicPlaceBindingRecord.url(inRoot: root).path, root.appendingPathComponent("PicPlace/account.json").path)

        let read = try XCTUnwrap(PicPlaceBindingRecord.read(inRoot: root))
        XCTAssertEqual(read, written)
        XCTAssertEqual(read.format, PicPlaceBindingRecord.format)
        XCTAssertEqual(read.initialSync.state, .pending)
        XCTAssertEqual(read.initialSync.case, .clean)

        // The file is plain, sorted, unescaped JSON a human can read.
        let text = try String(contentsOf: PicPlaceBindingRecord.url(inRoot: root), encoding: .utf8)
        XCTAssertTrue(text.contains("\"url\" : \"https://picplace.test\""), text)
        XCTAssertTrue(text.contains("\"username\" : \"regularsteven\""), text)

        PicPlaceBindingRecord.remove(inRoot: root)
        XCTAssertNil(PicPlaceBindingRecord.read(inRoot: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: PicPlaceBindingRecord.folderURL(inRoot: root).path),
                      "the folder is a library item and stays")
    }

    func testAccountKeyAndHost() {
        let r = record(url: "https://PicPlace.CO")
        XCTAssertEqual(r.server.host, "picplace.co")
        XCTAssertEqual(r.accountKey, "picplace.co|2a5d1f0c-7b3e-4e7a-9c11-0a1b2c3d4e5f")
        XCTAssertEqual(PicPlaceBindingRecord.accountKey(host: "Picplace.Test", userUUID: "ABC"), "picplace.test|abc")
        XCTAssertEqual(r.user.displayHandle, "regularsteven")
        XCTAssertEqual(PicPlaceBindingRecord.User(uuid: "0123456789abcdef", username: nil, name: nil).displayHandle, "01234567")
        XCTAssertEqual(PicPlaceBindingRecord.User(uuid: "x", username: "", name: "Steven").displayHandle, "Steven")
    }

    func testMatchingByHostUntilTheServerReportsAnID() {
        let byHost = record()
        XCTAssertTrue(byHost.matches(host: "picplace.test", userUUID: "2a5d1f0c-7b3e-4e7a-9c11-0a1b2c3d4e5f"))
        XCTAssertTrue(byHost.matches(host: "PICPLACE.TEST", userUUID: "2A5D1F0C-7B3E-4E7A-9C11-0A1B2C3D4E5F", serverID: "srv-1"),
                      "a server id on one side only cannot decide; the host does")
        XCTAssertFalse(byHost.matches(host: "picplace.co", userUUID: "2a5d1f0c-7b3e-4e7a-9c11-0a1b2c3d4e5f"))
        XCTAssertFalse(byHost.matches(host: "picplace.test", userUUID: "someone-else"))

        let byID = record(id: "srv-1")
        XCTAssertTrue(byID.matches(host: "anything.example", userUUID: "2a5d1f0c-7b3e-4e7a-9c11-0a1b2c3d4e5f", serverID: "srv-1"),
                      "the instance id wins over the host once both know it")
        XCTAssertFalse(byID.matches(host: "picplace.test", userUUID: "2a5d1f0c-7b3e-4e7a-9c11-0a1b2c3d4e5f", serverID: "srv-2"))
        XCTAssertTrue(byID.matches(host: "picplace.test", userUUID: "2a5d1f0c-7b3e-4e7a-9c11-0a1b2c3d4e5f"),
                      "a session that does not know the id falls back to the host")
    }

    func testLibraryFieldIsOptionalAndRoundTrips() throws {
        let root = try scratchRoot()
        // A record from before the field decodes without it.
        try record().write(inRoot: root)
        XCTAssertNil(try XCTUnwrap(PicPlaceBindingRecord.read(inRoot: root)).library)

        var bound = record()
        bound.library = .init(uuid: UUID(uuidString: "9C1F2A6E-0000-4000-8000-000000000001")!, name: "Field 2026")
        try bound.write(inRoot: root)
        let read = try XCTUnwrap(PicPlaceBindingRecord.read(inRoot: root))
        XCTAssertEqual(read.library?.name, "Field 2026")
        XCTAssertEqual(read.library?.uuid.uuidString, "9C1F2A6E-0000-4000-8000-000000000001")
        XCTAssertEqual(read.format, 1, "the field is optional in format 1; older readers ignore it")
        XCTAssertEqual(PicPlaceBindingRecord.settingsURL(inRoot: root).path, root.appendingPathComponent("PicPlace/settings.json").path)
    }

    func testUnreadableFileReadsAsNil() throws {
        let root = try scratchRoot()
        try FileManager.default.createDirectory(at: PicPlaceBindingRecord.folderURL(inRoot: root), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: PicPlaceBindingRecord.url(inRoot: root))
        XCTAssertTrue(PicPlaceBindingRecord.exists(inRoot: root))
        XCTAssertNil(PicPlaceBindingRecord.read(inRoot: root))
    }
}

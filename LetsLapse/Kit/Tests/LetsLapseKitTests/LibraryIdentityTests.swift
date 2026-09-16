import XCTest
@testable import LetsLapseKit

final class LibraryIdentityTests: XCTestCase {

    private let device = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func scratchRoot(_ name: String = "Field 2026") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-identity-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        return root
    }

    func testRoundTripThroughTheFile() throws {
        let root = try scratchRoot()
        XCTAssertNil(LibraryIdentity.read(inRoot: root))
        XCTAssertFalse(LibraryIdentity.exists(inRoot: root))

        let written = LibraryIdentity(
            id: UUID(uuidString: "9C1F2A6E-0000-4000-8000-000000000001")!,
            name: "  Field 2026 \n", createdAt: Date(timeIntervalSince1970: 1_789_000_000.5),
            createdByDevice: device, createdWith: "0.1.0 (42)")
        XCTAssertEqual(written.name, "Field 2026", "names are stored trimmed and single-line")
        try written.write(inRoot: root)

        XCTAssertTrue(LibraryIdentity.exists(inRoot: root))
        XCTAssertEqual(LibraryIdentity.url(inRoot: root).lastPathComponent, "letslapse-library.json")
        let read = try XCTUnwrap(LibraryIdentity.read(inRoot: root))
        XCTAssertEqual(read, written)
        XCTAssertEqual(read.format, LibraryIdentity.format)

        // Plain, sorted, unescaped JSON a human can read in Finder.
        let text = try String(contentsOf: LibraryIdentity.url(inRoot: root), encoding: .utf8)
        XCTAssertTrue(text.contains("\"name\" : \"Field 2026\""), text)
        XCTAssertTrue(text.contains("\"id\" : \"9C1F2A6E-0000-4000-8000-000000000001\""), text)
    }

    func testEnsureMintsOnceAndKeepsTheID() throws {
        let root = try scratchRoot("Client X")
        let first = try LibraryIdentity.ensure(inRoot: root, device: device, appVersion: "0.1.0")
        XCTAssertEqual(first.healing, .created)
        let minted = try XCTUnwrap(first.identity)
        XCTAssertEqual(minted.name, "Client X", "an unnamed library takes its folder's name")
        XCTAssertFalse(minted.namedByPerson, "…as a placeholder, not as a name a person gave")
        XCTAssertEqual(minted.createdByDevice, device)
        XCTAssertEqual(minted.createdWith, "0.1.0")

        let second = try LibraryIdentity.ensure(inRoot: root, name: "Something else", device: UUID())
        XCTAssertEqual(second.healing, .existing)
        XCTAssertEqual(second.identity, minted, "the file wins over the caller's name once it exists")
    }

    func testEnsureUsesTheGivenNameWhenMinting() throws {
        let root = try scratchRoot("folder-name")
        let healed = try LibraryIdentity.ensure(inRoot: root, name: "  Personal  ", device: device)
        XCTAssertEqual(healed.healing, .created)
        XCTAssertEqual(healed.identity?.name, "Personal")
        XCTAssertEqual(healed.identity?.namedByPerson, true)
    }

    func testFilesWithoutTheNamedFlagReadAsPlaceholders() throws {
        let root = try scratchRoot()
        let text = """
        {"createdAt":"2026-09-16T12:59:31.752Z","createdByDevice":"11111111-2222-3333-4444-555555555555","format":1,"id":"D60F42E7-4105-4BC5-9AEC-DA547C862214","name":"lib-a"}
        """
        try Data(text.utf8).write(to: LibraryIdentity.url(inRoot: root))
        let read = try XCTUnwrap(LibraryIdentity.read(inRoot: root))
        XCTAssertEqual(read.name, "lib-a")
        XCTAssertFalse(read.namedByPerson)
        // Naming it writes the flag.
        var named = read
        named.name = "Field 2026"
        named.namedByPerson = true
        try named.write(inRoot: root)
        XCTAssertEqual(LibraryIdentity.read(inRoot: root)?.namedByPerson, true)
    }

    func testUnreadableFileIsReportedAndLeftAlone() throws {
        let root = try scratchRoot()
        let url = LibraryIdentity.url(inRoot: root)
        try Data("{ not json".utf8).write(to: url)
        let healed = try LibraryIdentity.ensure(inRoot: root, device: device)
        XCTAssertEqual(healed.healing, .unreadable)
        XCTAssertNil(healed.identity)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{ not json", "never repaired silently")
        XCTAssertNil(LibraryIdentity.read(inRoot: root))
        XCTAssertTrue(LibraryIdentity.exists(inRoot: root))
    }

    func testDefaultNames() {
        XCTAssertEqual(LibraryIdentity.defaultName(forRoot: URL(fileURLWithPath: "/Volumes/letslapse")), "letslapse")
        XCTAssertEqual(LibraryIdentity.defaultName(forRoot: URL(fileURLWithPath: "/Volumes/letslapse/picplace.co/regularsteven/")), "regularsteven")
        XCTAssertEqual(LibraryIdentity.defaultName(forRoot: URL(fileURLWithPath: "/")), "LetsLapse")
        XCTAssertEqual(LibraryIdentity.cleanName(String(repeating: "x", count: 200)).count, 120)
        XCTAssertEqual(LibraryIdentity(name: "", createdByDevice: device).displayName, "Library")
    }

    // MARK: Detection

    func testDetectionOfAnEmptyFolder() throws {
        let root = try scratchRoot()
        XCTAssertEqual(LibraryIdentity.detect(root: root), .none)
        XCTAssertFalse(LibraryIdentity.detect(root: root).isLibrary)
        // A stray Projects folder without a document is not a library either.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        XCTAssertEqual(LibraryIdentity.detect(root: root), .none)
    }

    func testDetectionByIdentityFile() throws {
        let root = try scratchRoot()
        let identity = LibraryIdentity(name: "Field 2026", createdByDevice: device)
        try identity.write(inRoot: root)
        XCTAssertEqual(LibraryIdentity.detect(root: root), .identity(identity))
    }

    func testDetectionByDocumentsBeforeTheIdentityFile() throws {
        let root = try scratchRoot()
        let projects = root.appendingPathComponent("Projects", isDirectory: true)
        let folder = projects.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Non-project noise beside it is ignored.
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("not-a-uuid"), withIntermediateDirectories: true)
        XCTAssertEqual(LibraryIdentity.detect(root: root), .none, "a project folder without its document is not a document")
        try Data("{}".utf8).write(to: ProjectDocumentFormat.url(inProjectFolder: folder))
        XCTAssertEqual(LibraryIdentity.detect(root: root), .documents)
    }

    func testDetectionByTrashedDocument() throws {
        let root = try scratchRoot()
        let folder = root.appendingPathComponent("Projects/.trash", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: ProjectDocumentFormat.url(inProjectFolder: folder))
        XCTAssertEqual(LibraryIdentity.detect(root: root), .documents)
    }

    func testDetectionByExportAlone() throws {
        let root = try scratchRoot()
        let projects = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: projects.appendingPathComponent(LibraryExportFormat.fileName))
        XCTAssertEqual(LibraryIdentity.detect(root: root), .export)
        XCTAssertTrue(LibraryIdentity.detect(root: root).isLibrary)
    }
}

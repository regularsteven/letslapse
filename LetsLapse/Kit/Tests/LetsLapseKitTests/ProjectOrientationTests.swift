import CoreGraphics
import ImageIO
import XCTest
@testable import LetsLapseKit

final class ProjectOrientationTests: XCTestCase {

    private func library() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orientation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func project(in root: URL, turns: Int?, blends: [(String, Int?)] = []) throws -> URL {
        let folder = root.appendingPathComponent("Projects/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("source"), withIntermediateDirectories: true)
        var capture: [String: Any] = ["id": UUID().uuidString]
        if let turns { capture["quarterTurns"] = turns }
        let blendRows: [[String: Any]] = blends.map { name, rendered in
            var row: [String: Any] = ["outputFileName": name]
            if let rendered { row["renderedQuarterTurns"] = rendered }
            return row
        }
        let document: [String: Any] = ["formatVersion": 1, "capture": capture, "blends": blendRows]
        try JSONSerialization.data(withJSONObject: document).write(to: folder.appendingPathComponent("project.json"))
        return folder
    }

    func testSourcesTakeTheProjectsTurnAndBlendsTheDifference() throws {
        let root = try library()
        let folder = try project(in: root, turns: 3, blends: [("blends/old.mp4", 1), ("blends/new.mp4", 3), ("blends/before.png", nil)])
        let lookup = ProjectOrientation()
        XCTAssertEqual(lookup.turns(for: folder.appendingPathComponent("source/frame-00001.dng")), 3)
        XCTAssertEqual(lookup.turns(for: folder.appendingPathComponent("source/clips/segment-001.mov")), 3)
        XCTAssertEqual(lookup.turns(for: folder.appendingPathComponent("blends/old.mp4")), 2, "rendered at 1, shown at 3")
        XCTAssertEqual(lookup.turns(for: folder.appendingPathComponent("blends/new.mp4")), 0, "rendered at the current turn")
        XCTAssertEqual(lookup.turns(for: folder.appendingPathComponent("blends/before.png")), 3, "a blend from before the record")
        XCTAssertEqual(lookup.orientation(for: folder.appendingPathComponent("source/a.jpg"), fileOrientation: .right), .up)
        XCTAssertEqual(lookup.turns(for: folder.appendingPathComponent("poster.jpg")), 0, "rendered from the turned picture")
        XCTAssertEqual(lookup.turns(for: folder.appendingPathComponent("masks/sky.png")), 0)
    }

    func testABlendsStillTakesTheBlendsDifference() throws {
        let root = try library()
        let id = UUID().uuidString
        let folder = root.appendingPathComponent("Projects/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let document: [String: Any] = ["capture": ["quarterTurns": 2],
                                       "blends": [["id": id, "outputFileName": "blends/\(id).mp4", "renderedQuarterTurns": 1]]]
        try JSONSerialization.data(withJSONObject: document).write(to: folder.appendingPathComponent("project.json"))
        let lookup = ProjectOrientation()
        XCTAssertEqual(lookup.turns(for: folder.appendingPathComponent("posters/\(id).jpg")), 1)
        XCTAssertEqual(lookup.turns(for: folder.appendingPathComponent("posters/\(UUID().uuidString).jpg")), 2)
    }

    func testOutsideAProjectAndWithoutADocumentIsUpright() throws {
        let root = try library()
        let lookup = ProjectOrientation()
        XCTAssertEqual(lookup.turns(for: root.appendingPathComponent("scratch/frame.jpg")), 0)
        XCTAssertEqual(lookup.turns(for: URL(fileURLWithPath: "/tmp/Projects/not-a-uuid/source/a.jpg")), 0)
        let bare = root.appendingPathComponent("Projects/\(UUID().uuidString)/source/a.jpg")
        XCTAssertEqual(lookup.turns(for: bare), 0, "no project.json: no turn")
        let unturned = try project(in: root, turns: nil)
        XCTAssertEqual(lookup.turns(for: unturned.appendingPathComponent("source/a.jpg")), 0)
    }

    func testForgetRereadsAChangedDocument() throws {
        let root = try library()
        let folder = try project(in: root, turns: 1)
        let lookup = ProjectOrientation()
        let file = folder.appendingPathComponent("source/a.heic")
        XCTAssertEqual(lookup.turns(for: file), 1)
        let rewritten: [String: Any] = ["capture": ["quarterTurns": 2], "blends": [] as [Any]]
        try JSONSerialization.data(withJSONObject: rewritten).write(to: folder.appendingPathComponent("project.json"))
        XCTAssertEqual(lookup.turns(for: file), 1, "cached until told")
        lookup.forget(folder: folder)
        XCTAssertEqual(lookup.turns(for: file), 2)
    }
}

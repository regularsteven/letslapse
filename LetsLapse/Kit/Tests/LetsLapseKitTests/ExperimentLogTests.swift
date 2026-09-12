import XCTest
@testable import LetsLapseKit

/// W11: the experiment log's line form ↔ document, a torn last line, and
/// the appender that writes it.
final class ExperimentLogTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("xlog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private struct Header: Codable, Equatable { var startedAt: String; var deviceModel: String; var originID: String? }
    private struct Output: Codable, Equatable { var index: Int; var capturedFrames: Int; var failed: Bool }
    private struct Summary: Codable, Equatable { var completedOutputs: Int; var discarded: Bool }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testLinesRoundTripToTheDocument() throws {
        let encoder = JSONEncoder()
        let url = folder.appendingPathComponent("liveblend-test.ndjson")
        let writer = try XCTUnwrap(NDJSONWriter(url: url))
        writer.appendLine(try ExperimentLog.line(kind: "header", payload: try encoder.encode(Header(startedAt: "2026-09-13T00:00:00Z", deviceModel: "iPhone17,1", originID: "ABC"))))
        for index in 0..<3 {
            writer.appendLine(try ExperimentLog.line(kind: "output", payload: try encoder.encode(Output(index: index, capturedFrames: 10, failed: false))))
        }
        writer.appendLine(try ExperimentLog.line(kind: "summary", payload: try encoder.encode(Summary(completedOutputs: 3, discarded: false))))
        writer.close()

        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 5)
        XCTAssertTrue(lines[0].hasPrefix(#"{"deviceModel":"iPhone17,1","kind":"header""#), String(lines[0]))
        XCTAssertTrue(lines[1].contains(#""kind":"output""#))
        XCTAssertTrue(lines[4].contains(#""kind":"summary""#))

        // Bytes written are linear in outputs: one line each, no rewrite.
        let bytes = try Data(contentsOf: url).count
        XCTAssertLessThan(bytes, 5 * 120)

        let document = try object(try XCTUnwrap(ExperimentLog.document(fromLines: try Data(contentsOf: url))))
        XCTAssertEqual((document["header"] as? [String: Any])?["originID"] as? String, "ABC")
        XCTAssertNil((document["header"] as? [String: Any])?["kind"], "the line's kind never reaches the document")
        XCTAssertEqual((document["outputs"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual((document["outputs"] as? [[String: Any]])?.last?["index"] as? Int, 2)
        XCTAssertEqual((document["summary"] as? [String: Any])?["completedOutputs"] as? Int, 3)

        // And the document re-lines to the same bytes.
        let relined = try ExperimentLog.lines(fromDocument: try JSONSerialization.data(withJSONObject: document))
        XCTAssertEqual(relined, try Data(contentsOf: url))
    }

    func testTornLastLineKeepsEveryCompletedWindow() throws {
        let encoder = JSONEncoder()
        let url = folder.appendingPathComponent("liveblend-killed.ndjson")
        let writer = try XCTUnwrap(NDJSONWriter(url: url))
        writer.appendLine(try ExperimentLog.line(kind: "header", payload: try encoder.encode(Header(startedAt: "t", deviceModel: "d", originID: nil))))
        writer.appendLine(try ExperimentLog.line(kind: "output", payload: try encoder.encode(Output(index: 0, capturedFrames: 4, failed: false))))
        writer.appendLine(try ExperimentLog.line(kind: "output", payload: try encoder.encode(Output(index: 1, capturedFrames: 4, failed: false))))
        writer.close()
        // The run died mid-write of the third window.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"capturedFrames":2,"index":2,"kind":"out"#.utf8))
        try handle.close()

        let document = try object(try XCTUnwrap(ExperimentLog.document(fromLines: try Data(contentsOf: url))))
        XCTAssertEqual((document["outputs"] as? [[String: Any]])?.count, 2, "every completed window, nothing invented")
        XCTAssertNil(document["summary"], "no summary for a run that never finished")

        // A writer reopening the file closes the torn line off first.
        let reopened = try XCTUnwrap(NDJSONWriter(url: url))
        reopened.appendLine(try ExperimentLog.line(kind: "summary", payload: try encoder.encode(Summary(completedOutputs: 2, discarded: false))))
        reopened.close()
        let after = try object(try XCTUnwrap(ExperimentLog.document(fromLines: try Data(contentsOf: url))))
        XCTAssertEqual((after["summary"] as? [String: Any])?["completedOutputs"] as? Int, 2)
        XCTAssertEqual((after["outputs"] as? [[String: Any]])?.count, 2)
    }

    func testNoHeaderMeansNoDocumentAndPruneKeepsTheNewest() throws {
        XCTAssertNil(ExperimentLog.document(fromLines: Data(#"{"kind":"output","index":0}"#.utf8)))
        XCTAssertNil(ExperimentLog.document(fromLines: Data()))

        for stamp in ["20260901-1200", "20260902-1200", "20260903-1200", "20260904-1200"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent("liveblend-\(stamp).ndjson"))
        }
        try Data("x".utf8).write(to: folder.appendingPathComponent("console-20260901.log"))
        ExperimentLog.prune(directory: folder, prefix: "liveblend-", keep: 2)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names, ["console-20260901.log", "liveblend-20260903-1200.ndjson", "liveblend-20260904-1200.ndjson"])
    }
}

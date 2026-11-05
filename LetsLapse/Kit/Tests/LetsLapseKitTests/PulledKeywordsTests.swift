import XCTest
@testable import LetsLapseKit

final class PulledKeywordsTests: XCTestCase {
    /// A stand-in for the app's normaliser: trimmed, one of each whatever its case, first seen kept.
    private func clean(_ tags: [String]) -> [String] {
        var seen: [String] = []
        for tag in tags.map({ $0.trimmingCharacters(in: .whitespaces) }) where !tag.isEmpty {
            if !seen.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { seen.append(tag) }
        }
        return seen
    }

    private func settled(_ pulled: [String]?, auto: Bool = false, edited: [String]? = nil, imported: [String]? = nil) -> [String]? {
        PulledKeywords.settled(pulledTags: pulled, taggedAutomatically: auto, edited: edited, imported: imported, clean: clean)
    }

    func testAManifestEditedWithoutItsBundleWinsOverTheRecordsOlderList() {
        // Tagged by hand on a device (both copies), then a tag added by a client that writes the manifest alone.
        XCTAssertEqual(settled(["Prague", "broll"], edited: ["Prague"]), ["Prague", "broll"])
        // And a tag taken off the same way.
        XCTAssertEqual(settled(["Prague"], edited: ["Prague", "broll"]), ["Prague"])
    }

    func testADevicesOwnPushIsLeftAlone() {
        // A device writes both copies, so they arrive agreeing.
        XCTAssertNil(settled(["Prague", "broll"], edited: ["Prague", "broll"]))
        // The Keywords row stores the list as typed; the manifest holds it cleaned. Still the same list.
        XCTAssertNil(settled(["Prague"], edited: [" Prague ", "prague"]))
    }

    func testEveryTagRemovedClearsTheEditedLayer() {
        // The writer clears the layer for an empty list, as a hand edit to nothing does.
        XCTAssertEqual(settled(nil, edited: ["Prague"]), [])
        XCTAssertEqual(settled([], edited: ["Prague"]), [])
    }

    func testAProjectNeverTaggedByHandHasNothingToSettle() {
        // No record keywords at all: the panels fall back to the manifest's list, which is the one that arrived.
        XCTAssertNil(settled(["broll"]))
        XCTAssertNil(settled(nil))
    }

    func testTagsAddedOverAFilesOwnKeywordsBecomeTheEditedLayer() {
        // The file said Lisbon and the project was seeded with it; a tag was then added to the manifest alone.
        XCTAssertEqual(settled(["Lisbon", "broll"], imported: ["Lisbon"]), ["Lisbon", "broll"])
        // Seeded and untouched: nothing to do.
        XCTAssertNil(settled(["Lisbon"], imported: ["Lisbon"]))
        // "No tags" cannot be said over a file's own keywords; a hand edit cannot say it either.
        XCTAssertNil(settled(nil, imported: ["Lisbon"]))
    }

    func testTagsTheSilentPassChoseAreNeverMadeKeywords() {
        XCTAssertNil(settled(["water", "urban"], auto: true, imported: ["Lisbon"]))
        XCTAssertNil(settled(["water"], auto: true, edited: ["Prague"]))
    }

    func testAListGoingBackToWhatTheFileSaidIsHandedOnForTheWriterToClear() {
        // The writer sees it equals the imported list and clears the edited layer: a revert.
        XCTAssertEqual(settled(["Lisbon"], edited: ["Lisbon", "broll"], imported: ["Lisbon"]), ["Lisbon"])
    }
}

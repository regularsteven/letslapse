import XCTest
@testable import LetsLapseKit

final class LastEditMergeTests: XCTestCase {
    private typealias Stamp = LastEditMerge.Stamp<String>
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func testEachSidesNewDocumentsAreKept() {
        let outcome = LastEditMerge.merge(
            local: [Stamp(id: "mine", modifiedAt: at(1), deletedAt: nil)],
            remote: [Stamp(id: "theirs", modifiedAt: at(2), deletedAt: nil)],
            equal: { _ in false })
        XCTAssertEqual(outcome.choices, ["mine": .local, "theirs": .remote])
        XCTAssertTrue(outcome.localChanged)
        XCTAssertTrue(outcome.remoteChanged)
    }

    func testTheLaterEditWins() {
        let local = [Stamp(id: "a", modifiedAt: at(10), deletedAt: nil), Stamp(id: "b", modifiedAt: at(5), deletedAt: nil)]
        let remote = [Stamp(id: "a", modifiedAt: at(8), deletedAt: nil), Stamp(id: "b", modifiedAt: at(9), deletedAt: nil)]
        let outcome = LastEditMerge.merge(local: local, remote: remote, equal: { _ in false })
        XCTAssertEqual(outcome.choices, ["a": .local, "b": .remote])
        XCTAssertTrue(outcome.localChanged)
        XCTAssertTrue(outcome.remoteChanged)
    }

    func testALaterDeletionWinsOverAnEdit() {
        let outcome = LastEditMerge.merge(
            local: [Stamp(id: "a", modifiedAt: at(5), deletedAt: nil)],
            remote: [Stamp(id: "a", modifiedAt: at(1), deletedAt: at(7))],
            equal: { _ in false })
        XCTAssertEqual(outcome.choices, ["a": .remote])
        XCTAssertTrue(outcome.localChanged)
        XCTAssertFalse(outcome.remoteChanged)
    }

    func testAnEditAfterADeletionBringsItBack() {
        let outcome = LastEditMerge.merge(
            local: [Stamp(id: "a", modifiedAt: at(9), deletedAt: nil)],
            remote: [Stamp(id: "a", modifiedAt: at(1), deletedAt: at(7))],
            equal: { _ in false })
        XCTAssertEqual(outcome.choices, ["a": .local])
        XCTAssertFalse(outcome.localChanged)
        XCTAssertTrue(outcome.remoteChanged)
    }

    func testATieGoesToPicPlace() {
        let outcome = LastEditMerge.merge(
            local: [Stamp(id: "a", modifiedAt: at(3), deletedAt: nil)],
            remote: [Stamp(id: "a", modifiedAt: at(3), deletedAt: nil)],
            equal: { _ in false })
        XCTAssertEqual(outcome.choices, ["a": .remote])
        XCTAssertTrue(outcome.localChanged)
        XCTAssertFalse(outcome.remoteChanged)
    }

    func testCopiesThatAgreeChangeNothing() {
        let stamps = [Stamp(id: "a", modifiedAt: at(3), deletedAt: nil)]
        let outcome = LastEditMerge.merge(local: stamps, remote: stamps, equal: { _ in true })
        XCTAssertFalse(outcome.localChanged)
        XCTAssertFalse(outcome.remoteChanged)
    }

    func testAnUnstampedDocumentLosesToAStampedOne() {
        let outcome = LastEditMerge.merge(
            local: [Stamp(id: "a", modifiedAt: nil, deletedAt: nil)],
            remote: [Stamp(id: "a", modifiedAt: at(1), deletedAt: nil)],
            equal: { _ in false })
        XCTAssertEqual(outcome.choices, ["a": .remote])
    }
}

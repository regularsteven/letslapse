import XCTest
@testable import LetsLapseKit

/// W6: the pure gating rule behind the one library persister.
final class VersionGateTests: XCTestCase {

    func testNewerIsWrittenOlderAndEqualAreDropped() {
        var gate = VersionGate()
        XCTAssertTrue(gate.admit(1))
        XCTAssertTrue(gate.admit(2))
        XCTAssertFalse(gate.admit(1), "an older snapshot after a newer one is dropped — the R3 race")
        XCTAssertFalse(gate.admit(2), "equal is dropped")
        XCTAssertTrue(gate.admit(5), "gaps are fine; only order matters")
        XCTAssertFalse(gate.admit(3))
        XCTAssertEqual(gate.lastWritten, 5)
    }

    func testOutOfOrderArrivalKeepsOnlyTheNewest() {
        var gate = VersionGate()
        // Minted 1, 2, 3 on the main actor; the queue sees 2, 3, 1.
        var counter = VersionCounter()
        let versions = [counter.mint(), counter.mint(), counter.mint()]
        XCTAssertEqual(versions, [1, 2, 3])
        let written = [versions[1], versions[2], versions[0]].filter { gate.admit($0) }
        XCTAssertEqual(written, [2, 3])
        XCTAssertEqual(gate.lastWritten, 3)
    }

    func testFreshGateAdmitsNothingAtOrBelowZero() {
        var gate = VersionGate()
        XCTAssertFalse(gate.admit(0))
        XCTAssertFalse(gate.admit(-1))
        XCTAssertTrue(gate.admit(1))
    }
}

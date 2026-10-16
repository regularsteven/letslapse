import XCTest
@testable import LetsLapseKit

/// The push's render gate (2026-10-16): the background is a deferral, never
/// a failure, and a new project never goes up without its poster.
final class PicPlacePushGateTests: XCTestCase {

    private typealias Gate = PicPlacePushGate

    func testInFrontRendersWhateverPicPlaceHolds() {
        XCTAssertEqual(Gate.outcome(inFront: true, recordsOnServer: false, recordsMoved: true), .render)
        XCTAssertEqual(Gate.outcome(inFront: true, recordsOnServer: true, recordsMoved: true), .render)
        XCTAssertEqual(Gate.outcome(inFront: true, recordsOnServer: true, recordsMoved: false), .render)
        XCTAssertEqual(Gate.outcome(inFront: true, recordsOnServer: false, recordsMoved: false), .render)
    }

    /// The 2026-10-16 case: a new project whose push reached the render
    /// step after the phone locked is not sent at all — the next push in
    /// front sends records, poster and working copy together.
    func testANewProjectInTheBackgroundIsDeferredWhole() {
        XCTAssertEqual(Gate.outcome(inFront: false, recordsOnServer: false, recordsMoved: true), .deferWhole)
        // A record whose only push failed is still "never on PicPlace":
        // moved or not, nothing of it is there to update.
        XCTAssertEqual(Gate.outcome(inFront: false, recordsOnServer: false, recordsMoved: false), .deferWhole)
    }

    /// An edit of a project PicPlace holds goes up as records alone, with
    /// the poster deferred for the front — not marked failed.
    func testAnEditInTheBackgroundSendsRecordsWithoutThePoster() {
        XCTAssertEqual(Gate.outcome(inFront: false, recordsOnServer: true, recordsMoved: true), .sendRecordsOnly)
    }

    /// A poster catch-up (the records in step) in the background sends
    /// nothing: a records-only PUT would move the sequence for every device
    /// and carry no poster.
    func testAPosterCatchUpInTheBackgroundWaits() {
        XCTAssertEqual(Gate.outcome(inFront: false, recordsOnServer: true, recordsMoved: false), .deferPoster)
    }
}

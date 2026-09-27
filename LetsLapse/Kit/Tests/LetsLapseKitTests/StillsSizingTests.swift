import XCTest
@testable import LetsLapseKit

/// The stills size rules' promises, in the sizes the iPhone 18 Pro week turned
/// on: a 1080p still under a 12 MP choice is an alarm and a same-shape
/// substitute is not; an undeliverable choice falls to the nearest smaller
/// size of its own shape, never to video; and a request size is one
/// AVFoundation's own rules take, or none.
final class StillsSizingTests: XCTestCase {

    private func s(_ w: Int, _ h: Int) -> StillsSizing.Size { .init(width: w, height: h) }

    // MARK: isShort — the alarm

    func testTheWeekOf1080pIsAnAlarm() {
        XCTAssertTrue(StillsSizing.isShort(delivered: s(1920, 1080), expected: s(4224, 3024)))
        XCTAssertTrue(StillsSizing.isShort(delivered: s(1080, 1920), expected: s(4032, 3024)))
    }

    func testTheSameShapeSubstituteIsNotAnAlarm() {
        XCTAssertFalse(StillsSizing.isShort(delivered: s(4032, 3024), expected: s(4224, 3024)))
    }

    func testOrientationDoesNotMatter() {
        XCTAssertFalse(StillsSizing.isShort(delivered: s(3024, 4032), expected: s(4032, 3024)))
        XCTAssertFalse(StillsSizing.isShort(delivered: s(4032, 3024), expected: s(3024, 4032)))
    }

    func testLargerThanChosenIsFine() {
        XCTAssertFalse(StillsSizing.isShort(delivered: s(8064, 6048), expected: s(4032, 3024)))
    }

    func testAnEmptyExpectationNeverAlarms() {
        XCTAssertFalse(StillsSizing.isShort(delivered: s(0, 0), expected: s(0, 0)))
    }

    // MARK: substitute — the honest menu's fallback

    private let tripleCamera = [(1280, 720), (1920, 1080), (1920, 1440), (3840, 2160), (4032, 3024)]
        .map { StillsSizing.Size(width: $0.0, height: $0.1) }

    func test4224FallsTo4032NotTo1080p() {
        XCTAssertEqual(StillsSizing.substitute(for: s(4224, 3024), among: tripleCamera), s(4032, 3024))
    }

    func testSameShapeWinsOverMorePixels() {
        // 4K (16:9) has fewer pixels than 4032×3024 but is the wrong shape; a
        // 4:3 choice with only 4K and 1920×1440 below it keeps its shape.
        let offered = [s(3840, 2160), s(1920, 1440)]
        XCTAssertEqual(StillsSizing.substitute(for: s(4032, 3024), among: offered), s(1920, 1440))
    }

    func testAnyShapeWhenNoSameShapeIsOffered() {
        XCTAssertEqual(StillsSizing.substitute(for: s(4032, 3024), among: [s(3840, 2160), s(1920, 1080)]),
                       s(3840, 2160))
    }

    func testNeverTheChoiceItselfNorLarger() {
        XCTAssertNil(StillsSizing.substitute(for: s(1280, 720), among: [s(1280, 720), s(4032, 3024)]))
    }

    // MARK: requestSize — AVFoundation's two rules

    func testAskedAsChosenWhenBothRulesTakeIt() {
        XCTAssertEqual(StillsSizing.requestSize(wanted: s(4032, 3024), ceiling: s(4032, 3024),
                                                listed: [s(4032, 3024), s(8064, 6048)]), s(4032, 3024))
    }

    func testThePostPinStateIsCorrectedNotSent() {
        // The crash: 4224×3024 asked while the camera sat on 1080p.
        XCTAssertEqual(StillsSizing.requestSize(wanted: s(4224, 3024), ceiling: s(1920, 1080),
                                                listed: [s(1920, 1080), s(4224, 2376)]), s(1920, 1080))
    }

    func testAboveTheOutputCeilingWithNothingSmallerListedIsLeftUnset() {
        XCTAssertNil(StillsSizing.requestSize(wanted: s(4224, 3024), ceiling: s(4032, 3024),
                                              listed: [s(4224, 3024), s(8448, 6048)]))
    }

    func testNotListedFallsToTheLargestSmallerListedSize() {
        XCTAssertEqual(StillsSizing.requestSize(wanted: s(4224, 3024), ceiling: s(8448, 6048),
                                                listed: [s(4032, 3024), s(8064, 6048)]), s(4032, 3024))
    }

    func testWithNoFormatKnownOnlyTheCeilingApplies() {
        XCTAssertEqual(StillsSizing.requestSize(wanted: s(4224, 3024), ceiling: s(4224, 3024), listed: nil),
                       s(4224, 3024))
        XCTAssertNil(StillsSizing.requestSize(wanted: s(4224, 3024), ceiling: s(4032, 3024), listed: nil))
    }

    func testAnUnconfiguredOutputTakesNothing() {
        XCTAssertNil(StillsSizing.requestSize(wanted: s(4032, 3024), ceiling: s(0, 0), listed: [s(4032, 3024)]))
    }
}

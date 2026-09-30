import XCTest
@testable import LetsLapseKit

/// The capture screen's level (`HorizonLevel`). Gravity is built from a
/// clockwise device roll the way Core Motion reports it: upright portrait is
/// (0, −1), and turning the phone clockwise by θ moves gravity to (sin θ, −cos θ).
final class HorizonLevelTests: XCTestCase {

    private func gravity(rolledClockwise degrees: Double, flatness: Double = 0) -> (x: Double, y: Double) {
        let radians = degrees * .pi / 180
        let inPlane = (1 - flatness * flatness).squareRoot()
        return (sin(radians) * inPlane, -cos(radians) * inPlane)
    }

    private func level(rolledClockwise degrees: Double, interface turns: Int, flatness: Double = 0) -> HorizonLevel? {
        let g = gravity(rolledClockwise: degrees, flatness: flatness)
        return HorizonLevel.reading(gravityX: g.x, gravityY: g.y, interfaceQuarterTurns: turns)
    }

    func testUprightPortraitIsLevelWithTheReferenceAcrossTheScreen() throws {
        let reading = try XCTUnwrap(level(rolledClockwise: 0, interface: 0))
        XCTAssertEqual(reading.offLevelDegrees, 0, accuracy: 1e-9)
        XCTAssertEqual(reading.holdQuarterTurns, 0)
        XCTAssertEqual(reading.referenceDegrees, 0)
        XCTAssertEqual(reading.horizonDegrees, 0, accuracy: 1e-9)
    }

    func testAClockwiseTiltReadsPositiveAndTheHorizonTurnsTheOtherWay() throws {
        let reading = try XCTUnwrap(level(rolledClockwise: 5, interface: 0))
        XCTAssertEqual(reading.offLevelDegrees, 5, accuracy: 1e-9)
        // The world turns anticlockwise on a screen turned clockwise.
        XCTAssertEqual(reading.horizonDegrees, -5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(level(rolledClockwise: -3, interface: 0)).offLevelDegrees, -3, accuracy: 1e-9)
    }

    /// The field fault's second half: both landscape holds read level when
    /// level, with the chrome turned to follow — never the ±90 that drew a
    /// vertical bar, and the same small tilt reads the same either way round.
    func testBothLandscapeHoldsReadAgainstThemselvesWhenTheChromeFollows() throws {
        // Clockwise onto its side: the interface's .landscapeLeft (1).
        let clockwise = try XCTUnwrap(level(rolledClockwise: 92, interface: 1))
        XCTAssertEqual(clockwise.holdQuarterTurns, 1)
        XCTAssertEqual(clockwise.offLevelDegrees, 2, accuracy: 1e-9)
        XCTAssertEqual(clockwise.referenceDegrees, 0)
        XCTAssertEqual(clockwise.horizonDegrees, -2, accuracy: 1e-9)
        // Anticlockwise onto its side: .landscapeRight (3).
        let anticlockwise = try XCTUnwrap(level(rolledClockwise: -88, interface: 3))
        XCTAssertEqual(anticlockwise.holdQuarterTurns, 3)
        XCTAssertEqual(anticlockwise.offLevelDegrees, 2, accuracy: 1e-9)
        XCTAssertEqual(anticlockwise.referenceDegrees, 0)
    }

    /// Under the system rotation lock the chrome stays portrait while the
    /// picture is taken on its side: the reference turns a quarter so it still
    /// lies along the picture's horizontal axis, and the horizon follows it.
    func testARotationLockTurnsTheReferenceOntoThePicturesAxis() throws {
        let reading = try XCTUnwrap(level(rolledClockwise: 93, interface: 0))
        XCTAssertEqual(reading.holdQuarterTurns, 1)
        XCTAssertEqual(reading.offLevelDegrees, 3, accuracy: 1e-9)
        XCTAssertEqual(reading.referenceDegrees, -90)
        // The true horizon on a portrait screen held clockwise on its side.
        XCTAssertEqual(reading.horizonDegrees, -93, accuracy: 1e-9)
        let other = try XCTUnwrap(level(rolledClockwise: -90, interface: 0))
        XCTAssertEqual(other.referenceDegrees, 90)
    }

    /// An iPhone's chrome never turns upside down; the assembly does, so it
    /// reads the right way up to someone holding the phone that way.
    func testUpsideDownOnAPortraitChromeTurnsTheAssemblyHalfWay() throws {
        let reading = try XCTUnwrap(level(rolledClockwise: 181, interface: 0))
        XCTAssertEqual(reading.holdQuarterTurns, 2)
        XCTAssertEqual(reading.offLevelDegrees, 1, accuracy: 1e-9)
        XCTAssertEqual(reading.referenceDegrees, 180)
        XCTAssertEqual(try XCTUnwrap(level(rolledClockwise: -179, interface: 0)).holdQuarterTurns, 2)
    }

    func testTheHoldChangesAtTheDiagonal() throws {
        XCTAssertEqual(try XCTUnwrap(level(rolledClockwise: 44, interface: 0)).holdQuarterTurns, 0)
        XCTAssertEqual(try XCTUnwrap(level(rolledClockwise: 46, interface: 0)).holdQuarterTurns, 1)
        XCTAssertEqual(try XCTUnwrap(level(rolledClockwise: 46, interface: 0)).offLevelDegrees, -44, accuracy: 1e-9)
    }

    /// Looking a little down at a scene still reads; flat on a table or
    /// straight at the ground has no roll to show, so no reading at all —
    /// never the green "0°" that looks right and is not.
    func testFlatHasNoReadingButATiltedCameraStillDoes() throws {
        XCTAssertNotNil(level(rolledClockwise: 2, interface: 0, flatness: sin(60 * .pi / 180)))
        XCTAssertNil(level(rolledClockwise: 2, interface: 0, flatness: sin(80 * .pi / 180)))
        XCTAssertNil(HorizonLevel.reading(gravityX: 0, gravityY: 0, interfaceQuarterTurns: 0))
        XCTAssertNil(HorizonLevel.reading(gravityX: .nan, gravityY: -1, interfaceQuarterTurns: 0))
    }

    func testTheInterfaceTurnIsFolded() throws {
        let reading = try XCTUnwrap(level(rolledClockwise: -90, interface: -1))
        XCTAssertEqual(reading.referenceDegrees, 0)
        XCTAssertEqual(try XCTUnwrap(level(rolledClockwise: 0, interface: 7)).referenceDegrees, -90)
    }

    func testNormalizedDegreesFoldsIntoOneHalfOpenTurn() {
        XCTAssertEqual(HorizonLevel.normalizedDegrees(180), 180)
        XCTAssertEqual(HorizonLevel.normalizedDegrees(-180), 180)
        XCTAssertEqual(HorizonLevel.normalizedDegrees(270), -90)
        XCTAssertEqual(HorizonLevel.normalizedDegrees(-270), 90)
        XCTAssertEqual(HorizonLevel.normalizedDegrees(725), 5)
    }
}

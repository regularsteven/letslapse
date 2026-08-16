import XCTest
import CoreMedia
@testable import LetsLapseKit

/// The EVERY=Auto pacing policy, pinned. Pure maths, same as the ramp engine
/// it sits beside — the point of both being value types.
final class HolyGrailAutoIntervalTests: XCTestCase {

    /// An iPhone 16 Pro wide, as probed 2026-08-13: 1.0 s shutter ceiling on
    /// every format, ISO 54–12096.
    private let wide = HolyGrailRampEngine.HardwareLimits(
        minShutter: CMTime(value: 1, timescale: 8000),  // 1/8000 s
        maxShutter: CMTime(value: 1, timescale: 1),     // 1.0 s
        minISO: 54,
        maxISO: 12096,
        aperture: 1.78)

    private func seconds(shutter: Double, iso: Float) -> Double {
        HolyGrailAutoInterval.seconds(shutterSeconds: shutter, iso: iso, limits: wide)
    }

    // MARK: The floor half — the shutter still has room

    func testDaylightSitsOnTheFloor() {
        // 1/500 s at base ISO: bright, and nowhere near the ceiling.
        XCTAssertEqual(seconds(shutter: 1.0 / 500, iso: 54), 3)
    }

    /// The floor holds right up to the ceiling, not just in daylight — while
    /// the shutter is absorbing the light change on its own there is no reason
    /// to spread the frames out.
    func testJustShortOfTheCeilingStillSitsOnTheFloor() {
        XCTAssertEqual(seconds(shutter: 0.9, iso: 54), 3)
    }

    /// A high ISO the *shutter* hasn't pinned for — a short exposure someone
    /// forced — is not the ISO climb this policy is about, and must not widen
    /// the spacing.
    func testHighISOWithoutAPinnedShutterDoesNotWiden() {
        XCTAssertEqual(seconds(shutter: 1.0 / 60, iso: 3200), 3)
    }

    // MARK: The climb — shutter pinned, ISO carrying

    func testPinnedShutterAtBaseISOIsStillTheFloor() {
        XCTAssertEqual(seconds(shutter: 1.0, iso: 54), 3)
    }

    func testTwoStopsOfISOIsHalfwayUp() {
        // 4× base ISO = 2 stops = half of the 4-stop travel: 3 + 12/2 = 9.
        XCTAssertEqual(seconds(shutter: 1.0, iso: 54 * 4), 9)
    }

    func testFourStopsReachesTheCap() {
        XCTAssertEqual(seconds(shutter: 1.0, iso: 54 * 16), HolyGrailAutoInterval.capSeconds)
    }

    /// Past four stops the answer is still the cap — 15 s is where a timelapse
    /// stops reading as continuous motion, so nothing walks past it.
    func testDeepNightIsClampedToTheCap() {
        XCTAssertEqual(seconds(shutter: 1.0, iso: 12096), HolyGrailAutoInterval.capSeconds)
    }

    /// The interval is only ever the floor, the cap, or a whole number of
    /// seconds between them — the HUD prints the number the timer uses.
    func testEveryAnswerIsAWholeNumberOfSecondsInRange() {
        for step in 0...64 {
            let iso = Float(54) * exp2(Float(step) / 8)
            let value = seconds(shutter: 1.0, iso: iso)
            XCTAssertEqual(value, value.rounded())
            XCTAssertGreaterThanOrEqual(value, HolyGrailAutoInterval.floorSeconds)
            XCTAssertLessThanOrEqual(value, HolyGrailAutoInterval.capSeconds)
        }
    }

    /// Widening is monotone in ISO: a darker scene never asks for a *tighter*
    /// spacing than a brighter one, which is what would make a run oscillate.
    func testWideningIsMonotoneInISO() {
        var previous = 0.0
        for step in 0...64 {
            let value = seconds(shutter: 1.0, iso: Float(54) * exp2(Float(step) / 8))
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }

    // MARK: Re-pacing

    /// Sub-second moves are ignored: re-anchoring the window clock costs a
    /// frame's worth of jitter, and the answers are whole seconds anyway.
    func testOnlyWholeSecondMovesArePassedOn() {
        XCTAssertFalse(HolyGrailAutoInterval.isMeaningfulChange(from: 3, to: 3))
        XCTAssertFalse(HolyGrailAutoInterval.isMeaningfulChange(from: 3, to: 3.4))
        XCTAssertTrue(HolyGrailAutoInterval.isMeaningfulChange(from: 3, to: 4))
        XCTAssertTrue(HolyGrailAutoInterval.isMeaningfulChange(from: 9, to: 3))
    }

    // MARK: Through the engine

    /// The convenience overload reads the same pair the capture code applies,
    /// so the HUD and the timer can never disagree about which they used.
    func testEngineOverloadAgreesWithTheRawOne() {
        var engine = HolyGrailRampEngine(
            seed: .init(shutterSeconds: 1.0, iso: 54 * 4), limits: wide,
            anchorsToSeedExposure: false)
        engine.reclamp(to: wide)
        XCTAssertEqual(
            HolyGrailAutoInterval.seconds(for: engine, limits: wide),
            seconds(
                shutter: engine.currentTarget.shutterSeconds,
                iso: engine.currentTarget.iso))
    }
}

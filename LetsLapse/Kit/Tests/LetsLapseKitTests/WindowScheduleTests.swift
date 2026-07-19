import XCTest
@testable import LetsLapseKit

final class WindowScheduleTests: XCTestCase {
    func testConstantWindowPartitionsInput() {
        let schedule = WindowSchedule.make(totalInputFrames: 100, ramp: .constant(10))
        XCTAssertEqual(schedule.count, 10)
        XCTAssertEqual(schedule.reduce(0, +), 100)
        XCTAssertTrue(schedule.allSatisfy { $0 == 10 })
    }

    func testScheduleAlwaysConsumesExactlyAllInput() {
        let ramps: [BlendRamp] = [
            .constant(1),
            .constant(17),
            BlendRamp(startWindow: 1, endWindow: 50),
            BlendRamp(startWindow: 40, endWindow: 2, curve: .easeInOut),
            BlendRamp(startWindow: 3, endWindow: 90, curve: .easeOut),
        ]
        for total in [1, 7, 59, 300, 1234, 20000] {
            for ramp in ramps {
                let schedule = WindowSchedule.make(totalInputFrames: total, ramp: ramp)
                XCTAssertEqual(schedule.reduce(0, +), total, "ramp \(ramp) total \(total)")
                XCTAssertTrue(schedule.allSatisfy { $0 >= 1 })
            }
        }
    }

    func testRampGrowsMonotonically() {
        let schedule = WindowSchedule.make(
            totalInputFrames: 1000, ramp: BlendRamp(startWindow: 1, endWindow: 40))
        XCTAssertEqual(schedule.first, 1)
        // Drop the final window — it may be clamped by the frames remaining.
        let body = schedule.dropLast()
        for (a, b) in zip(body, body.dropFirst()) {
            XCTAssertLessThanOrEqual(a, b)
        }
        XCTAssertGreaterThan(body.last ?? 0, 30)
    }

    func testEmptyInputYieldsEmptySchedule() {
        XCTAssertTrue(WindowSchedule.make(totalInputFrames: 0, ramp: .constant(5)).isEmpty)
    }

    func testWindowNeverBelowOne() {
        let ramp = BlendRamp(startWindow: 1, endWindow: 1)
        XCTAssertEqual(ramp.window(atProgress: 0), 1)
        XCTAssertEqual(ramp.window(atProgress: 1), 1)
        let clampedInit = BlendRamp(startWindow: -5, endWindow: 0)
        XCTAssertEqual(clampedInit.startWindow, 1)
        XCTAssertEqual(clampedInit.endWindow, 1)
    }

    func testCurveShapes() {
        XCTAssertEqual(BlendCurve.linear.value(at: 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(BlendCurve.easeIn.value(at: 0.5), 0.25, accuracy: 1e-9)
        XCTAssertEqual(BlendCurve.easeOut.value(at: 0.5), 0.75, accuracy: 1e-9)
        XCTAssertEqual(BlendCurve.easeInOut.value(at: 0.5), 0.5, accuracy: 1e-9)
        for curve in BlendCurve.allCases {
            XCTAssertEqual(curve.value(at: 0), 0, accuracy: 1e-9)
            XCTAssertEqual(curve.value(at: 1), 1, accuracy: 1e-9)
            XCTAssertEqual(curve.value(at: -3), 0, accuracy: 1e-9)
            XCTAssertEqual(curve.value(at: 7), 1, accuracy: 1e-9)
        }
    }
}

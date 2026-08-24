import XCTest
import CoreVideo
@testable import LetsLapseKit

/// The gate's contract, exercised on synthetic frames: catch the Praha-style
/// 64 px lens excursion, leave sub-pixel OIS wander and unreadable scenes
/// alone, follow slow drift, and adopt a genuine reframe instead of fighting
/// it.
final class FrameAlignmentGateTests: XCTestCase {

    private let width = 1024
    private let height = 768

    /// A textured, non-periodic synthetic scene: nested sines with unrelated
    /// frequencies so correlation has one honest peak. `dx`/`dy` translate the
    /// content (positive = content moves right/down), `gain` scales exposure.
    private func makeFrame(dx: Double = 0, dy: Double = 0, gain: Double = 1,
                           fx: Double = 0.037, fy: Double = 0.023) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attributes, &buffer), kCVReturnSuccess)
        let pixelBuffer = buffer!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            let row = base + y * bytesPerRow
            let sy = Double(y) - dy
            for x in 0..<width {
                let sx = Double(x) - dx
                let value = 128
                    + 46 * sin(fx * sx + 1.3 * sin(0.011 * sy))
                    + 34 * sin(fy * sy + 0.7 * sin(0.017 * sx))
                let clamped = UInt8(max(0, min(255, value * gain)))
                let p = row + x * 4
                p[0] = clamped; p[1] = clamped; p[2] = clamped; p[3] = 255
            }
        }
        return pixelBuffer
    }

    private func makeAnchoredGate() -> FrameAlignmentGate {
        let gate = FrameAlignmentGate()
        let first = gate.evaluate(makeFrame())
        XCTAssertTrue(first.accepted)
        XCTAssertFalse(first.measured, "first frame only anchors")
        return gate
    }

    func testDetectsLargeVerticalShift() {
        let gate = makeAnchoredGate()
        let verdict = gate.evaluate(makeFrame(dy: 64))
        XCTAssertTrue(verdict.measured)
        XCTAssertFalse(verdict.accepted)
        XCTAssertEqual(verdict.dyPixels, 64, accuracy: 6)
        XCTAssertEqual(verdict.dxPixels, 0, accuracy: 6)
    }

    func testDetectsShiftThroughExposureChange() {
        // The Praha events happened under a ramping exposure — a brightness
        // change must not hide (or fake) a displacement.
        let gate = makeAnchoredGate()
        let shifted = gate.evaluate(makeFrame(dy: 64, gain: 0.7))
        XCTAssertFalse(shifted.accepted)
        XCTAssertEqual(shifted.dyPixels, 64, accuracy: 6)
        let dimOnly = gate.evaluate(makeFrame(gain: 0.7))
        XCTAssertTrue(dimOnly.accepted)
    }

    func testAcceptsSmallWander() {
        let gate = makeAnchoredGate()
        for (dx, dy) in [(0.0, 2.0), (1.0, -2.0), (-2.0, 1.0)] {
            let verdict = gate.evaluate(makeFrame(dx: dx, dy: dy))
            XCTAssertTrue(verdict.accepted, "±2 px OIS wander must pass")
            XCTAssertLessThan(verdict.shiftMagnitudePixels, 12)
        }
    }

    func testFlatSceneIsUnmeasuredAndAccepted() {
        let gate = makeAnchoredGate()
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, nil, &buffer)
        let flat = buffer!
        CVPixelBufferLockBaseAddress(flat, [])
        memset(CVPixelBufferGetBaseAddress(flat), 128,
               CVPixelBufferGetBytesPerRow(flat) * height)
        CVPixelBufferUnlockBaseAddress(flat, [])
        let verdict = gate.evaluate(flat)
        XCTAssertTrue(verdict.accepted)
        XCTAssertFalse(verdict.measured, "featureless frames must pass unjudged")
    }

    func testDecorrelatedSceneNeverRejects() {
        // A scene the anchor can't be found in (fully different texture) is a
        // low-confidence reading — the gate must accept, not guess.
        let gate = makeAnchoredGate()
        let verdict = gate.evaluate(makeFrame(dy: 40, fx: 0.291, fy: 0.171))
        XCTAssertTrue(verdict.accepted)
    }

    func testReanchorsAfterConsistentDisplacement() {
        // A knocked tripod displaces everything from here on. Two mostly-
        // displaced windows in a row = a real reframe: adopt it, report it.
        let gate = makeAnchoredGate()
        _ = gate.windowClosed()
        for window in 0..<2 {
            for _ in 0..<5 {
                XCTAssertFalse(gate.evaluate(makeFrame(dy: 64)).accepted)
            }
            let summary = gate.windowClosed()
            XCTAssertEqual(summary.rejectedFrames, 5)
            XCTAssertEqual(summary.reanchored, window == 1,
                           "re-anchor on the second consecutive displaced window")
        }
        XCTAssertTrue(gate.evaluate(makeFrame(dy: 64)).accepted,
                      "the displaced framing is the new baseline")
        XCTAssertFalse(gate.evaluate(makeFrame()).accepted,
                       "the old framing is now 64 px away from the anchor")
    }

    func testTransientExcursionDoesNotReanchor() {
        // The Praha signature: part of one window displaced, then back.
        let gate = makeAnchoredGate()
        for _ in 0..<6 { XCTAssertTrue(gate.evaluate(makeFrame()).accepted) }
        for _ in 0..<4 { XCTAssertFalse(gate.evaluate(makeFrame(dy: 64)).accepted) }
        for _ in 0..<2 { XCTAssertTrue(gate.evaluate(makeFrame()).accepted) }
        let summary = gate.windowClosed()
        XCTAssertEqual(summary.measuredFrames, 12)
        XCTAssertEqual(summary.rejectedFrames, 4)
        XCTAssertFalse(summary.reanchored)
        XCTAssertEqual(summary.peakShiftPixels ?? 0, 64, accuracy: 8)
        XCTAssertTrue(gate.evaluate(makeFrame()).accepted,
                      "baseline still the anchor after the excursion")
    }

    func testAnchorFollowsSlowDrift() {
        // 2 px per window for ten windows: 20 px of total drift, but never
        // more than 2 px from the rolling anchor — nothing may be rejected.
        let gate = makeAnchoredGate()
        for window in 1...10 {
            let drift = Double(window) * 2
            for _ in 0..<3 {
                let verdict = gate.evaluate(makeFrame(dy: drift))
                XCTAssertTrue(verdict.accepted, "drift window \(window) rejected")
            }
            XCTAssertEqual(gate.windowClosed().rejectedFrames, 0)
        }
    }
}

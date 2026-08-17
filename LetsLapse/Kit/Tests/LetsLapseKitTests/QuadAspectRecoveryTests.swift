import XCTest
@testable import LetsLapseKit

/// Recovering a flat object's real proportions from one photograph of it —
/// the measurement the Scanner's PAPER dial gates capture on.
///
/// The fixtures here are *synthesised rather than sampled*, and that is the
/// point: a pinhole camera is exactly modellable, so a test can put a known
/// rectangle at a known pose, project it by hand, and demand the ratio back to
/// within a fraction of a percent. A recorded fixture could only ever say "it
/// still does what it did"; this says "it is right".
final class QuadAspectRecoveryTests: XCTestCase {

    /// A 4:3 frame held portrait — what every Scanner run shoots.
    private let portraitFrame = 3.0 / 4.0
    /// iPhone main camera territory: ~68° horizontal, i.e. 0.5 / tan(34°).
    private let focal = 0.5 / tan(34 * .pi / 180)

    // MARK: - Projection

    /// Projects a `width` × `height` rectangle, tilted `pitch` about its own
    /// horizontal axis and `yaw` about its vertical one, at `distance` from a
    /// pinhole of focal length `focal`, into normalised bottom-left-origin
    /// corners.
    ///
    /// Units are arbitrary and cancel: only `width ÷ height` and the pose
    /// survive into the answer, which is the property under test.
    private func project(
        width: Double,
        height: Double,
        pitch: Double = 0,
        yaw: Double = 0,
        distance: Double = 500,
        focal: Double? = nil,
        frameAspect: Double? = nil
    ) -> NormalizedQuad {
        let f = focal ?? self.focal
        let aspect = frameAspect ?? portraitFrame
        let (cosPitch, sinPitch) = (cos(pitch), sin(pitch))
        let (cosYaw, sinYaw) = (cos(yaw), sin(yaw))

        func corner(_ x: Double, _ y: Double) -> NormalizedQuad.Point {
            // Rotate about x (pitch), then about y (yaw), then push down +Z.
            let y1 = y * cosPitch
            let z1 = y * sinPitch
            let x2 = x * cosYaw + z1 * sinYaw
            let z2 = -x * sinYaw + z1 * cosYaw + distance
            // Pinhole projection into frame-width units, then into the
            // per-axis normalised space the detector reports in.
            let imageX = f * x2 / z2
            let imageY = f * y1 / z2
            return NormalizedQuad.Point(x: imageX + 0.5, y: imageY * aspect + 0.5)
        }

        return NormalizedQuad(
            topLeft: corner(-width / 2, height / 2),
            topRight: corner(width / 2, height / 2),
            bottomLeft: corner(-width / 2, -height / 2),
            bottomRight: corner(width / 2, -height / 2),
            confidence: 0.9)
    }

    // MARK: - The measurement

    /// Square-on: no perspective to undo, and the apparent shape is the true
    /// one. This is the copy-stand case and by far the most common.
    func testFrontoParallelPageMeasuresItsOwnRatio() {
        let quad = project(width: 210, height: 297)
        let ratio = quad.rectifiedAspectRatio(
            frameAspect: portraitFrame, focalInFrameWidths: focal)
        XCTAssertEqual(try XCTUnwrap(ratio), 210.0 / 297.0, accuracy: 0.005)
    }

    /// The case the whole method exists for: a page shot from above at an angle
    /// keystones hard, and its *apparent* ratio is nowhere near the truth.
    func testTiltedPageRecoversItsRatioWhereTheApparentOneFails() throws {
        let quad = project(width: 210, height: 297, pitch: 40 * .pi / 180, yaw: 12 * .pi / 180)
        let a4 = 210.0 / 297.0

        // The naive measurement is wrong by a wide margin — this is the number
        // a gate would have had to work with without the recovery.
        let apparent = quad.apparentAspectRatio
        XCTAssertGreaterThan(abs(apparent - a4), 0.1)

        let recovered = try XCTUnwrap(quad.rectifiedAspectRatio(
            frameAspect: portraitFrame, focalInFrameWidths: focal))
        XCTAssertEqual(recovered, a4, accuracy: 0.01)
    }

    /// Landscape on the desk is the same stock, and `rectifiedPortraitRatio`
    /// is the form the stock table is written in.
    func testLandscapePageReportsTheSameStockRatio() throws {
        let quad = project(width: 297, height: 210, pitch: 25 * .pi / 180)
        let portrait = try XCTUnwrap(quad.rectifiedPortraitRatio(
            frameAspect: portraitFrame, focalInFrameWidths: focal))
        XCTAssertEqual(portrait, 210.0 / 297.0, accuracy: 0.01)
    }

    /// A shape that is not the stock stays not the stock however it is held.
    func testSquareCardIsNotMistakenForAPage() throws {
        let quad = project(width: 200, height: 200, pitch: 30 * .pi / 180, yaw: 20 * .pi / 180)
        let recovered = try XCTUnwrap(quad.rectifiedAspectRatio(
            frameAspect: portraitFrame, focalInFrameWidths: focal))
        XCTAssertEqual(recovered, 1, accuracy: 0.02)
    }

    /// Collinear corners — the shape a spurious edge-of-frame detection has.
    func testDegenerateQuadMeasuresNothing() {
        let flat = NormalizedQuad(
            topLeft: .init(x: 0.1, y: 0.5),
            topRight: .init(x: 0.9, y: 0.5),
            bottomLeft: .init(x: 0.1, y: 0.5),
            bottomRight: .init(x: 0.9, y: 0.5),
            confidence: 0.9)
        XCTAssertNil(flat.rectifiedAspectRatio(
            frameAspect: portraitFrame, focalInFrameWidths: focal))
    }

    // MARK: - The gate

    func testNamedStockAdmitsItsOwnPageAtAnAngle() {
        let quad = project(width: 210, height: 297, pitch: 35 * .pi / 180, yaw: 15 * .pi / 180)
        XCTAssertTrue(PerspectiveAspect.a4.admits(
            quad, frameAspect: portraitFrame, focalInFrameWidths: focal))
    }

    func testNamedStockRefusesAShapeItCannotBe() {
        let square = project(width: 200, height: 200, pitch: 20 * .pi / 180)
        XCTAssertFalse(PerspectiveAspect.a4.admits(
            square, frameAspect: portraitFrame, focalInFrameWidths: focal))

        // The classic junk detection: a long thin sliver down the edge of the
        // frame, which passes Vision's own aspect floor and is not a page.
        let sliver = project(width: 60, height: 400, pitch: 10 * .pi / 180)
        XCTAssertFalse(PerspectiveAspect.a4.admits(
            sliver, frameAspect: portraitFrame, focalInFrameWidths: focal))
    }

    /// A4 and Letter are 9% apart and this test says so out loud: the gate is
    /// not a stock identifier, and a run set to one must not refuse the other.
    func testTheGateDoesNotPoliceWhichPaperItIs() {
        let letter = project(width: 8.5, height: 11, pitch: 25 * .pi / 180)
        XCTAssertTrue(PerspectiveAspect.a4.admits(
            letter, frameAspect: portraitFrame, focalInFrameWidths: focal))
    }

    /// Auto is the "I haven't said" answer, and it has to admit everything —
    /// including the objects with no proportions anyone promised, which is the
    /// whole turntable case.
    func testAutoAdmitsAnything() {
        let odd = project(width: 137, height: 61, pitch: 30 * .pi / 180, yaw: 25 * .pi / 180)
        XCTAssertTrue(PerspectiveAspect.auto.admits(
            odd, frameAspect: portraitFrame, focalInFrameWidths: focal))
    }

    /// Fails open: a quad the method cannot measure must not stop a shoot.
    func testUnmeasurableQuadIsAdmitted() {
        let flat = NormalizedQuad(
            topLeft: .init(x: 0.2, y: 0.4),
            topRight: .init(x: 0.8, y: 0.4),
            bottomLeft: .init(x: 0.2, y: 0.4),
            bottomRight: .init(x: 0.8, y: 0.4),
            confidence: 0.9)
        XCTAssertTrue(PerspectiveAspect.a4.admits(
            flat, frameAspect: portraitFrame, focalInFrameWidths: focal))
    }
}

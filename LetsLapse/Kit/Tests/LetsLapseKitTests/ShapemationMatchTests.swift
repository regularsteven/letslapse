import XCTest
import CoreGraphics
@testable import LetsLapseKit

/// The Match step's rules, the Timing step's arithmetic, the Sort's key, and
/// the plan's per-family transforms — the Kit half of the 2026-09-11 designs.
final class ShapemationMatchTests: XCTestCase {
    private func ellipse(_ obliquity: Double, rotation: Double = 0.3, frame: CGSize = CGSize(width: 3024, height: 4032)) -> DetectedShape {
        DetectedShape.ellipse(centre: CGPoint(x: 1500, y: 2000), semiAxisX: 500, semiAxisY: 500 * obliquity, rotation: rotation, frame: frame, source: .detected)
    }
    private func quad(w: Double, h: Double, frame: CGSize = CGSize(width: 3024, height: 4032)) -> DetectedShape {
        let x0 = 1500 - w / 2, y0 = 2000 - h / 2
        return DetectedShape.quad(corners: [CGPoint(x: x0, y: y0), CGPoint(x: x0 + w, y: y0), CGPoint(x: x0 + w, y: y0 + h), CGPoint(x: x0, y: y0 + h)],
                                  frame: frame, source: .detected)
    }

    func testCircleRoundnessPerStrictness() {
        var m = ShapeMatch(family: .circle)
        XCTAssertTrue(m.matches(ellipse(0.9)))
        XCTAssertFalse(m.matches(ellipse(0.8)))
        m.strictness = .loose
        XCTAssertTrue(m.matches(ellipse(0.72)), "a mug seen from the side")
        XCTAssertFalse(m.matches(ellipse(0.6)))
        m.strictness = .strict
        XCTAssertFalse(m.matches(ellipse(0.9)))
        XCTAssertTrue(m.matches(ellipse(0.97)))
        XCTAssertFalse(m.matches(quad(w: 800, h: 800)), "never a quad")
    }

    func testOvalRatioAndTolerance() {
        var m = ShapeMatch(family: .oval)
        XCTAssertTrue(m.matches(ellipse(0.6)), "Any ratio")
        XCTAssertFalse(m.matches(ellipse(0.9)), "round enough to be a circle")
        m.ovalRatio = 0.6
        XCTAssertTrue(m.matches(ellipse(0.68)))
        XCTAssertFalse(m.matches(ellipse(0.72)))
        m.strictness = .loose
        XCTAssertTrue(m.matches(ellipse(0.78)))
        m.strictness = .strict
        XCTAssertFalse(m.matches(ellipse(0.68)))
        XCTAssertTrue(m.matches(ellipse(0.62)))
    }

    func testSquareAndRectangleClasses() {
        var sq = ShapeMatch(family: .square)
        XCTAssertTrue(sq.matches(quad(w: 1000, h: 850)), "1.18 within Normal's 1.25")
        XCTAssertFalse(sq.matches(quad(w: 1000, h: 700)))
        sq.strictness = .strict
        XCTAssertFalse(sq.matches(quad(w: 1000, h: 850)))
        XCTAssertTrue(sq.matches(quad(w: 1000, h: 970)))

        var rect = ShapeMatch(family: .rectangle)
        XCTAssertTrue(rect.matches(quad(w: 1200, h: 900)), "Any: a 4:3 is a rectangle")
        XCTAssertFalse(rect.matches(quad(w: 1000, h: 950)), "Any: a near-square is the square family")
        rect.aspectClass = .fourThree
        XCTAssertTrue(rect.matches(quad(w: 1200, h: 900)))
        XCTAssertTrue(rect.matches(quad(w: 900, h: 1200)), "orientation-free by default")
        XCTAssertFalse(rect.matches(quad(w: 1200, h: 800)), "3:2 is 12 % off 4:3")
        rect.strictness = .loose
        XCTAssertTrue(rect.matches(quad(w: 1200, h: 800)))
        rect.strictness = .normal
        rect.orientation = .landscape
        XCTAssertFalse(rect.matches(quad(w: 900, h: 1200)))
        rect.orientation = .any
        rect.aspectClass = .page
        XCTAssertTrue(rect.matches(quad(w: 1414, h: 1000)), "A-series")
        XCTAssertTrue(rect.matches(quad(w: 1294, h: 1000)), "Letter is Page too")
        rect.aspectClass = .custom; rect.customWidth = 21; rect.customHeight = 9
        XCTAssertTrue(rect.matches(quad(w: 2100, h: 900)))
        XCTAssertEqual(rect.summary, "Rectangle 21:9 · Normal")
    }

    /// A rectified aspect, when present, is what the match and the family judge.
    func testRectifiedAspectDrivesFamilyAndMatch() {
        var tilted = quad(w: 1000, h: 700)   // reads 1.43 on screen
        XCTAssertEqual(tilted.family, .rectangle)
        tilted.rectifiedAspect = 1.02         // but is a square seen at an angle
        XCTAssertEqual(tilted.family, .square)
        XCTAssertTrue(ShapeMatch(family: .square).matches(tilted))
        XCTAssertTrue(tilted.isRectified)
    }

    /// The register works a quad's rectified aspect out from its lens: a
    /// square-on frame recovers its apparent ratio; a keystoned view of a
    /// 4:3 rectangle recovers 4:3 where the apparent ratio does not.
    func testRegisterRectifiesQuadsFromTheLens() throws {
        let frame = CGSize(width: 3024, height: 4032)
        let fov = 69.0
        let flat = quad(w: 1200, h: 900, frame: frame).rectified(horizontalFieldOfView: fov, frame: frame)
        XCTAssertEqual(try XCTUnwrap(flat.rectifiedAspect), 4.0 / 3.0, accuracy: 0.03)
        // A 4:3 rectangle tilted away at the top: the far edge shorter.
        let keystoned = DetectedShape.quad(corners: [CGPoint(x: 1050, y: 1500), CGPoint(x: 1950, y: 1500),
                                                     CGPoint(x: 2300, y: 2500), CGPoint(x: 700, y: 2500)],
                                           frame: frame, source: .detected)
        let rectified = keystoned.rectified(horizontalFieldOfView: fov, frame: frame)
        XCTAssertNotNil(rectified.rectifiedAspect)
        XCTAssertNotEqual(rectified.effectiveAspect, keystoned.aspect, accuracy: 0.01, "perspective was undone")
        XCTAssertNil(quad(w: 1200, h: 900).rectified(horizontalFieldOfView: nil, frame: frame).rectifiedAspect, "no lens, no rectification")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shapes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rep = ShapeRegister.Representative(relativePath: "source/frame-00001.jpg", source: .sourceFrame, width: 3024, height: 4032, horizontalFieldOfView: fov)
        let reg = ShapeRegister(representative: rep, shapes: [quad(w: 1200, h: 900, frame: frame)]).rectifyingQuads()
        try reg.save(inProjectFolder: dir)
        let back = try XCTUnwrap(ShapeRegister.load(inProjectFolder: dir))
        XCTAssertEqual(back.representative.horizontalFieldOfView, fov)
        XCTAssertEqual(try XCTUnwrap(back.shapes[0].rectifiedAspect), 4.0 / 3.0, accuracy: 0.03)
    }

    func testTimingHoldsAndEstimate() {
        let constant = ShapemationTiming()
        XCTAssertEqual(constant.holds(count: 12), Array(repeating: 25, count: 12))
        XCTAssertEqual(constant.estimate(count: 12), "12 photos · 12.0 s of playback · 300 frames")
        XCTAssertEqual(constant.summary, "25 fps · 1 s each")

        let ramp = ShapemationTiming(fps: 25, ramp: .init(start: .seconds(2), middle: .seconds(0.5), end: .seconds(1)))
        XCTAssertEqual(ramp.holds(count: 12), [50, 43, 36, 30, 23, 16, 14, 16, 18, 20, 23, 25], "the design's own numbers")
        XCTAssertEqual(ramp.totalFrames(count: 12), 314)
        XCTAssertEqual(ramp.totalSeconds(count: 12), 12.56, accuracy: 1e-9)
        XCTAssertEqual(ramp.summary, "25 fps · ramp 2 s → 0.5 s → 1 s")

        let straight = ShapemationTiming(fps: 24, ramp: .init(start: .seconds(0.1), middle: nil, end: .frames(1)))
        XCTAssertEqual(ShapemationTiming.Hold.seconds(0.1).frames(at: 24), 2, "0.1 s is 2 frames at 24")
        XCTAssertEqual(ShapemationTiming.Hold.seconds(0.1).frames(at: 60), 6)
        XCTAssertEqual(straight.holds(count: 3), [2, 2, 1], "straight start → end, whole frames, never under one")
        XCTAssertEqual(ShapemationTiming.Hold.options.map(\.title), ["2 s", "1 s", "0.5 s", "0.25 s", "0.1 s", "3 frames", "2 frames", "1 frame"])

        let data = try! JSONEncoder().encode(ramp)
        XCTAssertEqual(try! JSONDecoder().decode(ShapemationTiming.self, from: data), ramp)
    }

    func testSortIsByShareOfTheFrame() {
        func item(_ diameter: Double, frame: CGSize) -> ShapemationItem {
            var shape = ellipse(1, frame: frame)
            shape.nativeDiameterPx = diameter
            return ShapemationItem(title: "\(Int(diameter))", imageURL: URL(fileURLWithPath: "/x"), pixelSize: frame, shape: shape)
        }
        let big = item(1350, frame: CGSize(width: 3024, height: 4032))       // 45 %
        let small = item(1400, frame: CGSize(width: 6000, height: 8000))     // 17 %, more pixels
        let mid = item(500, frame: CGSize(width: 1080, height: 1440))        // 46 %
        let given = [small, big, mid]
        XCTAssertEqual(ShapemationSort.largestFirst.sorted(given).map(\.title), ["500", "1350", "1400"])
        XCTAssertEqual(ShapemationSort.smallestFirst.sorted(given).map(\.title), ["1400", "1350", "500"])
        XCTAssertEqual(ShapemationSort.newestFirst.sorted(given).map(\.title), ["1400", "1350", "500"])
        XCTAssertEqual(ShapemationSort.share(of: big), 1350.0 / 3024, accuracy: 1e-9)
    }

    /// The plan's transforms: a tilted circle lands round, an oval lands
    /// level, a keystoned rectangle lands on the class's rectangle.
    func testPlanTransformsPerFamily() throws {
        let frame = CGSize(width: 3024, height: 4032)
        let url = URL(fileURLWithPath: "/x")
        // Circle, seen from the side (0.7): after placement the ellipse's
        // major and minor extents both equal the target.
        let tilted = ShapemationItem(title: "rim", imageURL: url, pixelSize: frame, shape: ellipse(0.7, rotation: 0.4))
        let plan = try XCTUnwrap(ShapemationPlan.make(items: [tilted], mode: .stack, match: ShapeMatch(family: .circle)))
        let h = plan.placements[0].transform
        let c = CGPoint(x: 1500, y: 2000)
        let a = h.apply(CGPoint(x: c.x + 500 * cos(0.4), y: c.y + 500 * sin(0.4)))       // major end
        let b = h.apply(CGPoint(x: c.x - 350 * sin(0.4), y: c.y + 350 * cos(0.4)))       // minor end (0.7 × 500)
        let centre = h.apply(c)
        XCTAssertEqual(hypot(a.x - centre.x, a.y - centre.y), plan.shapeSizePx / 2, accuracy: 0.5)
        XCTAssertEqual(hypot(b.x - centre.x, b.y - centre.y), plan.shapeSizePx / 2, accuracy: 0.5, "the minor axis was stretched to the major")

        // Oval, level: the major axis lands horizontal.
        var oval = ShapeMatch(family: .oval); oval.angle = .level
        let ov = ShapemationItem(title: "oval", imageURL: url, pixelSize: frame, shape: ellipse(0.6, rotation: 0.5))
        let plan2 = try XCTUnwrap(ShapemationPlan.make(items: [ov], mode: .stack, match: oval))
        let h2 = plan2.placements[0].transform
        let end = h2.apply(CGPoint(x: c.x + 500 * cos(0.5), y: c.y + 500 * sin(0.5)))
        let mid2 = h2.apply(c)
        XCTAssertEqual(end.y, mid2.y, accuracy: 0.5, "level")

        // Rectangle 4:3: a keystoned quad's corners land on a 4:3 rectangle of the target's long side.
        var rect = ShapeMatch(family: .rectangle); rect.aspectClass = .fourThree
        let keystoned = DetectedShape.quad(corners: [CGPoint(x: 1050, y: 1500), CGPoint(x: 1950, y: 1500),
                                                     CGPoint(x: 2300, y: 2500), CGPoint(x: 700, y: 2500)],
                                           frame: frame, source: .detected)
        let kq = ShapemationItem(title: "window", imageURL: url, pixelSize: frame, shape: keystoned)
        let plan3 = try XCTUnwrap(ShapemationPlan.make(items: [kq], mode: .stack, match: rect))
        let h3 = plan3.placements[0].transform
        let tl = h3.apply(CGPoint(x: 1050, y: 1500)), tr = h3.apply(CGPoint(x: 1950, y: 1500))
        let br = h3.apply(CGPoint(x: 2300, y: 2500)), bl = h3.apply(CGPoint(x: 700, y: 2500))
        XCTAssertEqual(tl.y, tr.y, accuracy: 0.5); XCTAssertEqual(bl.y, br.y, accuracy: 0.5)
        XCTAssertEqual(tl.x, bl.x, accuracy: 0.5); XCTAssertEqual(tr.x, br.x, accuracy: 0.5)
        let w = tr.x - tl.x, hgt = bl.y - tl.y
        XCTAssertEqual(w / hgt, 4.0 / 3.0, accuracy: 1e-6)
        XCTAssertEqual(max(w, hgt), plan3.shapeSizePx, accuracy: 1e-6)
        XCTAssertFalse(h3.isAffine, "a keystone needs the projective path")
    }
}

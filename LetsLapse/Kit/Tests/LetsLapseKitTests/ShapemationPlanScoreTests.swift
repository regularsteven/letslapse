import XCTest
import CoreGraphics
@testable import LetsLapseKit

/// The synthetic corpus's scorer (docs/shapemation/synthetic-corpus.md §5):
/// on items whose truth IS the register shape every residual is zero and
/// nothing is dropped, whatever the frames' sizes; on a truth the register
/// misses by 3 % the scorer says 0.03; and the manifest decodes as the
/// contract's §2 spells it.
final class ShapemationPlanScoreTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/x")

    /// Three quads of different sizes, off centre, on three frame sizes —
    /// two 4:3 either way up and a 16:9.
    private func quadItems() -> (items: [ShapemationItem], truths: [UUID: SceneManifest.Geometry]) {
        let specs: [(CGSize, CGPoint, Double, Double, Double)] = [
            (CGSize(width: 4032, height: 3024), CGPoint(x: 2600, y: 1100), 1200, 800, 0.0),
            (CGSize(width: 3024, height: 4032), CGPoint(x: 900, y: 2900), 700, 500, 0.15),
            (CGSize(width: 1920, height: 1080), CGPoint(x: 1300, y: 700), 480, 300, -0.08),
        ]
        var items: [ShapemationItem] = []
        var truths: [UUID: SceneManifest.Geometry] = [:]
        for (frame, centre, w, h, angle) in specs {
            let c = cos(angle), s = sin(angle)
            func corner(_ dx: Double, _ dy: Double) -> CGPoint {
                CGPoint(x: Double(centre.x) + dx * c - dy * s, y: Double(centre.y) + dx * s + dy * c)
            }
            let corners = [corner(-w / 2, -h / 2), corner(w / 2, -h / 2), corner(w / 2, h / 2), corner(-w / 2, h / 2)]
            let truth = SceneManifest.Geometry.quad(corners)
            let shape = try! SceneManifest.makeShape(truth, frame: frame)
            let item = ShapemationItem(title: "\(Int(w))", imageURL: url, pixelSize: frame, shape: shape)
            items.append(item)
            truths[item.id] = truth
        }
        return (items, truths)
    }

    private func circleItems() -> (items: [ShapemationItem], truths: [UUID: SceneManifest.Geometry]) {
        let specs: [(CGSize, CGPoint, Double)] = [
            (CGSize(width: 4032, height: 3024), CGPoint(x: 3000, y: 2200), 500),
            (CGSize(width: 3024, height: 4032), CGPoint(x: 700, y: 900), 260),
            (CGSize(width: 1920, height: 1080), CGPoint(x: 400, y: 800), 180),
        ]
        var items: [ShapemationItem] = []
        var truths: [UUID: SceneManifest.Geometry] = [:]
        for (frame, centre, r) in specs {
            let truth = SceneManifest.Geometry.ellipse(centre: centre, semiAxes: (r, r), rotation: 0.2)
            let shape = try! SceneManifest.makeShape(truth, frame: frame)
            let item = ShapemationItem(title: "\(Int(r))", imageURL: url, pixelSize: frame, shape: shape)
            items.append(item)
            truths[item.id] = truth
        }
        return (items, truths)
    }

    private func assertExact(_ score: ShapemationScore, count: Int, corners: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(score.placed, count, "every item placed", file: file, line: line)
        for s in score.items {
            XCTAssertLessThan(s.centrePx, 0.5, "centre", file: file, line: line)
            XCTAssertLessThan(abs(s.scale), 1e-3, "scale", file: file, line: line)
            XCTAssertLessThan(abs(s.rotationDeg), 0.01, "rotation", file: file, line: line)
            if corners {
                XCTAssertLessThan(try XCTUnwrap(s.cornerRmsPx, file: file, line: line), 0.5, "corners", file: file, line: line)
            } else {
                XCTAssertNil(s.cornerRmsPx, file: file, line: line)
            }
        }
        XCTAssertEqual(score.centre?.max ?? 1, 0, accuracy: 0.5 / 100, file: file, line: line)
    }

    func testRectanglesLandExactlyOnTheirOwnTruth() throws {
        let (items, truths) = quadItems()
        for sort in ShapemationSort.allCases {
            let sorted = sort.sorted(items)
            let plan = try XCTUnwrap(ShapemationPlan.make(items: sorted, mode: .stack, match: ShapeMatch(family: .rectangle)))
            XCTAssertEqual(plan.placements.count, 3, "nothing dropped by the plan under \(sort)")
            let score = ShapemationScore.measure(plan: plan, items: sorted, truths: truths)
            try assertExact(score, count: 3, corners: true)
            XCTAssertEqual(score.items.map(\.itemID), plan.placements.map(\.itemID), "scores follow the plan's order")
            let overlap = try XCTUnwrap(score.pairwiseOverlap)
            XCTAssertGreaterThan(overlap.median, 0, "consecutive footprints share the shape, so they overlap")
            XCTAssertLessThanOrEqual(overlap.max, 1)
        }
        // Crop mode has a plan too, and the residuals are the same numbers.
        let cropPlan = try XCTUnwrap(ShapemationPlan.make(items: items, mode: .crop, match: ShapeMatch(family: .rectangle)))
        try assertExact(ShapemationScore.measure(plan: cropPlan, items: items, truths: truths), count: 3, corners: true)
    }

    func testCirclesLandExactlyOnTheirOwnTruth() throws {
        let (items, truths) = circleItems()
        let plan = try XCTUnwrap(ShapemationPlan.make(items: ShapemationSort.largestFirst.sorted(items), mode: .stack, match: ShapeMatch(family: .circle)))
        XCTAssertEqual(plan.placements.count, 3)
        let score = ShapemationScore.measure(plan: plan, items: items, truths: truths)
        try assertExact(score, count: 3, corners: false)
        XCTAssertNil(score.cornerRmsPx, "no quads, no corner residual")
    }

    /// The scorer measures what it says: a truth the register misses by 3 %
    /// of its size scores centre ≈ 0.03, scale ≈ 0 and rotation ≈ 0.
    func testPerturbedTruthScoresItsOwnOffset() throws {
        let (items, _) = quadItems()
        var truths: [UUID: SceneManifest.Geometry] = [:]
        for item in items {
            let W = Double(item.pixelSize.width), H = Double(item.pixelSize.height)
            let px = try XCTUnwrap(item.shape.corners).map { CGPoint(x: Double($0.x) * W, y: Double($0.y) * H) }
            let major = DetectedShape.quadMetrics(cornersPx: px).major
            // Offset along the quad's own top edge, so the shift survives the levelling.
            let angle = item.shape.rotation
            let dx = 0.03 * major * cos(angle), dy = 0.03 * major * sin(angle)
            truths[item.id] = .quad(px.map { CGPoint(x: Double($0.x) + dx, y: Double($0.y) + dy) })
        }
        let plan = try XCTUnwrap(ShapemationPlan.make(items: items, mode: .stack, match: ShapeMatch(family: .rectangle)))
        let score = ShapemationScore.measure(plan: plan, items: items, truths: truths)
        XCTAssertEqual(score.placed, 3)
        for s in score.items {
            XCTAssertEqual(s.centre, 0.03, accuracy: 1e-4)
            XCTAssertEqual(s.centrePx, 0.03 * plan.shapeSizePx, accuracy: 0.05)
            XCTAssertEqual(s.scale, 0, accuracy: 1e-6)
            XCTAssertEqual(s.rotationDeg, 0, accuracy: 1e-6)
            XCTAssertEqual(try XCTUnwrap(s.cornerRmsPx), 0.03 * plan.shapeSizePx, accuracy: 0.05, "every corner moved by the same offset")
        }
        XCTAssertEqual(try XCTUnwrap(score.centre).median, 0.03, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(score.centre).p90, 0.03, accuracy: 1e-4)

        // And an item without a truth is not scored — the caller reports it.
        var fewer = truths
        fewer.removeValue(forKey: items[1].id)
        XCTAssertEqual(ShapemationScore.measure(plan: plan, items: items, truths: fewer).placed, 2)
    }

    func testPlanDropsWhatTheContractSaysItDrops() throws {
        // A degenerate shape is skipped by `make` without a word — the CLI
        // pre-detects it; here the plan just shows the skip so the CLI's
        // reason list is honest.
        let (items, _) = quadItems()
        var flat = items[0]
        flat.shape.majorAxis = 0
        let plan = try XCTUnwrap(ShapemationPlan.make(items: [flat, items[1], items[2]], mode: .stack, match: ShapeMatch(family: .rectangle)))
        XCTAssertEqual(plan.placements.count, 2)
        XCTAssertFalse(plan.placements.contains { $0.itemID == flat.id })
    }

    func testStatHelpers() {
        XCTAssertNil(ShapemationScore.Stat([]))
        let s = ShapemationScore.Stat([5, 1, 3, 2, 4])!
        XCTAssertEqual(s.median, 3); XCTAssertEqual(s.p90, 5); XCTAssertEqual(s.max, 5)
        XCTAssertEqual(ShapemationScore.median([1, 2, 3, 4]), 2.5)
        XCTAssertEqual(ShapemationScore.percentile(Array(stride(from: 1.0, through: 100, by: 1)), 0.9), 90)
        XCTAssertEqual(ShapemationScore.iou(CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 5, y: 0, width: 10, height: 10)), 1.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(ShapemationScore.iou(CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 20, y: 0, width: 10, height: 10)), 0)
        XCTAssertTrue(ShapemationScore.empty.summaryLine(dropped: 2).hasPrefix("SHAPEMATION SCORE: placed 0 · dropped 2 · centre median n/a"))
    }

    /// The manifest as Python writes it (contract §2), both kinds.
    func testSceneManifestDecodesTheContract() throws {
        let quad = """
        {
          "schema": 1, "id": "front-0042", "set": "scale-0.05",
          "frame": { "width": 4032, "height": 3024 },
          "subject": { "part": "tram_front", "viewpoint": "front", "scene": "day-hills-road", "family": "rectangle" },
          "sequence": { "index": 42, "of": 100, "approach": 0.42 },
          "truth":     { "kind": "quad", "cornersPx": [[100,200],[900,210],[890,700],[110,690]], "tiltDeg": 0, "yawDeg": 0 },
          "perturbed": { "kind": "quad", "cornersPx": [[105,205],[905,215],[895,705],[115,695]] },
          "perturbation": { "sigmaScale": 0.05, "sigmaCentre": 0, "sigmaRotationDeg": 0, "seed": 4242 },
          "placement": { "cx": 500, "cy": 450, "matrix": [1, 0, 0, 0, 1, 0] }
        }
        """
        let m = try JSONDecoder().decode(SceneManifest.self, from: Data(quad.utf8))
        XCTAssertEqual(m.id, "front-0042"); XCTAssertEqual(m.set, "scale-0.05")
        XCTAssertEqual(m.frameSize, CGSize(width: 4032, height: 3024))
        XCTAssertEqual(m.subject.viewpoint, "front"); XCTAssertEqual(m.subject.family, .rectangle); XCTAssertEqual(m.sequence.approach, 0.42)
        XCTAssertEqual(m.truth.kind, .quad)
        XCTAssertEqual(m.truth.cornersPx, [CGPoint(x: 100, y: 200), CGPoint(x: 900, y: 210), CGPoint(x: 890, y: 700), CGPoint(x: 110, y: 690)])
        XCTAssertEqual(m.truth.tiltDeg, 0); XCTAssertNil(m.perturbed.tiltDeg)
        XCTAssertEqual(m.perturbed.cornersPx?[0], CGPoint(x: 105, y: 205))
        XCTAssertEqual(m.perturbation.seed, 4242); XCTAssertEqual(m.perturbation.sigmaScale, 0.05)
        let shape = try SceneManifest.makeShape(m.perturbed, frame: m.frameSize)
        XCTAssertEqual(shape.kind, .quad); XCTAssertEqual(shape.source, .manual)
        XCTAssertEqual(shape.corners?[0].x ?? 0, 105.0 / 4032, accuracy: 1e-12)
        XCTAssertEqual(shape.corners?[0].y ?? 0, 205.0 / 3024, accuracy: 1e-12)

        let ellipse = """
        {
          "schema": 1, "id": "wheel-0007", "set": "centre-0.02",
          "frame": { "width": 1920, "height": 1080 },
          "subject": { "part": "wheel", "viewpoint": "left", "scene": "night-flat", "family": "oval" },
          "sequence": { "index": 7, "of": 60, "approach": 0.1 },
          "truth":     { "kind": "ellipse", "centrePx": [960, 540], "semiAxesPx": [200, 120], "rotation": 0.3, "tiltDeg": 10, "yawDeg": -20 },
          "perturbed": { "kind": "ellipse", "centrePx": [964, 541], "semiAxesPx": [200, 120], "rotation": 0.3 },
          "perturbation": { "sigmaScale": 0, "sigmaCentre": 0.02, "sigmaRotationDeg": 0, "seed": 1 }
        }
        """
        let e = try JSONDecoder().decode(SceneManifest.self, from: Data(ellipse.utf8))
        XCTAssertEqual(e.truth.kind, .ellipse)
        XCTAssertEqual(e.truth.centrePx, CGPoint(x: 960, y: 540)); XCTAssertEqual(e.truth.semiAxesPx, [200, 120])
        XCTAssertEqual(e.truth.rotation, 0.3); XCTAssertEqual(e.truth.yawDeg, -20); XCTAssertNil(e.truth.cornersPx)
        let es = try SceneManifest.makeShape(e.perturbed, frame: e.frameSize)
        XCTAssertEqual(es.kind, .ellipse); XCTAssertEqual(es.family, .oval); XCTAssertEqual(es.family, e.subject.family)
        XCTAssertEqual(es.majorAxis, 400.0 / 1920, accuracy: 1e-12); XCTAssertEqual(es.minorAxis, 240.0 / 1920, accuracy: 1e-12)
        XCTAssertEqual(es.centre.x, 964.0 / 1920, accuracy: 1e-12); XCTAssertEqual(es.centre.y, 541.0 / 1080, accuracy: 1e-12)
        XCTAssertEqual(es.nativeDiameterPx, 400)

        // Round trip: what the Kit writes, the Kit reads.
        let data = try JSONEncoder().encode(e)
        XCTAssertEqual(try JSONDecoder().decode(SceneManifest.self, from: data), e)
        XCTAssertThrowsError(try SceneManifest.makeShape(.init(kind: .quad, cornersPx: [CGPoint(x: 1, y: 1)]), frame: e.frameSize))
    }
}

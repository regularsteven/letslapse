import XCTest
import CoreGraphics
import simd
@testable import LetsLapseKit

/// The edge-chain pass on the region tests' card, and its wiring into the
/// detector. The chains themselves are checked against OpenCV's Edge Drawing
/// by the benchmark rig (byte-identical on the corpus's pictures at 1024 and
/// 2048, 2026-09-12); here is the geometry a person would draw.
final class EdgeDrawingTests: XCTestCase {
    /// A light card with a dark disc, a dark rectangle, a dark trapezoid and
    /// a light ring on a dark square (the hole case), drawn by Core Graphics
    /// — `RegionProposalsTests.card()`.
    private func card() -> CGImage {
        let w = 800, h = 600
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0.85, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 0.15, alpha: 1)
        ctx.fillEllipse(in: CGRect(x: 100, y: 120, width: 160, height: 160))          // disc, centre (180, 200) r 80
        ctx.fill(CGRect(x: 360, y: 100, width: 240, height: 140))                       // rectangle 240 × 140
        ctx.move(to: CGPoint(x: 120, y: 380)); ctx.addLine(to: CGPoint(x: 320, y: 380))  // trapezoid
        ctx.addLine(to: CGPoint(x: 280, y: 520)); ctx.addLine(to: CGPoint(x: 160, y: 520)); ctx.closePath(); ctx.fillPath()
        ctx.fill(CGRect(x: 480, y: 340, width: 220, height: 220))                       // dark square …
        ctx.setFillColor(gray: 0.85, alpha: 1)
        ctx.fillEllipse(in: CGRect(x: 520, y: 380, width: 140, height: 140))           // … with a light disc inside (a hole)
        return ctx.makeImage()!
    }

    func testChainsAreOrderedEightConnectedRuns() throws {
        let gray = try XCTUnwrap(RegionProposals.grayPlane(card()))
        let traced = EdgeDrawing.chains(in: RegionProposals.gaussian5(gray), settings: EdgeDrawing.Settings())
        XCTAssertGreaterThan(traced.anchors, 0)
        // Five outlines, none touching another: at least five chains.
        XCTAssertGreaterThanOrEqual(traced.chains.count, 5)
        for chain in traced.chains {
            XCTAssertGreaterThanOrEqual(chain.count, 2)
            for k in 1..<chain.count {
                XCTAssertLessThanOrEqual(max(abs(chain[k].x - chain[k - 1].x), abs(chain[k].y - chain[k - 1].y)), 1,
                                         "chain step \(k) jumps from \(chain[k - 1]) to \(chain[k])")
            }
            // One pixel, one place in one chain: the joins drop the anchor's
            // and the branch pixels' second copies.
            XCTAssertEqual(Set(chain.map { Int($0.y) * gray.width + Int($0.x) }).count, chain.count)
            for p in chain { XCTAssertTrue(p.x >= 1 && p.y >= 1 && Int(p.x) <= gray.width - 2 && Int(p.y) <= gray.height - 2) }
        }
        let all = traced.chains.flatMap { $0 }.map { Int($0.y) * gray.width + Int($0.x) }
        XCTAssertEqual(Set(all).count, all.count, "a pixel in two chains")
    }

    func testClosedLoopRule() {
        // A 30-px square walked around (120 points) with a 30-px tail: the
        // ends are far apart, but the chain returns to its start.
        var chain: [EdgeDrawing.Point] = []
        for x in 0..<30 { chain.append(EdgeDrawing.Point(Int32(x), 0)) }
        for y in 0..<30 { chain.append(EdgeDrawing.Point(29, Int32(y))) }
        for x in stride(from: 29, through: 0, by: -1) { chain.append(EdgeDrawing.Point(Int32(x), 29)) }
        for y in stride(from: 29, through: 0, by: -1) { chain.append(EdgeDrawing.Point(0, Int32(y))) }
        let square = chain
        for x in 1...30 { chain.append(EdgeDrawing.Point(Int32(-x), 0)) }
        let s = EdgeDrawing.Settings()
        let loops = EdgeDrawing.closedLoops(chain, settings: s)
        XCTAssertEqual(loops.count, 1)
        XCTAssertEqual(loops.first?.0, 0)
        // The join tolerance (3 px) lets the loop keep the tail's first pixels.
        XCTAssertGreaterThanOrEqual(loops.first?.1 ?? 0, 119)
        XCTAssertLessThanOrEqual(loops.first?.1 ?? 0, 122)
        // A ring whose ends meet is one loop, the whole chain.
        XCTAssertEqual(EdgeDrawing.closedLoops(square, settings: s).map { [$0.0, $0.1] }, [[0, 119]])
        // A straight line closes nothing; a short ring is below the floor.
        XCTAssertTrue(EdgeDrawing.closedLoops((0..<80).map { EdgeDrawing.Point(Int32($0), 0) }, settings: s).isEmpty)
        XCTAssertTrue(EdgeDrawing.closedLoops(Array(square.prefix(39)), settings: s).isEmpty)
    }

    func testClosedChainsFitTheCard() throws {
        let gray = try XCTUnwrap(RegionProposals.grayPlane(card()))
        let result = EdgeDrawing.detect(in: gray)
        XCTAssertGreaterThan(result.chains, 0)
        XCTAssertGreaterThanOrEqual(result.loops, 2)
        let ellipses = result.candidates.filter { $0.primitive == .ellipse }
        let rects = result.candidates.filter { $0.primitive == .rectangle }
        XCTAssertTrue(result.candidates.allSatisfy { $0.map.hasPrefix("ed-chain") && $0.edgeSupport == 1 })

        // The disc: centre (180, 200), radius 80 — CG's y is up, the plane's is down.
        let disc = try XCTUnwrap(ellipses.first { abs($0.ellipse!.centre.x - 180) < 3 && abs($0.ellipse!.centre.y - 400) < 3 })
        XCTAssertEqual(disc.ellipse!.semiMajor, 80, accuracy: 3)
        XCTAssertEqual(disc.ellipse!.semiMinor, 80, accuracy: 3)

        // The rectangle: 240 × 140 at (360…600, 100…240) → y-down 360…500.
        let rect = try XCTUnwrap(rects.first { c in
            let cx = c.corners!.map(\.x).reduce(0, +) / 4, cy = c.corners!.map(\.y).reduce(0, +) / 4
            return abs(cx - 480) < 3 && abs(cy - 430) < 3
        })
        let sides = (0..<4).map { simd_length(rect.corners![($0 + 1) % 4] - rect.corners![$0]) }
        XCTAssertEqual(sides.max()!, 240, accuracy: 4)

        // The trapezoid (a 200-wide top, 120-wide bottom) is neither a
        // rectangle nor an ellipse: refused, with the reason on record.
        XCTAssertFalse(result.candidates.contains { c in
            let centre: SIMD2<Double> = c.corners.map { $0.reduce(SIMD2<Double>(0, 0), +) / 4 } ?? c.ellipse!.centre
            return abs(centre.x - 220) < 20 && abs(centre.y - 150) < 20
        })
        XCTAssertTrue(result.refusals.contains { r in
            abs(r.centre.x - 220) < 20 && abs(r.centre.y - 150) < 20
                && (r.reason.contains("angle deviation") || r.reason.contains("vertices") || r.reason.contains("fill"))
        })
    }

    func testDetectorAdmitsChainShapesAndCountsThem() throws {
        let image = card()
        var s = ShapeDetector.Settings()
        s.minNativeDiameterPx = 0
        s.minDiameterFractionOfShortEdge = 0.1
        s.regionProposals = false
        s.edgeChains = false
        let without = try ShapeDetector(settings: s).detectWithDiagnostics(in: image, nativeSize: CGSize(width: 800, height: 600))
        s.edgeChains = true
        let with = try ShapeDetector(settings: s).detectWithDiagnostics(in: image, nativeSize: CGSize(width: 800, height: 600))
        XCTAssertEqual(without.diagnostics.edgeChains, 0)
        XCTAssertEqual(without.diagnostics.edgeLoops, 0)
        XCTAssertGreaterThan(with.diagnostics.edgeChains, 0)
        XCTAssertGreaterThanOrEqual(with.diagnostics.edgeLoops, 2)
        XCTAssertGreaterThanOrEqual(with.shapes.count, without.shapes.count)
        // The machine as a whole has the disc and the rectangle.
        XCTAssertTrue(with.shapes.contains { $0.kind == .ellipse && abs(Double($0.centre.x) * 800 - 180) < 4 && abs(Double($0.centre.y) * 600 - 400) < 4 })
        XCTAssertTrue(with.shapes.contains { $0.kind == .quad && abs(Double($0.centre.x) * 800 - 480) < 4 && abs(Double($0.centre.y) * 600 - 430) < 4 })
        // The chain pass offered them: admitted, or turned away only because
        // a Vision pass had already kept the same shape.
        let duplicates = with.diagnostics.refusals.filter { $0.kind == "edge" && $0.reason == "the same bounds as a kept shape" }.count
        XCTAssertGreaterThanOrEqual(with.diagnostics.edgeKept + duplicates, 2)
        XCTAssertTrue(with.diagnostics.summary.contains("edge chains"))
        XCTAssertFalse(without.diagnostics.summary.contains("edge chains"))
        // The profiles: off unless a mode asks for it.
        XCTAssertFalse(ShapeDetector.Settings().edgeChains)
        XCTAssertFalse(ShapeSearch().liveSettings().edgeChains)
    }

    func testDecodeLongEdgeFollowsTheEdgeChainScales() {
        var s = ShapeDetector.Settings()
        s.regionProposals = false
        s.edgeChains = false
        s.edgeChainLongEdges = [1024, 4096]
        XCTAssertEqual(s.decodeLongEdge, 1024)
        s.edgeChains = true
        XCTAssertEqual(s.decodeLongEdge, 4096)
        s.regionProposals = true
        s.regionProposalLongEdges = [1024, 2048]
        XCTAssertEqual(s.decodeLongEdge, 4096)
        s.edgeChainLongEdges = [512]
        XCTAssertEqual(s.decodeLongEdge, 2048)
        s.regionProposals = false
        XCTAssertEqual(s.decodeLongEdge, 1024)
    }

    func testDiagnosticsDecodeWithoutEdgeCounters() throws {
        let old = #"{"longEdge":1024,"quadsOffered":3,"quadsKept":1,"contourPasses":8,"contours":100,"ellipseFits":4,"ellipsesKept":1,"rimPeaks":2,"rimsKept":0,"regionMaps":18,"regions":5,"regionsKept":2,"milliseconds":12,"refusals":[]}"#
        let d = try JSONDecoder().decode(ShapeDetector.Diagnostics.self, from: Data(old.utf8))
        XCTAssertEqual(d.regionsKept, 2)
        XCTAssertEqual(d.edgeChains, 0)
        XCTAssertEqual(d.edgeLoops, 0)
        XCTAssertEqual(d.edgeKept, 0)
        var full = d
        full.edgeChains = 40; full.edgeLoops = 3; full.edgeKept = 1
        let roundTrip = try JSONDecoder().decode(ShapeDetector.Diagnostics.self, from: JSONEncoder().encode(full))
        XCTAssertEqual(roundTrip, full)
        XCTAssertTrue(roundTrip.summary.contains("3 loops over 40 edge chains, 1 admitted"))
    }
}

import XCTest
import CoreGraphics
import simd
@testable import LetsLapseKit

final class RegionProposalsTests: XCTestCase {
    /// A light card with a dark disc, a dark rectangle, a dark trapezoid and
    /// a light ring on a dark square (the hole case), drawn by Core Graphics.
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

    func testMapsTraceAndFitTheCard() throws {
        let image = card()
        let gray = try XCTUnwrap(RegionProposals.grayPlane(image))
        XCTAssertEqual(gray.width, 800); XCTAssertEqual(gray.height, 600)
        // Otsu on a two-tone card lands between the tones.
        let t = RegionProposals.otsuThreshold(gray)
        XCTAssertGreaterThan(t, 60); XCTAssertLessThan(t, 200)

        let result = RegionProposals.detect(in: gray)
        XCTAssertEqual(result.maps, 18)
        XCTAssertGreaterThan(result.regions, 0)
        let ellipses = result.candidates.filter { $0.primitive == .ellipse }
        let rects = result.candidates.filter { $0.primitive == .rectangle }

        // The disc: centre (180, 200), radius 80 — CG's y is up, the plane's is down.
        let disc = try XCTUnwrap(ellipses.first { abs($0.ellipse!.centre.x - 180) < 3 && abs($0.ellipse!.centre.y - (600 - 200)) < 3 })
        XCTAssertEqual(disc.ellipse!.semiMajor, 80, accuracy: 2.5)
        XCTAssertEqual(disc.ellipse!.semiMinor, 80, accuracy: 2.5)
        XCTAssertGreaterThan(disc.score, 0.95)

        // The rectangle: 240 × 140 at (360…600, 100…240) → y-down 360…500.
        let rect = try XCTUnwrap(rects.first { c in
            let cx = c.corners!.map(\.x).reduce(0, +) / 4, cy = c.corners!.map(\.y).reduce(0, +) / 4
            return abs(cx - 480) < 3 && abs(cy - 430) < 3
        })
        let widths = [0, 2].map { i in simd_length(rect.corners![i + 1] - rect.corners![i]) }
        XCTAssertEqual(max(widths[0], widths[1]), 240, accuracy: 3)
        XCTAssertGreaterThan(rect.score, 0.95)

        // The light disc inside the dark square is found through the hole.
        XCTAssertNotNil(ellipses.first { abs($0.ellipse!.centre.x - 590) < 3 && abs($0.ellipse!.centre.y - (600 - 450)) < 3 })

        // The trapezoid (a 200-wide top, 120-wide bottom) is neither a rectangle nor an ellipse.
        XCTAssertFalse(result.candidates.contains { c in
            let pts = c.corners ?? []
            guard !pts.isEmpty else { return false }
            let cy = pts.map(\.y).reduce(0, +) / 4
            return abs(cy - 150) < 20 && abs(pts.map(\.x).reduce(0, +) / 4 - 220) < 20
        })
        XCTAssertTrue(result.refusals.contains { $0.reason.contains("angle deviation") || $0.reason.contains("vertices") || $0.reason.contains("fill") })
    }

    func testApproximationKeepsFourCornersOfARectangle() {
        // A 240 × 140 rectangle traced pixel by pixel, with the trace starting mid-side.
        var pts: [SIMD2<Double>] = []
        for x in 0..<240 { pts.append(SIMD2(Double(x), 0)) }
        for y in 0..<140 { pts.append(SIMD2(239, Double(y))) }
        for x in stride(from: 239, through: 0, by: -1) { pts.append(SIMD2(Double(x), 139)) }
        for y in stride(from: 139, through: 0, by: -1) { pts.append(SIMD2(0, Double(y))) }
        let rotated = Array(pts[100...] + pts[..<100])
        let perimeter = 2.0 * (240 + 140)
        XCTAssertEqual(RegionProposals.approximate(rotated, epsilon: 0.02 * perimeter).count, 4)
        XCTAssertEqual(RegionProposals.approximate(pts, epsilon: 0.02 * perimeter).count, 4)
    }

    func testTracerFollowsABorderLongerThanTheFrameRule() {
        // A one-pixel serpentine: its border visits every pixel, about twice
        // its pixel count, far past the old 16 · (w + h) step limit.
        let w = 160, h = 120
        var plane = RegionProposals.Plane(width: w, height: h)
        var y = 4, row = 0
        while y < 116 {
            for x in 4..<156 { plane.data[y * w + x] = 255 }
            let cx = row % 2 == 0 ? 155 : 4
            for yy in y..<min(h - 1, y + 3) { plane.data[yy * w + cx] = 255 }
            y += 2; row += 1
        }
        let pixels = plane.data.filter { $0 != 0 }.count
        let contours = RegionProposals.trace(plane, minPixels: 20)
        XCTAssertEqual(contours.count, 1)
        let c = try! XCTUnwrap(contours.first)
        XCTAssertGreaterThan(c.count, 16 * (w + h))
        XCTAssertLessThanOrEqual(max(abs(c.last!.x - c.first!.x), abs(c.last!.y - c.first!.y)), 1)   // closed
        XCTAssertEqual(Set(c.map { Int($0.y) * w + Int($0.x) }).count, pixels)                       // every pixel of a 1-px line is border
    }

    func testPolygonIoU() {
        let square = [SIMD2<Double>(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)]
        let shifted = square.map { $0 + SIMD2(5, 0) }
        XCTAssertEqual(RegionProposals.polygonIoU(square, square), 1, accuracy: 1e-9)
        XCTAssertEqual(RegionProposals.polygonIoU(square, shifted), 50.0 / 150.0, accuracy: 1e-9)
        XCTAssertEqual(RegionProposals.polygonIoU(square, square.reversed()), 1, accuracy: 1e-9)
        // A non-convex subject (an L) against its bounding square.
        let l = [SIMD2<Double>(0, 0), SIMD2(10, 0), SIMD2(10, 4), SIMD2(4, 4), SIMD2(4, 10), SIMD2(0, 10)]
        XCTAssertEqual(RegionProposals.polygonIoU(l, square), 64.0 / 100.0, accuracy: 1e-9)
    }

    func testDetectorAdmitsRegionShapesTheVisionPassesMissed() throws {
        let image = card()
        var s = ShapeDetector.Settings()
        s.minNativeDiameterPx = 0
        s.minDiameterFractionOfShortEdge = 0.1
        s.regionProposals = false
        let without = try ShapeDetector(settings: s).detectWithDiagnostics(in: image, nativeSize: CGSize(width: 800, height: 600))
        s.regionProposals = true
        let with = try ShapeDetector(settings: s).detectWithDiagnostics(in: image, nativeSize: CGSize(width: 800, height: 600))
        XCTAssertEqual(without.diagnostics.regionMaps, 0)
        XCTAssertEqual(with.diagnostics.regionMaps, 18)
        XCTAssertGreaterThanOrEqual(with.shapes.count, without.shapes.count)
        // Whatever Vision made of the card, the machine as a whole has the disc and the rectangle.
        XCTAssertTrue(with.shapes.contains { $0.kind == .ellipse && abs(Double($0.centre.x) * 800 - 180) < 4 && abs(Double($0.centre.y) * 600 - 400) < 4 })
        XCTAssertTrue(with.shapes.contains { $0.kind == .quad && abs(Double($0.centre.x) * 800 - 480) < 4 && abs(Double($0.centre.y) * 600 - 430) < 4 })
        // The live profile leaves the region pass off.
        XCTAssertFalse(ShapeSearch().liveSettings().regionProposals)
        XCTAssertTrue(ShapeSearch().fileSettings().regionProposals)
    }

    func testDiagnosticsDecodeWithoutRegionCounters() throws {
        let old = #"{"longEdge":1024,"quadsOffered":3,"quadsKept":1,"contourPasses":8,"contours":100,"ellipseFits":4,"ellipsesKept":1,"rimPeaks":2,"rimsKept":0,"milliseconds":12,"refusals":[]}"#
        let d = try JSONDecoder().decode(ShapeDetector.Diagnostics.self, from: Data(old.utf8))
        XCTAssertEqual(d.quadsOffered, 3)
        XCTAssertEqual(d.regionMaps, 0)
        let roundTrip = try JSONDecoder().decode(ShapeDetector.Diagnostics.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(roundTrip, d)
    }
}

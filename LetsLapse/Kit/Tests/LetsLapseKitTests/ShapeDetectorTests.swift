import XCTest
import CoreGraphics
@testable import LetsLapseKit

/// The shape-sequence spike's self-test as a unit test: a known ellipse and a
/// perspective quad drawn on a card must come back with their geometry, and
/// the composer must put the shape where it says it does.
final class ShapeDetectorTests: XCTestCase {
    private func card() -> (CGImage, CGPoint, Double, Double, Double, [CGPoint]) {
        let W = 3000, H = 2000
        let ec = CGPoint(x: 1000, y: 800), ea = 500.0, eb = 300.0, er = 25.0 * Double.pi / 180
        let quad = [CGPoint(x: 1900, y: 400), CGPoint(x: 2600, y: 520), CGPoint(x: 2600, y: 1500), CGPoint(x: 1900, y: 1650)]
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(CGColor(srgbRed: 0.75, green: 0.8, blue: 0.85, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1))
        ctx.saveGState(); ctx.translateBy(x: ec.x, y: ec.y); ctx.rotate(by: er)
        ctx.fillEllipse(in: CGRect(x: -ea, y: -eb, width: 2 * ea, height: 2 * eb)); ctx.restoreGState()
        ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.9, alpha: 1))
        ctx.move(to: quad[0]); for p in quad.dropFirst() { ctx.addLine(to: p) }; ctx.closePath(); ctx.fillPath()
        ctx.setStrokeColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.05, alpha: 1)); ctx.setLineWidth(12)
        ctx.move(to: quad[0]); for p in quad.dropFirst() { ctx.addLine(to: p) }; ctx.closePath(); ctx.strokePath()
        return (ctx.makeImage()!, ec, ea, eb, er, quad)
    }

    func testFitRecoversKnownEllipse() {
        var pts: [SIMD2<Double>] = []
        let er = 25.0 * Double.pi / 180
        for i in 0..<200 {
            let t = Double(i) / 200 * 2 * .pi
            let x = 500 * cos(t), y = 300 * sin(t)
            pts.append(SIMD2(1000 + x * cos(er) - y * sin(er), 800 + x * sin(er) + y * cos(er)))
        }
        let e = EllipseFit.fit(pts)!
        XCTAssertEqual(e.centre.x, 1000, accuracy: 0.01)
        XCTAssertEqual(e.centre.y, 800, accuracy: 0.01)
        XCTAssertEqual(e.semiMajor, 500, accuracy: 0.01)
        XCTAssertEqual(e.semiMinor, 300, accuracy: 0.01)
        XCTAssertEqual(e.rotation, er, accuracy: 1e-6)
        let q = EllipseFit.quality(e, pts)
        XCTAssertLessThan(q.residual, 1e-9)
        XCTAssertEqual(q.coverage, 1)
    }

    func testDetectorFindsCardShapes() throws {
        let (image, ec, ea, eb, er, quad) = card()
        let shapes = try ShapeDetector().detect(in: image, nativeSize: CGSize(width: 3000, height: 2000))
        guard let ellipse = shapes.first(where: { $0.kind == .ellipse }) else { return XCTFail("no ellipse") }
        XCTAssertEqual(Double(ellipse.centre.x) * 3000, Double(ec.x), accuracy: 3)
        XCTAssertEqual(Double(ellipse.centre.y) * 2000, Double(ec.y), accuracy: 3)
        XCTAssertEqual(ellipse.majorAxis * 3000 / 2, ea, accuracy: 3)
        XCTAssertEqual(ellipse.minorAxis * 3000 / 2, eb, accuracy: 3)
        XCTAssertEqual(ellipse.rotation, er, accuracy: 0.01)
        XCTAssertEqual(ellipse.family, .oval)
        let quads = shapes.filter { $0.kind == .quad }
        XCTAssertFalse(quads.isEmpty, "no quad")
        let best = quads.min { a, b in
            hypot(Double(a.centre.x) * 3000 - 2250, Double(a.centre.y) * 2000 - 1017) < hypot(Double(b.centre.x) * 3000 - 2250, Double(b.centre.y) * 2000 - 1017)
        }!
        let corners = best.corners!.map { CGPoint(x: $0.x * 3000, y: $0.y * 2000) }
        for (found, truth) in zip(corners, quad) {
            XCTAssertEqual(Double(found.x), Double(truth.x), accuracy: 45)
            XCTAssertEqual(Double(found.y), Double(truth.y), accuracy: 45)
        }
        XCTAssertEqual(best.family, .rectangle)
    }

    func testPlanLocksShapeAndSizesCanvas() {
        let a = DetectedShape(kind: .ellipse, centre: CGPoint(x: 0.25, y: 0.5), majorAxis: 0.2, minorAxis: 0.2, rotation: 0, corners: nil, confidence: 1, nativeDiameterPx: 400)
        let b = DetectedShape(kind: .ellipse, centre: CGPoint(x: 0.75, y: 0.5), majorAxis: 0.4, minorAxis: 0.4, rotation: 0, corners: nil, confidence: 1, nativeDiameterPx: 800)
        let items = [
            ShapemationItem(title: "a", imageURL: URL(fileURLWithPath: "/a"), pixelSize: CGSize(width: 2000, height: 1000), shape: a),
            ShapemationItem(title: "b", imageURL: URL(fileURLWithPath: "/b"), pixelSize: CGSize(width: 2000, height: 1000), shape: b),
        ]
        let stack = ShapemationPlan.make(items: items, mode: .stack)!
        XCTAssertEqual(stack.shapeSizePx, 400)
        // a: scale 1, centre at (500,500) → footprint x ∈ [−500, 1500]; b: scale 0.5, centre (750,250) → x ∈ [−750, 250].
        XCTAssertEqual(stack.canvas.width, 2250, accuracy: 0.5)
        XCTAssertEqual(stack.canvas.height, 1000, accuracy: 0.5)
        XCTAssertEqual(stack.anchor.x, 750, accuracy: 0.5)
        for p in stack.placements {
            let item = items.first { $0.id == p.itemID }!
            let c = p.transform.apply(CGPoint(x: item.shape.centre.x * 2000, y: item.shape.centre.y * 1000))
            XCTAssertEqual(c.x, stack.anchor.x, accuracy: 1e-6)
            XCTAssertEqual(c.y, stack.anchor.y, accuracy: 1e-6)
        }
        let crop = ShapemationPlan.make(items: items, mode: .crop)!
        XCTAssertEqual(crop.canvas.width, 750, accuracy: 0.5)   // x ∈ [−500, 250]
        XCTAssertEqual(crop.canvas.height, 500, accuracy: 0.5)  // y ∈ [−250, 250]
        XCTAssertEqual(crop.outputOptions().first?.size.width, 750)
    }

    func testManualShapesMeasureAndClassify() {
        let frame = CGSize(width: 3000, height: 2000)
        // A circle drawn by hand: 400 px radius at (1000, 800).
        let circle = DetectedShape.ellipse(centre: CGPoint(x: 1000, y: 800), semiAxisX: 400, semiAxisY: 400, rotation: 0, frame: frame)
        XCTAssertEqual(circle.family, .circle)
        XCTAssertEqual(circle.source, .manual)
        XCTAssertEqual(circle.nativeDiameterPx, 800, accuracy: 1e-9)
        XCTAssertEqual(Double(circle.centre.x), 1000.0 / 3000, accuracy: 1e-9)
        // A taller-than-wide ellipse keeps its major axis major, turned 90°.
        let tall = DetectedShape.ellipse(centre: CGPoint(x: 500, y: 500), semiAxisX: 100, semiAxisY: 300, rotation: 0, frame: frame)
        XCTAssertEqual(tall.majorAxis * 3000 / 2, 300, accuracy: 1e-9)
        XCTAssertEqual(tall.rotation, .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(tall.family, .oval)
        // A square drawn corner to corner.
        let sq = DetectedShape.quad(corners: [CGPoint(x: 100, y: 100), CGPoint(x: 700, y: 100), CGPoint(x: 700, y: 700), CGPoint(x: 100, y: 700)], frame: frame)
        XCTAssertEqual(sq.family, .square)
        XCTAssertEqual(sq.nativeDiameterPx, 600, accuracy: 1e-9)
        XCTAssertEqual(sq.rotation, 0, accuracy: 1e-9)
        // Drag one corner out: re-measured as a rectangle, centre moves with it.
        var edited = sq
        edited.corners![1] = CGPoint(x: 1500.0 / 3000, y: 100.0 / 2000)
        edited.corners![2] = CGPoint(x: 1500.0 / 3000, y: 700.0 / 2000)
        edited = edited.remeasured(frame: frame)
        XCTAssertEqual(edited.family, .rectangle)
        XCTAssertEqual(edited.nativeDiameterPx, 1400, accuracy: 1e-9)
        XCTAssertEqual(Double(edited.centre.x) * 3000, 800, accuracy: 1e-9)
        // An ellipse whose minor axis was dragged past the major swaps on re-measure.
        var swapped = circle
        swapped.minorAxis = swapped.majorAxis * 1.5
        swapped = swapped.remeasured(frame: frame)
        XCTAssertGreaterThan(swapped.majorAxis, swapped.minorAxis)
        XCTAssertEqual(swapped.rotation, .pi / 2, accuracy: 1e-9)
    }

    func testManualRegisterIsNotAnalysed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shapes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var reg = ShapeRegister.manual(representative: .init(relativePath: "source/frame-00001.dng", source: .sourceFrame, width: 3024, height: 4032))
        reg.shapes.append(DetectedShape.ellipse(centre: CGPoint(x: 1512, y: 2016), semiAxisX: 500, semiAxisY: 500, rotation: 0, frame: reg.frameSize))
        try reg.save(inProjectFolder: dir)
        let back = try XCTUnwrap(ShapeRegister.load(inProjectFolder: dir))
        XCTAssertFalse(back.isAnalysed)
        XCTAssertEqual(back.manualShapes.count, 1)
        XCTAssertEqual(back.shapes.first?.source, .manual)
    }

    func testRegisterRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shapes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A true 1000 px square on a 3024×4032 frame, as the detector or a hand would write it.
        var shape = DetectedShape.quad(corners: [CGPoint(x: 1000, y: 1500), CGPoint(x: 2000, y: 1500), CGPoint(x: 2000, y: 2500), CGPoint(x: 1000, y: 2500)],
                                       frame: CGSize(width: 3024, height: 4032), source: .detected)
        shape.confidence = 0.9
        let reg = ShapeRegister(analysedAt: Date(timeIntervalSince1970: 1_700_000_000), representative: .init(relativePath: "source/frame-00001.jpg", source: .sourceFrame, width: 3024, height: 4032), shapes: [shape])
        try reg.save(inProjectFolder: dir)
        let back = ShapeRegister.load(inProjectFolder: dir)
        XCTAssertEqual(back, reg)
        XCTAssertEqual(back?.families()[.square], 1)
    }
}

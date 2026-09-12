import XCTest
import CoreGraphics
import CoreVideo
@testable import LetsLapseKit

/// The shape-sequence spike's self-test as a unit test: a known ellipse and a
/// perspective quad drawn on a card must come back with their geometry, and
/// the composer must put the shape where it says it does.
/// The Vision machine on its own: the region pass has its own tests
/// (`RegionProposalsTests`) and, unoptimised in a test build, costs ~50 s per
/// picture at 1024 + 2048.
private extension ShapeDetector.Settings {
    var visionOnly: ShapeDetector.Settings { var s = self; s.regionProposals = false; return s }
}

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
        let shapes = try ShapeDetector(settings: ShapeDetector.Settings().visionOnly).detect(in: image, nativeSize: CGSize(width: 3000, height: 2000))
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
    // MARK: - The viewfinder pass

    /// A preview buffer arrives in the sensor's landscape; handed the portrait
    /// pose (`.right`) the live profile must report in the upright frame — the
    /// card's ellipse at (1000, 800) of 3000×2000 lands at (1200, 1000) of the
    /// 2000×3000 upright picture, rotated by a quarter turn.
    func testLiveDetectFromPixelBufferReportsUprightSpace() throws {
        let (image, _, ea, eb, er, _) = card()
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer)
        let pb = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(pb), width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        CVPixelBufferUnlockBaseAddress(pb, [])

        let detector = ShapeDetector(settings: .live)
        let shapes = try detector.detect(in: pb, orientation: .right)
        guard let ellipse = shapes.first(where: { $0.kind == .ellipse }) else { return XCTFail("no ellipse in the upright frame") }
        // Upright frame is 2000 wide × 3000 tall; axes are fractions of that width.
        XCTAssertEqual(Double(ellipse.centre.x) * 2000, 1200, accuracy: 25)
        XCTAssertEqual(Double(ellipse.centre.y) * 3000, 1000, accuracy: 25)
        XCTAssertEqual(ellipse.majorAxis * 2000 / 2, ea, accuracy: 25)
        XCTAssertEqual(ellipse.minorAxis * 2000 / 2, eb, accuracy: 25)
        // A quarter turn clockwise adds 90° to the major axis' angle.
        let expected = er + .pi / 2
        let delta = abs(atan2(sin(ellipse.rotation - expected), cos(ellipse.rotation - expected)))
        XCTAssertLessThan(min(delta, abs(delta - .pi)), 0.05)
        // Preview pixels, not the still's: the size is in the frame it was measured on.
        XCTAssertEqual(ellipse.nativeDiameterPx, 2 * ea, accuracy: 60)
        XCTAssertEqual(ellipse.source, .detected)
    }

    /// The file pass: a kept live shape snaps to the file's fit and keeps its
    /// id; a file detection over a dismissed shape is dropped; a file detection
    /// nobody saw is recorded as a plain detection; a kept shape with no file
    /// match survives as captured, sized for the still.
    func testReconcileSnapsKeptDropsDismissedRecordsExtras() {
        let preview = CGSize(width: 1080, height: 1440), photo = CGSize(width: 3024, height: 4032)
        func circle(_ x: Double, _ y: Double, _ d: Double, source: DetectedShape.Source = .detected) -> DetectedShape {
            DetectedShape(kind: .ellipse, centre: CGPoint(x: x, y: y), majorAxis: d, minorAxis: d, rotation: 0, corners: nil,
                          confidence: 0.8, nativeDiameterPx: d * 1080, source: source)
        }
        let keptA = circle(0.30, 0.30, 0.20)     // matched by the file
        let keptB = circle(0.75, 0.80, 0.18)     // no file match
        let dismissed = circle(0.50, 0.55, 0.22)
        let viewfinder = ViewfinderShapes(kept: [keptA, keptB], dismissed: [dismissed], frameSize: preview)
        let fileA = circle(0.31, 0.29, 0.21)     // the same circle, fitted at full quality
        let fileDismissed = circle(0.51, 0.55, 0.21)
        let fileExtra = circle(0.15, 0.85, 0.19)
        var out = ShapeReconciler.reconcile(viewfinder, photoDetections: [fileExtra, fileDismissed, fileA], photoSize: photo)
        XCTAssertEqual(out.count, 3)
        let a = out.removeFirst()
        XCTAssertEqual(a.id, keptA.id)
        XCTAssertEqual(a.source, .captured)
        XCTAssertEqual(Double(a.centre.x), 0.31, accuracy: 1e-9, "took the file's geometry")
        XCTAssertEqual(a.nativeDiameterPx, 0.21 * 1080, accuracy: 1e-6, "the file's own native size")
        let b = out.removeFirst()
        XCTAssertEqual(b.id, keptB.id)
        XCTAssertEqual(b.source, .captured)
        XCTAssertEqual(Double(b.centre.x), 0.75, accuracy: 1e-9, "kept its live geometry")
        XCTAssertEqual(b.nativeDiameterPx, 0.18 * 3024, accuracy: 1e-6, "rescaled to the still")
        let extra = out.removeFirst()
        XCTAssertEqual(extra.source, .detected)
        XCTAssertEqual(Double(extra.centre.x), 0.15, accuracy: 1e-9)
        XCTAssertFalse(out.contains { abs(Double($0.centre.x) - 0.51) < 0.01 }, "the dismissed circle stays out")

        let provisional = ShapeReconciler.provisional(viewfinder, photoSize: photo)
        XCTAssertEqual(provisional.map(\.id), [keptA.id, keptB.id])
        XCTAssertEqual(provisional.map(\.source), [.captured, .captured])
    }

    func testKeptShapesSurviveARegisterReRun() {
        let rep = ShapeRegister.Representative(relativePath: "source/frame-00001.jpg", source: .sourceFrame, width: 3024, height: 4032)
        let frame = CGSize(width: 3024, height: 4032)
        let drawn = DetectedShape.ellipse(centre: CGPoint(x: 1000, y: 1000), semiAxisX: 300, semiAxisY: 300, rotation: 0, frame: frame)
        var captured = drawn; captured.id = UUID(); captured.source = DetectedShape.Source.captured
        var found = drawn; found.id = UUID(); found.source = DetectedShape.Source.detected
        let reg = ShapeRegister(representative: rep, shapes: [drawn, captured, found])
        let kept: [DetectedShape.Source] = reg.keptShapes.map { $0.source }
        XCTAssertEqual(kept, [.manual, .captured])
        XCTAssertEqual(reg.manualShapes.count, 1)
    }
    // MARK: - The search dials

    /// Family picks which half of the machine runs: on the card, Circular
    /// returns the ellipse and no quad, Rectangular the quad and no ellipse.
    func testSearchFamilySkipsTheOtherHalf() throws {
        let (image, _, _, _, _, _) = card()
        let native = CGSize(width: 3000, height: 2000)
        let circular = try ShapeDetector(settings: ShapeSearch(family: .circular).fileSettings().visionOnly).detect(in: image, nativeSize: native)
        XCTAssertEqual(circular.map(\.kind), [.ellipse])
        let rectangular = try ShapeDetector(settings: ShapeSearch(family: .rectangular).fileSettings().visionOnly).detect(in: image, nativeSize: native)
        XCTAssertFalse(rectangular.isEmpty)
        XCTAssertTrue(rectangular.allSatisfy { $0.kind == .quad })
    }

    /// Size is a floor and a ceiling on the short edge: the card's ellipse is
    /// 1000 px on a 2000 px short edge (0.5) — Large keeps it, Mid and Small
    /// refuse it.
    func testSearchSizeGatesOnTheShortEdge() throws {
        let (image, _, _, _, _, _) = card()
        let native = CGSize(width: 3000, height: 2000)
        func ellipses(_ size: ShapeSearch.Size) throws -> Int {
            try ShapeDetector(settings: ShapeSearch(family: .circular, size: size).fileSettings().visionOnly)
                .detect(in: image, nativeSize: native).filter { $0.kind == .ellipse }.count
        }
        XCTAssertEqual(try ellipses(.all), 1)
        XCTAssertEqual(try ellipses(.large), 1)
        XCTAssertEqual(try ellipses(.mid), 0)
        XCTAssertEqual(try ellipses(.small), 0)
    }

    /// The live mapping: the defaults are the shipped profile; Low is one
    /// contrast pass with tight gates, High three with loose ones; Large looks
    /// at 256 px, Small at 512.
    /// The file pass's All floor is 0.10 of the short edge with no pixel
    /// minimum; the viewfinder keeps 1/6.
    func testSearchFileFloorIsATenthOfTheShortEdge() {
        let file = ShapeSearch().fileSettings(), live = ShapeSearch().liveSettings()
        XCTAssertEqual(file.minDiameterFractionOfShortEdge, 0.10, accuracy: 1e-9)
        XCTAssertEqual(file.minNativeDiameterPx, 0)
        XCTAssertEqual(live.minDiameterFractionOfShortEdge, 1.0 / 6.0, accuracy: 1e-9)
        XCTAssertEqual(ShapeSearch(size: .mid).fileSettings().minDiameterFractionOfShortEdge, 1.0 / 6.0, accuracy: 1e-9)
        XCTAssertEqual(ShapeSearch(size: .small).fileSettings().minDiameterFractionOfShortEdge, 1.0 / 12.0, accuracy: 1e-9)
    }

    func testSearchLiveMapping() {
        let base = ShapeSearch().liveSettings()
        XCTAssertEqual(base.detectionLongEdge, 384)
        XCTAssertEqual(base.contrastAdjustments, [1.0, 2.0])
        XCTAssertEqual(base.maxFitResidual, 0.06)
        XCTAssertTrue(base.edgeThresholds.isEmpty)
        XCTAssertEqual(base.minNativeDiameterPx, 0)
        XCTAssertTrue(base.detectQuads && base.detectEllipses)
        let low = ShapeSearch(sensitivity: .low).liveSettings()
        XCTAssertEqual(low.contrastAdjustments, [1.0])
        XCTAssertEqual(low.maxFitResidual, 0.04)
        XCTAssertGreaterThan(low.quadEdgeSupport, base.quadEdgeSupport)
        let high = ShapeSearch(sensitivity: .high).liveSettings()
        XCTAssertEqual(high.contrastAdjustments.count, 3)
        XCTAssertGreaterThan(high.maxFitResidual, base.maxFitResidual)
        XCTAssertEqual(ShapeSearch(size: .large).liveSettings().detectionLongEdge, 256)
        XCTAssertEqual(ShapeSearch(size: .small).liveSettings().detectionLongEdge, 512)
        XCTAssertEqual(ShapeSearch(size: .small).liveSettings().minDiameterFractionOfShortEdge, 1.0 / 12.0, accuracy: 1e-12)
        XCTAssertFalse(ShapeSearch(family: .circular).liveSettings().detectQuads)
        XCTAssertFalse(ShapeSearch(family: .rectangular).liveSettings().detectEllipses)
        XCTAssertEqual(ShapeSearch(family: .circular, sensitivity: .low, size: .large).token, "circular/low/large")
        // The file pass keeps its own resolution and edge maps whatever the dials say.
        let file = ShapeSearch(sensitivity: .high, size: .small).fileSettings()
        XCTAssertEqual(file.detectionLongEdge, 1024)
        XCTAssertFalse(file.edgeThresholds.isEmpty)
    }
    // MARK: - Edge-point circles

    /// A ribbed medallion: a disc with a scalloped outline and radial spokes,
    /// the class the contour tracer cannot close (the ribs cut the outline
    /// into pieces). Beside it a semicircular arch, which must not come back
    /// as a circle. Drawn on a textured ground so the edge threshold is not
    /// trivially the shape's own.
    private func medallionCard() -> (CGImage, CGPoint, Double) {
        let W = 2400, H = 1800
        let centre = CGPoint(x: 800, y: 900), radius = 380.0
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(CGColor(srgbRed: 0.82, green: 0.74, blue: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        // Ground texture: a brick pattern of faint lines.
        ctx.setStrokeColor(CGColor(srgbRed: 0.72, green: 0.64, blue: 0.42, alpha: 1)); ctx.setLineWidth(3)
        for y in stride(from: 0, to: H, by: 90) { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: W, y: y)) }
        for x in stride(from: 0, to: W, by: 160) { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: H)) }
        ctx.strokePath()
        // The medallion: a disc with 36 rays poking 9 % past its rim (the
        // outline the tracer sees is a star) and spokes inside, light on the
        // ground. Between the rays the rim is the circle it is.
        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.92, blue: 0.88, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
        for k in 0..<36 {
            let t = Double(k) / 36 * 2 * .pi, half = 0.02
            ctx.move(to: CGPoint(x: centre.x + 0.9 * radius * cos(t - half), y: centre.y + 0.9 * radius * sin(t - half)))
            ctx.addLine(to: CGPoint(x: centre.x + 1.09 * radius * cos(t), y: centre.y + 1.09 * radius * sin(t)))
            ctx.addLine(to: CGPoint(x: centre.x + 0.9 * radius * cos(t + half), y: centre.y + 0.9 * radius * sin(t + half)))
            ctx.closePath()
        }
        ctx.fillPath()
        ctx.setStrokeColor(CGColor(srgbRed: 0.6, green: 0.55, blue: 0.45, alpha: 1)); ctx.setLineWidth(6)
        for k in 0..<36 {
            let t = Double(k) / 36 * 2 * .pi
            ctx.move(to: CGPoint(x: centre.x + 60 * cos(t), y: centre.y + 60 * sin(t)))
            ctx.addLine(to: CGPoint(x: centre.x + 0.85 * radius * cos(t), y: centre.y + 0.85 * radius * sin(t)))
        }
        ctx.strokePath()
        // The arch: the top half of a ring, 300 px radius, on the right.
        ctx.setStrokeColor(CGColor(srgbRed: 0.35, green: 0.3, blue: 0.25, alpha: 1)); ctx.setLineWidth(14)
        ctx.addArc(center: CGPoint(x: 1800, y: 1000), radius: 300, startAngle: .pi, endAngle: 0, clockwise: false)
        ctx.strokePath()
        return (ctx.makeImage()!, centre, radius)
    }

    func testEdgeCirclesFindTheRibbedMedallionAndRefuseTheArch() throws {
        let (image, centre, radius) = medallionCard()
        let native = CGSize(width: 2400, height: 1800)
        for (name, settings) in [("file", ShapeSearch().fileSettings().visionOnly), ("live", ShapeSearch().liveSettings())] {
            let shapes = try ShapeDetector(settings: settings).detect(in: image, nativeSize: native)
            let ellipses = shapes.filter { $0.kind == .ellipse }
            guard let medallion = ellipses.first(where: { abs(Double($0.centre.x) * 2400 - centre.x) < 40 && abs(Double($0.centre.y) * 1800 - centre.y) < 40 })
            else { return XCTFail("\(name): medallion not found; ellipses: \(ellipses.map { ($0.centre, $0.majorAxis) })") }
            XCTAssertEqual(medallion.majorAxis * 2400 / 2, radius, accuracy: 0.08 * radius, name)
            XCTAssertGreaterThan(medallion.obliquity, 0.85, name)
            XCTAssertFalse(ellipses.contains { abs(Double($0.centre.x) * 2400 - 1800) < 80 && abs(Double($0.centre.y) * 1800 - 1000) < 80 },
                           "\(name): the arch came back as a circle")
        }
    }
    /// The register keeps the viewfinder's account of a capture — dials,
    /// lens, samples, what was refused — and the detector explains itself.
    func testViewfinderTrailRoundTripsAndDiagnosticsExplainAMiss() throws {
        let (image, _, _, _, _, _) = card()
        var strict = ShapeSearch(family: .circular, sensitivity: .low).fileSettings()
        strict.maxFitResidual = 0.0001   // nothing passes; every fit must say why
        strict.regionProposals = false   // the Vision machine's own trail is under test
        let (shapes, diag) = try ShapeDetector(settings: strict).detectWithDiagnostics(in: image, nativeSize: CGSize(width: 3000, height: 2000))
        XCTAssertTrue(shapes.filter { $0.kind == DetectedShape.Kind.ellipse }.isEmpty)
        XCTAssertGreaterThan(diag.ellipseFits, 0)
        XCTAssertTrue(diag.refusals.contains { $0.kind == "ellipse" && $0.reason.hasPrefix("residual") }, "\(diag.refusals.map(\.reason))")
        XCTAssertLessThanOrEqual(diag.refusals.count, 24)
        XCTAssertGreaterThan(diag.milliseconds, 0)

        var viewfinder = ViewfinderShapes(kept: [], dismissed: [], frameSize: CGSize(width: 1080, height: 1440),
                                          search: ShapeSearch(family: .circular, sensitivity: .high), horizontalFieldOfView: 24.9,
                                          samples: 212, samplesWithShapes: 3, lastSample: diag)
        viewfinder.dismissed = []
        var trail = ViewfinderTrail(viewfinder)
        trail.file = diag
        XCTAssertEqual(trail.summary, "circular/high/all · lens 24.9° · 212 samples, 3 with shapes · 0 kept, 0 dismissed")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shapes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var reg = ShapeRegister(representative: .init(relativePath: "source/frame-00001.jpg", source: .sourceFrame, width: 3024, height: 4032, horizontalFieldOfView: 24.9), shapes: [])
        reg.viewfinder = trail
        try reg.save(inProjectFolder: dir)
        let back = try XCTUnwrap(ShapeRegister.load(inProjectFolder: dir))
        XCTAssertEqual(back.viewfinder, trail, "a miss is still a record")
        XCTAssertEqual(back.viewfinder?.file?.refusals.first?.reason, diag.refusals.first?.reason)
    }
}

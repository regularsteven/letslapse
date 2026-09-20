import XCTest
import AVFoundation
import CoreGraphics
import CoreVideo
@testable import LetsLapseKit

/// The output frame (docs/shapemation/output-frame.md): a framing reads
/// straight or eased between its keys and clamps outside them; a `.frame`
/// plan puts every face on its target at its size, flags what falls short
/// of the frame or is blown up past the cap, and leaves the stack modes'
/// numbers untouched; the renderer writes one photo per hold over black.
final class ShapemationFramingTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/x")
    private let hd = CGSize(width: 1920, height: 1080)

    // MARK: - framing(at:)

    func testFramingInterpolatesLinearAndInOutAndClamps() {
        let from = (face: CGPoint(x: 0.2, y: 0.3), size: 0.2)
        let to = (face: CGPoint(x: 0.8, y: 0.7), size: 0.6)
        let linear = ShapemationFraming.approach(outputSize: hd, from: from, to: to)
        XCTAssertEqual(linear.ease, .linear)
        var f = linear.framing(at: 0)
        XCTAssertEqual(f.face, from.face); XCTAssertEqual(f.size, 0.2)
        f = linear.framing(at: 1)
        XCTAssertEqual(f.face, to.face); XCTAssertEqual(f.size, 0.6)
        f = linear.framing(at: 0.5)
        XCTAssertEqual(f.face.x, 0.5, accuracy: 1e-12); XCTAssertEqual(f.face.y, 0.5, accuracy: 1e-12)
        XCTAssertEqual(f.size, 0.4, accuracy: 1e-12)
        f = linear.framing(at: 0.25)
        XCTAssertEqual(f.size, 0.3, accuracy: 1e-12)

        let eased = ShapemationFraming.approach(outputSize: hd, from: from, to: to, ease: .inOut)
        XCTAssertEqual(eased.framing(at: 0).size, 0.2)
        XCTAssertEqual(eased.framing(at: 1).size, 0.6)
        // smoothstep(0.5) = 0.5, smoothstep(0.25) = 0.15625
        XCTAssertEqual(eased.framing(at: 0.5).size, 0.4, accuracy: 1e-12)
        XCTAssertEqual(eased.framing(at: 0.25).size, 0.2 + 0.4 * 0.15625, accuracy: 1e-12)
        XCTAssertEqual(eased.framing(at: 0.25).face.x, 0.2 + 0.6 * 0.15625, accuracy: 1e-12)

        // Outside 0…1 is the nearer end.
        XCTAssertEqual(linear.framing(at: -3).size, 0.2)
        XCTAssertEqual(linear.framing(at: 7).size, 0.6)
        XCTAssertEqual(eased.framing(at: .nan).size, 0.2)
    }

    func testThreeKeyFramingReadsBetweenNeighbours() {
        let keys = [
            ShapemationFraming.Key(at: 1, face: CGPoint(x: 0.8, y: 0.5), size: 0.3),
            ShapemationFraming.Key(at: 0, face: CGPoint(x: 0.2, y: 0.5), size: 0.3),
            ShapemationFraming.Key(at: 0.5, face: CGPoint(x: 0.5, y: 0.5), size: 0.6),
        ]
        let framing = ShapemationFraming(outputSize: CGSize(width: 1080, height: 1080), keys: keys)
        XCTAssertEqual(framing.keys.map(\.at), [0, 0.5, 1], "sorted in init")
        XCTAssertEqual(framing.framing(at: 0.25).size, 0.45, accuracy: 1e-12)
        XCTAssertEqual(framing.framing(at: 0.25).face.x, 0.35, accuracy: 1e-12)
        XCTAssertEqual(framing.framing(at: 0.5).size, 0.6, accuracy: 1e-12)
        XCTAssertEqual(framing.framing(at: 0.75).size, 0.45, accuracy: 1e-12)
        XCTAssertEqual(framing.framing(at: 0.75).face.x, 0.65, accuracy: 1e-12)
        XCTAssertEqual(framing.framing(at: 1).face.x, 0.8)
    }

    func testStillAndValidationAndTolerantDecode() throws {
        let still = ShapemationFraming.still(outputSize: hd, face: CGPoint(x: 0.5, y: 0.55), size: 0.25)
        XCTAssertEqual(still.keys.count, 2)
        XCTAssertEqual(still.framing(at: 0.37).size, 0.25)
        XCTAssertEqual(still.framing(at: 0.37).face, CGPoint(x: 0.5, y: 0.55))
        XCTAssertEqual(still.upscaleCap, 2)

        // One key becomes a still; the ends are pinned to 0 and 1.
        let one = ShapemationFraming(outputSize: hd, keys: [ShapemationFraming.Key(at: 0.4, face: .zero, size: 0.5)])
        XCTAssertEqual(one.keys.map(\.at), [0, 1])
        let loose = ShapemationFraming(outputSize: hd, keys: [ShapemationFraming.Key(at: 0.9, face: .zero, size: 0.5),
                                                                ShapemationFraming.Key(at: 0.1, face: .zero, size: 0.2)])
        XCTAssertEqual(loose.keys.map(\.at), [0, 1])
        XCTAssertEqual(loose.keys.map(\.size), [0.2, 0.5])

        // Round trip, then a record from a later build: an unknown ease and no cap.
        let data = try JSONEncoder().encode(still)
        XCTAssertEqual(try JSONDecoder().decode(ShapemationFraming.self, from: data), still)
        let foreign = """
        {"outputSize":[1080,1080],"keys":[{"at":0,"face":[0.5,0.5],"size":0.3},{"at":1,"face":[0.5,0.5],"size":0.5}],"ease":"bounce"}
        """
        let decoded = try JSONDecoder().decode(ShapemationFraming.self, from: Data(foreign.utf8))
        XCTAssertEqual(decoded.ease, .linear)
        XCTAssertEqual(decoded.upscaleCap, 2)
        XCTAssertEqual(decoded.framing(at: 0.5).size, 0.4, accuracy: 1e-12)
    }

    func testPresetsGiveEvenSizesAtTheLongEdge() {
        XCTAssertEqual(ShapemationFraming.aspectPresets.map(\.label), ["1:1", "4:5", "3:2", "16:9", "2:3", "9:16"])
        XCTAssertEqual(ShapemationFraming.sizePresets, [1080, 1920, 2160])
        func size(_ label: String, _ edge: Int) -> CGSize {
            ShapemationFraming.outputSize(aspect: ShapemationFraming.aspectPresets.first { $0.label == label }!, longEdge: edge)
        }
        XCTAssertEqual(size("16:9", 1920), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(size("9:16", 1920), CGSize(width: 1080, height: 1920))
        XCTAssertEqual(size("1:1", 1080), CGSize(width: 1080, height: 1080))
        XCTAssertEqual(size("4:5", 2160), CGSize(width: 1728, height: 2160))
        XCTAssertEqual(size("3:2", 1080), CGSize(width: 1080, height: 720))
        XCTAssertEqual(size("2:3", 1080), CGSize(width: 720, height: 1080))
        for aspect in ShapemationFraming.aspectPresets {
            for edge in ShapemationFraming.sizePresets {
                let s = ShapemationFraming.outputSize(aspect: aspect, longEdge: edge)
                XCTAssertEqual(Int(s.width) % 2, 0); XCTAssertEqual(Int(s.height) % 2, 0)
                XCTAssertEqual(Int(max(s.width, s.height)), edge)
            }
        }
    }

    // MARK: - The .frame plan

    /// Three circles: a far face 300 px at the centre of a 4032×3024, a near
    /// face 2500 px off-centre in a 3024×4032, a mid one 200 px in a 1920×1080.
    private struct Spec { var frame: CGSize; var centre: CGPoint; var diameter: Double }
    private let specs = [
        Spec(frame: CGSize(width: 4032, height: 3024), centre: CGPoint(x: 2016, y: 1512), diameter: 300),
        Spec(frame: CGSize(width: 3024, height: 4032), centre: CGPoint(x: 1500, y: 2000), diameter: 2500),
        Spec(frame: CGSize(width: 1920, height: 1080), centre: CGPoint(x: 1000, y: 600), diameter: 200),
    ]

    private func circleItems() -> (items: [ShapemationItem], truths: [UUID: SceneManifest.Geometry]) {
        var items: [ShapemationItem] = []
        var truths: [UUID: SceneManifest.Geometry] = [:]
        for spec in specs {
            let truth = SceneManifest.Geometry.ellipse(centre: spec.centre, semiAxes: (spec.diameter / 2, spec.diameter / 2), rotation: 0)
            let shape = try! SceneManifest.makeShape(truth, frame: spec.frame)
            let item = ShapemationItem(title: "\(Int(spec.diameter))", imageURL: url, pixelSize: spec.frame, shape: shape)
            items.append(item)
            truths[item.id] = truth
        }
        return (items, truths)
    }

    func testFramePlanPutsEveryFaceOnItsTargetAndFlagsWhatDoesNotFit() throws {
        let (items, truths) = circleItems()
        let framing = ShapemationFraming.still(outputSize: hd, face: CGPoint(x: 0.5, y: 0.55), size: 0.25)
        XCTAssertNil(ShapemationPlan.make(items: items, mode: .frame, match: ShapeMatch(family: .circle)), "a frame plan needs a framing")
        let plan = try XCTUnwrap(ShapemationPlan.make(items: items, mode: .frame, match: ShapeMatch(family: .circle), framing: framing))
        XCTAssertEqual(plan.mode, .frame)
        XCTAssertEqual(plan.canvas, CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(plan.placements.count, 3, "flag and keep: nothing excluded")
        XCTAssertEqual(plan.framing, framing)
        let target = CGPoint(x: 960, y: 594)
        XCTAssertEqual(plan.anchor, target)
        XCTAssertEqual(plan.shapeSizePx, 270, accuracy: 1e-9)

        for (placement, spec) in zip(plan.placements, specs) {
            // The register shape's centre through the transform lands on the target.
            let landed = placement.transform.apply(spec.centre)
            XCTAssertEqual(landed.x, target.x, accuracy: 0.5, spec.frame.debugDescription)
            XCTAssertEqual(landed.y, target.y, accuracy: 0.5, spec.frame.debugDescription)
            XCTAssertEqual(placement.target, target)
            XCTAssertEqual(placement.targetSizePx, 270, accuracy: 1e-9)
            XCTAssertEqual(placement.scale, 270 / spec.diameter, accuracy: 1e-9)
            XCTAssertEqual(placement.feasibility.upscale, placement.scale)
        }

        // Far: 0.9 × 4032×3024 = 3628.8×2721.6, top-left at (960 − 2016×0.9, 594 − 1512×0.9) = (−854.4, −766.8): covers the frame.
        let far = plan.placements[0]
        XCTAssertEqual(far.feasibility.verdict, .fits)
        XCTAssertEqual(far.feasibility.upscale, 0.9, accuracy: 1e-9)
        XCTAssertEqual(far.footprint.minX, -854.4, accuracy: 1e-6)
        XCTAssertEqual(far.footprint.minY, -766.8, accuracy: 1e-6)
        XCTAssertEqual(far.feasibility.shortfall.left, 0); XCTAssertEqual(far.feasibility.shortfall.top, 0)
        XCTAssertEqual(far.feasibility.shortfall.right, 0); XCTAssertEqual(far.feasibility.shortfall.bottom, 0)

        // Near: 270/2500 = 0.108; the photo is 326.592×435.456 with its top-left at
        // (960 − 1500×0.108, 594 − 2000×0.108) = (798, 378), bottom-right at (1124.592, 813.456).
        let near = plan.placements[1]
        XCTAssertEqual(near.feasibility.verdict, .short)
        XCTAssertEqual(near.feasibility.upscale, 0.108, accuracy: 1e-9)
        XCTAssertEqual(near.feasibility.shortfall.left, 798, accuracy: 1e-6)
        XCTAssertEqual(near.feasibility.shortfall.top, 378, accuracy: 1e-6)
        XCTAssertEqual(near.feasibility.shortfall.right, 1920 - 1124.592, accuracy: 1e-6)
        XCTAssertEqual(near.feasibility.shortfall.bottom, 1080 - 813.456, accuracy: 1e-6)

        // Mid: 270/200 = 1.35, the photo 2592×1458 from (960 − 1350, 594 − 810): covers, under the cap.
        let mid = plan.placements[2]
        XCTAssertEqual(mid.feasibility.verdict, .fits)
        XCTAssertEqual(mid.feasibility.upscale, 1.35, accuracy: 1e-9)

        XCTAssertEqual(plan.flagged.map(\.itemID), [near.itemID])
        XCTAssertEqual(plan.feasibilitySummary.short, 1)
        XCTAssertEqual(plan.feasibilitySummary.upscaled, 0)

        // The scorer measures against each placement's own target and carries the verdicts.
        let score = ShapemationScore.measure(plan: plan, items: items, truths: truths)
        XCTAssertEqual(score.placed, 3)
        for s in score.items {
            XCTAssertLessThan(s.centrePx, 0.5)
            XCTAssertLessThan(abs(s.scale), 1e-6)
        }
        XCTAssertEqual(score.items.map(\.verdict), [.fits, .short, .fits])
        XCTAssertEqual(score.flaggedShort, 1)
        XCTAssertEqual(score.flaggedUpscaled, 0)
        XCTAssertTrue(score.summaryLine(dropped: 0).hasSuffix(" · flagged: short 1 · upscaled 0"), score.summaryLine(dropped: 0))
    }

    func testALargeFaceUpscalesTheFarPhotoPastTheCap() throws {
        let (items, _) = circleItems()
        let framing = ShapemationFraming.still(outputSize: hd, face: CGPoint(x: 0.5, y: 0.55), size: 0.6)
        let plan = try XCTUnwrap(ShapemationPlan.make(items: items, mode: .frame, match: ShapeMatch(family: .circle), framing: framing))
        XCTAssertEqual(plan.shapeSizePx, 648, accuracy: 1e-9)
        // 648 / 300 = 2.16 > 2: blown up past the cap, and it still covers the frame.
        let far = plan.placements[0]
        XCTAssertEqual(far.feasibility.upscale, 2.16, accuracy: 1e-9)
        XCTAssertEqual(far.feasibility.verdict, .upscaled)
        XCTAssertEqual(far.feasibility.shortfall.left, 0)
        // 648 / 200 = 3.24 on the mid photo; 648 / 2500 on the near one, still short.
        XCTAssertEqual(plan.placements[2].feasibility.verdict, .upscaled)
        XCTAssertEqual(plan.placements[1].feasibility.verdict, .short)
        XCTAssertEqual(plan.feasibilitySummary.short, 1)
        XCTAssertEqual(plan.feasibilitySummary.upscaled, 2)
        XCTAssertEqual(plan.flagged.count, 3)

        // A looser cap lets the far photo through.
        let loose = ShapemationFraming.still(outputSize: hd, face: CGPoint(x: 0.5, y: 0.55), size: 0.6, upscaleCap: 4)
        let plan2 = try XCTUnwrap(ShapemationPlan.make(items: items, mode: .frame, match: ShapeMatch(family: .circle), framing: loose))
        XCTAssertEqual(plan2.placements[0].feasibility.verdict, .fits)
        XCTAssertEqual(plan2.placements[2].feasibility.verdict, .fits)
    }

    func testApproachFramingReadsEachPhotoAtItsOwnT() throws {
        // Five identical photos through an 18 % → 50 % approach: t = 0, ¼, ½, ¾, 1.
        let spec = specs[0]
        let shape = DetectedShape.ellipse(centre: spec.centre, semiAxisX: 150, semiAxisY: 150, rotation: 0, frame: spec.frame)
        let items = (0..<5).map { ShapemationItem(title: "\($0)", imageURL: url, pixelSize: spec.frame, shape: shape) }
        let framing = ShapemationFraming.approach(outputSize: hd, from: (CGPoint(x: 0.3, y: 0.55), 0.18), to: (CGPoint(x: 0.7, y: 0.55), 0.5))
        let plan = try XCTUnwrap(ShapemationPlan.make(items: items, mode: .frame, match: ShapeMatch(family: .circle), framing: framing))
        let sizes = plan.placements.map { $0.targetSizePx / 1080 }
        for (got, want) in zip(sizes, [0.18, 0.26, 0.34, 0.42, 0.50]) { XCTAssertEqual(got, want, accuracy: 1e-9) }
        let xs = plan.placements.map { Double($0.target.x) / 1920 }
        for (got, want) in zip(xs, [0.3, 0.4, 0.5, 0.6, 0.7]) { XCTAssertEqual(got, want, accuracy: 1e-9) }
        for (placement, size) in zip(plan.placements, sizes) {
            let landed = placement.transform.apply(spec.centre)
            XCTAssertEqual(landed.x, placement.target.x, accuracy: 0.5)
            XCTAssertEqual(landed.y, placement.target.y, accuracy: 0.5)
            XCTAssertEqual(placement.scale, size * 1080 / 300, accuracy: 1e-9)
        }
        XCTAssertEqual(plan.shapeSizePx, 0.18 * 1080, accuracy: 1e-9, "the first placement's")
        XCTAssertEqual(plan.anchor.x, 0.3 * 1920, accuracy: 1e-9)

        // A single item reads t = 0.
        let one = try XCTUnwrap(ShapemationPlan.make(items: [items[0]], mode: .frame, match: ShapeMatch(family: .circle), framing: framing))
        XCTAssertEqual(one.placements[0].targetSizePx, 0.18 * 1080, accuracy: 1e-9)
    }

    func testStackAndCropPlansCarryTheAnchorAsEveryTarget() throws {
        let (items, _) = circleItems()
        for mode in [ShapemationMode.stack, .crop] {
            guard let plan = ShapemationPlan.make(items: items, mode: mode, match: ShapeMatch(family: .circle)) else {
                XCTAssertEqual(mode, .crop, "only the crop can be too small")
                continue
            }
            XCTAssertEqual(plan.shapeSizePx, 200, "the smallest native diameter")
            XCTAssertNil(plan.framing)
            XCTAssertTrue(plan.flagged.isEmpty)
            XCTAssertEqual(plan.feasibilitySummary.short, 0)
            XCTAssertEqual(plan.feasibilitySummary.upscaled, 0)
            for p in plan.placements {
                XCTAssertEqual(p.target, plan.anchor)
                XCTAssertEqual(p.targetSizePx, plan.shapeSizePx)
                XCTAssertEqual(p.feasibility, .fits(scale: p.scale))
                XCTAssertEqual(p.feasibility.verdict, .fits)
            }
        }
        // A framing passed to a stack plan is ignored.
        let framing = ShapemationFraming.still(outputSize: hd)
        XCTAssertEqual(ShapemationPlan.make(items: items, mode: .stack, match: ShapeMatch(family: .circle), framing: framing),
                       ShapemationPlan.make(items: items, mode: .stack, match: ShapeMatch(family: .circle)))
    }

    // MARK: - The renderer

    /// A solid `colour` image of `size` pixels.
    private func solid(_ size: CGSize, r: CGFloat, g: CGFloat, b: CGFloat) throws -> CGImage {
        let w = Int(size.width), h = Int(size.height)
        let context = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        return try XCTUnwrap(context.makeImage())
    }

    /// Every decoded frame of the clip as BGRA buffers, in presentation order.
    private func frames(of clip: URL) async throws -> [CVPixelBuffer] {
        let asset = AVURLAsset(url: clip)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var buffers: [CVPixelBuffer] = []
        while let sample = output.copyNextSampleBuffer() {
            if let pb = CMSampleBufferGetImageBuffer(sample) { buffers.append(pb) }
        }
        return buffers
    }

    /// (r, g, b) at a pixel of a CGImage, whatever its own layout: drawn
    /// into an RGBA context of the same size and read there (y from the top).
    private func pixel(_ cg: CGImage, x: Int, y: Int) throws -> (Int, Int, Int) {
        let w = cg.width, h = cg.height
        let context = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let base = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let p = base + (h - 1 - y) * w * 4 + x * 4
        return (Int(p[0]), Int(p[1]), Int(p[2]))
    }

    /// (r, g, b) at a pixel of a BGRA buffer.
    private func pixel(_ pb: CVPixelBuffer, x: Int, y: Int) -> (Int, Int, Int) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(pb)
        let p = base + y * row + x * 4
        return (Int(p[2]), Int(p[1]), Int(p[0]))
    }

    /// Three photos at one frame each over a 320×180 frame: a red one whose
    /// face fills the frame, then a blue and a green one whose faces are so
    /// large the photos shrink to a patch in the middle. Under `.frame` the
    /// corner of frame 2 is black — under a stack it would still be red.
    func testFrameRenderWritesOnePhotoPerHoldOverBlack() async throws {
        let size = CGSize(width: 320, height: 180)
        let source = CGSize(width: 640, height: 360)
        let red = try solid(source, r: 1, g: 0, b: 0)
        let blue = try solid(source, r: 0, g: 0, b: 1)
        let green = try solid(source, r: 0, g: 1, b: 0)
        let centre = CGPoint(x: 320, y: 180)
        let items = [
            ShapemationItem(title: "red", imageURL: url, pixelSize: source,
                            shape: DetectedShape.ellipse(centre: centre, semiAxisX: 50, semiAxisY: 50, rotation: 0, frame: source)),
            ShapemationItem(title: "blue", imageURL: url, pixelSize: source,
                            shape: DetectedShape.ellipse(centre: centre, semiAxisX: 300, semiAxisY: 300, rotation: 0, frame: source)),
            ShapemationItem(title: "green", imageURL: url, pixelSize: source,
                            shape: DetectedShape.ellipse(centre: centre, semiAxisX: 300, semiAxisY: 300, rotation: 0, frame: source)),
        ]
        let images: [UUID: CGImage] = [items[0].id: red, items[1].id: blue, items[2].id: green]
        // Face 90 px: red scales 0.9 (576×324 over 320×180), blue and green 0.15 (96×54 in the middle).
        let framing = ShapemationFraming.still(outputSize: size, face: CGPoint(x: 0.5, y: 0.5), size: 0.5)
        let plan = try XCTUnwrap(ShapemationPlan.make(items: items, mode: .frame, match: ShapeMatch(family: .circle), framing: framing))
        XCTAssertEqual(plan.placements[0].feasibility.verdict, .fits)
        XCTAssertEqual(plan.placements[1].feasibility.verdict, .short)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shapemation-frame-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clip = root.appendingPathComponent("clip.mp4")
        let renderer = ShapemationRenderer()
        renderer.timing = ShapemationTiming(fps: 25, each: .frames(1))
        let poster = try renderer.render(plan: plan, items: items, outputSize: size, to: clip, load: { item in
            try XCTUnwrap(images[item.id])
        })
        XCTAssertEqual(poster?.width, 320)
        XCTAssertEqual(poster?.height, 180)

        let decoded = try await frames(of: clip)
        XCTAssertEqual(decoded.count, 3, "one frame per hold")
        XCTAssertEqual(CVPixelBufferGetWidth(decoded[0]), 320)
        func isRed(_ p: (Int, Int, Int)) -> Bool { p.0 > 180 && p.1 < 80 && p.2 < 80 }
        func isBlack(_ p: (Int, Int, Int)) -> Bool { p.0 < 40 && p.1 < 40 && p.2 < 40 }
        func isGreen(_ p: (Int, Int, Int)) -> Bool { p.1 > 180 && p.0 < 80 && p.2 < 80 }
        func isBlue(_ p: (Int, Int, Int)) -> Bool { p.2 > 180 && p.0 < 80 && p.1 < 80 }
        // Frame 0: red everywhere.
        XCTAssertTrue(isRed(pixel(decoded[0], x: 4, y: 4)), "\(pixel(decoded[0], x: 4, y: 4))")
        XCTAssertTrue(isRed(pixel(decoded[0], x: 160, y: 90)))
        // Frame 1: blue in the middle, black at the corner — the red did not stay.
        XCTAssertTrue(isBlue(pixel(decoded[1], x: 160, y: 90)), "\(pixel(decoded[1], x: 160, y: 90))")
        XCTAssertTrue(isBlack(pixel(decoded[1], x: 4, y: 4)), "\(pixel(decoded[1], x: 4, y: 4))")
        // Frame 2: green in the middle, black at the corner; not frame 0.
        XCTAssertTrue(isGreen(pixel(decoded[2], x: 160, y: 90)), "\(pixel(decoded[2], x: 160, y: 90))")
        XCTAssertTrue(isBlack(pixel(decoded[2], x: 4, y: 4)), "\(pixel(decoded[2], x: 4, y: 4))")
        XCTAssertFalse(isRed(pixel(decoded[2], x: 4, y: 4)), "no accumulation: the first frame is not the last")

        // The poster is the last frame: green in the middle, black at the corner.
        let posterImage = try XCTUnwrap(poster)
        let posterCorner = try pixel(posterImage, x: 4, y: 4), posterMid = try pixel(posterImage, x: 160, y: 90)
        XCTAssertTrue(isBlack(posterCorner), "\(posterCorner)")
        XCTAssertTrue(isGreen(posterMid), "\(posterMid)")

        // The same three under .stack accumulate: frame 2's corner is still red.
        let stack = try XCTUnwrap(ShapemationPlan.make(items: items, mode: .stack, match: ShapeMatch(family: .circle)))
        let stackClip = root.appendingPathComponent("stack.mp4")
        let stackSize = CGSize(width: 320, height: max(2, floor(stack.canvas.height * 320 / stack.canvas.width / 2) * 2))
        _ = try renderer.render(plan: stack, items: items, outputSize: stackSize, to: stackClip, load: { item in try XCTUnwrap(images[item.id]) })
        let stacked = try await frames(of: stackClip)
        XCTAssertEqual(stacked.count, 3)
        XCTAssertTrue(isRed(pixel(stacked[2], x: 4, y: 4)), "\(pixel(stacked[2], x: 4, y: 4))")
    }

    /// A levelled oval tilted 5° in a 3:2 photo at a face size where the
    /// photo's axis-aligned bounds still cover the 1920×1080 frame while two
    /// opposite frame corners lie 55 px outside the rotated photo: the
    /// verdict is `short` (decided on the quad, not its box), the shortfall
    /// names that corner's two sides, and the evaluator renders it black.
    func testARotatedPhotoWhoseBoundsCoverTheFrameIsStillShortAtTheCorner() throws {
        let source = CGSize(width: 3000, height: 2000)
        let shape = DetectedShape.ellipse(centre: CGPoint(x: 1500, y: 1000), semiAxisX: 188, semiAxisY: 120,
                                          rotation: 5 * .pi / 180, frame: source)
        let item = ShapemationItem(title: "tilted", imageURL: url, pixelSize: source, shape: shape)
        let framing = ShapemationFraming.still(outputSize: hd, face: CGPoint(x: 0.5, y: 0.5), size: 0.22)
        let plan = try XCTUnwrap(ShapemationPlan.make(items: [item], mode: .frame, match: ShapeMatch(family: .oval), framing: framing))
        let p = try XCTUnwrap(plan.placements.first)
        // The box around the rotated photo reaches past every frame edge…
        XCTAssertLessThanOrEqual(p.footprint.minX, 0); XCTAssertLessThanOrEqual(p.footprint.minY, 0)
        XCTAssertGreaterThanOrEqual(p.footprint.maxX, 1920); XCTAssertGreaterThanOrEqual(p.footprint.maxY, 1080)
        // …and the verdict is short all the same.
        XCTAssertEqual(p.feasibility.verdict, .short)
        let f = p.feasibility.shortfall
        XCTAssertEqual(max(f.left, f.top, f.right, f.bottom), 55.5, accuracy: 1)
        // Two opposite corners are uncovered, each marking both of its sides.
        XCTAssertEqual(f.left, f.right, accuracy: 1e-9); XCTAssertEqual(f.top, f.bottom, accuracy: 1e-9)
        XCTAssertEqual(f.left, f.top, accuracy: 1e-9)
        XCTAssertEqual(plan.feasibilitySummary.short, 1)

        // Through the evaluator at 384×216 the uncovered corners are black
        // and the middle is the photo. Which diagonal depends on the tilt's
        // sign: try both and require exactly one pair black.
        let size = CGSize(width: 384, height: 216)
        let blue = try solid(CGSize(width: 1500, height: 1000), r: 0, g: 0, b: 1)
        let image = ShapemationFrameEvaluator.image(item: item, decoded: blue, placement: p, outputSize: size, canvas: plan.canvas)
        let cg = try XCTUnwrap(CIContext().createCGImage(image, from: image.extent))
        func isBlack(_ x: Int, _ y: Int) throws -> Bool { let c = try pixel(cg, x: x, y: y); return c.0 < 8 && c.1 < 8 && c.2 < 8 }
        let mid = try pixel(cg, x: 192, y: 108)
        XCTAssertTrue(mid.2 > 200 && mid.0 < 80, "\(mid)")
        let trbl = try isBlack(382, 1) && isBlack(1, 214)
        let tlbr = try isBlack(1, 1) && isBlack(382, 214)
        XCTAssertTrue(trbl != tlbr, "one diagonal's corners are black: TR/BL \(trbl), TL/BR \(tlbr)")

        // Five per cent larger the photo covers every corner and fits.
        let bigger = ShapemationFraming.still(outputSize: hd, face: CGPoint(x: 0.5, y: 0.5), size: 0.24)
        let fits = try XCTUnwrap(ShapemationPlan.make(items: [item], mode: .frame, match: ShapeMatch(family: .oval), framing: bigger))
        XCTAssertEqual(fits.placements[0].feasibility.verdict, .fits)
    }

    /// An item the plan cannot place (a zero-axis shape) does not count
    /// towards `t`: the last photo placed reads the end key.
    func testSkippedItemsDoNotStretchTheFramingOverTheEnd() throws {
        var (items, _) = circleItems()
        var dud = items[2]
        dud.shape.majorAxis = 0; dud.shape.nativeDiameterPx = 0
        items[2] = dud
        let framing = ShapemationFraming.approach(outputSize: hd, from: (CGPoint(x: 0.5, y: 0.5), 0.18), to: (CGPoint(x: 0.5, y: 0.5), 0.5))
        let plan = try XCTUnwrap(ShapemationPlan.make(items: items, mode: .frame, match: ShapeMatch(family: .circle), framing: framing))
        XCTAssertEqual(plan.placements.count, 2)
        XCTAssertEqual(plan.placements[0].targetSizePx, 0.18 * 1080, accuracy: 1e-9)
        XCTAssertEqual(plan.placements[1].targetSizePx, 0.5 * 1080, accuracy: 1e-9, "the last placed photo reads t = 1")
    }

    /// The evaluator alone: the photo placed over black at the output size.
    func testEvaluatorPlacesOnePhotoOverBlack() throws {
        let size = CGSize(width: 320, height: 180)
        let source = CGSize(width: 640, height: 360)
        let blue = try solid(source, r: 0, g: 0, b: 1)
        let item = ShapemationItem(title: "blue", imageURL: url, pixelSize: source,
                                   shape: DetectedShape.ellipse(centre: CGPoint(x: 320, y: 180), semiAxisX: 300, semiAxisY: 300, rotation: 0, frame: source))
        let framing = ShapemationFraming.still(outputSize: size, face: CGPoint(x: 0.5, y: 0.5), size: 0.5)
        let plan = try XCTUnwrap(ShapemationPlan.make(items: [item], mode: .frame, match: ShapeMatch(family: .circle), framing: framing))
        let image = ShapemationFrameEvaluator.image(item: item, decoded: blue, placement: plan.placements[0], outputSize: size, canvas: plan.canvas)
        XCTAssertEqual(image.extent, CGRect(origin: .zero, size: size))
        let context = CIContext()
        let cg = try XCTUnwrap(context.createCGImage(image, from: image.extent))
        XCTAssertEqual(cg.width, 320); XCTAssertEqual(cg.height, 180)
        // The corner is black, the middle blue (loosely: the context's colour
        // management moves a device-RGB primary a little).
        let corner = try pixel(cg, x: 4, y: 4), mid = try pixel(cg, x: 160, y: 90)
        XCTAssertTrue(corner.0 < 8 && corner.1 < 8 && corner.2 < 8, "\(corner)")
        XCTAssertTrue(mid.2 > 200 && mid.0 < 80 && mid.1 < 80, "\(mid)")
    }
}

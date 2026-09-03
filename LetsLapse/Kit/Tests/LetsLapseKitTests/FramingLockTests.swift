import XCTest
import CoreGraphics
#if canImport(CoreImage)
import CoreImage
#endif
@testable import LetsLapseKit

/// A smooth synthetic scene: a coarse random grid, bilinearly interpolated,
/// so a fractional shift is an exact resample rather than a rounded one.
private struct SyntheticScene {
    let cols: Int
    let rows: Int
    let cell: Double
    let values: [Double]

    init(width: Int, height: Int, cell: Double = 9, seed: UInt64 = 7) {
        self.cell = cell
        cols = Int((Double(width) / cell).rounded(.up)) + 3
        rows = Int((Double(height) / cell).rounded(.up)) + 3
        var rng = SplitMix64(seed: seed)
        values = (0..<(cols * rows)).map { _ in Double(rng.next() % 1000) / 1000 }
    }

    func sample(_ x: Double, _ y: Double) -> Double {
        let u = x / cell + 1, v = y / cell + 1
        let i = Int(u.rounded(.down)), j = Int(v.rounded(.down))
        let fu = u - Double(i), fv = v - Double(j)
        func at(_ a: Int, _ b: Int) -> Double {
            values[min(max(b, 0), rows - 1) * cols + min(max(a, 0), cols - 1)]
        }
        let top = at(i, j) * (1 - fu) + at(i + 1, j) * fu
        let bottom = at(i, j + 1) * (1 - fu) + at(i + 1, j + 1) * fu
        return top * (1 - fv) + bottom * fv
    }

    /// The scene with its content moved by (+dx, +dy): pixel (x, y) shows
    /// scene point (x − dx, y − dy). Optional linear gradient, optional gain.
    func plane(width: Int, height: Int, dx: Double, dy: Double, gradient: Double = 0, gain: Double = 1) -> LumaPlane {
        var pixels = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let value = sample(Double(x) - dx, Double(y) - dy) * gain + gradient * Double(x + y) / Double(width + height)
                pixels[y * width + x] = Float(value)
            }
        }
        return LumaPlane(width: width, height: height, pixels: pixels)
    }
}

final class FramingLockTests: XCTestCase {

    // MARK: Phase correlation

    func testIdenticalPlanesCorrelateAtZero() {
        let scene = SyntheticScene(width: 256, height: 192)
        let plane = scene.plane(width: 256, height: 192, dx: 0, dy: 0)
        let engine = PhaseCorrelator(width: 256, height: 192)
        let spectrum = engine.spectrum(of: plane)
        let shift = engine.shift(from: spectrum, to: spectrum)
        XCTAssertEqual(shift.dx, 0, accuracy: 1e-3)
        XCTAssertEqual(shift.dy, 0, accuracy: 1e-3)
        XCTAssertGreaterThan(shift.response, 0.85)
    }

    func testIntegerShiftSignConvention() {
        // Content moved right 7 and up 5 → dx +7, dy −5 (y-down).
        let scene = SyntheticScene(width: 256, height: 192)
        let engine = PhaseCorrelator(width: 256, height: 192)
        let anchor = engine.spectrum(of: scene.plane(width: 256, height: 192, dx: 0, dy: 0))
        let moved = engine.spectrum(of: scene.plane(width: 256, height: 192, dx: 7, dy: -5))
        let shift = engine.shift(from: anchor, to: moved)
        XCTAssertEqual(shift.dx, 7, accuracy: 0.1)
        XCTAssertEqual(shift.dy, -5, accuracy: 0.1)
        XCTAssertGreaterThan(shift.response, 0.5)
    }

    func testSubPixelShiftUnderGradientAndGain() {
        let scene = SyntheticScene(width: 320, height: 240)
        let engine = PhaseCorrelator(width: 320, height: 240)
        let anchor = engine.spectrum(of: scene.plane(width: 320, height: 240, dx: 0, dy: 0))
        // A brighter frame with a vignette-like gradient: the high-pass and
        // the normalised cross-power must both ignore them.
        let moved = engine.spectrum(of: scene.plane(width: 320, height: 240, dx: 2.5, dy: 0.25, gradient: 0.4, gain: 1.8))
        let shift = engine.shift(from: anchor, to: moved)
        XCTAssertEqual(shift.dx, 2.5, accuracy: 0.15)
        XCTAssertEqual(shift.dy, 0.25, accuracy: 0.15)
    }

    func testUnrelatedPlanesScoreLow() {
        // Different seeds AND different grid pitches, so the two scenes
        // share no periodic structure the correlator could latch onto.
        let a = SyntheticScene(width: 256, height: 192, cell: 9, seed: 1)
        let b = SyntheticScene(width: 256, height: 192, cell: 11.5, seed: 2)
        let engine = PhaseCorrelator(width: 256, height: 192)
        let shift = engine.shift(
            from: engine.spectrum(of: a.plane(width: 256, height: 192, dx: 0, dy: 0)),
            to: engine.spectrum(of: b.plane(width: 256, height: 192, dx: 0, dy: 0)))
        XCTAssertLessThan(shift.response, FramingReview.confidenceFloor)
    }

    func testParabolicOffsetIsBounded() {
        XCTAssertEqual(PhaseCorrelator.parabolicOffset(left: 0.5, centre: 1, right: 0.5), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(PhaseCorrelator.parabolicOffset(left: 0.4, centre: 1, right: 0.8), 0)
        XCTAssertEqual(PhaseCorrelator.parabolicOffset(left: 1, centre: 1, right: 1), 0)
        XCTAssertLessThanOrEqual(abs(PhaseCorrelator.parabolicOffset(left: 0.99, centre: 1, right: 0)), 0.5)
    }

    // MARK: Measurement → review

    /// A 70-photo shoot: a slow x drift, a 6 px knock at photos 40–45 and a
    /// 3 px one at 62, measured in 30-photo chunks so the path crosses two
    /// anchor boundaries.
    private func syntheticShoot() -> (urls: [URL], truth: [(Double, Double)], review: FramingReview) {
        let width = 256, height = 192
        let scene = SyntheticScene(width: width, height: height, seed: 11)
        var truth: [(Double, Double)] = []
        for index in 0..<70 {
            var dx = Double(index) * 0.05
            var dy = 0.0
            if (40...45).contains(index) { dy = 6; dx += 0.5 }
            if index == 62 { dy = -3 }
            truth.append((dx, dy))
        }
        let urls = (0..<70).map { URL(fileURLWithPath: String(format: "/synthetic/frame-%05d.png", $0 + 1)) }
        let table = Dictionary(uniqueKeysWithValues: zip(urls, truth))
        let offsets = try! FramingMeasurement.measure(
            urls: urls, scale: 1,
            luma: { url in
                let (dx, dy) = table[url]!
                return scene.plane(width: width, height: height, dx: dx, dy: dy)
            },
            chunk: 30, workers: 3)
        let review = FramingReview.make(
            width: width, height: height, measurementScale: 1, offsets: offsets,
            captureSpanSeconds: 70, reviewedAt: Date(timeIntervalSince1970: 1_800_000_000))
        return (urls, truth, review)
    }

    func testMeasurementTracksTheTruthAcrossChunks() {
        let (urls, truth, review) = syntheticShoot()
        XCTAssertEqual(review.frames.count, 70)
        for (index, frame) in review.frames.enumerated() {
            XCTAssertEqual(frame.name, urls[index].lastPathComponent)
            XCTAssertEqual(frame.dx, truth[index].0, accuracy: 0.25, "frame \(index) dx")
            XCTAssertEqual(frame.dy, truth[index].1, accuracy: 0.25, "frame \(index) dy")
        }
    }

    func testReviewFindsTheKnocksAndSizesTheCrop() {
        let (_, _, review) = syntheticShoot()
        XCTAssertEqual(review.verdict, .recommended)
        XCTAssertEqual(review.events.count, 2, review.events.map(\.summary).joined(separator: " | "))
        XCTAssertEqual(review.events[0].firstIndex, 40)
        XCTAssertEqual(review.events[0].lastIndex, 45)
        XCTAssertEqual(review.events[0].peakPixels, 6, accuracy: 0.4)
        XCTAssertEqual(review.events[0].summary, "Photos 41–46 · 6 photos · \(FramingReview.format(review.events[0].peakPixels)) px")
        XCTAssertEqual(review.events[1].firstIndex, 62)
        XCTAssertTrue(review.summary.hasPrefix("2 knocks across 70 photos over 70 s, the largest"), review.summary)
        // Excursion: x 0…3.95 (drift + 0.5), y −3…6 → insets ≈ 2, 4.5; the
        // y axis is tighter on a 192-tall frame.
        XCTAssertEqual(review.plan.insetY, 4.5, accuracy: 0.3)
        XCTAssertEqual(review.plan.cropFraction, 9.0 / 192, accuracy: 0.004)
        XCTAssertEqual(review.plan.referenceY, 1.5, accuracy: 0.3)
        XCTAssertEqual(review.driftX, 3.45, accuracy: 0.4)
        XCTAssertLessThan(review.driftY, 1)
    }

    func testSteadyShootReadsAsSteady() {
        let width = 256, height = 192
        let scene = SyntheticScene(width: width, height: height, seed: 3)
        let urls = (0..<12).map { URL(fileURLWithPath: "/synthetic/still-\($0).png") }
        let offsets = try! FramingMeasurement.measure(
            urls: urls, scale: 1,
            luma: { _ in scene.plane(width: width, height: height, dx: 0.1, dy: -0.1) },
            chunk: 30, workers: 1)
        let review = FramingReview.make(width: width, height: height, measurementScale: 1, offsets: offsets)
        XCTAssertEqual(review.verdict, .steady)
        XCTAssertTrue(review.events.isEmpty)
        XCTAssertTrue(review.summary.hasPrefix("The framing held within"), review.summary)
        XCTAssertLessThan(review.plan.cropFraction, 0.002)
    }

    func testReviewRoundTripsThroughJSONAndCommits() throws {
        let (_, _, review) = syntheticShoot()
        let data = try review.data()
        let back = try FramingReview.decode(data)
        XCTAssertEqual(back, review)
        XCTAssertFalse(back.isStabilised)
        let committed = back.applyingPlan(at: Date(timeIntervalSince1970: 1_800_000_100))
        XCTAssertTrue(committed.isStabilised)
        XCTAssertTrue(committed.isStabilisationCurrent)
        XCTAssertEqual(committed.stabilisation?.cropFraction, review.plan.cropFraction)
        var reReviewed = committed
        reReviewed.reviewedAt = Date(timeIntervalSince1970: 1_800_000_200)
        XCTAssertFalse(reReviewed.isStabilisationCurrent)
        XCTAssertNil(committed.withdrawingStabilisation().stabilisation)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("framing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertNil(FramingReview.load(inSourceFolder: folder))
        try committed.write(inSourceFolder: folder)
        XCTAssertEqual(FramingReview.load(inSourceFolder: folder), committed)
        XCTAssertNotNil(FramingLock.load(inSourceFolder: folder))
    }

    func testDisplayNumbers() {
        XCTAssertEqual(FramingReview.displayNumber(name: "frame-00802.dng", index: 3), 802)
        XCTAssertEqual(FramingReview.displayNumber(name: "IMG_0042.JPG", index: 3), 4)
        XCTAssertEqual(FramingReview.duration(84 * 60 + 10), "84 minutes")
        XCTAssertEqual(FramingReview.duration(2 * 3600 + 10 * 60), "2 h 10 min")
    }

    // MARK: Lock geometry

    func testLockCropStaysInsideEveryPhoto() {
        let (urls, _, review) = syntheticShoot()
        let lock = FramingLock(review: review.applyingPlan())!
        let size = CGSize(width: review.width, height: review.height)
        for url in urls {
            let rect = lock.cropRect(forName: url.lastPathComponent, in: size)
            XCTAssertGreaterThanOrEqual(rect.minX, -1e-6, url.lastPathComponent)
            XCTAssertGreaterThanOrEqual(rect.minY, -1e-6, url.lastPathComponent)
            XCTAssertLessThanOrEqual(rect.maxX, size.width + 1e-6, url.lastPathComponent)
            XCTAssertLessThanOrEqual(rect.maxY, size.height + 1e-6, url.lastPathComponent)
            XCTAssertEqual(rect.width / rect.height, size.width / size.height, accuracy: 1e-9)
        }
        // An unmeasured photo gets the shared crop, centred.
        let unknown = lock.cropRect(forName: "frame-99999.png", in: size)
        XCTAssertEqual(unknown.midX, size.width / 2, accuracy: 1e-9)
        XCTAssertEqual(unknown.midY, size.height / 2, accuracy: 1e-9)
        XCTAssertNil(FramingLock(review: review))
    }

    func testLockScale() {
        XCTAssertEqual(FrameRotation.lockScale(width: 4032, height: 3024, inset: .zero), 1)
        XCTAssertEqual(FrameRotation.lockScale(width: 4032, height: 3024, inset: CGSize(width: 4.6, height: 11.4)), 1 - 22.8 / 3024, accuracy: 1e-9)
        XCTAssertEqual(FrameRotation.lockScale(width: 100, height: 100, inset: CGSize(width: 60, height: 0)), 0)
    }

    #if canImport(CoreImage)
    func testLevelledPutsShiftedContentBack() throws {
        let width = 256, height = 192
        let scene = SyntheticScene(width: width, height: height, seed: 5)
        func cgImage(dx: Double, dy: Double) -> CGImage {
            let plane = scene.plane(width: width, height: height, dx: dx, dy: dy)
            let bytes = plane.pixels.map { UInt8(min(max($0, 0), 1) * 255) }
            return makeGrayImage(width: width, height: height, values: bytes)
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        func render(_ image: CIImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 4, bounds: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            return bytes
        }
        let inset = CGSize(width: 6, height: 5)
        let reference = FrameRotation.levelled(CIImage(cgImage: cgImage(dx: 0, dy: 0)), degrees: 0, offset: .zero, lockInset: inset)
        let moved = FrameRotation.levelled(CIImage(cgImage: cgImage(dx: 4, dy: 3)), degrees: 0, offset: CGVector(dx: 4, dy: 3), lockInset: inset)
        XCTAssertEqual(moved.extent, CGRect(x: 0, y: 0, width: width, height: height))
        let a = render(reference), b = render(moved)
        var total = 0
        var count = 0
        for y in 8..<(height - 8) {
            for x in 8..<(width - 8) {
                total += abs(Int(a[(y * width + x) * 4]) - Int(b[(y * width + x) * 4]))
                count += 1
            }
        }
        let mean = Double(total) / Double(count)
        XCTAssertLessThan(mean, 2.5, "mean abs difference \(mean)/255 after the lock")
        // And without the lock the same two frames differ visibly.
        let rawA = render(CIImage(cgImage: cgImage(dx: 0, dy: 0)))
        let rawB = render(CIImage(cgImage: cgImage(dx: 4, dy: 3)))
        var rawTotal = 0
        for index in stride(from: 0, to: rawA.count, by: 4) { rawTotal += abs(Int(rawA[index]) - Int(rawB[index])) }
        XCTAssertGreaterThan(Double(rawTotal) / Double(width * height), 10)
    }

    func testRotatedKeepsItsExtentThroughTheGeneralisation() {
        let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360))
        XCTAssertEqual(FrameRotation.rotated(image, degrees: 3).extent, image.extent)
        XCTAssertEqual(FrameRotation.levelled(image, degrees: 3, offset: CGVector(dx: 2, dy: -1), lockInset: CGSize(width: 3, height: 3)).extent, image.extent)
        // Inactive everything: the very same image object.
        XCTAssertTrue(FrameRotation.levelled(image, degrees: 0, offset: .zero, lockInset: .zero) === image)
    }
    #endif
}

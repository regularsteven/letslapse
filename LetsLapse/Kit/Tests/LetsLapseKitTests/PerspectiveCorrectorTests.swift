import XCTest
import CoreImage
@testable import LetsLapseKit

/// The Scanner's rectification: four detected corners in, a de-keystoned frame
/// out, at the aspect the operator named.
final class PerspectiveCorrectorTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perspective-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A 1000×1000 test frame — square, so nothing about the *source* biases
    /// the aspect assertions below; every ratio measured is the quad's or the
    /// hint's.
    private func testImage(width: CGFloat = 1000, height: CGFloat = 1000) -> CIImage {
        CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func quad(
        topLeft: (Double, Double),
        topRight: (Double, Double),
        bottomLeft: (Double, Double),
        bottomRight: (Double, Double),
        confidence: Double = 0.9
    ) -> NormalizedQuad {
        NormalizedQuad(
            topLeft: .init(x: topLeft.0, y: topLeft.1),
            topRight: .init(x: topRight.0, y: topRight.1),
            bottomLeft: .init(x: bottomLeft.0, y: bottomLeft.1),
            bottomRight: .init(x: bottomRight.0, y: bottomRight.1),
            confidence: confidence)
    }

    /// A keystoned page: the top edge is further away, so it is narrower.
    private var keystonedPage: NormalizedQuad {
        quad(
            topLeft: (0.22, 0.86), topRight: (0.78, 0.86),
            bottomLeft: (0.12, 0.14), bottomRight: (0.88, 0.14))
    }

    // MARK: - Producing an image at all

    func testCorrectsAKeystonedQuad() throws {
        let corrected = try XCTUnwrap(
            PerspectiveCorrector.correct(testImage(), quad: keystonedPage, aspect: .auto))
        XCTAssertGreaterThan(corrected.extent.width, 1)
        XCTAssertGreaterThan(corrected.extent.height, 1)
        XCTAssertFalse(corrected.extent.isInfinite)
    }

    /// A quad with no area is what a spurious detection at the frame edge looks
    /// like, and it must come back nil rather than as an infinite-extent image
    /// that only fails later, at render time.
    func testDegenerateQuadReturnsNil() {
        let collapsed = quad(
            topLeft: (0.5, 0.5), topRight: (0.5, 0.5),
            bottomLeft: (0.5, 0.5), bottomRight: (0.5, 0.5))
        XCTAssertNil(PerspectiveCorrector.correct(testImage(), quad: collapsed, aspect: .auto))
    }

    // MARK: - Auto keeps the quad's own proportions

    /// A 2:1 quad on a square frame rectifies to roughly 2:1 — `.auto` promises
    /// the quad's apparent ratio and nothing else.
    func testAutoKeepsTheQuadsOwnAspect() throws {
        let wide = quad(
            topLeft: (0.05, 0.65), topRight: (0.95, 0.65),
            bottomLeft: (0.05, 0.20), bottomRight: (0.95, 0.20))
        let corrected = try XCTUnwrap(
            PerspectiveCorrector.correct(testImage(), quad: wide, aspect: .auto))
        let ratio = corrected.extent.width / corrected.extent.height
        XCTAssertEqual(ratio, 2, accuracy: 0.1)
    }

    // MARK: - Hints

    func testAspectHintsConstrainTheOutput() throws {
        let cases: [(PerspectiveAspect, Double)] = [
            (.a4, 1 / 2.0.squareRoot()),
            (.letter, 8.5 / 11.0),
            (.fourBySix, 4.0 / 6.0),
            (.square, 1.0),
        ]
        for (aspect, expected) in cases {
            let corrected = try XCTUnwrap(
                PerspectiveCorrector.correct(testImage(), quad: keystonedPage, aspect: aspect),
                "\(aspect.rawValue) produced no image")
            let ratio = Double(corrected.extent.width / corrected.extent.height)
            XCTAssertEqual(ratio, expected, accuracy: 0.01, "\(aspect.rawValue) landed at \(ratio)")
        }
    }

    /// The hint names a stock, not an orientation: a page lying on its side
    /// rectifies to A4 landscape, not to a portrait sheet with the content
    /// squashed into it.
    func testHintFollowsTheQuadsOrientation() throws {
        let landscapePage = quad(
            topLeft: (0.08, 0.70), topRight: (0.92, 0.72),
            bottomLeft: (0.08, 0.30), bottomRight: (0.92, 0.28))
        let corrected = try XCTUnwrap(
            PerspectiveCorrector.correct(testImage(), quad: landscapePage, aspect: .a4))
        let ratio = Double(corrected.extent.width / corrected.extent.height)
        XCTAssertEqual(ratio, 2.0.squareRoot(), accuracy: 0.01)
        XCTAssertGreaterThan(corrected.extent.width, corrected.extent.height)
    }

    /// Auto is the default and must stay a no-op on the geometry — anything
    /// else would silently reshape frames for a user who never named a stock.
    func testAutoDoesNotResample() throws {
        let plain = try XCTUnwrap(
            PerspectiveCorrector.correct(testImage(), quad: keystonedPage, aspect: .auto))
        XCTAssertNil(PerspectiveCorrector.targetRatio(
            for: .auto, correctedWidth: plain.extent.width, correctedHeight: plain.extent.height))
    }

    // MARK: - Files

    func testWritesACorrectedSiblingBesideTheSource() throws {
        let source = directory.appendingPathComponent("frame-00001.heic")
        let context = CIContext()
        try context.writeHEIFRepresentation(
            of: testImage(width: 800, height: 600),
            to: source,
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)

        let written = try PerspectiveCorrector.writeCorrected(
            from: source, quad: keystonedPage, aspect: .square)
        XCTAssertEqual(written.lastPathComponent, "frame-00001-corrected.heic")
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))

        let readBack = try XCTUnwrap(CIImage(contentsOf: written))
        let ratio = Double(readBack.extent.width / readBack.extent.height)
        XCTAssertEqual(ratio, 1, accuracy: 0.02)
        // Non-destructive: the original is still there, byte for byte.
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    /// Bayer RAW cannot be rectified — resampling a colour-filter mosaic mixes
    /// the sites it exists to keep apart — so the DNG is refused rather than
    /// silently mangled.
    func testRefusesToRectifyRAW() {
        let dng = directory.appendingPathComponent("frame-00001.dng")
        FileManager.default.createFile(atPath: dng.path, contents: Data([0, 1, 2]))
        XCTAssertThrowsError(
            try PerspectiveCorrector.writeCorrected(from: dng, quad: keystonedPage)
        ) { error in
            guard case PerspectiveCorrectionError.rawIsNotRectifiable = error else {
                return XCTFail("expected rawIsNotRectifiable, got \(error)")
            }
        }
    }

    /// The sequence path is driven by the sidecar: frames that recorded a
    /// rectangle are corrected, frames that didn't are left alone.
    func testCorrectSequenceOnlyTouchesFramesThatSawARectangle() throws {
        let context = CIContext()
        for index in 1...3 {
            let url = directory.appendingPathComponent(String(format: "frame-%05d.heic", index))
            try context.writeHEIFRepresentation(
                of: testImage(width: 400, height: 300),
                to: url,
                format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        let writer = try XCTUnwrap(FrameTimestampWriter(directory: directory))
        writer.append(.init(frame: 0, captureTime: Date(), shutter: 0.008, iso: 54,
                            rectangle: keystonedPage))
        writer.append(.init(frame: 1, captureTime: Date(), shutter: 0.008, iso: 54))
        writer.append(.init(frame: 2, captureTime: Date(), shutter: 0.008, iso: 54,
                            rectangle: keystonedPage))
        writer.close()

        let result = PerspectiveCorrector.correctSequence(in: directory, aspect: .a4)
        XCTAssertEqual(result.failures.count, 0)
        XCTAssertEqual(result.written.map(\.lastPathComponent),
                       ["frame-00001-corrected.heic", "frame-00003-corrected.heic"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("frame-00002-corrected.heic").path))
    }

    // MARK: - The sidecar's side of the contract

    /// The corner block round-trips through the NDJSON sidecar as arrays, and a
    /// frame with no rectangle omits the key entirely rather than writing null.
    func testRectangleRoundTripsThroughTheSidecar() throws {
        let writer = try XCTUnwrap(FrameTimestampWriter(directory: directory))
        writer.append(.init(frame: 0, captureTime: Date(timeIntervalSince1970: 1_700_000_000),
                            shutter: 0.008, iso: 54, ev: 8.2, rectangle: keystonedPage))
        writer.append(.init(frame: 1, captureTime: Date(timeIntervalSince1970: 1_700_000_002),
                            shutter: 0.008, iso: 54, ev: 8.2))
        writer.close()

        let text = try String(contentsOf: writer.url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"topLeft\":[0.22,0.86]"), text)
        let lines = text.split(separator: "\n")
        XCTAssertFalse(lines[1].contains("rectangle"), String(lines[1]))

        let loaded = try FrameTimestamps.load(from: writer.url)
        let first = try XCTUnwrap(loaded.entries.first?.rectangle)
        XCTAssertEqual(first.topLeft.x, 0.22, accuracy: 1e-9)
        XCTAssertEqual(first.bottomRight.y, 0.14, accuracy: 1e-9)
        XCTAssertEqual(first.confidence, 0.9, accuracy: 1e-9)
        XCTAssertNil(loaded.entries[1].rectangle)
    }

    // MARK: - Corner geometry

    func testMaxCornerDistanceTakesTheFurthestTravelledCorner() {
        let pivoted = quad(
            topLeft: (0.22, 0.86), topRight: (0.78, 0.86),
            bottomLeft: (0.12, 0.14), bottomRight: (0.92, 0.14))
        XCTAssertEqual(keystonedPage.maxCornerDistance(to: pivoted), 0.04, accuracy: 1e-9)
        XCTAssertEqual(keystonedPage.maxCornerDistance(to: keystonedPage), 0, accuracy: 1e-12)
    }
}

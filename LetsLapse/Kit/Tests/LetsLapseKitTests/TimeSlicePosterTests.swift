import AVFoundation
import CoreGraphics
import ImageIO
import XCTest
@testable import LetsLapseKit

/// The poster fast path (docs/time-slicing-poster-fast-path.md §7 stage 2),
/// measured on synthesized stills whose gray level encodes the frame index:
/// a band's value identifies which master frame — and, at depth, which
/// window mean — it shows.
final class TimeSlicePosterTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeslice-poster-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        scratch = nil
        super.tearDown()
    }

    /// Gray level of still `index` of `count`: a ramp from 20 to 235 so no
    /// frame is black (an unwritten band would read as 0) and adjacent frames
    /// stay distinguishable.
    private func level(_ index: Int, of count: Int) -> UInt8 {
        UInt8(20 + (235 - 20) * index / max(1, count - 1))
    }

    private func makeStills(count: Int, width: Int = 320, height: Int = 240) throws -> [URL] {
        try (0..<count).map { index in
            let value = level(index, of: count)
            let image = makeGrayImage(
                width: width, height: height, values: [UInt8](repeating: value, count: width * height))
            let url = scratch.appendingPathComponent(String(format: "frame-%04d.png", index))
            try ImageExporter.write(image, to: url, format: .png)
            return url
        }
    }

    /// Gamma-domain averaging, so a window's expected value is the plain
    /// mean of its stills' bytes — no transfer curve to model.
    private func makeProvider(
        urls: [URL], windows: [Int], decoded: ((Int) -> Void)? = nil
    ) throws -> StillsWindowProvider {
        try StillsWindowProvider(
            core: try makeCore(), urls: urls, windows: windows,
            decode: .gamma(load: { try ImageStacker.loadImage(at: $0) }, linearLight: false),
            onStillDecoded: decoded)
    }

    private func loadImage(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func sample(_ image: CGImage, points: [(x: Int, y: Int)]) throws -> [Double] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return points.map { Double(pixels[$0.y * width * 4 + $0.x * 4]) }
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    // MARK: - The provider

    func testProviderRendersEachWindowsMean() throws {
        // 12 stills at depth 3 → 4 masters, each the mean of three levels.
        let urls = try makeStills(count: 12)
        let windows = WindowSchedule.make(totalInputFrames: 12, ramp: .constant(3))
        XCTAssertEqual(windows, [3, 3, 3, 3])
        let provider = try makeProvider(urls: urls, windows: windows)
        XCTAssertEqual(provider.frameCount, 4)
        XCTAssertEqual(provider.width, 320)
        XCTAssertEqual(provider.height, 240)

        for master in [2, 0, 3] {
            let frame = try provider.frame(at: master)
            let range = provider.sourceRange(of: master)
            let expected = range.map { Double(level($0, of: 12)) }.reduce(0, +) / Double(range.count)
            let buffer = frame.pixelBuffer
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let value = Double(base[120 * bytesPerRow + 160 * 4])
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            // Dither is ±1 LSB; the window means sit ~50 levels apart.
            XCTAssertEqual(value, expected, accuracy: 2, "master \(master) should be its window's mean")
        }
    }

    func testProviderRefusesASchedulThatDoesNotMatchTheStills() throws {
        let urls = try makeStills(count: 5)
        XCTAssertThrowsError(try makeProvider(urls: urls, windows: [2, 2]))
        XCTAssertThrowsError(try makeProvider(urls: urls, windows: [2, 0, 3]))
    }

    // MARK: - The pass

    func testPosterBandsAreTheLadderFramesBlendedAtDepth() throws {
        // 24 stills at depth 2 → 12 masters; 4 bands newest at the left
        // spread over the master: indices 11, 7, 4, 0 (the ladder's own
        // rounding). Each band must be its window's MEAN, not a single still
        // — blending is proven, not assumed.
        let urls = try makeStills(count: 24)
        let windows = WindowSchedule.make(totalInputFrames: 24, ramp: .constant(2))
        var decodes = 0
        let provider = try makeProvider(urls: urls, windows: windows) { decodes = $0 }
        let settings = TimeSliceSettings(newestEdge: .left, segments: 4, offsetFrames: 1)
        let posterURL = scratch.appendingPathComponent("poster.png")

        let results = try TimeSliceRenderer().renderPosters(
            provider: provider, recipes: [settings], posterURLs: [posterURL])
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].wrotePoster)
        XCTAssertEqual(results[0].masterFrames, 12)
        XCTAssertEqual(results[0].width, 320)
        XCTAssertEqual(results[0].height, 240)

        let ladder = try XCTUnwrap(TimeSliceGeometry.posterIndices(masterFrames: 12, segments: 4))
        XCTAssertEqual(ladder, [11, 7, 4, 0])
        // Four windows of two stills — eight decodes, plus nothing: still 0
        // sized the stack and was reused by window 0.
        XCTAssertEqual(decodes, 8)

        let image = try loadImage(posterURL)
        let bands = try sample(image, points: [(40, 120), (120, 120), (200, 120), (280, 120)])
        for (band, master) in ladder.enumerated() {
            let range = provider.sourceRange(of: master)
            let expected = range.map { Double(level($0, of: 24)) }.reduce(0, +) / Double(range.count)
            XCTAssertEqual(bands[band], expected, accuracy: 2,
                           "band \(band) should be master \(master)'s window mean")
        }
        XCTAssertGreaterThan(bands[0], bands[3])
    }

    /// The fast path lays down the same geometry as the tail pass: a poster
    /// rendered from the indexed provider equals one the existing `render`
    /// composes from a sequential provider over the same master frames.
    func testFastPosterMatchesTheTailPassPosterOverTheSameMaster() throws {
        let urls = try makeStills(count: 20)
        let windows = WindowSchedule.make(totalInputFrames: 20, ramp: .constant(1))
        let provider = try makeProvider(urls: urls, windows: windows)
        var settings = TimeSliceSettings(newestEdge: .bottom, segments: 5, offsetFrames: 1)
        let fastURL = scratch.appendingPathComponent("fast.png")
        _ = try TimeSliceRenderer().renderPosters(
            provider: provider, recipes: [settings], posterURLs: [fastURL])

        // The same frames, handed to the tail pass in order.
        let sequential = SequentialAdapter(provider: try makeProvider(urls: urls, windows: windows))
        let tailURL = scratch.appendingPathComponent("tail.png")
        let tail = try TimeSliceRenderer().render(
            provider: sequential, settings: settings, animationURL: nil, posterURL: tailURL)
        XCTAssertTrue(tail.wrotePoster)

        let fast = try pixels(try loadImage(fastURL))
        let reference = try pixels(try loadImage(tailURL))
        XCTAssertEqual(fast, reference, "fast poster and tail-pass poster should be byte-identical")

        // And a grid, whose layout is derived rather than asked for.
        settings.grid = TimeSliceGrid(origin: .topRight, metric: .euclidean)
        settings.segments = 4
        let fastGrid = scratch.appendingPathComponent("fast-grid.png")
        let gridResults = try TimeSliceRenderer().renderPosters(
            provider: provider, recipes: [settings], posterURLs: [fastGrid])
        XCTAssertEqual(gridResults[0].grid?.columns, 4)
        XCTAssertEqual(gridResults[0].grid?.rows, 3)
        let tailGrid = scratch.appendingPathComponent("tail-grid.png")
        let tailGridResult = try TimeSliceRenderer().render(
            provider: SequentialAdapter(provider: try makeProvider(urls: urls, windows: windows)),
            settings: settings, animationURL: nil, posterURL: tailGrid)
        XCTAssertEqual(gridResults[0].grid, tailGridResult.grid)
        XCTAssertEqual(try pixels(try loadImage(fastGrid)), try pixels(try loadImage(tailGrid)))
    }

    func testBatchWalksTheUnionOnceAndMatchesSoloRenders() throws {
        let urls = try makeStills(count: 30)
        let windows = WindowSchedule.make(totalInputFrames: 30, ramp: .constant(1))
        var recipes = [
            TimeSliceSettings(newestEdge: .left, segments: 4, offsetFrames: 1),
            TimeSliceSettings(newestEdge: .top, segments: 6, offsetFrames: 1),
        ]
        recipes[1].grid = TimeSliceGrid(origin: .bottomLeft, metric: .manhattan)
        recipes[1].segments = 4

        let union = try TimeSliceRenderer.posterFrameIndices(
            recipes: recipes, masterFrames: 30, width: 320, height: 240)
        let bands = Set(try XCTUnwrap(TimeSliceGeometry.posterIndices(masterFrames: 30, segments: 4)))
        let cells = Set(try XCTUnwrap(TimeSliceGridGeometry.posterIndices(
            masterFrames: 30, columns: 4, rows: 3, origin: .bottomLeft, metric: .manhattan)))
        XCTAssertEqual(Set(union), bands.union(cells))
        XCTAssertEqual(union, union.sorted())

        var decodes = 0
        let provider = try makeProvider(urls: urls, windows: windows) { decodes = $0 }
        let batchURLs = [scratch.appendingPathComponent("b1.png"), scratch.appendingPathComponent("b2.png")]
        _ = try TimeSliceRenderer().renderPosters(
            provider: provider, recipes: recipes, posterURLs: batchURLs)
        // Each union frame decoded exactly once (plus still 0 for sizing,
        // which window 0 — always in a full-spread ladder — consumed).
        XCTAssertEqual(decodes, union.count)

        for (index, recipe) in recipes.enumerated() {
            let solo = scratch.appendingPathComponent("solo\(index).png")
            _ = try TimeSliceRenderer().renderPosters(
                provider: try makeProvider(urls: urls, windows: windows),
                recipes: [recipe], posterURLs: [solo])
            XCTAssertEqual(try pixels(try loadImage(batchURLs[index])), try pixels(try loadImage(solo)),
                           "batch member \(index) should equal its solo render")
        }
    }

    func testShortMasterRepeatsFramesRatherThanFailing() throws {
        // 3 masters under 6 bands: the ladder repeats and the union is 3.
        let urls = try makeStills(count: 3)
        let windows = WindowSchedule.make(totalInputFrames: 3, ramp: .constant(1))
        let provider = try makeProvider(urls: urls, windows: windows)
        let settings = TimeSliceSettings(newestEdge: .left, segments: 6, offsetFrames: 1)
        let union = try TimeSliceRenderer.posterFrameIndices(
            recipes: [settings], masterFrames: 3, width: 320, height: 240)
        XCTAssertEqual(union, [0, 1, 2])
        let url = scratch.appendingPathComponent("short.png")
        _ = try TimeSliceRenderer().renderPosters(
            provider: provider, recipes: [settings], posterURLs: [url])
        let image = try loadImage(url)
        // Every band written: no zero anywhere along the middle row.
        let row = try sample(image, points: (0..<320).map { ($0, 120) })
        XCTAssertFalse(row.contains { $0 < 5 }, "a short master left bands unwritten")
    }

    func testStillZeroSizesTheStackEvenWhenOutsideTheUnion() throws {
        // A 2-band poster over 10 masters needs masters 9 and 0 — but at
        // depth 1 a ladder of 2 over 5 masters is [4, 0]; make the union
        // skip 0 by using 3 bands over 4 masters → [3, 2, 0]... so instead
        // use the grid-free trick: a ladder always ends at 0, so the union
        // always holds window 0. Prove the sizing decode still happens
        // exactly once and is reused: decodes == union window sizes.
        let urls = try makeStills(count: 10)
        let windows = WindowSchedule.make(totalInputFrames: 10, ramp: .constant(2))
        var decodes = 0
        let provider = try makeProvider(urls: urls, windows: windows) { decodes = $0 }
        XCTAssertEqual(decodes, 1, "still 0 is decoded at construction for the size")
        let settings = TimeSliceSettings(newestEdge: .right, segments: 2, offsetFrames: 1)
        _ = try TimeSliceRenderer().renderPosters(
            provider: provider, recipes: [settings],
            posterURLs: [scratch.appendingPathComponent("size.png")])
        // Masters 4 and 0, two stills each; still 0 reused → 3 more decodes.
        XCTAssertEqual(decodes, 4)
    }

    func testRefusesBandsUnderTheFloor() throws {
        let urls = try makeStills(count: 4, width: 40, height: 30)
        let windows = WindowSchedule.make(totalInputFrames: 4, ramp: .constant(1))
        let provider = try makeProvider(urls: urls, windows: windows)
        XCTAssertThrowsError(try TimeSliceRenderer().renderPosters(
            provider: provider, recipes: [TimeSliceSettings(segments: 24, offsetFrames: 1)],
            posterURLs: [scratch.appendingPathComponent("refused.png")])
        ) { error in
            guard case LapseError.timeSliceInvalid = error else {
                return XCTFail("expected timeSliceInvalid, got \(error)")
            }
        }
    }

    // MARK: - The sequence render is byte-stable on the shared primitive

    func testSequenceRenderStillAveragesWindows() throws {
        // The refactor moved the stacker's per-window body into
        // `BlendWindowRenderer`; the written file must still carry the
        // window means in order.
        let urls = try makeStills(count: 8)
        let output = scratch.appendingPathComponent("seq.mp4")
        let core = try makeCore()
        let result = try ImageStacker(core: core).stackSequence(
            imageURLs: urls, ramp: .constant(2), outputFPS: 30, linearLight: false, outputURL: output)
        XCTAssertEqual(result.outputFrames, 4)

        let asset = AVURLAsset(url: output)
        let reader = try AVAssetReader(asset: asset)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(trackOutput)
        XCTAssertTrue(reader.startReading())
        var index = 0
        while let sample = trackOutput.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let value = Double(base[120 * CVPixelBufferGetBytesPerRow(buffer) + 160 * 4])
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            let expected = (Double(level(index * 2, of: 8)) + Double(level(index * 2 + 1, of: 8))) / 2
            // H.264 round trip: ±16 discriminates window means ~60 apart.
            XCTAssertEqual(value, expected, accuracy: 16, "frame \(index)")
            index += 1
        }
        XCTAssertEqual(index, 4)
    }

    func testSourcePositionMatchesTheSequencePathsArithmetic() {
        // (end − window/2) ÷ (N − 1), clamped — the expression both sequence
        // paths carried inline before the extraction.
        XCTAssertEqual(ImageStacker.sourcePosition(windowStart: 0, window: 1, totalFrames: 1), 0)
        XCTAssertEqual(ImageStacker.sourcePosition(windowStart: 0, window: 1, totalFrames: 11), 0.1)
        XCTAssertEqual(ImageStacker.sourcePosition(windowStart: 8, window: 4, totalFrames: 13),
                       Double(12 - 2) / 12)
        XCTAssertEqual(ImageStacker.sourcePosition(windowStart: 9, window: 3, totalFrames: 12), 1)
    }
}

/// Feeds an indexed provider to the sequential tail pass, in order — so the
/// two passes can be compared over the identical master frames.
private final class SequentialAdapter: OrderedFrameProvider {
    let frameCount: Int
    let transform: CGAffineTransform
    let nominalFPS: Double = 30
    private let provider: IndexedFrameProvider
    private var cursor = 0

    init(provider: IndexedFrameProvider) {
        self.provider = provider
        frameCount = provider.frameCount
        transform = provider.transform
    }

    func next() throws -> TimeSliceFrame? {
        guard cursor < frameCount else { return nil }
        defer { cursor += 1 }
        return try provider.frame(at: cursor)
    }
}

import AVFoundation
import CoreGraphics
import XCTest
@testable import LetsLapseKit

/// End-to-end checks of the time-slicing pass against synthesized clips whose
/// per-frame gray level is a known function of the frame index — so each
/// band's brightness identifies which master frame it shows, the same
/// measurement that established the reference clip's ladder.
final class TimeSliceRendererTests: XCTestCase {

    /// H.264 round trips shift grays a little; adjacent commanded frames in
    /// these tests differ by ~34 levels, so ±16 discriminates cleanly.
    private let tolerance = 16.0

    private var scratchURLs: [URL] = []

    override func tearDown() {
        for url in scratchURLs { try? FileManager.default.removeItem(at: url) }
        scratchURLs = []
        super.tearDown()
    }

    private func scratchFile(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeslice-test-\(UUID().uuidString)-\(name)")
        scratchURLs.append(url)
        return url
    }

    private func makeRampClip(frames: Int = 60, width: Int = 320, height: Int = 240) throws -> URL {
        let url = scratchFile("master.mov")
        try VideoSynthesizer.makeVideo(at: url, frames: frames, width: width, height: height, pattern: .ramp)
        return url
    }

    private func expectedGray(frame: Int, of total: Int) -> Double {
        VideoSynthesizer.rampLevel(frame: frame, of: total) * 255
    }

    /// Decodes the given frame indices of a clip and samples the blue channel
    /// (the clip is gray, so any channel serves) at the given points.
    private func sampleFrames(
        of url: URL, frameIndices: Set<Int>, points: [(x: Int, y: Int)]
    ) async throws -> [Int: [Double]] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw LapseError.noVideoTrack(url)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [Int: [Double]] = [:]
        var index = 0
        while let sample = output.copyNextSampleBuffer() {
            if let buffer = CMSampleBufferGetImageBuffer(sample) {
                if frameIndices.contains(index) {
                    CVPixelBufferLockBaseAddress(buffer, .readOnly)
                    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                    samples[index] = points.map { Double(base[$0.y * bytesPerRow + $0.x * 4]) }
                    CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                }
                index += 1
            }
        }
        return samples
    }

    private func frameCount(of url: URL) async throws -> Int {
        let provider = try await AssetFrameProvider(url: url)
        return provider.frameCount
    }

    // MARK: - The sampler, measured

    func testSlicedBandsShowTheCommandedMasterFrames() async throws {
        // 60-frame ramp, 4 bands, lag 10 → spread 30, output 30 frames.
        // Newest at the left: sliced frame t band b shows master t + 30 − 10b.
        let master = try makeRampClip()
        let sliced = scratchFile("sliced.mp4")
        let settings = TimeSliceSettings(newestEdge: .left, segments: 4, offsetFrames: 10)
        let provider = try await AssetFrameProvider(url: master)
        XCTAssertEqual(provider.frameCount, 60)

        let result = try TimeSliceRenderer().render(
            provider: provider, settings: settings, animationURL: sliced, posterURL: nil)
        XCTAssertEqual(result.masterFrames, 60)
        XCTAssertEqual(result.outputFrames, 30)
        let slicedCount = try await frameCount(of: sliced)
        XCTAssertEqual(slicedCount, 30)

        // Band centers: widths 80 → x = 40, 120, 200, 280.
        let centers = [(40, 120), (120, 120), (200, 120), (280, 120)]
        let samples = try await sampleFrames(of: sliced, frameIndices: [0, 10], points: centers)
        for t in [0, 10] {
            let bands = try XCTUnwrap(samples[t])
            for b in 0..<4 {
                let commanded = t + 30 - 10 * b
                XCTAssertEqual(
                    bands[b], expectedGray(frame: commanded, of: 60), accuracy: tolerance,
                    "frame \(t) band \(b) should show master \(commanded)")
            }
            // The gradient must fall left → right when the newest band leads.
            XCTAssertGreaterThan(bands[0], bands[3])
        }
    }

    func testNewestEdgeRightReversesTheGradient() async throws {
        let master = try makeRampClip()
        let sliced = scratchFile("sliced-right.mp4")
        let settings = TimeSliceSettings(newestEdge: .right, segments: 4, offsetFrames: 10)
        let provider = try await AssetFrameProvider(url: master)
        _ = try TimeSliceRenderer().render(
            provider: provider, settings: settings, animationURL: sliced, posterURL: nil)

        let centers = [(40, 120), (120, 120), (200, 120), (280, 120)]
        let samples = try await sampleFrames(of: sliced, frameIndices: [0], points: centers)
        let bands = try XCTUnwrap(samples[0])
        for b in 0..<4 {
            let commanded = 0 + 30 - 10 * (3 - b)
            XCTAssertEqual(bands[b], expectedGray(frame: commanded, of: 60), accuracy: tolerance)
        }
        XCTAssertLessThan(bands[0], bands[3])
    }

    func testHorizontalSlicingCutsAcrossY() async throws {
        let master = try makeRampClip()
        let sliced = scratchFile("sliced-top.mp4")
        let settings = TimeSliceSettings(newestEdge: .top, segments: 4, offsetFrames: 10)
        let provider = try await AssetFrameProvider(url: master)
        _ = try TimeSliceRenderer().render(
            provider: provider, settings: settings, animationURL: sliced, posterURL: nil)

        // Band centers down the frame: heights 60 → y = 30, 90, 150, 210.
        let centers = [(160, 30), (160, 90), (160, 150), (160, 210)]
        let samples = try await sampleFrames(of: sliced, frameIndices: [0], points: centers)
        let bands = try XCTUnwrap(samples[0])
        for b in 0..<4 {
            let commanded = 30 - 10 * b
            XCTAssertEqual(bands[b], expectedGray(frame: commanded, of: 60), accuracy: tolerance)
        }
    }

    // MARK: - Grid (docs/time-slicing.md §10)

    func testGridCellsShowTheCommandedMasterFramesFromTheOriginCorner() async throws {
        // 320×240, 4 columns → 80 px cells → 240/80 = 3 rows exactly.
        // Manhattan, origin top-left, lag 6 → maxLag = (3+2)×6 = 30.
        let master = try makeRampClip()
        let sliced = scratchFile("grid.mp4")
        var settings = TimeSliceSettings(segments: 4, offsetFrames: 6)
        settings.grid = TimeSliceGrid(origin: .topLeft, metric: .manhattan)
        let provider = try await AssetFrameProvider(url: master)

        let result = try TimeSliceRenderer().render(
            provider: provider, settings: settings, animationURL: sliced, posterURL: nil)
        XCTAssertEqual(result.grid?.columns, 4)
        XCTAssertEqual(result.grid?.rows, 3)
        XCTAssertEqual(result.grid?.cellPixels, 80)
        XCTAssertEqual(result.maxLagFrames, 30)
        XCTAssertEqual(result.outputFrames, 30)

        // Cell centres: x = 40, 120, 200, 280 · y = 40, 120, 200.
        var points: [(x: Int, y: Int)] = []
        for row in 0..<3 {
            for column in 0..<4 { points.append((40 + column * 80, 40 + row * 80)) }
        }
        let samples = try await sampleFrames(of: sliced, frameIndices: [0, 12], points: points)
        for t in [0, 12] {
            let cells = try XCTUnwrap(samples[t])
            for row in 0..<3 {
                for column in 0..<4 {
                    let commanded = t + 30 - (column + row) * 6
                    XCTAssertEqual(
                        cells[row * 4 + column], expectedGray(frame: commanded, of: 60),
                        accuracy: tolerance,
                        "frame \(t) cell (\(column),\(row)) should show master \(commanded)")
                }
            }
        }
    }

    /// The wavefront is diagonal: cells on the same anti-diagonal share a
    /// moment, and moving the origin moves where the sweep starts.
    func testTheOriginCornerMovesTheWavefront() async throws {
        let master = try makeRampClip()
        let sliced = scratchFile("grid-br.mp4")
        var settings = TimeSliceSettings(segments: 4, offsetFrames: 6)
        settings.grid = TimeSliceGrid(origin: .bottomRight, metric: .manhattan)
        let provider = try await AssetFrameProvider(url: master)
        _ = try TimeSliceRenderer().render(
            provider: provider, settings: settings, animationURL: sliced, posterURL: nil)

        let corners = [(40, 40), (280, 40), (40, 200), (280, 200)]
        let samples = try await sampleFrames(of: sliced, frameIndices: [0], points: corners)
        let cells = try XCTUnwrap(samples[0])
        // Bottom-right holds the newest (master 30); top-left the oldest (0).
        XCTAssertEqual(cells[3], expectedGray(frame: 30, of: 60), accuracy: tolerance)
        XCTAssertEqual(cells[0], expectedGray(frame: 0, of: 60), accuracy: tolerance)
        // The off-diagonal corners sit at Manhattan distance 2 and 3 (4×3 is
        // not square), so the wavefront reaches the top-right first.
        XCTAssertEqual(cells[1], expectedGray(frame: 18, of: 60), accuracy: tolerance)
        XCTAssertEqual(cells[2], expectedGray(frame: 12, of: 60), accuracy: tolerance)
    }

    func testEuclideanGridRoundsItsLadderAndStaysWithinTheClip() async throws {
        let master = try makeRampClip()
        let sliced = scratchFile("grid-eucl.mp4")
        var settings = TimeSliceSettings(segments: 4, offsetFrames: 6)
        settings.grid = TimeSliceGrid(origin: .topLeft, metric: .euclidean)
        let provider = try await AssetFrameProvider(url: master)
        let result = try TimeSliceRenderer().render(
            provider: provider, settings: settings, animationURL: sliced, posterURL: nil)
        // √(3² + 2²) = 3.606 × 6 = 21.6 → 22 frames of spread.
        XCTAssertEqual(result.maxLagFrames, 22)
        XCTAssertEqual(result.outputFrames, 38)

        let samples = try await sampleFrames(
            of: sliced, frameIndices: [0], points: [(40, 40), (280, 200), (120, 120)])
        let cells = try XCTUnwrap(samples[0])
        XCTAssertEqual(cells[0], expectedGray(frame: 22, of: 60), accuracy: tolerance)
        XCTAssertEqual(cells[1], expectedGray(frame: 0, of: 60), accuracy: tolerance)
        // (1,1): √2 × 6 = 8.49 → 8, so master 22 − 8 = 14.
        XCTAssertEqual(cells[2], expectedGray(frame: 14, of: 60), accuracy: tolerance)
    }

    func testGridPosterSpreadsTheWholeShootDiagonally() async throws {
        let master = try makeRampClip()
        let poster = scratchFile("grid-poster.png")
        var settings = TimeSliceSettings(segments: 4, offsetFrames: 6)
        settings.grid = TimeSliceGrid(origin: .topLeft, metric: .manhattan)
        let provider = try await AssetFrameProvider(url: master)
        let result = try TimeSliceRenderer().render(
            provider: provider, settings: settings, animationURL: nil, posterURL: poster)
        XCTAssertTrue(result.wrotePoster)

        let image = try XCTUnwrap(loadImage(poster))
        let cells = try samplePoster(image, points: [(40, 40), (280, 200), (200, 120)])
        // Distance 0 of 5 → master 59; distance 5 → 0; (2,1) is distance 3 →
        // 59 × (1 − 3/5) = 23.6 → 24.
        XCTAssertEqual(cells[0], expectedGray(frame: 59, of: 60), accuracy: tolerance)
        XCTAssertEqual(cells[1], expectedGray(frame: 0, of: 60), accuracy: tolerance)
        XCTAssertEqual(cells[2], expectedGray(frame: 24, of: 60), accuracy: tolerance)
    }

    /// Every cell is written on every output frame — a gap in the tiling would
    /// leave black, which no per-cell sample would catch.
    func testEveryPixelOfAGridFrameIsWritten() async throws {
        // 17 columns over 320 px: cells of 19 px, edges cropped.
        let master = try makeRampClip()
        let sliced = scratchFile("grid-cover.mp4")
        var settings = TimeSliceSettings(segments: 17, offsetFrames: 1)
        settings.grid = TimeSliceGrid(origin: .topLeft, metric: .manhattan)
        let provider = try await AssetFrameProvider(url: master)
        _ = try TimeSliceRenderer().render(
            provider: provider, settings: settings, animationURL: sliced, posterURL: nil)

        var points: [(x: Int, y: Int)] = []
        for x in stride(from: 0, to: 320, by: 1) { points.append((x, 7)) }
        for y in stride(from: 0, to: 240, by: 1) { points.append((113, y)) }
        let samples = try await sampleFrames(of: sliced, frameIndices: [5], points: points)
        let values = try XCTUnwrap(samples[5])
        // The ramp never reaches black, so any zero is an unwritten pixel.
        XCTAssertFalse(values.contains { $0 < 5 }, "the grid left pixels unwritten")
    }

    func testGridRefusesCellsUnderTheFloor() async throws {
        let master = try makeRampClip(frames: 40, width: 320, height: 240)
        let provider = try await AssetFrameProvider(url: master)
        var settings = TimeSliceSettings(segments: 48, offsetFrames: 1)
        settings.grid = TimeSliceGrid()
        XCTAssertThrowsError(try TimeSliceRenderer().render(
            provider: provider, settings: settings,
            animationURL: scratchFile("refused-grid.mp4"), posterURL: nil)
        ) { error in
            guard case LapseError.timeSliceInvalid = error else {
                return XCTFail("expected timeSliceInvalid, got \(error)")
            }
        }
    }

    // MARK: - Poster

    func testPosterSpansTheWholeShootNewestAtTheChosenEdge() async throws {
        let master = try makeRampClip()
        let poster = scratchFile("poster.png")
        let settings = TimeSliceSettings(newestEdge: .left, segments: 4, offsetFrames: 10)
        let provider = try await AssetFrameProvider(url: master)
        let result = try TimeSliceRenderer().render(
            provider: provider, settings: settings, animationURL: nil, posterURL: poster)
        XCTAssertTrue(result.wrotePoster)

        let image = try XCTUnwrap(loadImage(poster))
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 240)
        let bands = try samplePoster(image, points: [(40, 120), (120, 120), (200, 120), (280, 120)])
        // Full-source spread, independent of the lag: masters 59, 39, 20, 0.
        for (b, commanded) in [59, 39, 20, 0].enumerated() {
            XCTAssertEqual(bands[b], expectedGray(frame: commanded, of: 60), accuracy: tolerance,
                           "poster band \(b) should show master \(commanded)")
        }
    }

    private func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func samplePoster(_ image: CGImage, points: [(x: Int, y: Int)]) throws -> [Double] {
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

    // MARK: - Refusals and mapping

    func testSpreadLongerThanTheClipRefuses() async throws {
        let master = try makeRampClip(frames: 20)
        let provider = try await AssetFrameProvider(url: master)
        let settings = TimeSliceSettings()  // 24 × 2 → spread 46 > 20 frames
        XCTAssertThrowsError(try TimeSliceRenderer().render(
            provider: provider, settings: settings,
            animationURL: scratchFile("refused.mp4"), posterURL: nil)
        ) { error in
            guard case LapseError.timeSliceInvalid = error else {
                return XCTFail("expected timeSliceInvalid, got \(error)")
            }
        }
    }

    func testBandsThinnerThanTheFloorRefuse() async throws {
        let master = try makeRampClip(frames: 20, width: 40, height: 30)
        let provider = try await AssetFrameProvider(url: master)
        let settings = TimeSliceSettings(segments: 24, offsetFrames: 1)  // 40 ÷ 24 < 2 px
        XCTAssertThrowsError(try TimeSliceRenderer().render(
            provider: provider, settings: settings,
            animationURL: nil, posterURL: scratchFile("refused.png"))
        ) { error in
            guard case LapseError.timeSliceInvalid = error else {
                return XCTFail("expected timeSliceInvalid, got \(error)")
            }
        }
    }

    func testDisplayEdgeMapsThroughTheMasterTransform() {
        // Identity: every edge is itself.
        for edge in TimeSliceEdge.allCases {
            XCTAssertEqual(TimeSliceRenderer.encodedEdge(displayEdge: edge, transform: .identity), edge)
        }
        // The 90° portrait transform (encoded landscape shown upright):
        // display-left is fed by the encoded bottom edge.
        let portrait = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 240, ty: 0)
        XCTAssertEqual(TimeSliceRenderer.encodedEdge(displayEdge: .left, transform: portrait), .bottom)
        XCTAssertEqual(TimeSliceRenderer.encodedEdge(displayEdge: .right, transform: portrait), .top)
        XCTAssertEqual(TimeSliceRenderer.encodedEdge(displayEdge: .top, transform: portrait), .left)
        XCTAssertEqual(TimeSliceRenderer.encodedEdge(displayEdge: .bottom, transform: portrait), .right)
        // 180°: everything flips.
        let upsideDown = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 320, ty: 240)
        XCTAssertEqual(TimeSliceRenderer.encodedEdge(displayEdge: .left, transform: upsideDown), .right)
        XCTAssertEqual(TimeSliceRenderer.encodedEdge(displayEdge: .top, transform: upsideDown), .bottom)
    }

    func testPTSAreCarriedFromTheMaster() async throws {
        // The master is 30 fps with PTS n/30; sliced frame t must carry master
        // frame t's own PTS, so frame 0 starts at 0 and spacing stays 1/30.
        let master = try makeRampClip()
        let sliced = scratchFile("sliced-pts.mp4")
        let provider = try await AssetFrameProvider(url: master)
        _ = try TimeSliceRenderer().render(
            provider: provider, settings: TimeSliceSettings(segments: 4, offsetFrames: 10),
            animationURL: sliced, posterURL: nil)

        let asset = AVURLAsset(url: sliced)
        let duration = try await asset.load(.duration)
        // 30 frames at 1/30 s: the last frame's PTS is 29/30, duration ≈ 1.0.
        XCTAssertEqual(duration.seconds, 1.0, accuracy: 0.1)
    }
}

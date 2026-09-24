import AVFoundation
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LetsLapseKit

/// Rotate 90° is a record (2026-09-24): a file inside a turned project's
/// folder comes out of every decode funnel turned — ImageIO, raw, a movie's
/// track transform, the video blend — and its bytes never change.
final class TurnedProjectDecodeTests: XCTestCase {

    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("turned-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("Projects/\(UUID().uuidString)", isDirectory: true)
        for folder in ["source", "blends"] {
            try FileManager.default.createDirectory(
                at: project.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try writeDocument(turns: 1, blends: [["outputFileName": "blends/now.png", "renderedQuarterTurns": 1]])
    }

    override func tearDownWithError() throws {
        ProjectOrientation.shared.forget(folder: project)
        try? FileManager.default.removeItem(at: root)
    }

    private func writeDocument(turns: Int, blends: [[String: Any]] = []) throws {
        let document: [String: Any] = ["capture": ["quarterTurns": turns], "blends": blends]
        try JSONSerialization.data(withJSONObject: document)
            .write(to: project.appendingPathComponent("project.json"))
        ProjectOrientation.shared.forget(folder: project)
    }

    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// 4×2: 10 20 30 40 / 50 60 70 80 — no two cells alike.
    private func writePNG(to url: URL) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(
            destination, makeGrayImage(width: 4, height: 2, values: [10, 20, 30, 40, 50, 60, 70, 80]), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testAStillDecodesTurnedAndIsNeverRewritten() throws {
        let url = project.appendingPathComponent("source/frame-0001.png")
        try writePNG(to: url)
        let before = try digest(url)
        // A clockwise quarter: the bottom-left cell leads the top row.
        let turned: [UInt8] = [50, 10, 60, 20, 70, 30, 80, 40]
        let stacked = try ImageStacker.loadImage(at: url)
        XCTAssertEqual(stacked.width, 2)
        XCTAssertEqual(stacked.height, 4)
        XCTAssertEqual(grayValues(of: stacked), turned)
        let decoded = try XCTUnwrap(OrientedDecode.cgImage(url: url, maxPixelSize: 64))
        XCTAssertEqual(grayValues(of: decoded), turned)
        XCTAssertEqual(try digest(url), before, "the file is untouched")

        // The same file outside any project is as stored.
        let loose = root.appendingPathComponent("loose.png")
        try FileManager.default.copyItem(at: url, to: loose)
        XCTAssertEqual(grayValues(of: try ImageStacker.loadImage(at: loose)), [10, 20, 30, 40, 50, 60, 70, 80])
    }

    func testABlendRenderedAtTheTurnIsShownAsItIs() throws {
        let url = project.appendingPathComponent("blends/now.png")
        try writePNG(to: url)
        XCTAssertEqual(grayValues(of: try ImageStacker.loadImage(at: url)), [10, 20, 30, 40, 50, 60, 70, 80])
        // Another turn later, it shows turned by the one it has not got.
        try writeDocument(turns: 2, blends: [["outputFileName": "blends/now.png", "renderedQuarterTurns": 1]])
        XCTAssertEqual(grayValues(of: try ImageStacker.loadImage(at: url)), [50, 10, 60, 20, 70, 30, 80, 40])
    }

    func testARawDecodesTurned() throws {
        // Mid grey — Core Image's raw decoder hands back an empty image for
        // an all-black linear DNG.
        let width = 512, height = 256
        var rgb = Data(capacity: width * height * 6)
        var grey = UInt16(Double(65535) * 0.18).littleEndian
        let sample = withUnsafeBytes(of: &grey) { Data($0) }
        for _ in 0 ..< width * height * 3 { rgb.append(sample) }
        let url = project.appendingPathComponent("source/frame-0001.dng")
        try DNGAuthor.writeLinearDNG(rgb16: rgb, width: width, height: height, preview: nil, to: url)
        let before = try digest(url)
        let raw = try XCTUnwrap(LossyLinearDNG.rawFilter(for: url))
        let extent = try XCTUnwrap(raw.outputImage).extent
        XCTAssertEqual(extent.width, CGFloat(height))
        XCTAssertEqual(extent.height, CGFloat(width))
        XCTAssertEqual(try digest(url), before)

        let loose = root.appendingPathComponent("loose.dng")
        try FileManager.default.copyItem(at: url, to: loose)
        let upright = try XCTUnwrap(LossyLinearDNG.rawFilter(for: loose)?.outputImage).extent
        XCTAssertEqual(upright.width, CGFloat(width))
    }

    func testAMovieAndItsBlendCarryTheTurnInTheTrack() async throws {
        let url = project.appendingPathComponent("source/clip.mov")
        try VideoSynthesizer.makeVideo(at: url, frames: 30, width: 160, height: 120, fps: 30, pattern: .box)
        let before = try digest(url)
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let natural = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)
        let shown = ProjectOrientation.shared.transform(for: url, preferred: preferred, naturalSize: natural)
        XCTAssertEqual(QuarterTurns.displaySize(naturalSize: natural, transform: shown), CGSize(width: 120, height: 160))

        // The blend writes the turned transform, so the clip plays turned
        // wherever it goes; the pixels are the file's, not re-rendered.
        let output = root.appendingPathComponent("blend.mp4")
        let blender = VideoBlender(core: try makeCore())
        _ = try await blender.blend(
            input: url, to: output,
            options: VideoBlendOptions(ramp: .constant(5), outputFPS: 30, codec: .h264, linearLight: true))
        let outTracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        let out = try XCTUnwrap(outTracks.first)
        let outNatural = try await out.load(.naturalSize)
        let outTransform = try await out.load(.preferredTransform)
        let outShown = QuarterTurns.displaySize(naturalSize: outNatural, transform: outTransform)
        XCTAssertEqual(outShown.width, 120, accuracy: 0.5)
        XCTAssertEqual(outShown.height, 160, accuracy: 0.5)
        XCTAssertEqual(try digest(url), before)
    }
}

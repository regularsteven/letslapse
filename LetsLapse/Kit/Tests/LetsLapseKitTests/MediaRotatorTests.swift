import XCTest
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import LetsLapseKit

/// The metadata-only 90°-clockwise rotate: EXIF composition, lossless JPEG
/// tag edits, PNG pixel rotation, and preferredTransform updates for MOV
/// (in-place header rewrite) and MP4 (passthrough export).
final class MediaRotatorTests: XCTestCase {
    private let latitude = 37.7749
    private let longitude = -122.4194

    // MARK: - Composition table

    func testCompositionTableCoversAllEightValues() {
        let expected: [UInt16: UInt16] = [1: 6, 6: 3, 3: 8, 8: 1, 2: 7, 7: 4, 4: 5, 5: 2]
        for (from, to) in expected {
            XCTAssertEqual(MediaRotator.exifRotated90CW[Int(from)], to,
                           "\(from) rotated 90° CW should be \(to)")
        }
    }

    // MARK: - Still helpers

    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rotator-\(UUID().uuidString).\(ext)")
    }

    /// A camera-style JPEG with GPS + EXIF blocks and an asymmetric 3×2 grid.
    private func writeSourceJPEG(to url: URL) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: abs(latitude),
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: abs(longitude),
                kCGImagePropertyGPSLongitudeRef: "W",
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:07:26 10:30:00",
            ],
        ]
        CGImageDestinationAddImage(
            destination,
            makeGrayImage(width: 3, height: 2, values: [10, 20, 30, 40, 50, 60]),
            properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// Raw index-0 decode, deliberately ignoring the orientation tag — equal
    /// values before and after a rotate prove the bitstream wasn't re-encoded.
    private func rawDecode(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func properties(of url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func orientationTag(of url: URL) throws -> Int? {
        (try properties(of: url)[kCGImagePropertyOrientation] as? UInt32).map(Int.init)
    }

    // MARK: - JPEG

    func testRotateJPEGIsMetadataOnlyAndCyclesBack() throws {
        let url = tempURL("jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSourceJPEG(to: url)
        let before = grayValues(of: try rawDecode(url))

        try MediaRotator.rotateStill90CW(at: url)
        XCTAssertEqual(try orientationTag(of: url), 6)
        XCTAssertEqual(grayValues(of: try rawDecode(url)), before,
                       "stored pixels must be byte-identical — metadata-only edit")
        let gps = try XCTUnwrap(try properties(of: url)[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        XCTAssertEqual(gps[kCGImagePropertyGPSLatitude] as? Double ?? -1, abs(latitude), accuracy: 0.001)
        XCTAssertEqual(gps[kCGImagePropertyGPSLongitudeRef] as? String, "W")
        let exif = try XCTUnwrap(try properties(of: url)[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, "2026:07:26 10:30:00")

        try MediaRotator.rotateStill90CW(at: url)
        XCTAssertEqual(try orientationTag(of: url), 3)
        try MediaRotator.rotateStill90CW(at: url)
        XCTAssertEqual(try orientationTag(of: url), 8)
        try MediaRotator.rotateStill90CW(at: url)
        XCTAssertEqual(try orientationTag(of: url) ?? 1, 1, "four rotates return to upright")
        XCTAssertEqual(grayValues(of: try rawDecode(url)), before)
    }

    // MARK: - PNG

    func testRotatePNGRotatesPixelsLosslessly() throws {
        let url = tempURL("png")
        defer { try? FileManager.default.removeItem(at: url) }
        try ImageExporter.write(
            makeGrayImage(width: 3, height: 2, values: [10, 20, 30, 40, 50, 60]),
            to: url, format: .png)

        try MediaRotator.rotateStill90CW(at: url)

        let rotated = try rawDecode(url)
        XCTAssertEqual(rotated.width, 2)
        XCTAssertEqual(rotated.height, 3)
        // Same expectation OrientationTests pins for a 90° CW display rotate.
        let values = grayValues(of: rotated)
        for (index, expected) in [40, 10, 50, 20, 60, 30].enumerated() {
            XCTAssertLessThanOrEqual(abs(Int(values[index]) - expected), 1,
                                     "pixel \(index): got \(values[index]), expected \(expected)")
        }
        let orientation = try orientationTag(of: url)
        XCTAssertTrue(orientation == nil || orientation == 1,
                      "PNG rotation is baked, not tagged")
    }

    // MARK: - Video helpers

    private func videoTrack(of url: URL) async throws -> AVAssetTrack {
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        return try XCTUnwrap(tracks.first)
    }

    private func displaySize(of url: URL) async throws -> CGSize {
        let track = try await videoTrack(of: url)
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    // MARK: - MOV (in-place header rewrite)

    /// Empirically pins the AVMutableMovie in-place `writeHeader` semantics:
    /// transform lands, frames still decode, four rotates restore the
    /// original display size.
    func testRotateMOVUpdatesPreferredTransformInPlace() async throws {
        let url = tempURL("mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try VideoSynthesizer.makeVideo(at: url, frames: 12, width: 64, height: 48, fps: 12)
        let originalDuration = try await AVURLAsset(url: url).load(.duration).seconds

        try await MediaRotator.rotateVideo90CW(at: url)

        let track = try await videoTrack(of: url)
        let transform = try await track.load(.preferredTransform)
        XCTAssertEqual(transform.a, 0, accuracy: 0.0001)
        XCTAssertEqual(transform.b, 1, accuracy: 0.0001)
        XCTAssertEqual(transform.c, -1, accuracy: 0.0001)
        XCTAssertEqual(transform.d, 0, accuracy: 0.0001)
        XCTAssertEqual(transform.tx, 48, accuracy: 0.01, "translation renormalized to the origin")
        XCTAssertEqual(transform.ty, 0, accuracy: 0.01)
        let display = try await displaySize(of: url)
        XCTAssertEqual(display.width, 48, accuracy: 0.01)
        XCTAssertEqual(display.height, 64, accuracy: 0.01)

        // The rewritten file still decodes.
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        let frame = try await generator.image(at: .zero).image
        XCTAssertEqual(frame.width, 48)
        XCTAssertEqual(frame.height, 64)

        for _ in 0..<3 {
            try await MediaRotator.rotateVideo90CW(at: url)
        }
        let restored = try await displaySize(of: url)
        XCTAssertEqual(restored.width, 64, accuracy: 0.01, "four rotates restore the display size")
        XCTAssertEqual(restored.height, 48, accuracy: 0.01)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(duration, originalDuration, accuracy: 0.05, "media data untouched")
    }

    // MARK: - MP4 (passthrough rewrite)

    func testRotateMP4PassthroughKeepsCodecAndDuration() async throws {
        let url = tempURL("mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try VideoSynthesizer.makeVideo(at: url, frames: 12, width: 64, height: 48, fps: 12, fileType: .mp4)
        let originalDuration = try await AVURLAsset(url: url).load(.duration).seconds

        try await MediaRotator.rotateVideo90CW(at: url)

        let track = try await videoTrack(of: url)
        let transform = try await track.load(.preferredTransform)
        XCTAssertEqual(transform.b, 1, accuracy: 0.0001)
        XCTAssertEqual(transform.c, -1, accuracy: 0.0001)
        let display = try await displaySize(of: url)
        XCTAssertEqual(display.width, 48, accuracy: 0.01)
        XCTAssertEqual(display.height, 64, accuracy: 0.01)

        let descriptions = try await track.load(.formatDescriptions)
        let codec = CMFormatDescriptionGetMediaSubType(try XCTUnwrap(descriptions.first))
        XCTAssertEqual(codec, kCMVideoCodecType_H264, "passthrough must not re-encode")
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(duration, originalDuration, accuracy: 0.1)
    }
}

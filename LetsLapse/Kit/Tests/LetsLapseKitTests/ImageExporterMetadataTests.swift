import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LetsLapseKit

/// Metadata carryover for derived images (stacked long exposures, blended
/// frames): the EXIF/GPS/TIFF blocks of a source photo must survive into the
/// PNG/JPEG the exporter writes, while orientation — already baked into the
/// derived pixels — must not come along.
final class ImageExporterMetadataTests: XCTestCase {
    private let latitude = 37.7749
    private let longitude = -122.4194

    private func makeImage(width: Int = 8, height: Int = 8) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.5, green: 0.25, blue: 0.125, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    /// A camera-style source JPEG: GPS fix, EXIF capture time, TIFF identity,
    /// and a non-default orientation.
    private func writeSourceJPEG() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("carryover-src-\(UUID().uuidString).jpg")
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
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Apple",
                kCGImagePropertyTIFFOrientation: 6,
            ],
        ]
        CGImageDestinationAddImage(destination, try makeImage(), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func properties(of url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func assertCarriesFix(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let properties = try properties(of: url)
        let gps = try XCTUnwrap(properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
                                "no GPS dictionary in \(url.lastPathComponent)", file: file, line: line)
        XCTAssertEqual(gps[kCGImagePropertyGPSLatitude] as? Double ?? -1, abs(latitude),
                       accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(gps[kCGImagePropertyGPSLongitudeRef] as? String, "W", file: file, line: line)
        let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
                                 file: file, line: line)
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, "2026:07:26 10:30:00",
                       file: file, line: line)
    }

    func testCarryoverExtractsBlocksAndDropsOrientation() throws {
        let sourceURL = try writeSourceJPEG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let metadata = try XCTUnwrap(ImageExporter.carryoverMetadata(from: sourceURL))
        XCTAssertNotNil(metadata[kCGImagePropertyGPSDictionary])
        XCTAssertNotNil(metadata[kCGImagePropertyExifDictionary])
        let tiff = try XCTUnwrap(metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        XCTAssertEqual(tiff[kCGImagePropertyTIFFMake] as? String, "Apple")
        XCTAssertNil(tiff[kCGImagePropertyTIFFOrientation],
                     "orientation is baked into derived pixels and must not carry over")
    }

    /// The production path for a stacked Photo-mode shot: PNG out, source
    /// metadata in — the fix must survive the round trip.
    func testPNGOutputCarriesGPS() throws {
        let sourceURL = try writeSourceJPEG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("carryover-out-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        try ImageExporter.write(
            try makeImage(), to: outputURL, format: .png,
            metadata: ImageExporter.carryoverMetadata(from: sourceURL))
        try assertCarriesFix(outputURL)
        let orientation = try properties(of: outputURL)[kCGImagePropertyOrientation] as? Int
        XCTAssertTrue(orientation == nil || orientation == 1,
                      "derived output must not re-apply the source rotation")
    }

    /// The live-blend frame path: JPEG out with a GPS dictionary attached.
    func testJPEGOutputCarriesGPS() throws {
        let sourceURL = try writeSourceJPEG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("carryover-out-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        try ImageExporter.write(
            try makeImage(), to: outputURL, format: .jpeg,
            metadata: ImageExporter.carryoverMetadata(from: sourceURL))
        try assertCarriesFix(outputURL)
    }

    /// No metadata argument = the exporter's old behavior, byte-for-byte
    /// stable API for every existing caller.
    func testNilMetadataStillWrites() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("carryover-plain-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try ImageExporter.write(try makeImage(), to: outputURL, format: .png)
        XCTAssertNotNil(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
    }
}

import XCTest
import ImageIO
@testable import LetsLapseKit

/// The contract Phase 0 exists for: a DNG this app authors must report the
/// exposure it was taken at. Before this, an authored blend had no EXIF IFD at
/// all — ISO, shutter, aperture and brightness were simply absent from every
/// blended interval frame, which is what made a shoot impossible to audit
/// afterwards.
final class DNGExposureTests: XCTestCase {
    private let exposure = DNGAuthor.DNGExposure(
        iso: 400,
        exposureDuration: 1.0 / 60,
        aperture: 1.78,
        brightness: 2.5,
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000))

    private func exif(of url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return try XCTUnwrap(
            properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
            "no EXIF dictionary; properties were \(properties.keys)")
    }

    private func assertMatchesExposure(_ exif: [CFString: Any], file: StaticString = #filePath, line: UInt = #line) {
        let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.doubleValue
            ?? (exif[kCGImagePropertyExifISOSpeedRatings] as? NSNumber)?.doubleValue
        XCTAssertEqual(iso, 400, file: file, line: line)
        let shutter = try? XCTUnwrap(exif[kCGImagePropertyExifExposureTime] as? Double)
        XCTAssertEqual(shutter ?? 0, 1.0 / 60, accuracy: 1e-6, file: file, line: line)
        let fNumber = try? XCTUnwrap(exif[kCGImagePropertyExifFNumber] as? Double)
        XCTAssertEqual(fNumber ?? 0, 1.78, accuracy: 1e-4, file: file, line: line)
        let brightness = try? XCTUnwrap(exif[kCGImagePropertyExifBrightnessValue] as? Double)
        XCTAssertEqual(brightness ?? 0, 2.5, accuracy: 1e-4, file: file, line: line)
    }

    func testLinearDNGCarriesExposureTags() throws {
        let width = 1024, height = 768
        let rgb = Data(repeating: 0x40, count: width * height * 6)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("exif-linear-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: url) }
        try DNGAuthor.writeLinearDNG(
            rgb16: rgb, width: width, height: height,
            exif: DNGAuthor.exifTags(exposure),
            preview: nil, to: url)
        assertMatchesExposure(try exif(of: url))
    }

    /// The path a blended interval frame actually takes: camera-native samples,
    /// re-mosaiced, lossless-JPEG tiled. Its IFD layout is hand-built separately
    /// from the linear writer's, so it needs its own proof.
    func testCompressedBayerDNGCarriesExposureTags() throws {
        let width = 1024, height = 768
        var mosaic = [UInt16](repeating: 0, count: width * height)
        for index in 0..<mosaic.count { mosaic[index] = UInt16(2000 + (index % 4000)) }
        var neutral = Data()
        for _ in 0..<3 { neutral.appendU32(1); neutral.appendU32(1) }
        var illuminant = Data(); illuminant.appendU16(21)
        var matrix = Data()
        for value in [10000, 0, 0, 0, 10000, 0, 0, 0, 10000] as [Int32] {
            matrix.appendU32(UInt32(bitPattern: value)); matrix.appendU32(10000)
        }
        let cameraColor = [
            DNGTagValue(tag: 50721, type: 10, count: 9, payload: matrix),
            DNGTagValue(tag: 50728, type: 5, count: 3, payload: neutral),
            DNGTagValue(tag: 50778, type: 3, count: 1, payload: illuminant),
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("exif-bayer-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: url) }
        try DNGAuthor.writeCompressedBayerDNG(
            mosaic: mosaic, width: width, height: height,
            cfaPattern: [0, 1, 1, 2],
            cameraColor: cameraColor,
            exif: DNGAuthor.exifTags(exposure),
            preview: nil, to: url)
        assertMatchesExposure(try exif(of: url))
        // The image itself must still decode — an EXIF IFD spliced into the
        // wrong place would break every offset after it.
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, width)
    }

    /// GPS and EXIF share IFD0's pointer space; adding one must not displace
    /// the other.
    func testExposureAndGPSCoexist() throws {
        let width = 1024, height = 768
        var mosaic = [UInt16](repeating: 0, count: width * height)
        for index in 0..<mosaic.count { mosaic[index] = UInt16(1000 + (index % 3000)) }
        var neutral = Data()
        for _ in 0..<3 { neutral.appendU32(1); neutral.appendU32(1) }
        let cameraColor = [DNGTagValue(tag: 50728, type: 5, count: 3, payload: neutral)]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("exif-gps-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: url) }
        try DNGAuthor.writeCompressedBayerDNG(
            mosaic: mosaic, width: width, height: height,
            cfaPattern: [0, 1, 1, 2],
            cameraColor: cameraColor,
            gps: DNGAuthor.gpsTags(
                latitude: 51.5, longitude: -0.12, altitude: 35,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000)),
            exif: DNGAuthor.exifTags(exposure),
            preview: nil, to: url)
        assertMatchesExposure(try exif(of: url))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let gps = try XCTUnwrap(properties[kCGImagePropertyGPSDictionary as String] as? [String: Any])
        let latitude = try XCTUnwrap(gps[kCGImagePropertyGPSLatitude as String] as? Double)
        XCTAssertEqual(latitude, 51.5, accuracy: 0.001)
    }

    /// EV is only meaningful when aperture, shutter and ISO are all known — a
    /// partial EV is wrong, not approximate.
    func testExposureValueDerivation() {
        // f/1.78, 1/60s, ISO 400 → log2(3.1684 * 60) - 2 ≈ 5.57
        let ev = try? XCTUnwrap(exposure.exposureValue)
        XCTAssertEqual(ev ?? 0, 5.57, accuracy: 0.02)
        XCTAssertNil(DNGAuthor.DNGExposure(iso: 100, aperture: 1.8).exposureValue)
        XCTAssertNil(DNGAuthor.DNGExposure().exposureValue)
    }

    func testReadsExposureFromPhotoMetadataDictionary() {
        let metadata: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifISOSpeedRatings as String: [NSNumber(value: 250)],
                kCGImagePropertyExifExposureTime as String: NSNumber(value: 0.02),
                kCGImagePropertyExifFNumber as String: NSNumber(value: 2.2),
                kCGImagePropertyExifBrightnessValue as String: NSNumber(value: -1.5),
            ]
        ]
        let parsed = DNGAuthor.DNGExposure(photoMetadata: metadata)
        XCTAssertEqual(parsed.iso, 250)
        XCTAssertEqual(parsed.exposureDuration, 0.02)
        XCTAssertEqual(parsed.aperture, 2.2)
        XCTAssertEqual(parsed.brightness, -1.5)
    }

    /// The session document and the per-capture sidecar must round-trip — they
    /// are what a shoot is audited from after the fact.
    func testSessionAndSidecarRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = try XCTUnwrap(CaptureExposureWriter(directory: directory))
        for index in 0..<3 {
            writer.append(CaptureExposureLog.Entry(
                frameIndex: index, exposure: exposure, capturedAt: Date()))
        }
        writer.close()
        let sidecar = try CaptureExposureLog.loadSidecar(from: writer.url)
        XCTAssertEqual(sidecar.count, 3)
        XCTAssertEqual(sidecar[2].frameIndex, 2)
        XCTAssertEqual(sidecar[0].iso, 400)
        XCTAssertNil(sidecar[0].blendCount)

        let session = CaptureExposureLog.Session(
            sessionID: "abc", deviceModel: "iPhone16,1",
            captureMode: "interval", blendMode: "auto",
            frames: [CaptureExposureLog.Entry(
                frameIndex: 1, exposure: exposure, blendCount: 3)])
        let url = try XCTUnwrap(CaptureExposureLog.write(session, toDirectory: directory))
        XCTAssertEqual(url.lastPathComponent, "capture_log.json")
        let loaded = try CaptureExposureLog.loadSession(from: url)
        XCTAssertEqual(loaded.blendMode, "auto")
        XCTAssertEqual(loaded.frames.first?.blendCount, 3)
        XCTAssertEqual(loaded.frames.first?.aperture, 1.78)
    }
}

import XCTest
import ImageIO
@testable import LetsLapseKit

/// GPS geotagging for the DNG path: the authored writers embed a GPS sub-IFD,
/// and pass-through Apple originals get one appended without disturbing the
/// pixel data. Mirrors the JPEG path's `CLLocation.exifGPSDictionary()`, but
/// the DNG writer is hand-rolled so the tags are emitted directly.
final class GPSTaggingTests: XCTestCase {
    // San Francisco, a little above sea level.
    private let latitude = 37.7749
    private let longitude = -122.4194
    private let altitude = 52.0
    private let timestamp = Date(timeIntervalSince1970: 1_690_000_000) // fixed, deterministic

    private func gpsDictionary(of url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return try XCTUnwrap(properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
                             "no GPS dictionary in \(url.lastPathComponent)")
    }

    private func assertMatchesFix(_ gps: [CFString: Any], file: StaticString = #filePath, line: UInt = #line) {
        let lat = gps[kCGImagePropertyGPSLatitude] as? Double
        let lon = gps[kCGImagePropertyGPSLongitude] as? Double
        XCTAssertEqual(gps[kCGImagePropertyGPSLatitudeRef] as? String, "N", file: file, line: line)
        XCTAssertEqual(gps[kCGImagePropertyGPSLongitudeRef] as? String, "W", file: file, line: line)
        XCTAssertEqual(lat ?? -1, abs(latitude), accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(lon ?? -1, abs(longitude), accuracy: 0.001, file: file, line: line)
    }

    // MARK: - Authored paths

    /// A LinearRaw DNG authored with a GPS tag set must still be claimed by the
    /// RAW codec and surface the fix through ImageIO's GPS dictionary.
    func testLinearDNGCarriesGPS() throws {
        let width = 1024, height = 768
        let rgb = Data(count: width * height * 6)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gps-linear-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: url) }

        try DNGAuthor.writeLinearDNG(
            rgb16: rgb, width: width, height: height,
            gps: DNGAuthor.gpsTags(latitude: latitude, longitude: longitude,
                                   altitude: altitude, timestamp: timestamp),
            preview: nil, to: url)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.adobe.raw-image")
        assertMatchesFix(try gpsDictionary(of: url))
    }

    /// The camera-native tiled Bayer path (the production blend output) must
    /// carry GPS and still decode.
    func testCompressedBayerDNGCarriesGPS() throws {
        let width = 1024, height = 768
        var mosaic = [UInt16](repeating: 0, count: width * height)
        for index in 0..<mosaic.count { mosaic[index] = UInt16(2000 + (index % 4000)) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gps-bayer-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: url) }

        try DNGAuthor.writeCompressedBayerDNG(
            mosaic: mosaic, width: width, height: height,
            cfaPattern: [0, 1, 1, 2],
            cameraColor: [
                DNGTagValue(tag: 50721, type: 10, count: 9, payload: {
                    var d = Data()
                    for value in [32406, -15372, -4986, -9689, 18758, 415, 557, -2040, 10570] {
                        d.appendU32(UInt32(bitPattern: Int32(value))); d.appendU32(10000)
                    }
                    return d
                }()),
                DNGTagValue(tag: 50728, type: 5, count: 3, payload: {
                    var d = Data(); for _ in 0..<3 { d.appendU32(1); d.appendU32(1) }; return d
                }()),
                DNGTagValue(tag: 50778, type: 3, count: 1, payload: { var d = Data(); d.appendU16(21); return d }()),
            ],
            gps: DNGAuthor.gpsTags(latitude: latitude, longitude: longitude,
                                   altitude: altitude, timestamp: timestamp),
            preview: nil, to: url)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.adobe.raw-image")
        assertMatchesFix(try gpsDictionary(of: url))
    }

    // MARK: - Pass-through injection

    /// Appending a GPS IFD to an already-authored DNG must add the fix while
    /// leaving the file decodable — the pass-through (blend == 1) path.
    func testInjectGPSIntoAuthoredDNG() throws {
        let width = 1024, height = 768
        let rgb = Data(count: width * height * 6)
        let plainURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gps-inject-src-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: plainURL) }
        try DNGAuthor.writeLinearDNG(rgb16: rgb, width: width, height: height, preview: nil, to: plainURL)

        let original = try Data(contentsOf: plainURL)
        let tagged = DNGAuthor.dngByInsertingGPS(
            into: original, latitude: latitude, longitude: longitude,
            altitude: altitude, timestamp: timestamp)
        XCTAssertGreaterThan(tagged.count, original.count, "injection must append the GPS structures")

        let taggedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gps-inject-out-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: taggedURL) }
        try tagged.write(to: taggedURL)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(taggedURL as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.adobe.raw-image",
                       "the raw image must survive GPS injection")
        assertMatchesFix(try gpsDictionary(of: taggedURL))
    }

    /// Injecting into a file that already has a GPS IFD is a no-op.
    func testInjectGPSIsIdempotent() throws {
        let width = 1024, height = 768
        let rgb = Data(count: width * height * 6)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gps-idem-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: url) }
        try DNGAuthor.writeLinearDNG(
            rgb16: rgb, width: width, height: height,
            gps: DNGAuthor.gpsTags(latitude: latitude, longitude: longitude,
                                   altitude: altitude, timestamp: timestamp),
            preview: nil, to: url)

        let original = try Data(contentsOf: url)
        let again = DNGAuthor.dngByInsertingGPS(
            into: original, latitude: 0, longitude: 0, altitude: 0, timestamp: timestamp)
        XCTAssertEqual(again, original, "a file that already carries GPS must be returned unchanged")
    }

    /// The big-endian branch — the byte order every iPhone original uses.
    /// ImageIO won't claim a hand-built stub as an image, so the GPS IFD is
    /// verified by walking the TIFF directly.
    func testInjectGPSBigEndian() throws {
        // Minimal big-endian ("MM") TIFF: header + a one-entry IFD0.
        var stub = Data([0x4D, 0x4D, 0x00, 0x2A]) // MM, 42
        stub.append(contentsOf: [0x00, 0x00, 0x00, 0x08]) // IFD0 at offset 8
        stub.append(contentsOf: [0x00, 0x01])             // 1 entry
        stub.append(contentsOf: [0x01, 0x00])             // tag 256 (ImageWidth)
        stub.append(contentsOf: [0x00, 0x04])             // type LONG
        stub.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // count 1
        stub.append(contentsOf: [0x00, 0x00, 0x00, 0x10]) // value 16
        stub.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // next IFD 0

        let tagged = DNGAuthor.dngByInsertingGPS(
            into: stub, latitude: latitude, longitude: longitude,
            altitude: altitude, timestamp: timestamp)
        XCTAssertGreaterThan(tagged.count, stub.count)

        // Big-endian readers.
        func u16(_ offset: Int) -> Int {
            Int(tagged[offset]) << 8 | Int(tagged[offset + 1])
        }
        func u32(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 << 8 | Int(tagged[offset + $1]) }
        }
        XCTAssertEqual(tagged[0], 0x4D, "byte order must be preserved")
        let ifd0 = u32(4)
        // Walk IFD0 for the GPSInfoIFDPointer (34853).
        let count0 = u16(ifd0)
        var gpsIFDOffset: Int?
        for index in 0..<count0 {
            let entry = ifd0 + 2 + index * 12
            if u16(entry) == 34853 { gpsIFDOffset = u32(entry + 8) }
        }
        let gps = try XCTUnwrap(gpsIFDOffset, "rebuilt IFD0 must reference a GPS IFD")
        // Walk the GPS IFD for LatitudeRef (1) and Latitude (2).
        let gpsCount = u16(gps)
        var latRef: String?
        var degrees: Int?
        for index in 0..<gpsCount {
            let entry = gps + 2 + index * 12
            switch u16(entry) {
            case 1: latRef = String(UnicodeScalar(tagged[entry + 8]))   // inline ASCII
            case 2: degrees = u32(u32(entry + 8))                       // first rational numerator
            default: break
            }
        }
        XCTAssertEqual(latRef, "N")
        XCTAssertEqual(degrees, 37, "latitude degrees must round-trip in big-endian")
    }
}

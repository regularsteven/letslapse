import XCTest
import ImageIO
@testable import LetsLapseKit

/// Byte-level Orientation (TIFF tag 274) editing for DNGs: the getter's
/// defaults, the in-place inline overwrite (file size unchanged), the
/// append-only IFD0 rebuild for tag-less files, both byte orders, and the
/// interplay with the GPS injector and the authored writers.
final class DNGOrientationTests: XCTestCase {

    // MARK: - Minimal TIFF stubs

    /// A minimal, structurally valid TIFF: header + one IFD0 holding
    /// ImageWidth/ImageLength and optionally an Orientation entry. Not a
    /// decodable image — it exercises the parser, asserted through
    /// `DNGAuthor.dngOrientation`. Entry layout is deterministic: with three
    /// sorted tags (256, 257, 274) the Orientation value bytes sit at 42–43.
    private func stubTIFF(bigEndian: Bool, orientation: UInt16?) -> Data {
        var data = Data()
        func u16Bytes(_ value: UInt16) -> [UInt8] {
            let bytes: [UInt8] = [UInt8(value >> 8), UInt8(value & 0xFF)]
            return bigEndian ? bytes : bytes.reversed()
        }
        func u32Bytes(_ value: UInt32) -> [UInt8] {
            let bytes: [UInt8] = [
                UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
            ]
            return bigEndian ? bytes : bytes.reversed()
        }
        data.append(contentsOf: bigEndian ? [0x4D, 0x4D] : [0x49, 0x49])
        data.append(contentsOf: u16Bytes(42))
        data.append(contentsOf: u32Bytes(8)) // IFD0 immediately after header
        var tags: [(tag: UInt16, type: UInt16, count: UInt32, inline: [UInt8])] = [
            (256, 4, 1, u32Bytes(4)), // ImageWidth
            (257, 4, 1, u32Bytes(4)), // ImageLength
        ]
        if let orientation {
            // SHORT inline: value bytes left-justified, then padding.
            tags.append((274, 3, 1, u16Bytes(orientation) + [0, 0]))
        }
        tags.sort { $0.tag < $1.tag }
        data.append(contentsOf: u16Bytes(UInt16(tags.count)))
        for tag in tags {
            data.append(contentsOf: u16Bytes(tag.tag))
            data.append(contentsOf: u16Bytes(tag.type))
            data.append(contentsOf: u32Bytes(tag.count))
            data.append(contentsOf: tag.inline)
        }
        data.append(contentsOf: u32Bytes(0)) // no next IFD
        return data
    }

    private func differingIndices(_ a: Data, _ b: Data) -> [Int] {
        precondition(a.count == b.count)
        return (0..<a.count).filter { a[a.startIndex + $0] != b[b.startIndex + $0] }
    }

    private func imageIOOrientation(of url: URL) throws -> Int? {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        if let value = properties[kCGImagePropertyOrientation] as? UInt32 { return Int(value) }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        return (tiff?[kCGImagePropertyTIFFOrientation] as? UInt32).map(Int.init)
    }

    // MARK: - Getter

    func testGetterDefaultsToUprightWhenTagAbsent() {
        XCTAssertEqual(DNGAuthor.dngOrientation(in: stubTIFF(bigEndian: false, orientation: nil)), 1)
        XCTAssertEqual(DNGAuthor.dngOrientation(in: stubTIFF(bigEndian: true, orientation: nil)), 1)
        XCTAssertEqual(DNGAuthor.dngOrientation(in: Data([0x00, 0x01, 0x02])), 1, "garbage reads as upright")
    }

    func testGetterReadsBothByteOrders() {
        XCTAssertEqual(DNGAuthor.dngOrientation(in: stubTIFF(bigEndian: false, orientation: 6)), 6)
        XCTAssertEqual(DNGAuthor.dngOrientation(in: stubTIFF(bigEndian: true, orientation: 8)), 8)
    }

    // MARK: - In-place overwrite

    func testInPlaceOverwriteLittleEndian() throws {
        let input = stubTIFF(bigEndian: false, orientation: 1)
        let output = try DNGAuthor.dngBySettingOrientation(input, to: 6)
        XCTAssertEqual(output.count, input.count, "inline SHORT edit must not grow the file")
        XCTAssertEqual(DNGAuthor.dngOrientation(in: output), 6)
        let changed = differingIndices(input, output)
        XCTAssertFalse(changed.isEmpty)
        XCTAssertTrue(Set(changed).isSubset(of: [42, 43]),
                      "only the inline value bytes may change, got \(changed)")
    }

    func testInPlaceOverwriteBigEndian() throws {
        let input = stubTIFF(bigEndian: true, orientation: 3)
        let output = try DNGAuthor.dngBySettingOrientation(input, to: 6)
        XCTAssertEqual(output.count, input.count)
        XCTAssertEqual(DNGAuthor.dngOrientation(in: output), 6)
        XCTAssertEqual(Array(output.prefix(2)), [0x4D, 0x4D], "byte order mark preserved")
        let changed = differingIndices(input, output)
        XCTAssertTrue(Set(changed).isSubset(of: [42, 43]),
                      "only the inline value bytes may change, got \(changed)")
    }

    // MARK: - Append-only rebuild

    func testRebuildAppendsWhenTagAbsent() throws {
        let input = stubTIFF(bigEndian: false, orientation: nil)
        let output = try DNGAuthor.dngBySettingOrientation(input, to: 6)
        XCTAssertGreaterThan(output.count, input.count, "tag-less files gain an appended IFD0")
        XCTAssertEqual(DNGAuthor.dngOrientation(in: output), 6)
        // Everything but the header's IFD0 pointer (bytes 4–7) is preserved.
        XCTAssertEqual(output.prefix(4), input.prefix(4))
        XCTAssertEqual(output.subdata(in: 8..<input.count), input.subdata(in: 8..<input.count))
    }

    func testMalformedInputThrows() {
        XCTAssertThrowsError(try DNGAuthor.dngBySettingOrientation(Data([0x49, 0x49, 42]), to: 6))
        XCTAssertThrowsError(try DNGAuthor.dngBySettingOrientation(Data(repeating: 0xAB, count: 64), to: 6))
    }

    // MARK: - Authored writers declare upright

    func testAuthoredLinearDNGDeclaresUpright() throws {
        let width = 1024, height = 768
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("orient-linear-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: url) }
        try DNGAuthor.writeLinearDNG(
            rgb16: Data(count: width * height * 6), width: width, height: height,
            preview: nil, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(DNGAuthor.dngOrientation(in: data), 1, "authored pixels are display-oriented")
        XCTAssertEqual(try imageIOOrientation(of: url) ?? 1, 1)
    }

    func testAuthoredBayerDNGDeclaresUpright() throws {
        let width = 1024, height = 768
        var mosaic = [UInt16](repeating: 0, count: width * height)
        for index in 0..<mosaic.count { mosaic[index] = UInt16(2000 + (index % 4000)) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("orient-bayer-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: url) }
        try DNGAuthor.writeCompressedBayerDNG(
            mosaic: mosaic, width: width, height: height,
            cfaPattern: [0, 1, 1, 2],
            cameraColor: Self.testCameraColor,
            preview: nil, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(DNGAuthor.dngOrientation(in: data), 1)
        XCTAssertEqual(try imageIOOrientation(of: url) ?? 1, 1)
    }

    // MARK: - Real authored file round trips

    /// The production rotate on an authored DNG: tag exists (the writers now
    /// emit 1), so the edit is in-place — same byte count — and ImageIO agrees.
    func testSetOrientationOnAuthoredDNGIsInPlace() throws {
        let width = 1024, height = 768
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("orient-roundtrip-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: url) }
        try DNGAuthor.writeLinearDNG(
            rgb16: Data(count: width * height * 6), width: width, height: height,
            preview: nil, to: url)
        let input = try Data(contentsOf: url)
        let output = try DNGAuthor.dngBySettingOrientation(input, to: 6)
        XCTAssertEqual(output.count, input.count, "existing tag edits in place")
        XCTAssertEqual(DNGAuthor.dngOrientation(in: output), 6)
        try output.write(to: url, options: .atomic)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.adobe.raw-image",
                       "still claimed by the RAW codec after the edit")
        XCTAssertEqual(try imageIOOrientation(of: url), 6)
    }

    /// A rotated pass-through DNG that later gets geotagged must keep its
    /// orientation: the GPS injector copies IFD0 entry records verbatim.
    func testOrientationSurvivesGPSInjection() throws {
        let width = 1024, height = 768
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("orient-gps-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: url) }
        try DNGAuthor.writeLinearDNG(
            rgb16: Data(count: width * height * 6), width: width, height: height,
            preview: nil, to: url)
        let rotated = try DNGAuthor.dngBySettingOrientation(try Data(contentsOf: url), to: 8)
        let geotagged = DNGAuthor.dngByInsertingGPS(
            into: rotated,
            latitude: 37.7749, longitude: -122.4194, altitude: 52,
            timestamp: Date(timeIntervalSince1970: 1_690_000_000))
        XCTAssertGreaterThan(geotagged.count, rotated.count, "GPS IFD appended")
        XCTAssertEqual(DNGAuthor.dngOrientation(in: geotagged), 8)
        try geotagged.write(to: url, options: .atomic)
        XCTAssertEqual(try imageIOOrientation(of: url), 8)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNotNil(properties[kCGImagePropertyGPSDictionary], "GPS fix still readable")
    }

    /// Identity/typical camera-colour tag set, mirroring GPSTaggingTests.
    private static let testCameraColor: [DNGTagValue] = [
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
        DNGTagValue(tag: 50778, type: 3, count: 1, payload: {
            var d = Data(); d.appendU16(21); return d
        }()),
    ]
}

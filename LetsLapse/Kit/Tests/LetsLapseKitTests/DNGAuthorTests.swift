import XCTest
import CoreVideo
import ImageIO
@testable import LetsLapseKit

final class DNGAuthorTests: XCTestCase {
    // MARK: - Payload builders

    private func shorts(_ values: [UInt16]) -> Data {
        var data = Data()
        for value in values { data.appendU16(value) }
        return data
    }

    private func longs(_ values: [UInt32]) -> Data {
        var data = Data()
        for value in values { data.appendU32(value) }
        return data
    }

    private func rationals(_ values: [(UInt32, UInt32)]) -> Data {
        var data = Data()
        for (numerator, denominator) in values {
            data.appendU32(numerator)
            data.appendU32(denominator)
        }
        return data
    }

    private func srationals(_ values: [(Int32, Int32)]) -> Data {
        var data = Data()
        for (numerator, denominator) in values {
            data.appendU32(UInt32(bitPattern: numerator))
            data.appendU32(UInt32(bitPattern: denominator))
        }
        return data
    }

    /// A minimal but honest reference: RGGB pattern, full 16-bit range, a
    /// plausible camera matrix and as-shot neutral — the same tag set the
    /// runtime harvests from a real capture's DNG.
    private func syntheticReference() -> DNGReference {
        let matrix: [(Int32, Int32)] = [
            (10000, 10000), (-3000, 10000), (-1000, 10000),
            (-4000, 10000), (12000, 10000), (2000, 10000),
            (-500, 10000), (2000, 10000), (6000, 10000),
        ]
        let ifd0: [DNGTagValue] = [
            DNGTagValue(tag: 271, type: 2, count: 10, payload: Data("LetsLapse\0".utf8)),
            DNGTagValue(tag: 272, type: 2, count: 5, payload: Data("Test\0".utf8)),
            DNGTagValue(tag: 274, type: 3, count: 1, payload: shorts([1])),
            DNGTagValue(tag: 50706, type: 1, count: 4, payload: Data([1, 4, 0, 0])),
            DNGTagValue(tag: 50707, type: 1, count: 4, payload: Data([1, 1, 0, 0])),
            DNGTagValue(tag: 50708, type: 2, count: 15, payload: Data("Synthetic Test\0".utf8)),
            DNGTagValue(tag: 50721, type: 10, count: 9, payload: srationals(matrix)),
            DNGTagValue(tag: 50727, type: 5, count: 3,
                        payload: rationals([(1, 1), (1, 1), (1, 1)])),
            DNGTagValue(tag: 50728, type: 5, count: 3,
                        payload: rationals([(5500, 10000), (10000, 10000), (6800, 10000)])),
            DNGTagValue(tag: 50730, type: 10, count: 1, payload: srationals([(0, 100)])),
            DNGTagValue(tag: 50778, type: 3, count: 1, payload: shorts([21])),
        ]
        let raw: [DNGTagValue] = [
            DNGTagValue(tag: 33421, type: 3, count: 2, payload: shorts([2, 2])),
            DNGTagValue(tag: 33422, type: 1, count: 4, payload: Data([0, 1, 1, 2])),
            DNGTagValue(tag: 50710, type: 1, count: 3, payload: Data([0, 1, 2])),
            DNGTagValue(tag: 50711, type: 3, count: 1, payload: shorts([1])),
            DNGTagValue(tag: 50713, type: 3, count: 2, payload: shorts([1, 1])),
            DNGTagValue(tag: 50714, type: 3, count: 1, payload: shorts([0])),
            DNGTagValue(tag: 50717, type: 4, count: 1, payload: longs([65535])),
            DNGTagValue(tag: 50719, type: 5, count: 2, payload: rationals([(0, 1), (0, 1)])),
            DNGTagValue(tag: 50720, type: 5, count: 2, payload: rationals([(1024, 1), (768, 1)])),
            DNGTagValue(tag: 50829, type: 4, count: 4, payload: longs([0, 0, 768, 1024])),
        ]
        let exif: [DNGTagValue] = [
            DNGTagValue(tag: 33434, type: 5, count: 1, payload: rationals([(1, 60)])),
            DNGTagValue(tag: 34855, type: 3, count: 1, payload: shorts([400])),
        ]
        return DNGReference(ifd0: ifd0, raw: raw, exif: exif)
    }

    private func gradientMosaic(width: Int, height: Int) -> Data {
        var pixels = [UInt16](repeating: 0, count: width * height)
        for index in 0..<pixels.count {
            pixels[index] = UInt16((index * 17) % 60000)
        }
        return pixels.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - Author + decode

    // NOTE: CoreRAW declines very small rasters (a 64x64 CFA is sniffed as
    // plain TIFF), so these tests use a realistic-but-fast 1024x768.

    func testAuthoredDNGDecodesThroughImageIO() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dng-test-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: url) }

        try DNGAuthor.writeBayerDNG(
            mosaic: gradientMosaic(width: 1024, height: 768),
            width: 1024, height: 768,
            reference: syntheticReference(),
            preview: nil,
            to: url)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.adobe.raw-image",
                       "the authored file must be claimed by the RAW codec, not plain TIFF")
        XCTAssertGreaterThanOrEqual(CGImageSourceGetCount(source), 1)
        let image = try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(source, 0, nil),
            "Apple's RAW decoder should demosaic the authored DNG")
        XCTAssertEqual(image.width, 1024)
        XCTAssertEqual(image.height, 768)
    }

    /// iPhone DNGs are big-endian ("MM"); every multi-byte payload must be
    /// normalised to little-endian at parse time or copied matrices and
    /// levels would be silently byte-swapped garbage.
    func testParsesBigEndianTIFF() throws {
        var file = Data([0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08])
        func appendBE16(_ value: UInt16) { file.append(UInt8(value >> 8)); file.append(UInt8(value & 0xFF)) }
        func appendBE32(_ value: UInt32) {
            file.append(UInt8((value >> 24) & 0xFF)); file.append(UInt8((value >> 16) & 0xFF))
            file.append(UInt8((value >> 8) & 0xFF)); file.append(UInt8(value & 0xFF))
        }
        // IFD0 @8 with 5 entries; the RATIONAL spills to offset 74.
        appendBE16(5)
        appendBE16(256); appendBE16(4); appendBE32(1); appendBE32(4224)          // ImageWidth LONG
        appendBE16(262); appendBE16(3); appendBE32(1); appendBE16(32803); appendBE16(0) // Photometric SHORT
        appendBE16(33421); appendBE16(3); appendBE32(2); appendBE16(2); appendBE16(2)   // CFARepeatPatternDim
        appendBE16(33422); appendBE16(1); appendBE32(4); file.append(contentsOf: [2, 1, 1, 0]) // CFAPattern BYTE
        appendBE16(50728); appendBE16(5); appendBE32(1); appendBE32(74)          // AsShotNeutral RATIONAL -> offset
        appendBE32(0)                                                            // next IFD
        appendBE32(5500); appendBE32(10000)                                      // the rational at 74

        let reference = try DNGDocument.parseReference(file)
        XCTAssertEqual(reference.raw.first { $0.tag == 256 }.flatMap(DNGDocument.firstShortOrLong), 4224)
        XCTAssertEqual(reference.raw.first { $0.tag == 33421 }.map(DNGDocument.longValues), [2, 2])
        XCTAssertEqual(reference.raw.first { $0.tag == 33422 }.map { Array($0.payload) }, [2, 1, 1, 0])
        let neutral = try XCTUnwrap(reference.raw.first { $0.tag == 50728 })
        XCTAssertEqual(neutral.payload.readU32(at: 0), 5500)
        XCTAssertEqual(neutral.payload.readU32(at: 4), 10000)
    }

    /// The exact runtime path against a real iPhone Bayer DNG when one is
    /// available locally: parse its (big-endian, tiled, compressed) metadata,
    /// author a same-size synthetic mosaic with it, and require the RAW codec
    /// to claim and demosaic the result.
    func testRoundTripsRealIPhoneDNG() throws {
        let realURL = URL(fileURLWithPath: "/Users/stevenwright/Downloads/frame-00001.DNG")
        guard FileManager.default.fileExists(atPath: realURL.path) else {
            throw XCTSkip("no local iPhone reference DNG")
        }
        let reference = try DNGDocument.parseReference(try Data(contentsOf: realURL))
        let width = Int(try XCTUnwrap(reference.raw.first { $0.tag == 256 }.flatMap(DNGDocument.firstShortOrLong)))
        let height = Int(try XCTUnwrap(reference.raw.first { $0.tag == 257 }.flatMap(DNGDocument.firstShortOrLong)))
        XCTAssertGreaterThan(width, 1000)

        var pixels = [UInt16](repeating: 0, count: width * height)
        for index in 0..<pixels.count { pixels[index] = UInt16(800 + (index % 3000)) }
        let mosaic = pixels.withUnsafeBufferPointer { Data(buffer: $0) }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dng-iphone-roundtrip-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: url) }
        try DNGAuthor.writeBayerDNG(
            mosaic: mosaic, width: width, height: height,
            reference: reference, preview: nil, to: url)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.adobe.raw-image",
                       "authored-from-iPhone-metadata DNG must be claimed by the RAW codec")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // Decoders honor DefaultCropSize, trimming the sensor's masked
        // border (4224 -> 4032 on the iPhone 16 Pro), so expect the crop.
        func tagInt(_ entry: DNGTagValue?, index: Int) -> Int? {
            guard let entry else { return nil }
            switch entry.type {
            case 3 where entry.payload.count >= index * 2 + 2:
                return Int(entry.payload.readU16(at: index * 2))
            case 4 where entry.payload.count >= index * 4 + 4:
                return Int(entry.payload.readU32(at: index * 4))
            case 5 where entry.payload.count >= index * 8 + 8:
                let numerator = entry.payload.readU32(at: index * 8)
                let denominator = max(1, entry.payload.readU32(at: index * 8 + 4))
                return Int(numerator / denominator)
            default:
                return nil
            }
        }
        let crop = reference.raw.first { $0.tag == 50720 }
        let expectedWidth = tagInt(crop, index: 0) ?? width
        let expectedHeight = tagInt(crop, index: 1) ?? height
        XCTAssertEqual(image.width, expectedWidth)
        XCTAssertEqual(image.height, expectedHeight)
    }

    /// Full-fidelity regression against a real camera DNG when one is
    /// available locally: re-authoring its own mosaic with its own tags must
    /// still be claimed and demosaiced by the RAW codec.
    func testRoundTripsRealCameraDNG() throws {
        let realURL = URL(fileURLWithPath: "/Users/stevenwright/Pictures/drone/DJI_0117.DNG")
        guard FileManager.default.fileExists(atPath: realURL.path) else {
            throw XCTSkip("no local reference DNG")
        }
        let data = try Data(contentsOf: realURL)
        let reference = try DNGDocument.parseReference(data)
        let width = try XCTUnwrap(reference.raw.first { $0.tag == 256 }.flatMap(DNGDocument.firstShortOrLong))
        let height = try XCTUnwrap(reference.raw.first { $0.tag == 257 }.flatMap(DNGDocument.firstShortOrLong))
        let stripOffset = try XCTUnwrap(reference.raw.first { $0.tag == 273 }.flatMap(DNGDocument.firstShortOrLong))
        let stripCount = try XCTUnwrap(reference.raw.first { $0.tag == 279 }.flatMap(DNGDocument.firstShortOrLong))
        let mosaic = data.subdata(in: Int(stripOffset)..<Int(stripOffset + stripCount))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dng-roundtrip-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: url) }
        try DNGAuthor.writeBayerDNG(
            mosaic: mosaic, width: Int(width), height: Int(height),
            reference: reference, preview: nil, to: url)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.adobe.raw-image")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, Int(width))
        XCTAssertEqual(image.height, Int(height))
    }

    func testAuthoredDNGWithPreviewRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dng-test-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: url) }

        let previewWidth = 32
        let previewHeight = 18
        var rgb = Data(capacity: previewWidth * previewHeight * 3)
        for index in 0..<(previewWidth * previewHeight) {
            rgb.append(UInt8(index % 255))
            rgb.append(UInt8((index * 2) % 255))
            rgb.append(UInt8((index * 3) % 255))
        }

        try DNGAuthor.writeBayerDNG(
            mosaic: gradientMosaic(width: 1024, height: 768),
            width: 1024, height: 768,
            reference: syntheticReference(),
            preview: DNGAuthor.Preview(width: previewWidth, height: previewHeight, rgb: rgb),
            to: url)

        // Our own parser must be able to re-read what we author — that is
        // the same code path used against real capture DNGs at runtime.
        let parsed = try DNGDocument.parseReference(try Data(contentsOf: url))
        let cfa = try XCTUnwrap(parsed.raw.first { $0.tag == 33422 })
        XCTAssertEqual(Array(cfa.payload), [0, 1, 1, 2])
        XCTAssertTrue(parsed.ifd0.contains { $0.tag == 50721 }, "color matrix should be carried")
        XCTAssertTrue(parsed.exif.contains { $0.tag == 33434 }, "exposure time should be carried")

        // And ImageIO should claim it as RAW (full-size primary image) while
        // still offering a fast thumbnail from the embedded preview.
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.adobe.raw-image")
        let primary = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(primary.width, 1024)
        XCTAssertEqual(primary.height, 768)
        let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ] as CFDictionary)
        XCTAssertNotNil(thumbnail)
    }

    /// The mp4-render bug: a DNG with a tiny embedded preview must load at
    /// full raw size through the blend pipeline's image loader, not at the
    /// preview's size.
    func testLoadImageDecodesFullRawNotEmbeddedPreview() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dng-loadimage-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: url) }

        var rgb = Data()
        for _ in 0..<(32 * 24) { rgb.append(90); rgb.append(90); rgb.append(90) }
        try DNGAuthor.writeBayerDNG(
            mosaic: gradientMosaic(width: 1024, height: 768),
            width: 1024, height: 768,
            reference: syntheticReference(),
            preview: DNGAuthor.Preview(width: 32, height: 24, rgb: rgb),
            to: url)

        let image = try ImageStacker.loadImage(at: url)
        XCTAssertGreaterThanOrEqual(max(image.width, image.height), 1024,
            "loader must demosaic the raw, not return the 32px embedded preview")
    }

    func testMissingCFAPatternThrows() {
        var reference = syntheticReference()
        reference.raw.removeAll { $0.tag == 33422 }
        XCTAssertThrowsError(try DNGAuthor.writeBayerDNG(
            mosaic: gradientMosaic(width: 8, height: 8),
            width: 8, height: 8,
            reference: reference,
            preview: nil,
            to: FileManager.default.temporaryDirectory.appendingPathComponent("never.dng")))
    }

    // MARK: - Bayer accumulator

    private func makeMosaicBuffer(width: Int, height: Int, value: UInt16) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_OneComponent16, nil, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw DNGError.unsupportedBuffer("test buffer (\(status))")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<height {
            let pointer = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt16.self)
            for column in 0..<width {
                pointer[column] = value
            }
        }
        return buffer
    }

    func testAccumulatorAveragesMosaics() throws {
        let accumulator = BayerAccumulator()
        try accumulator.accumulate(makeMosaicBuffer(width: 32, height: 32, value: 100))
        try accumulator.accumulate(makeMosaicBuffer(width: 32, height: 32, value: 201))
        XCTAssertEqual(accumulator.frameCount, 2)

        let mosaic = try accumulator.finalizeMosaic()
        XCTAssertEqual(mosaic.count, 32 * 32 * 2)
        for index in 0..<(32 * 32) {
            let value = mosaic.readU16(at: index * 2)
            XCTAssertLessThanOrEqual(abs(Int(value) - 150), 1)
        }
        // Window closed: next accumulate starts fresh.
        try accumulator.accumulate(makeMosaicBuffer(width: 32, height: 32, value: 40))
        let second = try accumulator.finalizeMosaic()
        XCTAssertEqual(second.readU16(at: 0), 40)
    }

    func testAccumulatorRejectsSizeChange() throws {
        let accumulator = BayerAccumulator()
        try accumulator.accumulate(makeMosaicBuffer(width: 32, height: 32, value: 10))
        XCTAssertThrowsError(try accumulator.accumulate(makeMosaicBuffer(width: 16, height: 16, value: 10)))
    }

    func testFinalizeWithoutFramesThrows() {
        XCTAssertThrowsError(try BayerAccumulator().finalizeMosaic())
    }
}

import CoreImage
import XCTest
@testable import LetsLapseKit

/// The archive pipeline end to end on a synthetic Bayer DNG the Kit wrote
/// itself: the mosaic route must be bit-exact, the demosaiced JPEG XL route
/// must render through Apple's decoder like the source.
final class DNGArchiveConverterTests: XCTestCase {

    private func makeSource() throws -> URL {
        let width = 1024, height = 768
        var mosaic = [UInt16](repeating: 0, count: width * height)
        let pattern: [UInt8] = [0, 1, 1, 2]
        for y in 0..<height {
            for x in 0..<width {
                let colour = Int(pattern[((y & 1) << 1) | (x & 1)])
                let fx = Double(x) / Double(width), fy = Double(y) / Double(height)
                // A smooth scene: red ramps across, blue down, green a bowl.
                let value: Double
                switch colour {
                case 0: value = 0.05 + 0.6 * fx
                case 2: value = 0.05 + 0.5 * fy
                default: value = 0.1 + 0.5 * (1 - (fx - 0.5) * (fx - 0.5) * 4 * (fy - 0.5) * (fy - 0.5) * 4)
                }
                mosaic[y * width + x] = UInt16(min(65535, max(0, value * 65535)))
            }
        }
        func srationals(_ values: [Double]) -> Data {
            var data = Data()
            for value in values {
                data.appendU32(UInt32(bitPattern: Int32((value * 10000).rounded())))
                data.appendU32(10000)
            }
            return data
        }
        var neutral = Data()
        for value in [0.5, 1.0, 0.7] { neutral.appendU32(UInt32(value * 10000)); neutral.appendU32(10000) }
        var illuminant = Data()
        illuminant.appendU16(21)
        let tags = [
            DNGTagValue(tag: 50721, type: 10, count: 9, payload: srationals([1.2, -0.4, -0.1, -0.5, 1.5, 0.05, 0.0, 0.2, 0.7])),
            DNGTagValue(tag: 50728, type: 5, count: 3, payload: neutral),
            DNGTagValue(tag: 50778, type: 3, count: 1, payload: illuminant),
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("archive-source-\(UUID().uuidString).dng")
        try DNGAuthor.writeCompressedBayerDNG(
            mosaic: mosaic, width: width, height: height, cfaPattern: pattern,
            cameraColor: tags, headroomStops: 2, preview: nil, to: url)
        return url
    }

    private func appleMeans(_ url: URL) throws -> SIMD3<Double> {
        guard let raw = CIRAWFilter(imageURL: url) else { throw XCTSkip("CIRAWFilter declined \(url.lastPathComponent)") }
        raw.boostAmount = 0
        raw.extendedDynamicRangeAmount = 2
        raw.scaleFactor = 0.5
        guard let image = raw.outputImage, let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else {
            throw XCTSkip("no output")
        }
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAh])
        let extent = image.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        var pixels = [Float](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: extent, format: .RGBAf, colorSpace: space)
        }
        var mean = SIMD3<Double>.zero
        for i in stride(from: 0, to: pixels.count, by: 4) {
            mean += SIMD3<Double>(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
        }
        return mean / Double(w * h)
    }

    func testLosslessMosaicRouteIsBitExactAndSmaller() throws {
        let source = try makeSource()
        defer { try? FileManager.default.removeItem(at: source) }
        let output = source.deletingPathExtension().appendingPathExtension("mosaic.dng")
        defer { try? FileManager.default.removeItem(at: output) }
        let converter = DNGArchive.Converter()
        let report = try converter.convert(source, to: output, strategy: .losslessMosaic)
        XCTAssertEqual(report.decodePath, "native-lj92")
        XCTAssertEqual(report.width, 1024)
        XCTAssertEqual(report.height, 768)
        // The mosaic must come back sample for sample.
        let before = try DNGArchive.NativeDecoder.decode(url: source).frame
        let after = try DNGDocument.parseDirectories(try Data(contentsOf: output))
        let raw = ([after.ifd0] + after.subIFDs).first { $0.int(262) == 32803 }!
        XCTAssertEqual(raw.int(259), 52546, "JPEG XL tiles")
        // Decode our own JXL tiles through ImageIO and compare the plane.
        let offsets = raw.tag(324)!.ints, counts = raw.tag(325)!.ints
        let data = try Data(contentsOf: output)
        let tileWidth = raw.int(322)!, tileHeight = raw.int(323)!
        let across = (1024 + tileWidth - 1) / tileWidth
        var mismatches = 0
        for (index, offset) in offsets.enumerated() {
            let tile = data.subdata(in: offset..<(offset + counts[index]))
            guard let src = CGImageSourceCreateWithData(tile as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  let bytes = image.dataProvider?.data as Data? else { return XCTFail("tile \(index) did not decode") }
            XCTAssertEqual(image.bitsPerComponent, 16)
            let spp = image.bitsPerPixel / 16
            let x0 = (index % across) * tileWidth, y0 = (index / across) * tileHeight
            for y in 0..<min(tileHeight, 768 - y0) {
                for x in 0..<min(tileWidth, 1024 - x0) {
                    let value: UInt16 = bytes.withUnsafeBytes { $0.load(fromByteOffset: y * image.bytesPerRow + x * spp * 2, as: UInt16.self) }
                    if value != before.samples[(y0 + y) * 1024 + x0 + x] { mismatches += 1 }
                }
            }
        }
        XCTAssertEqual(mismatches, 0, "lossless JPEG XL mosaic is not the source mosaic")
        XCTAssertLessThan(report.outputBytes, report.inputBytes, "JPEG XL lossless should be under lossless JPEG")
        print(String(format: "  mosaic: %.2f MB → %.2f MB in %.0f ms", Double(report.inputBytes) / 1e6, Double(report.outputBytes) / 1e6, report.totalMilliseconds))
    }

    func testArchiveRouteRendersLikeTheSourceAndCarriesBaselineExposure() throws {
        let source = try makeSource()
        defer { try? FileManager.default.removeItem(at: source) }
        let output = source.deletingPathExtension().appendingPathExtension("archive.dng")
        defer { try? FileManager.default.removeItem(at: output) }
        let converter = DNGArchive.Converter()
        let strategy = DNGArchive.Strategy.archive(megapixels: 0.5, distance: 0.5)
        let report = try converter.convert(source, to: output, strategy: strategy)
        XCTAssertLessThan(report.width * report.height, 520_000)
        XCTAssertGreaterThan(report.width * report.height, 480_000)
        XCTAssertLessThan(report.outputBytes, report.inputBytes / 3)

        let directories = try DNGDocument.parseDirectories(try Data(contentsOf: output))
        XCTAssertEqual(directories.ifd0.doubles(50730), [2.0], "the source's BaselineExposure travels")
        XCTAssertEqual(directories.ifd0.doubles(50714).count, 3, "levels once per sample")
        XCTAssertNotNil(directories.ifd0.tag(50712), "gamma table carrier")
        XCTAssertEqual(directories.ifd0.ints(52554), [5], "effort 5")

        let a = try appleMeans(source), b = try appleMeans(output)
        for c in 0..<3 {
            XCTAssertEqual(b[c], a[c], accuracy: max(0.004, a[c] * 0.03), "channel \(c): archive renders like the source")
        }
        print(String(format: "  archive: %dx%d %.2f MB → %.2f MB in %.0f ms; source R %.4f G %.4f B %.4f, archive R %.4f G %.4f B %.4f",
                     report.width, report.height, Double(report.inputBytes) / 1e6, Double(report.outputBytes) / 1e6, report.totalMilliseconds,
                     a.x, a.y, a.z, b.x, b.y, b.z))
    }

    /// Apple's own DNGs code each Bayer tile as a two-component lossless JPEG
    /// of half the width; the native decoder must read that layout too.
    func testNativeDecoderReadsTwoComponentCFATiles() throws {
        let width = 1024, height = 512, tile = 256
        var mosaic = [UInt16](repeating: 0, count: width * height)
        for i in 0..<mosaic.count { mosaic[i] = UInt16((i * 7919) % 65536) }
        var tiles: [Data] = []
        for row in 0..<(height / tile) {
            for column in 0..<(width / tile) {
                var block = [UInt16](repeating: 0, count: tile * tile)
                for y in 0..<tile {
                    for x in 0..<tile { block[y * tile + x] = mosaic[(row * tile + y) * width + column * tile + x] }
                }
                // Half the width, two interleaved components: the same samples.
                tiles.append(try LosslessJPEG.encode(interleaved: block, width: tile / 2, height: tile, components: 2))
            }
        }
        let image = DNGArchive.Image(
            width: width, height: height, samplesPerPixel: 1, bitsPerSample: 16,
            photometric: .cfa(pattern: [0, 1, 1, 2], rows: 2, columns: 2), compression: .losslessJPEG,
            tileWidth: tile, tileHeight: tile, tiles: tiles, levels: .uniform(black: 0, white: 65535))
        var metadata = DNGArchive.Metadata()
        metadata.ifd0 = DNGArchive.sRGBColorTags()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("two-component-\(UUID().uuidString).dng")
        try DNGArchive.write(image: image, metadata: metadata, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(DNGArchive.NativeDecoder.canDecode(url))
        let decoded = try DNGArchive.NativeDecoder.decode(url: url).frame
        XCTAssertEqual(decoded.samples, mosaic, "two-component tiles must land as the mosaic")
    }

    /// A single-IFD source (Apple's camera DNGs) keeps CFA geometry, ActiveArea
    /// and opcode lists in IFD0. None of it may reach a LinearRaw archive, the
    /// masked border must be cropped away, and the validator must catch the
    /// shape Lightroom refused.
    func testSingleIFDSourceGeometryDoesNotLeakAndActiveAreaIsCropped() throws {
        // A raw-in-IFD0 CFA DNG with a masked 64-column border on the right.
        let width = 1088, height = 512, activeRight = 1024
        var mosaic = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width { mosaic[y * width + x] = x < activeRight ? UInt16(2000 + (x + y) % 3000) : 0 }
        }
        var tiles: [Data] = []
        for row in 0..<(height / 256) {
            for column in 0..<((width + 255) / 256) {
                var block = [UInt16](repeating: 0, count: 256 * 256)
                for y in 0..<256 {
                    for x in 0..<256 { block[y * 256 + x] = mosaic[(row * 256 + y) * width + min(width - 1, column * 256 + x)] }
                }
                tiles.append(try LosslessJPEG.encode(samples: block, width: 256, height: 256))
            }
        }
        let image = DNGArchive.Image(
            width: width, height: height, samplesPerPixel: 1, bitsPerSample: 16,
            photometric: .cfa(pattern: [0, 1, 1, 2], rows: 2, columns: 2), compression: .losslessJPEG,
            tileWidth: 256, tileHeight: 256, tiles: tiles, levels: .uniform(black: 0, white: 65535))
        var metadata = DNGArchive.Metadata()
        metadata.ifd0 = DNGArchive.sRGBColorTags()
        metadata.raw = [
            DNGTagValue(tag: 50829, type: 4, count: 4, payload: { var d = Data(); for v: UInt32 in [0, 0, UInt32(height), UInt32(activeRight)] { d.appendU32(v) }; return d }()),
            DNGTagValue(tag: 51022, type: 7, count: 4, payload: Data([0, 0, 0, 0])),
        ]
        // The writer filters raw tags to a whitelist; force these two in the
        // way a camera would write them, by editing the built data's IFD0.
        var data = try DNGArchive.makeDNG(image: image, metadata: metadata)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("single-ifd-\(UUID().uuidString).dng")
        // Re-author with ActiveArea and an opcode list present in the raw IFD
        // via the reference writer (it carries raw tags verbatim).
        let parsed = try DNGDocument.parseDirectories(data)
        var rawTags = parsed.ifd0
        rawTags.append(metadata.raw[0])
        rawTags.append(metadata.raw[1])
        rawTags.append(DNGArchive.rationalTag(50720, [Double(activeRight), Double(height)]))
        data = try DNGAuthor.makeDNGData(
            image: mosaic.withUnsafeBufferPointer { Data(buffer: $0) }, width: width, height: height,
            samplesPerPixel: 1, photometric: 32803,
            reference: DNGReference(ifd0: rawTags, raw: rawTags), preview: nil)
        try data.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let check = try DNGDocument.parseDirectories(data)
        XCTAssertNotNil(check.ifd0.tag(50829), "fixture carries ActiveArea in IFD0")
        XCTAssertNotNil(check.ifd0.tag(33422), "fixture carries CFAPattern in IFD0")
        XCTAssertTrue(DNGArchive.validate(data).isEmpty, "the fixture itself is a valid CFA DNG: \(DNGArchive.validate(data))")

        // Native decode crops to the active area…
        let decoded = try DNGArchive.NativeDecoder.decode(url: source).frame
        XCTAssertEqual(decoded.width, activeRight)
        XCTAssertEqual(decoded.height, height)
        XCTAssertEqual(decoded.samples[activeRight - 1], mosaic[activeRight - 1])
        // …and its carried colour tags hold no geometry.
        for tag: UInt16 in [33421, 33422, 50710, 50711, 50829, 51022, 50720, 50714, 50717] {
            XCTAssertNil(decoded.metadata.colorTags.tag(tag), "tag \(tag) leaked into the carried colour tags")
        }

        // The archive of it is valid and Adobe-shaped: LinearRaw, no CFA tags, crop inside the image.
        let output = source.deletingPathExtension().appendingPathExtension("archive.dng")
        defer { try? FileManager.default.removeItem(at: output) }
        let report = try DNGArchive.Converter().convert(source, to: output, strategy: .archive(megapixels: nil, distance: 0.5))
        XCTAssertEqual(report.width, activeRight)
        let archived = try Data(contentsOf: output)
        XCTAssertTrue(DNGArchive.validate(archived).isEmpty, "\(DNGArchive.validate(archived))")
        let outTags = try DNGDocument.parseDirectories(archived).ifd0
        XCTAssertNil(outTags.tag(33422))
        XCTAssertNil(outTags.tag(50829))
        XCTAssertNil(outTags.tag(51022))
        XCTAssertEqual(outTags.doubles(50720), [Double(activeRight), Double(height)])

        // And the validator names the leak when it is forced through.
        var leaky = DNGArchive.Metadata()
        leaky.ifd0 = DNGArchive.sRGBColorTags()
        let linear = DNGArchive.Image(
            width: 64, height: 64, samplesPerPixel: 3, bitsPerSample: 16, photometric: .linearRaw, compression: .none,
            tileWidth: 64, tileHeight: 64, tiles: [Data(count: 64 * 64 * 6)], levels: .uniform(black: 0, white: 65535))
        var bad = try DNGDocument.parseDirectories(try DNGArchive.makeDNG(image: linear, metadata: leaky)).ifd0
        bad.append(DNGTagValue(tag: 33422, type: 1, count: 4, payload: Data([0, 1, 1, 2])))
        bad.append(DNGTagValue(tag: 50829, type: 4, count: 4, payload: { var d = Data(); for v: UInt32 in [0, 0, 64, 32] { d.appendU32(v) }; return d }()))
        bad.append(DNGArchive.rationalTag(50719, [0, 0]))
        bad.append(DNGArchive.rationalTag(50720, [64, 64]))   // wider than the 32-column active area
        let badData = try DNGAuthor.makeDNGData(
            image: Data(count: 64 * 64 * 6), width: 64, height: 64, samplesPerPixel: 3, photometric: 34892,
            reference: DNGReference(ifd0: bad, raw: bad), preview: nil)
        let issues = DNGArchive.validate(badData)
        XCTAssertTrue(issues.contains { $0.contains("CFA tag") }, "\(issues)")
        XCTAssertTrue(issues.contains { $0.contains("DefaultCrop") }, "\(issues)")
    }

    func testSequenceConversionReportsProgressAndStops() throws {
        let sources = try (0..<3).map { _ in try makeSource() }
        defer { sources.forEach { try? FileManager.default.removeItem(at: $0) } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("archive-seq-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let converter = DNGArchive.Converter()
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var values: [Int] = []
            func add(_ value: Int) { lock.lock(); values.append(value); lock.unlock() }
        }
        let seen = Seen()
        let result = converter.convert(files: sources, to: directory, strategy: .losslessMosaic, inFlight: 2) { snapshot in
            seen.add(snapshot.framesDone)
        }
        XCTAssertEqual(result.reports.count, 3)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(seen.values.sorted(), [1, 2, 3])
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.count, 3)

        // A run told to stop before it starts produces nothing.
        let stopped = converter.convert(files: sources, to: directory, strategy: .losslessMosaic, inFlight: 1, shouldContinue: { false })
        XCTAssertTrue(stopped.reports.isEmpty)
    }
}

extension DNGArchiveConverterTests {
    /// A GainMap in OpcodeList3 must be baked into a demosaiced archive: a flat
    /// field under a map that doubles the red gain on the right half comes out
    /// with red doubled on the right half.
    func testGainMapFromOpcodeList3IsBakedIntoTheArchive() throws {
        let width = 512, height = 256
        var mosaic = [UInt16](repeating: 0, count: width * height)
        let pattern: [UInt8] = [0, 1, 1, 2]
        for y in 0..<height {
            for x in 0..<width {
                let colour = Int(pattern[((y & 1) << 1) | (x & 1)])
                mosaic[y * width + x] = UInt16(([0.25, 0.5, 0.125][colour]) * 65535)
            }
        }
        var tiles: [Data] = []
        for column in 0..<2 {
            var block = [UInt16](repeating: 0, count: 256 * 256)
            for y in 0..<256 { for x in 0..<256 { block[y * 256 + x] = mosaic[y * width + column * 256 + x] } }
            tiles.append(try LosslessJPEG.encode(samples: block, width: 256, height: 256))
        }
        // OpcodeList3 with one GainMap, 3 map planes, 2×2 points: red gain 1 on
        // the left column of points and 2 on the right; green and blue 1.
        var blob = Data()
        func u32(_ v: UInt32) { blob.append(contentsOf: withUnsafeBytes(of: v.bigEndian, Array.init)) }
        func f64(_ v: Double) { blob.append(contentsOf: withUnsafeBytes(of: v.bitPattern.bigEndian, Array.init)) }
        func f32(_ v: Float) { blob.append(contentsOf: withUnsafeBytes(of: v.bitPattern.bigEndian, Array.init)) }
        u32(1)
        u32(9); u32(0x0103_0000); u32(0); u32(76 + 2 * 2 * 3 * 4)
        u32(0); u32(0); u32(UInt32(height)); u32(UInt32(width))      // area
        u32(0); u32(3); u32(1); u32(1)                                // plane 0, 3 planes, pitch 1×1
        u32(2); u32(2)                                                // points V, H
        f64(1.0); f64(1.0)                                            // spacing V, H (two points span 0…1)
        f64(0); f64(0)                                                // origin
        u32(3)                                                        // map planes
        for _ in 0..<2 {          // rows
            f32(1); f32(1); f32(1)      // left point: r g b
            f32(2); f32(1); f32(1)      // right point: red ×2
        }
        let image = DNGArchive.Image(
            width: width, height: height, samplesPerPixel: 1, bitsPerSample: 16,
            photometric: .cfa(pattern: pattern, rows: 2, columns: 2), compression: .losslessJPEG,
            tileWidth: 256, tileHeight: 256, tiles: tiles, levels: .uniform(black: 0, white: 65535))
        var metadata = DNGArchive.Metadata()
        metadata.ifd0 = DNGArchive.sRGBColorTags()
        metadata.opcodeLists = [51022: blob]
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("gainmap-\(UUID().uuidString).dng")
        try DNGArchive.write(image: image, metadata: metadata, to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let decoded = try DNGArchive.NativeDecoder.decode(url: source).frame
        XCTAssertEqual(decoded.metadata.opcodeLists[51022], blob, "the source's opcode list rides along")
        let parsed = try DNGArchive.parseOpcodes(blob)
        XCTAssertEqual(parsed.gainMaps.count, 1)
        XCTAssertEqual(parsed.gainMaps[0].pointsH, 2)
        XCTAssertEqual(parsed.gainMaps[0].gains, [1, 1, 1, 2, 1, 1, 1, 1, 1, 2, 1, 1])

        let demosaicer = try MetalDemosaicOrSkip()
        let rgb = try demosaicer.run(decoded, method: .mhc, targetPixels: nil, gainMaps: parsed.gainMaps).frame
        func pixel(_ x: Int, _ y: Int) -> [Float] { (0..<3).map { rgb.samples[(y * rgb.width + x) * 3 + $0] } }
        // Left edge: gain ≈ 1 (u ≈ 0); right edge: red gain ≈ 2 (u ≈ 1); middle ≈ 1.5.
        XCTAssertEqual(pixel(1, 100)[0], 0.25 * (1 + 1.5 / 512), accuracy: 0.004)
        XCTAssertEqual(pixel(width - 2, 100)[0], 0.25 * (2 - 1.5 / 512), accuracy: 0.004)
        XCTAssertEqual(pixel(width / 2, 100)[0], 0.25 * 1.5, accuracy: 0.004)
        XCTAssertEqual(pixel(width / 2, 100)[1], 0.5, accuracy: 0.002)
        XCTAssertEqual(pixel(width / 2, 100)[2], 0.125, accuracy: 0.002)

        // The archive route bakes it and carries no opcode list; the mosaic
        // route carries the list verbatim.
        let archive = source.deletingPathExtension().appendingPathExtension("archive.dng")
        defer { try? FileManager.default.removeItem(at: archive) }
        let report = try DNGArchive.Converter().convert(source, to: archive, strategy: .archive(megapixels: nil, distance: 0))
        XCTAssertTrue(report.notes.contains { $0.contains("baked 1 GainMap") }, "\(report.notes)")
        XCTAssertNil(try DNGDocument.parseDirectories(try Data(contentsOf: archive)).ifd0.tag(51022))
        let mosaicCopy = source.deletingPathExtension().appendingPathExtension("mosaic.dng")
        defer { try? FileManager.default.removeItem(at: mosaicCopy) }
        _ = try DNGArchive.Converter().convert(source, to: mosaicCopy, strategy: .losslessMosaic)
        XCTAssertEqual(try DNGDocument.parseDirectories(try Data(contentsOf: mosaicCopy)).ifd0.tag(51022)?.payload, blob)
    }

    private func MetalDemosaicOrSkip() throws -> DNGArchive.MetalDemosaic {
        do { return try DNGArchive.MetalDemosaic() } catch { throw XCTSkip("no Metal: \(error)") }
    }
}

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

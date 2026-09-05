import CoreImage
import ImageIO
import XCTest
@testable import LetsLapseKit

/// The general tiled writer: containers it produces must open in Apple's
/// decoder without the `LossyLinearDNG` repack, carry their levels and codec
/// tags where the Kit's own parser finds them, and render a curve carried
/// as a LinearizationTable — or as a polynomial over a zero black level —
/// to the same picture as the plain linear file.
final class DNGArchiveTests: XCTestCase {

    private let width = 512, height = 384

    /// A smooth synthetic scene in 16-bit linear RGB, R G B interleaved.
    private func scene() -> [UInt16] {
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 3
                let fx = Double(x) / Double(width - 1), fy = Double(y) / Double(height - 1)
                samples[i] = UInt16(min(65535, 3000 + fx * 50000))
                samples[i + 1] = UInt16(min(65535, 2000 + fy * 40000))
                samples[i + 2] = UInt16(min(65535, 1000 + (fx * fy) * 60000))
            }
        }
        return samples
    }

    private func tiles(of samples: [UInt16], components: Int, tile: Int, transform: (UInt16) -> UInt16 = { $0 }) throws -> [Data] {
        try tilesOf(samples, width: width, height: height, components: components, tile: tile, transform: transform)
    }

    private func tilesOf(_ samples: [UInt16], width: Int, height: Int, components: Int, tile: Int, transform: (UInt16) -> UInt16 = { $0 }) throws -> [Data] {
        let across = (width + tile - 1) / tile, down = (height + tile - 1) / tile
        var tiles: [Data] = []
        for row in 0..<down {
            for column in 0..<across {
                var block = [UInt16](repeating: 0, count: tile * tile * components)
                for y in 0..<tile {
                    let sy = min(row * tile + y, height - 1)
                    for x in 0..<tile {
                        let sx = min(column * tile + x, width - 1)
                        for c in 0..<components {
                            block[(y * tile + x) * components + c] = transform(samples[(sy * width + sx) * components + c])
                        }
                    }
                }
                tiles.append(try LosslessJPEG.encode(interleaved: block, width: tile, height: tile, components: components))
            }
        }
        return tiles
    }

    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(name)-\(UUID().uuidString).dng")
        try data.write(to: url)
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

    // MARK: - Container

    /// ImageIO's raw sniff refuses CFA DNGs narrower than ~700 px (measured
    /// 2026-09-05: 640 wide → `public.tiff` and no decode, 768 wide →
    /// `com.adobe.raw-image`; `CIRAWFilter` opens both), so the CFA fixture
    /// is a realistic 1024×768 rather than the 512×384 scene above.
    func testCFALosslessJPEGContainerOpensAsRaw() throws {
        let width = 1024, height = 768
        var mosaic = [UInt16](repeating: 0, count: width * height)
        for i in 0..<mosaic.count { mosaic[i] = UInt16(2000 + (i % 4000)) }
        let tiles = try tilesOf(mosaic, width: width, height: height, components: 1, tile: 256)
        let image = DNGArchive.Image(
            width: width, height: height, samplesPerPixel: 1, bitsPerSample: 16,
            photometric: .cfa(pattern: [0, 1, 1, 2], rows: 2, columns: 2), compression: .losslessJPEG,
            tileWidth: 256, tileHeight: 256, tiles: tiles, levels: .uniform(black: 0, white: 65535))
        var metadata = DNGArchive.Metadata()
        metadata.ifd0 = DNGArchive.sRGBColorTags()
        let data = try DNGArchive.makeDNG(image: image, metadata: metadata)
        let url = try write(data, "cfa")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.adobe.raw-image")
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, width)
        XCTAssertEqual(decoded.height, height)
        guard case .declined = LossyLinearDNG.inspect(data) else { return XCTFail("a lossless CFA file must not need the repack") }

        let parsed = try DNGDocument.parseReference(data)
        XCTAssertEqual(parsed.raw.int(259), 7)
        XCTAssertEqual(parsed.raw.tag(33422)?.ints, [0, 1, 1, 2])
        XCTAssertEqual(parsed.ifd0.tag(50706)?.ints, [1, 4, 0, 0])
        XCTAssertEqual(parsed.ifd0.tag(50707)?.ints, [1, 1, 0, 0])
    }

    func testJPEGXLContainerCarriesItsTagsWhereTheRepackParserFindsThem() throws {
        // Container only: the tiles are placeholders, the point is the tag set.
        let tile = Data([0xFF, 0x0A, 1, 2, 3, 4])
        let image = DNGArchive.Image(
            width: 1000, height: 700, samplesPerPixel: 3, bitsPerSample: 16,
            photometric: .linearRaw, compression: .jpegXL(distance: 0.5, effort: 7, decodeSpeed: 4),
            tileWidth: 400, tileHeight: 400, tiles: Array(repeating: tile, count: 6),
            levels: .uniform(black: 2048, white: 65535))
        var metadata = DNGArchive.Metadata()
        metadata.ifd0 = DNGArchive.sRGBColorTags()
        metadata.defaultCropOrigin = [0, 0]
        metadata.defaultCropSize = [1000, 700]
        metadata.originalRawFileName = "_WEX0001.ARW"
        let data = try DNGArchive.makeDNG(image: image, metadata: metadata)

        guard case .applicable(let plan) = LossyLinearDNG.inspect(data) else {
            return XCTFail("a JPEG XL LinearRaw container is exactly what the repack parser recognises")
        }
        XCTAssertEqual(plan.width, 1000)
        XCTAssertEqual(plan.height, 700)
        XCTAssertEqual(plan.compression, 52546)
        XCTAssertEqual(plan.tileWidth, 400)
        XCTAssertEqual(plan.tileHeight, 400)
        XCTAssertEqual(plan.tileOffsets.count, 6)
        XCTAssertEqual(plan.blackLevels, [2048, 2048, 2048])
        XCTAssertEqual(plan.whiteLevels, [65535, 65535, 65535])
        XCTAssertEqual(plan.polynomials, Array(repeating: [0, 1], count: 3), "no opcodes were written")

        let directories = try DNGDocument.parseDirectories(data)
        XCTAssertEqual(directories.ifd0.tag(50706)?.ints, [1, 7, 0, 0])
        XCTAssertEqual(directories.ifd0.tag(50707)?.ints, [1, 7, 0, 0])
        XCTAssertEqual(directories.ifd0.tag(50827)?.text, "_WEX0001.ARW")
        XCTAssertEqual(directories.ifd0.doubles(52553), [0.5])
        XCTAssertEqual(directories.ifd0.ints(52554), [7])
        XCTAssertEqual(directories.ifd0.ints(52555), [4])
        XCTAssertEqual(directories.ifd0.doubles(50720), [1000, 700])
    }

    func testRefusesAPolynomialOverANonZeroBlackLevel() {
        let image = DNGArchive.Image(
            width: 8, height: 8, samplesPerPixel: 3, bitsPerSample: 16,
            photometric: .linearRaw, compression: .none, tileWidth: 8, tileHeight: 8,
            tiles: [Data(count: 8 * 8 * 6)],
            levels: DNGArchive.Levels(black: [100], white: [65535], mapPolynomials: Array(repeating: [0, 0.1, 0, 0.9], count: 3)))
        XCTAssertThrowsError(try DNGArchive.makeDNG(image: image, metadata: DNGArchive.Metadata()))
    }

    // MARK: - Rendering

    /// The plain file, a LinearizationTable file and a MapPolynomial-over-
    /// zero-black file of the same scene must render to the same picture
    /// through Apple's decoder. This is the fold-free rendering guarantee
    /// the archive writer rests on.
    func testCurvesCarriedByTableOrPolynomialRenderLikeThePlainFile() throws {
        let linear = scene()

        // Plain: 3-component lossless JPEG, no curve.
        let plainTiles = try tiles(of: linear, components: 3, tile: 256)
        let plain = DNGArchive.Image(
            width: width, height: height, samplesPerPixel: 3, bitsPerSample: 16,
            photometric: .linearRaw, compression: .losslessJPEG, tileWidth: 256, tileHeight: 256,
            tiles: plainTiles, levels: .uniform(black: 0, white: 65535))
        var metadata = DNGArchive.Metadata()
        metadata.ifd0 = DNGArchive.sRGBColorTags()
        let plainURL = try write(try DNGArchive.makeDNG(image: plain, metadata: metadata), "plain")
        defer { try? FileManager.default.removeItem(at: plainURL) }

        // Table: store v = 65535·(L/65535)^(1/2.2), table[v] = 65535·(v/65535)^2.2.
        let gamma = 2.2
        var table = [UInt16](repeating: 0, count: 65536)
        for v in 0..<65536 { table[v] = UInt16((pow(Double(v) / 65535, gamma) * 65535).rounded()) }
        let tableTiles = try tiles(of: linear, components: 3, tile: 256) { sample in
            UInt16((pow(Double(sample) / 65535, 1 / gamma) * 65535).rounded())
        }
        let tabled = DNGArchive.Image(
            width: width, height: height, samplesPerPixel: 3, bitsPerSample: 16,
            photometric: .linearRaw, compression: .losslessJPEG, tileWidth: 256, tileHeight: 256,
            tiles: tableTiles, levels: DNGArchive.Levels(black: [0], white: [65535], linearizationTable: table))
        let tableURL = try write(try DNGArchive.makeDNG(image: tabled, metadata: metadata), "table")
        defer { try? FileManager.default.removeItem(at: tableURL) }

        // Polynomial: store x = 65535·g(L), with L = P(x) = 0.1x + 0.9x³ (Adobe's cubic shape).
        let c1 = 0.1, c3 = 0.9
        func inverse(_ target: Double) -> Double {
            // Monotonic cubic: bisection is plenty at 16 bits.
            var lo = 0.0, hi = 1.0
            for _ in 0..<40 {
                let mid = (lo + hi) / 2
                if c1 * mid + c3 * mid * mid * mid < target { lo = mid } else { hi = mid }
            }
            return (lo + hi) / 2
        }
        let polyTiles = try tiles(of: linear, components: 3, tile: 256) { sample in
            UInt16((inverse(Double(sample) / 65535) * 65535).rounded())
        }
        let poly = DNGArchive.Image(
            width: width, height: height, samplesPerPixel: 3, bitsPerSample: 16,
            photometric: .linearRaw, compression: .losslessJPEG, tileWidth: 256, tileHeight: 256,
            tiles: polyTiles, levels: DNGArchive.Levels(black: [0], white: [65535], mapPolynomials: Array(repeating: [0, c1, 0, c3], count: 3)))
        let polyURL = try write(try DNGArchive.makeDNG(image: poly, metadata: metadata), "poly")
        defer { try? FileManager.default.removeItem(at: polyURL) }

        let plainMeans = try appleMeans(plainURL)
        let tableMeans = try appleMeans(tableURL)
        let polyMeans = try appleMeans(polyURL)
        print(String(format: "  plain R %.5f G %.5f B %.5f", plainMeans.x, plainMeans.y, plainMeans.z))
        print(String(format: "  table R %.5f G %.5f B %.5f", tableMeans.x, tableMeans.y, tableMeans.z))
        print(String(format: "  poly  R %.5f G %.5f B %.5f", polyMeans.x, polyMeans.y, polyMeans.z))
        XCTAssertGreaterThan(plainMeans.y, 0.01, "the plain file rendered black — the container is wrong before any curve question")
        for c in 0..<3 {
            XCTAssertEqual(tableMeans[c], plainMeans[c], accuracy: plainMeans[c] * 0.01, "LinearizationTable channel \(c)")
            XCTAssertEqual(polyMeans[c], plainMeans[c], accuracy: plainMeans[c] * 0.01, "MapPolynomial channel \(c)")
        }
    }

    /// Three-component lossless JPEG must decode through Apple to the same
    /// picture as the same samples written as an uncompressed strip.
    func testThreeComponentLosslessJPEGMatchesUncompressed() throws {
        let linear = scene()
        let tilesLJ = try tiles(of: linear, components: 3, tile: 128)
        let image = DNGArchive.Image(
            width: width, height: height, samplesPerPixel: 3, bitsPerSample: 16,
            photometric: .linearRaw, compression: .losslessJPEG, tileWidth: 128, tileHeight: 128,
            tiles: tilesLJ, levels: .uniform(black: 0, white: 65535))
        var metadata = DNGArchive.Metadata()
        metadata.ifd0 = DNGArchive.sRGBColorTags()
        let compressedURL = try write(try DNGArchive.makeDNG(image: image, metadata: metadata), "lj3")
        defer { try? FileManager.default.removeItem(at: compressedURL) }

        var raw = Data(capacity: linear.count * 2)
        for value in linear { raw.appendU16(value) }
        var white = Data()
        for _ in 0..<3 { white.appendU16(65535) }
        let reference = DNGReference(
            ifd0: [DNGTagValue(tag: 50706, type: 1, count: 4, payload: Data([1, 4, 0, 0]))] + DNGArchive.sRGBColorTags(),
            raw: [DNGTagValue(tag: 50717, type: 3, count: 3, payload: white)])
        let uncompressed = try DNGAuthor.makeDNGData(
            image: raw, width: width, height: height, samplesPerPixel: 3, photometric: 34892,
            reference: reference, preview: nil)
        let uncompressedURL = try write(uncompressed, "strip")
        defer { try? FileManager.default.removeItem(at: uncompressedURL) }

        let a = try appleMeans(compressedURL), b = try appleMeans(uncompressedURL)
        for c in 0..<3 {
            XCTAssertEqual(a[c], b[c], accuracy: max(1e-4, b[c] * 0.005), "channel \(c)")
        }
    }

    /// A pedestal must be written once per sample: Apple's decoder renders a
    /// single-value BlackLevel on LinearRaw as a bright colour wash. The
    /// writer expands it, and the pedestal file renders like the plain one.
    func testPedestalIsWrittenPerSampleAndRendersLikeThePlainFile() throws {
        let linear = scene()
        let plainTiles = try tiles(of: linear, components: 3, tile: 256)
        var metadata = DNGArchive.Metadata()
        metadata.ifd0 = DNGArchive.sRGBColorTags()
        let plain = DNGArchive.Image(
            width: width, height: height, samplesPerPixel: 3, bitsPerSample: 16,
            photometric: .linearRaw, compression: .losslessJPEG, tileWidth: 256, tileHeight: 256,
            tiles: plainTiles, levels: .uniform(black: 0, white: 65535))
        let plainURL = try write(try DNGArchive.makeDNG(image: plain, metadata: metadata), "plain2")
        defer { try? FileManager.default.removeItem(at: plainURL) }

        let pedestal = 2048.0
        let pedestalTiles = try tiles(of: linear, components: 3, tile: 256) { sample in
            UInt16((pedestal + Double(sample) / 65535 * (65535 - pedestal)).rounded())
        }
        let pedestalled = DNGArchive.Image(
            width: width, height: height, samplesPerPixel: 3, bitsPerSample: 16,
            photometric: .linearRaw, compression: .losslessJPEG, tileWidth: 256, tileHeight: 256,
            tiles: pedestalTiles, levels: .uniform(black: pedestal, white: 65535))
        let data = try DNGArchive.makeDNG(image: pedestalled, metadata: metadata)
        let parsed = try DNGDocument.parseDirectories(data)
        XCTAssertEqual(parsed.ifd0.doubles(50714), [2048, 2048, 2048], "BlackLevel expanded to one value per sample")
        XCTAssertEqual(parsed.ifd0.ints(50717), [65535, 65535, 65535])
        let pedestalURL = try write(data, "pedestal")
        defer { try? FileManager.default.removeItem(at: pedestalURL) }

        let a = try appleMeans(plainURL), b = try appleMeans(pedestalURL)
        for c in 0..<3 {
            XCTAssertEqual(b[c], a[c], accuracy: a[c] * 0.01, "channel \(c) with a pedestal")
        }
    }

    func testCapabilityProbeRuns() {
        let report = DNGCapabilityProbe.run(tryJPEGXLSession: true)
        XCTAssertFalse(report.videoEncoders.isEmpty)
        XCTAssertTrue(report.imageIODecodesJPEGXL || report.os.hasPrefix("macOS 13") || report.os.hasPrefix("macOS 14"))
        print(DNGCapabilityProbe.text(report))
    }
}

extension DNGArchiveTests {
    /// The toe carrier (the lossy default): its LinearizationTable must invert
    /// the encoder across the whole range, the toe's slope must continue below
    /// the pedestal down to the table floor (negative noise survives, never
    /// clipped to black), and Apple must render a toe-carried file like the
    /// plain file — the same fold-free guarantee the gamma table has.
    func testToeCarrierRoundTripsAndRendersLikeThePlainFile() throws {
        let gamma = 2.2, toe = 0.0033, pedestal = 12288
        let encoding = DNGArchive.StoredEncoding(curve: .toeLUT(gamma: gamma, toe: toe), bitsPerSample: 16, pedestal: pedestal)
        let levels = encoding.levels(samplesPerPixel: 3)
        let table = try XCTUnwrap(levels.linearizationTable)
        XCTAssertEqual(table.count, 65536)
        XCTAssertEqual(levels.black, [Double(pedestal)])

        // Independent statement of the curve: F(L) = a·L below t, c·L^(1/γ)+d above,
        // matched in value and slope at t, F(1) = 1.
        let tg = pow(toe, 1 / gamma)
        let c = 1 / (1 + tg * (1 / gamma - 1)), d = 1 - c, a = (c / gamma) * pow(toe, 1 / gamma - 1)
        XCTAssertEqual(a * toe, c * tg + d, accuracy: 1e-12, "value-matched at the toe")
        XCTAssertEqual(c + d, 1, accuracy: 1e-12)
        // 160 codes per twelve-bit count at black, ~77 counts of negative range.
        let codesPerCount = a * Double(65535 - pedestal) / 3567
        XCTAssertEqual(codesPerCount, 160, accuracy: 5)
        let floorCounts = Double(pedestal) / (a * Double(65535 - pedestal)) * 3567
        XCTAssertEqual(floorCounts, 77, accuracy: 3)

        // Encode a ramp from the floor to 1.0 and read it back through the table.
        let floor = -Double(pedestal) / (a * Double(65535 - pedestal))
        let count = 4096
        let ramp = (0..<count).map { Float(floor + (1 - floor) * Double($0) / Double(count - 1)) }
        var stored = [UInt16](repeating: 0, count: count)
        ramp.withUnsafeBufferPointer { encoding.encode16($0.baseAddress!, count: count, into: &stored) }
        XCTAssertEqual(stored[0], 0, "the floor lands on code 0")
        XCTAssertEqual(stored[count - 1], 65535)
        var worst = 0.0
        for i in 0..<count {
            let back = (Double(table[Int(stored[i])]) - Double(pedestal)) / Double(65535 - pedestal)
            worst = max(worst, abs(back - Double(ramp[i])))
        }
        // The table's output is quantised to 16-bit linearized units (1/53247
        // ≈ 1.9e-5 of the range) and one stored code at the top of the gamma
        // branch is worth γ/c ≈ 2.1 linearized codes: the round trip is exact
        // to that quantisation, measured 2.8e-5.
        XCTAssertLessThan(worst, 6e-5, "table inverts the encoder to within the 16-bit quantisation")
        // Monotonic table, and the toe is linear: equal code steps, equal light steps.
        XCTAssertTrue(zip(table, table.dropFirst()).allSatisfy { $0 <= $1 })
        let step1 = Double(table[pedestal + 100]) - Double(table[pedestal])
        let step2 = Double(table[pedestal + 200]) - Double(table[pedestal + 100])
        XCTAssertEqual(step1, step2, accuracy: 2)

        // Apple renders the toe file like the plain file.
        let linear = scene()
        let plainTiles = try tiles(of: linear, components: 3, tile: 256)
        let plain = DNGArchive.Image(
            width: width, height: height, samplesPerPixel: 3, bitsPerSample: 16,
            photometric: .linearRaw, compression: .losslessJPEG, tileWidth: 256, tileHeight: 256,
            tiles: plainTiles, levels: .uniform(black: 0, white: 65535))
        var metadata = DNGArchive.Metadata()
        metadata.ifd0 = DNGArchive.sRGBColorTags()
        let plainURL = try write(try DNGArchive.makeDNG(image: plain, metadata: metadata), "plain-toe")
        defer { try? FileManager.default.removeItem(at: plainURL) }
        let toeTiles = try tiles(of: linear, components: 3, tile: 256) { sample in
            var one = Float(sample) / 65535
            var code: UInt16 = 0
            encoding.encode16(&one, count: 1, into: &code)
            return code
        }
        let toed = DNGArchive.Image(
            width: width, height: height, samplesPerPixel: 3, bitsPerSample: 16,
            photometric: .linearRaw, compression: .losslessJPEG, tileWidth: 256, tileHeight: 256,
            tiles: toeTiles, levels: levels)
        let toeURL = try write(try DNGArchive.makeDNG(image: toed, metadata: metadata), "toe")
        defer { try? FileManager.default.removeItem(at: toeURL) }
        XCTAssertEqual(DNGArchive.validate(try Data(contentsOf: toeURL)), [])
        let plainMeans = try appleMeans(plainURL), toeMeans = try appleMeans(toeURL)
        for channel in 0..<3 {
            XCTAssertEqual(toeMeans[channel], plainMeans[channel], accuracy: plainMeans[channel] * 0.01, "toe carrier channel \(channel)")
        }
    }
}

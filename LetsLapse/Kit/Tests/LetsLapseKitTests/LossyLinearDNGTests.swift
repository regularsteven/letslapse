import CoreImage
import Metal
import XCTest
@testable import LetsLapseKit

/// Adobe lossy DNGs (JPEG XL, resized or not) must decode to the same
/// picture as the camera's own ARW.
///
/// ## The fixtures
///
/// Four projects on the external volume hold the same 486-frame Sony
/// ILCE-7M4 dusk→night sequence in four containers, all converted from the
/// same ARWs with Adobe DNG Converter 18.6:
///
/// | project    | what                                       | per frame |
/// |------------|--------------------------------------------|-----------|
/// | `E854D311` | the ARWs straight from the camera          | 18.7 MB   |
/// | `93F772E0` | DNG, lossless CFA, no size optimisation    | 12.2 MB   |
/// | `8E67730E` | DNG, lossy JPEG XL, full size              |  1.9 MB   |
/// | `B91FD599` | DNG, lossy JPEG XL, resized to 10 MP       |  1.3 MB   |
///
/// The ARW is the gold standard: it is what the camera saw, decoded by the
/// same Apple pipeline every other container goes through. `B91FD599` is the
/// container that matters — resize *and* lossy is the archival win — and
/// before `LossyLinearDNG` it rendered as a yellow-green wash in this app and
/// in Preview alike (green ×3, blue ÷3 on the dusk frame; blue gone on the
/// night frames). The tests skip when the volume is not mounted, the way
/// `RawDecodePathTests` does.
///
/// ## What "the same picture" means here
///
/// Means over the whole frame and over an 8×6 grid of blocks, per channel, in
/// the engine's linear Display P3 — so a tile placed in the wrong spot, a
/// plane swapped, or a black level applied to the wrong channel fails
/// loudly, while the few-percent difference Apple's pipeline has *anyway*
/// between an ARW and any DNG of it (its own Sony profile versus the DNG's
/// colour matrices) passes. The lossless CFA DNG is measured against the ARW
/// on the same terms as a control: the lossy containers are held to within
/// a few points of what that control achieves.
final class LossyLinearDNGTests: XCTestCase {

    // MARK: - Fixtures

    private static let root = URL(fileURLWithPath: "/Volumes/letslapse/Projects")
    private static let arwProject = "E854D311-96E3-49EC-8179-146DBC896E18"
    private static let cfaProject = "93F772E0-973C-45B2-B362-095E4D017BA1"
    private static let lossyFullProject = "8E67730E-51DF-427D-AA31-B6EDEC5BDE74"
    private static let lossy10MPProject = "B91FD599-3931-490D-A3A0-61D4E2563E8E"

    /// Dusk, dark, and night — the black levels Adobe picks climb through
    /// the sequence and the night frames are where the noise floor is most
    /// of the picture.
    private static let frames = ["_WEX3879", "_WEX4159", "_WEX4319"]

    private static func frame(_ project: String, _ name: String, ext: String) -> URL {
        root.appendingPathComponent(project).appendingPathComponent("source")
            .appendingPathComponent("\(name).\(ext)")
    }

    private func requireFixtures() throws {
        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: Self.frame(Self.lossy10MPProject, Self.frames[0], ext: "dng").path),
            "lossy DNG fixtures unavailable — mount /Volumes/letslapse")
    }

    // MARK: - Measurement

    /// Whole-frame and 8×6-block channel means of a frame decoded through the
    /// engine's own decoder at the editor's quarter scale.
    private struct Means {
        let whole: SIMD3<Double>
        let blocks: [SIMD3<Double>]   // row-major, 8 across × 6 down
    }

    private static let blocksAcross = 8, blocksDown = 6

    private func decodeMeans(_ url: URL) throws -> Means {
        let decoder = try LinearFrameDecoder()
        let frame = try decoder.decode(url: url, scale: 0.25)
        let texture = frame.texture
        let width = texture.width, height = texture.height
        var pixels = [Float16](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!, bytesPerRow: width * 8,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        var whole = SIMD3<Double>.zero
        var blocks = [SIMD3<Double>](repeating: .zero, count: Self.blocksAcross * Self.blocksDown)
        var counts = [Int](repeating: 0, count: blocks.count)
        for y in 0..<height {
            let by = min(Self.blocksDown - 1, y * Self.blocksDown / height)
            for x in 0..<width {
                let i = (y * width + x) * 4
                let rgb = SIMD3<Double>(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
                whole += rgb
                let bx = min(Self.blocksAcross - 1, x * Self.blocksAcross / width)
                blocks[by * Self.blocksAcross + bx] += rgb
                counts[by * Self.blocksAcross + bx] += 1
            }
        }
        return Means(
            whole: whole / Double(width * height),
            blocks: zip(blocks, counts).map { $0 / Double(max(1, $1)) })
    }

    private func report(_ label: String, _ rgb: SIMD3<Double>) {
        print(String(
            format: "  %-34@ R %.5f  G %.5f  B %.5f", label as NSString, rgb.x, rgb.y, rgb.z))
    }

    /// Largest per-channel relative error of `candidate` against `reference`
    /// over the values that are well above the noise floor, and the largest
    /// absolute error over all of them.
    ///
    /// The block floor matters. Below ~0.02 linear the two demosaics disagree
    /// by *design*: Apple's decode of the camera file lifts the deepest
    /// shadows where Adobe's does not, and the ratio of two near-zero means
    /// says nothing about the container. Measured 2026-09-05: Adobe's own
    /// lossless linear conversion of the dusk frame shows the same 0.2–0.7×
    /// bottom-row ratios against the ARW that the lossy repack does, and the
    /// two agree with each other within 2% — see
    /// `testRepack_matchesAdobesOwnLosslessLinearConversion`.
    private func compare(
        _ candidate: Means, to reference: Means, blockFloor: Double = 0.02
    ) -> (wholeRelative: Double, blockRelative: Double, blockAbsolute: Double) {
        func relative(_ a: SIMD3<Double>, _ b: SIMD3<Double>, floor: Double) -> Double {
            var worst = 0.0
            for c in 0..<3 where b[c] >= floor {
                worst = max(worst, abs(a[c] - b[c]) / b[c])
            }
            return worst
        }
        let whole = relative(candidate.whole, reference.whole, floor: 0.002)
        var blockRelative = 0.0, blockAbsolute = 0.0, worstBlock = -1
        for (index, (a, b)) in zip(candidate.blocks, reference.blocks).enumerated() {
            let r = relative(a, b, floor: blockFloor)
            if r > blockRelative { blockRelative = r; worstBlock = index }
            for c in 0..<3 { blockAbsolute = max(blockAbsolute, abs(a[c] - b[c])) }
        }
        if worstBlock >= 0 {
            let a = candidate.blocks[worstBlock], b = reference.blocks[worstBlock]
            print(String(
                format: "    worst block %d (row %d, col %d): candidate R %.4f G %.4f B %.4f  reference R %.4f G %.4f B %.4f",
                worstBlock, worstBlock / Self.blocksAcross, worstBlock % Self.blocksAcross,
                a.x, a.y, a.z, b.x, b.y, b.z))
        }
        return (whole, blockRelative, blockAbsolute)
    }

    // MARK: - Inspection

    func testInspect_recognisesTheResizedLossyFile() throws {
        try requireFixtures()
        let url = Self.frame(Self.lossy10MPProject, "_WEX3879", ext: "dng")
        guard case .applicable(let plan) = LossyLinearDNG.inspect(url: url) else {
            return XCTFail("the 10 MP lossy frame was declined")
        }
        XCTAssertEqual(plan.width, 3872)
        XCTAssertEqual(plan.height, 2581)
        XCTAssertEqual(plan.compression, 52546, "JPEG XL")
        XCTAssertEqual(plan.bitsPerSample, 16)
        XCTAssertEqual(plan.tileOffsets.count, plan.tilesAcross * plan.tilesDown)
        XCTAssertEqual(plan.blackLevels, [394, 50, 2454], "per-plane black levels, as rationals")
        XCTAssertEqual(plan.whiteLevels, [65535, 65535, 65535])
        XCTAssertEqual(plan.polynomials.count, 3)
        for polynomial in plan.polynomials {
            XCTAssertEqual(polynomial.count, 4, "cubic")
            XCTAssertEqual(polynomial[0], 0)
            XCTAssertEqual(polynomial[2], 0)
        }
        XCTAssertEqual(plan.polynomials[1][3], 0.9375, accuracy: 1e-6)
        XCTAssertLessThan(plan.polynomials[2][3], 0.8, "blue's polynomial is scaled to its own maximum")
        XCTAssertTrue(LossyLinearDNG.isApplicable(url))
    }

    func testInspect_declinesTheContainersAppleAlreadyDecodesRight() throws {
        try requireFixtures()
        let cfa = Self.frame(Self.cfaProject, "_WEX3879", ext: "dng")
        guard case .declined(let why) = LossyLinearDNG.inspect(url: cfa) else {
            return XCTFail("the lossless CFA DNG must be left alone")
        }
        XCTAssertTrue(why.contains("LinearRaw"), why)
        XCTAssertFalse(LossyLinearDNG.isApplicable(cfa))
        XCTAssertFalse(LossyLinearDNG.isApplicable(Self.frame(Self.arwProject, "_WEX3879", ext: "ARW")))
    }

    func testInspect_declinesGarbage() {
        guard case .declined = LossyLinearDNG.inspect(Data(repeating: 0x42, count: 512)) else {
            return XCTFail("random bytes were accepted")
        }
        guard case .declined = LossyLinearDNG.inspect(Data([0x49, 0x49, 42, 0, 8, 0, 0, 0])) else {
            return XCTFail("an empty TIFF was accepted")
        }
    }

    // MARK: - The arithmetic

    /// Stage 2 of the DNG pipeline with the plane's polynomial folded in:
    /// black subtracted, white scaled, cubic applied — and values below black
    /// stay negative rather than clipping.
    func testLinearise_matchesTheSpecAndKeepsNegatives() {
        let plane = LossyLinearDNG.PlaneConstants(
            black: 2454, white: 65535, coefficients: [0, 0.051486, 0, 0.772289])
        func spec(_ v: Double) -> Double {
            let x = (v - 2454) / (65535 - 2454)
            return 0.051486 * x + 0.772289 * x * x * x
        }
        for v in [2454.0, 3000, 8000, 21359, 40000, 65535] {
            XCTAssertEqual(plane.linearise(v), spec(v), accuracy: 1e-12, "at \(v)")
        }
        XCTAssertEqual(plane.linearise(2454), 0, accuracy: 1e-15)
        XCTAssertLessThan(plane.linearise(1000), 0, "sub-black noise is preserved, not clipped")
        XCTAssertEqual(plane.linearise(65535), 0.051486 + 0.772289, accuracy: 1e-12)

        let identity = LossyLinearDNG.PlaneConstants(black: 0, white: 255, coefficients: [])
        XCTAssertEqual(identity.linearise(255), 1, accuracy: 1e-12)
        XCTAssertEqual(identity.linearise(51), 0.2, accuracy: 1e-12)
    }

    func testEncode_sitsOnThePedestal() {
        let ped = Double(LossyLinearDNG.pedestal)
        XCTAssertEqual(LossyLinearDNG.PlaneConstants.encode(0), LossyLinearDNG.pedestal)
        XCTAssertEqual(LossyLinearDNG.PlaneConstants.encode(1), 65535)
        XCTAssertEqual(LossyLinearDNG.PlaneConstants.encode(-0.01), UInt16((ped - 0.01 * (65535 - ped)).rounded()))
        XCTAssertEqual(LossyLinearDNG.PlaneConstants.encode(-1), 0, "clamped, not wrapped")
        XCTAssertEqual(LossyLinearDNG.PlaneConstants.encode(3), 65535)
    }

    func testMapPolynomials_parsesOnePerPlaneBigEndian() throws {
        var blob = Data()
        func u32(_ v: UInt32) { blob.append(contentsOf: withUnsafeBytes(of: v.bigEndian, Array.init)) }
        func f64(_ v: Double) { blob.append(contentsOf: withUnsafeBytes(of: v.bitPattern.bigEndian, Array.init)) }
        u32(3)
        for plane in 0..<3 {
            u32(8); u32(0x01030000); u32(0); u32(36 + 8 * 4)
            u32(0); u32(0); u32(100); u32(200)          // area: top, left, bottom, right
            u32(UInt32(plane)); u32(1); u32(1); u32(1) // plane, planes, row pitch, col pitch
            u32(3)
            f64(0); f64(0.0625 * Double(plane + 1)); f64(0); f64(0.9375)
        }
        let polynomials = try LossyLinearDNG.mapPolynomials(in: blob, width: 200, height: 100)
        XCTAssertEqual(polynomials.count, 3)
        XCTAssertEqual(polynomials[0], [0, 0.0625, 0, 0.9375])
        XCTAssertEqual(polynomials[1], [0, 0.125, 0, 0.9375])
        XCTAssertEqual(polynomials[2], [0, 0.1875, 0, 0.9375])

        XCTAssertThrowsError(try LossyLinearDNG.mapPolynomials(in: blob, width: 400, height: 100),
                             "a polynomial that covers part of the image is not foldable")
        var other = Data()
        other.append(contentsOf: withUnsafeBytes(of: UInt32(1).bigEndian, Array.init))
        other.append(contentsOf: withUnsafeBytes(of: UInt32(9).bigEndian, Array.init)) // GainMap
        other.append(contentsOf: [UInt8](repeating: 0, count: 12))
        XCTAssertThrowsError(try LossyLinearDNG.mapPolynomials(in: other, width: 1, height: 1))
    }

    // MARK: - The repack

    func testRepack_isADNGAppleOpensAtTheSourceSize() throws {
        try requireFixtures()
        let url = Self.frame(Self.lossy10MPProject, "_WEX3879", ext: "dng")
        let started = Date()
        let repacked = try LossyLinearDNG.repack(url: url)
        let elapsed = Date().timeIntervalSince(started)
        print(String(format: "  repack: %.0f ms, %.1f MB", elapsed * 1000, Double(repacked.count) / 1e6))
        XCTAssertGreaterThan(repacked.count, 3872 * 2581 * 6)
        guard let filter = CIRAWFilter(imageData: repacked, identifierHint: "com.adobe.raw-image") else {
            return XCTFail("CIRAWFilter declined the repacked bytes")
        }
        XCTAssertEqual(filter.nativeSize, CGSize(width: 3872, height: 2581))
        XCTAssertNotNil(filter.outputImage)
        // The as-shot neutral the converter reports comes from the carried
        // AsShotNeutral tag, so it must agree with the lossless conversion.
        if let lossless = CIRAWFilter(imageURL: Self.frame(Self.cfaProject, "_WEX3879", ext: "dng")) {
            XCTAssertEqual(Double(filter.neutralTemperature), Double(lossless.neutralTemperature), accuracy: 5)
            XCTAssertEqual(Double(filter.neutralTint), Double(lossless.neutralTint), accuracy: 0.5)
        }
        XCTAssertNil(LossyLinearDNG.lastRepackFailureReason)
    }

    /// `LL_DUMP_REPACK=<dir>` writes the repacked bytes of the three frames
    /// there as `.dng`, to look at with any DNG reader when a number above
    /// needs a picture behind it.
    func testRepack_dumpForInspection() throws {
        guard let directory = ProcessInfo.processInfo.environment["LL_DUMP_REPACK"] else {
            throw XCTSkip("set LL_DUMP_REPACK=<dir> to write the repacked frames")
        }
        try requireFixtures()
        for name in Self.frames {
            let url = Self.frame(Self.lossy10MPProject, name, ext: "dng")
            let out = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-repacked.dng")
            try LossyLinearDNG.repack(url: url).write(to: out)
            print("  wrote \(out.path)")
        }
    }

    func testRepack_neverTouchesTheFile() throws {
        try requireFixtures()
        let url = Self.frame(Self.lossy10MPProject, "_WEX4159", ext: "dng")
        func fingerprint() throws -> (Int, Date?, Data) {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let head = handle.readData(ofLength: 65536)
            try handle.seek(toOffset: UInt64(max(0, (values.fileSize ?? 0) - 65536)))
            let tail = handle.readData(ofLength: 65536)
            return (values.fileSize ?? -1, values.contentModificationDate, head + tail)
        }
        let before = try fingerprint()
        _ = try LossyLinearDNG.repack(url: url)
        _ = try decodeMeans(url)
        let after = try fingerprint()
        XCTAssertEqual(before.0, after.0)
        XCTAssertEqual(before.1, after.1)
        XCTAssertEqual(before.2, after.2)
    }

    // MARK: - Against the gold standard

    /// The control: how far Apple's decode of the lossless CFA DNG sits from
    /// its decode of the ARW. The lossy containers are held to this, with a
    /// few points of slack for the resize and the codec.
    private func control(_ name: String, arw: Means) throws -> (whole: Double, block: Double, absolute: Double) {
        let cfa = try decodeMeans(Self.frame(Self.cfaProject, name, ext: "dng"))
        report("lossless CFA DNG", cfa.whole)
        let gap = compare(cfa, to: arw)
        print(String(format: "    control gap to ARW: whole %.1f%%  block %.1f%%  abs %.5f",
                     gap.wholeRelative * 100, gap.blockRelative * 100, gap.blockAbsolute))
        return (gap.wholeRelative, gap.blockRelative, gap.blockAbsolute)
    }

    /// Green-channel ratio of every block against the gold frame, laid out
    /// as the picture — the shape of a disagreement says what it is
    /// (a corner-to-centre gradient is vignetting, one block is content).
    private func printRatioMap(_ label: String, _ candidate: Means, _ reference: Means) {
        print("    \(label) block ratios (G, candidate ÷ gold):")
        for row in 0..<Self.blocksDown {
            var line = "      "
            for col in 0..<Self.blocksAcross {
                let i = row * Self.blocksAcross + col
                let ratio = reference.blocks[i].y > 1e-6 ? candidate.blocks[i].y / reference.blocks[i].y : .nan
                line += String(format: "%5.2f ", ratio)
            }
            print(line)
        }
    }

    private func assertMatchesGold(project: String, label: String) throws {
        try requireFixtures()
        for name in Self.frames {
            print("== \(name)")
            let arw = try decodeMeans(Self.frame(Self.arwProject, name, ext: "ARW"))
            report("ARW (gold)", arw.whole)
            let control = try control(name, arw: arw)
            let lossy = try decodeMeans(Self.frame(project, name, ext: "dng"))
            report(label, lossy.whole)
            if name == Self.frames[0] {
                printRatioMap("lossless CFA DNG", try decodeMeans(Self.frame(Self.cfaProject, name, ext: "dng")), arw)
                printRatioMap(label, lossy, arw)
            }
            let gap = compare(lossy, to: arw)
            print(String(format: "    %@ gap to ARW: whole %.1f%%  block %.1f%%  abs %.5f",
                         label as NSString, gap.wholeRelative * 100, gap.blockRelative * 100, gap.blockAbsolute))
            // Whole-frame channel means: the control's gap plus five points.
            XCTAssertLessThan(gap.wholeRelative, control.whole + 0.05,
                              "\(name): \(label) whole-frame means drift from the ARW")
            // Blocks well above the noise floor: the control's gap plus eight
            // points — a swapped plane or a misplaced tile is tens of percent.
            XCTAssertLessThan(gap.blockRelative, control.block + 0.08,
                              "\(name): \(label) block means drift from the ARW")
            // Every block, including the noise floor: an absolute bound that a
            // wrapped negative (bright blue speckle) or a lost pedestal breaks.
            XCTAssertLessThan(gap.blockAbsolute, max(0.004, control.absolute * 2),
                              "\(name): \(label) has a block far from the ARW")
            // And it must not be the wash: before the repack the dusk frame's
            // green was three times the ARW's.
            XCTAssertLessThan(abs(lossy.whole.y / arw.whole.y - 1), 0.15, "\(name): green is off")
            XCTAssertLessThan(abs(lossy.whole.z / arw.whole.z - 1), 0.20, "\(name): blue is off")
        }
    }

    func testResizedLossy_matchesTheARW() throws {
        try assertMatchesGold(project: Self.lossy10MPProject, label: "10 MP lossy JXL DNG")
    }

    func testFullSizeLossy_matchesTheARW() throws {
        try assertMatchesGold(project: Self.lossyFullProject, label: "full-size lossy JXL DNG")
    }

    /// The tightest statement available: the repacked lossy file renders the
    /// way Adobe's *lossless* linear conversion of the same ARW renders
    /// through the same Apple pipeline — same demosaic, no codec, uniform
    /// black, no opcodes, a container Apple handles natively. Whatever the
    /// lossy path lost or bent would show up here as a block that disagrees.
    ///
    /// The conversion is made on the fly with the DNG Converter installed on
    /// this Mac (`-l -c`, ~10 s) and the test skips where it is not.
    func testRepack_matchesAdobesOwnLosslessLinearConversion() throws {
        try requireFixtures()
        let converter = URL(fileURLWithPath: "/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: converter.path), "Adobe DNG Converter is not installed")
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("LossyLinearDNGTests-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        for name in Self.frames {
            let arw = Self.frame(Self.arwProject, name, ext: "ARW")
            let process = Process()
            process.executableURL = converter
            process.arguments = ["-l", "-c", "-p0", "-d", scratch.path, "-o", "\(name)-linear.dng", arw.path]
            process.standardOutput = nil
            process.standardError = nil
            try process.run()
            process.waitUntilExit()
            let linear = scratch.appendingPathComponent("\(name)-linear.dng")
            try XCTSkipIf(!FileManager.default.fileExists(atPath: linear.path), "DNG Converter produced nothing")
            guard case .declined = LossyLinearDNG.inspect(url: linear) else {
                return XCTFail("a lossless linear DNG must decode natively, not through the repack")
            }

            let reference = try decodeMeans(linear)
            let lossy = try decodeMeans(Self.frame(Self.lossy10MPProject, name, ext: "dng"))
            print("== \(name) against Adobe's lossless linear conversion")
            report("linear lossless (Adobe demosaic)", reference.whole)
            report("10 MP lossy JXL DNG, repacked", lossy.whole)
            // Blocks above 0.01 linear: below that the 10 MP resample and
            // the codec's noise shape a near-zero mean, not the container.
            let gap = compare(lossy, to: reference, blockFloor: 0.01)
            print(String(format: "    gap: whole %.1f%%  block %.1f%%  abs %.5f",
                         gap.wholeRelative * 100, gap.blockRelative * 100, gap.blockAbsolute))
            XCTAssertLessThan(gap.wholeRelative, 0.03, "\(name): whole-frame means")
            XCTAssertLessThan(gap.blockRelative, 0.06, "\(name): a block above the noise floor disagrees")
        }
    }

    /// The reason the repack exists, kept as a measurement: the same file
    /// opened by URL — Apple's own decode — is the wash. If this ever starts
    /// passing, Apple fixed the decoder and the repack can be retired.
    func testAppleDecodeOfTheOriginal_isStillWrong() throws {
        try requireFixtures()
        let url = Self.frame(Self.lossy10MPProject, "_WEX3879", ext: "dng")
        let arw = try decodeMeans(Self.frame(Self.arwProject, "_WEX3879", ext: "ARW"))
        guard let raw = CIRAWFilter(imageURL: url) else { return XCTFail("CIRAWFilter refused the file") }
        raw.boostAmount = 0
        raw.extendedDynamicRangeAmount = 2
        raw.scaleFactor = 0.25
        guard let image = raw.outputImage,
              let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else {
            return XCTFail("no output")
        }
        let context = CIContext(options: [.workingColorSpace: linearP3, .workingFormat: CIFormat.RGBAh])
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                           bounds: extent, format: .RGBAf, colorSpace: linearP3)
        }
        var mean = SIMD3<Double>.zero
        for i in stride(from: 0, to: pixels.count, by: 4) {
            mean += SIMD3<Double>(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
        }
        mean /= Double(width * height)
        report("Apple decode of the original", mean)
        report("ARW (gold)", arw.whole)
        let greenRatio = mean.y / arw.whole.y
        print(String(format: "    green ×%.2f, blue ×%.2f", greenRatio, mean.z / arw.whole.z))
        XCTAssertGreaterThan(greenRatio, 1.5,
            "Apple now decodes the lossy file's green within 50% of the ARW — re-measure before keeping the repack")
    }
}

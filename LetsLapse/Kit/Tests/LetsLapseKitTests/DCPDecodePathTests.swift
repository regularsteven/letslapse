import Metal
import simd
import XCTest
@testable import LetsLapseKit

/// The Adobe DCP decode path: the container reader, the table semantics, and
/// what the path does to shadow colour against the three paths that came
/// before it.
///
/// ## Two kinds of test here, and they skip for different reasons
///
/// The parser tests need Adobe's profiles installed (Lightroom or Camera Raw);
/// the render tests need those *and* the calibration frame on the external
/// volume. Neither ships with the repo, so both skip rather than fail when
/// absent — but `testDCPParser_illuminantKelvinMapping` deliberately needs
/// neither, because the illuminant table is pure arithmetic and a rule that
/// only gets checked on one developer's machine is not checked.
final class DCPDecodePathTests: XCTestCase {

    // MARK: - Fixtures

    private static let frameURL = URL(fileURLWithPath:
        "/Volumes/letslapse/Projects/ACF3E290-87F9-49C9-8F5D-69A0C62B786D/source/frame-00001.dng")

    /// The shadow patch, in the 4032×3024 frame's top-left-origin pixels —
    /// the same rectangle `RawDecodePathTests` measures, so the numbers here
    /// sit directly alongside that file's.
    private static let waterPatch = CGRect(x: 120, y: 1812, width: 200, height: 160)
    /// The bright patch, for the tone-dependence measurement.
    private static let hullPatch = CGRect(x: 400, y: 2188, width: 96, height: 28)

    /// The baseline `RawDecodePathTests` measured for `.bradfordAdaptation` on
    /// this frame at +60 mired. Recorded for context only — every comparison
    /// below re-measures Bradford in the same process rather than trusting a
    /// number from another run, so a drift in the default path shows up as a
    /// changed comparison instead of a mysteriously failing assertion.
    private static let recordedBradfordBlueOverGreen = 2.48

    private static let warmed: GradeRecipe = {
        var recipe = GradeRecipe()
        recipe.temperatureMired = 60
        return recipe
    }()

    private func requireFixture() throws -> URL {
        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: Self.frameURL.path),
            "calibration frame unavailable — mount /Volumes/letslapse")
        return Self.frameURL
    }

    private func requireProfiles() throws {
        try XCTSkipIf(
            !DCPProfileLocator.isInstalled,
            "Adobe camera profiles are not installed — they ship with Lightroom/Camera Raw")
    }

    /// The profile the calibration frame would actually render through.
    private func requireFrameProfile() throws -> URL {
        let url = try requireFixture()
        try requireProfiles()
        guard let model = DngMetadata.cameraModel(url: url) else {
            throw XCTSkip("the calibration frame carries no camera model")
        }
        guard let profile = try? DCPProfileLocator.profile(forCameraModel: model) else {
            throw XCTSkip("no Adobe profile is installed for \(model)")
        }
        return profile
    }

    // MARK: - Render helpers (mirrors RawDecodePathTests)

    private func render(
        _ path: RawDecodePath, recipe: GradeRecipe, scale: Float = 0.5
    ) throws -> (texture: MTLTexture, scale: Float, fallback: String?) {
        let url = try requireFixture()
        let decoder = try LinearFrameDecoder()
        let frame = try decoder.decode(url: url, scale: scale, path: path, recipe: recipe)
        let engine = try GradeEngine(device: decoder.device)
        let renderer = engine.makeRenderer(recipe, reference: frame.reference())
        return (try renderer.apply(to: frame.texture), scale, decoder.lastDCPFallbackReason)
    }

    private func meanRGB(_ texture: MTLTexture, patch: CGRect, scale: Float) -> SIMD3<Double> {
        let region = CGRect(
            x: patch.minX * CGFloat(scale), y: patch.minY * CGFloat(scale),
            width: patch.width * CGFloat(scale), height: patch.height * CGFloat(scale))
            .integral
            .intersection(CGRect(x: 0, y: 0, width: texture.width, height: texture.height))
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return .zero }
        let width = Int(region.width), height = Int(region.height)
        var pixels = [Float16](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!, bytesPerRow: width * 8,
                from: MTLRegionMake2D(Int(region.minX), Int(region.minY), width, height),
                mipmapLevel: 0)
        }
        var sum = SIMD3<Double>.zero
        for i in stride(from: 0, to: pixels.count, by: 4) {
            sum += SIMD3<Double>(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
        }
        return sum / Double(width * height)
    }

    private func blueOverGreen(_ rgb: SIMD3<Double>) -> Double {
        rgb.y > 1e-9 ? rgb.z / rgb.y : .infinity
    }

    private func report(_ label: String, _ rgb: SIMD3<Double>) {
        print(String(
            format: "  %-24@  R %.5f  G %.5f  B %.5f   B/G %.4f",
            label as NSString, rgb.x, rgb.y, rgb.z, blueOverGreen(rgb)))
    }

    // MARK: - 1. Parser structure

    /// The table dimensions and the data length have to agree, or every
    /// lookup past the first row reads someone else's cell.
    ///
    /// Also checks the axis order, which is the detail most likely to be
    /// wrong and least likely to announce it: the DNG spec stores these
    /// tables value-outer / hue-middle / saturation-inner, the reverse of the
    /// order the dimension triple lists. The spec's own invariant — every
    /// zero-saturation cell carries a value scale of exactly 1.0 — holds under
    /// the correct reading and breaks under the transposed one, so asserting
    /// it pins the indexing rather than merely the sizes.
    func testDCPParser_roundtripsLookTableDims() throws {
        let profileURL = try requireFrameProfile()
        let profile = try DCPParser.parse(url: profileURL)

        print("== DCP profile ==")
        print("  file:   \(profileURL.lastPathComponent)")
        print("  name:   \(profile.profileName)")
        print("  camera: \(profile.uniqueCameraModel)")
        print("  illuminants: \(profile.illuminant1K) K / \(profile.illuminant2K) K")
        print("  hueSatMap dims: \(profile.hueSatMapDims) → \(profile.hueSatMapData1.count) cells")
        print("  lookTable dims: \(profile.lookTableDims) → \(profile.lookTableData.count) cells")
        print("  toneCurve points: \(profile.toneCurve.count)")

        XCTAssertFalse(profile.uniqueCameraModel.isEmpty, "the profile names no camera")
        XCTAssertTrue(profile.hasForwardMatrices, "the profile carries no forward matrices")

        let look = profile.lookTableDims
        XCTAssertGreaterThan(look.x, 0, "look table has no hue divisions")
        XCTAssertGreaterThan(look.y, 0, "look table has no saturation divisions")
        XCTAssertGreaterThan(look.z, 0, "look table has no value divisions")
        XCTAssertEqual(
            look.x * look.y * look.z, profile.lookTableData.count,
            "look table dims and data length disagree")

        let hsm = profile.hueSatMapDims
        XCTAssertEqual(
            hsm.x * hsm.y * hsm.z, profile.hueSatMapData1.count,
            "hue/sat map dims and data length disagree")
        if !profile.hueSatMapData2.isEmpty {
            XCTAssertEqual(
                profile.hueSatMapData2.count, profile.hueSatMapData1.count,
                "the two illuminant tables are different sizes")
        }

        // The spec's zero-saturation invariant, under the documented axis
        // order. A transposed reading fails this.
        for dims in [hsm, look] where dims.x > 0 && dims.y > 0 && dims.z > 0 {
            let data = dims == hsm ? profile.hueSatMapData1 : profile.lookTableData
            for v in 0..<dims.z {
                for h in 0..<dims.x {
                    let i = DCPTableIndex.offset(hue: h, sat: 0, value: v, dims: dims)
                    XCTAssertEqual(
                        data[i].z, 1.0, accuracy: 1e-6,
                        "zero-saturation cell (h:\(h) v:\(v)) must carry value scale 1.0 — "
                        + "if this fails the table axis order is transposed")
                }
            }
        }
    }

    // MARK: - 2. DCP vs Bradford

    /// The path's reason for existing: does the profile's tone-dependent hue
    /// map pull the cold cast out of the shadows that a Bradford 3×3 leaves in?
    func testDCPPath_vs_Bradford_shadowChrominance() throws {
        _ = try requireFrameProfile()

        let bradford = try render(.bradfordAdaptation, recipe: Self.warmed)
        let dcp = try render(.dcpProfile, recipe: Self.warmed)
        try XCTSkipIf(dcp.fallback != nil, "DCP path fell back: \(dcp.fallback ?? "")")

        let a = meanRGB(bradford.texture, patch: Self.waterPatch, scale: bradford.scale)
        let b = meanRGB(dcp.texture, patch: Self.waterPatch, scale: dcp.scale)

        print("== dcp vs bradford, shadow patch (temperature +60 mired) ==")
        report("bradford water", a)
        report("dcp water", b)
        print(String(
            format: "  B/G  bradford %.4f → dcp %.4f  (%+.2f%%)   [recorded bradford %.2f]",
            blueOverGreen(a), blueOverGreen(b),
            (blueOverGreen(b) / blueOverGreen(a) - 1) * 100,
            Self.recordedBradfordBlueOverGreen))

        XCTAssertGreaterThan(b.y, 0, "the DCP path rendered the shadow patch black")
        XCTAssertLessThan(
            blueOverGreen(b), blueOverGreen(a),
            "the DCP path should carry less shadow blue than the Bradford baseline")
    }

    // MARK: - 3. DCP vs CIRAW

    /// Both paths balance in camera space ahead of the profile; the DCP path
    /// then adds Adobe's tables. This measures what the tables alone are
    /// worth, with the white-balance ordering held constant.
    ///
    /// No directional assertion: `.cirawFilter` renders through Apple's device
    /// profile, which is a real calibration of the same sensor and not
    /// obviously further from Lightroom than Adobe's own. Which of the two
    /// lands closer is the question this path was built to answer, and an
    /// assertion here would be presupposing the answer.
    func testDCPPath_vs_CIRAW_shadowChrominance() throws {
        _ = try requireFrameProfile()

        let ciraw = try render(.cirawFilter, recipe: Self.warmed)
        let dcp = try render(.dcpProfile, recipe: Self.warmed)
        try XCTSkipIf(dcp.fallback != nil, "DCP path fell back: \(dcp.fallback ?? "")")

        let a = meanRGB(ciraw.texture, patch: Self.waterPatch, scale: ciraw.scale)
        let b = meanRGB(dcp.texture, patch: Self.waterPatch, scale: dcp.scale)

        print("== dcp vs ciraw, shadow patch (temperature +60 mired) ==")
        report("ciraw water", a)
        report("dcp water", b)
        print(String(
            format: "  B/G  ciraw %.4f → dcp %.4f  (%+.2f%%)",
            blueOverGreen(a), blueOverGreen(b),
            (blueOverGreen(b) / blueOverGreen(a) - 1) * 100))

        XCTAssertGreaterThan(b.y, 0, "the DCP path rendered the shadow patch black")
        XCTAssertNotEqual(
            blueOverGreen(a), blueOverGreen(b), accuracy: 1e-6,
            "the DCP tables changed nothing — the pass is not reaching the pixels")
    }

    /// The claim the whole path rests on, measured: the look table moves
    /// shadows and highlights by *different* amounts.
    ///
    /// This is the one property that cannot be faked by a better matrix, and
    /// so the one worth asserting directly. A 3×3 is a single linear map — it
    /// scales every pixel's channels the same way, so whatever it does to the
    /// shadow patch's blue/green ratio it does equally to the highlight's. A
    /// non-zero differential here is proof the table is being evaluated
    /// against brightness rather than collapsing to a constant, which is both
    /// the feature and the thing a transposed axis order would quietly break.
    func testDCPPath_movesShadowsAndHighlightsDifferently() throws {
        _ = try requireFrameProfile()

        let ciraw = try render(.cirawFilter, recipe: Self.warmed)
        let dcp = try render(.dcpProfile, recipe: Self.warmed)
        try XCTSkipIf(dcp.fallback != nil, "DCP path fell back: \(dcp.fallback ?? "")")

        let shadowA = meanRGB(ciraw.texture, patch: Self.waterPatch, scale: ciraw.scale)
        let shadowB = meanRGB(dcp.texture, patch: Self.waterPatch, scale: dcp.scale)
        let hullA = meanRGB(ciraw.texture, patch: Self.hullPatch, scale: ciraw.scale)
        let hullB = meanRGB(dcp.texture, patch: Self.hullPatch, scale: dcp.scale)

        let shadowShift = blueOverGreen(shadowB) / blueOverGreen(shadowA) - 1
        let highlightShift = blueOverGreen(hullB) / blueOverGreen(hullA) - 1

        print("== dcp tone dependence (vs ciraw, temperature +60 mired) ==")
        report("ciraw shadow", shadowA)
        report("dcp shadow", shadowB)
        report("ciraw highlight", hullA)
        report("dcp highlight", hullB)
        print(String(
            format: "  shadow B/G shift %+.2f%%, highlight B/G shift %+.2f%%",
            shadowShift * 100, highlightShift * 100))
        print(String(
            format: "  differential %+.2f%% — non-zero is the tone dependence "
            + "no 3x3 can produce", (shadowShift - highlightShift) * 100))

        XCTAssertGreaterThan(hullB.y, 0, "the DCP path rendered the highlight patch black")
        XCTAssertGreaterThan(
            abs(shadowShift - highlightShift), 0.01,
            "shadows and highlights moved together — the look table is behaving "
            + "like a constant, which means it is not being indexed by value")
    }

    // MARK: - 4. Illuminant mapping

    /// The EXIF `LightSource` codes, checked against a profile authored here.
    ///
    /// Codes 20 and 21 are the pair worth pinning: 20 is **D55** (5503 K) and
    /// 21 is **D65** (6504 K), not the other way round. Apple's profiles
    /// calibrate at 17 and 21 — Standard A and D65 — so reading 21 as D75
    /// would put every hue/sat interpolation on the wrong side of the shot
    /// temperature. This test authors its own bytes and needs nothing
    /// installed.
    func testDCPParser_illuminantKelvinMapping() throws {
        let data = Self.makeMinimalDCP(illuminant1: 17, illuminant2: 21)
        let profile = try DCPParser.parse(data: data, name: "synthetic")

        XCTAssertEqual(profile.illuminant1K, 2856, accuracy: 0.5, "code 17 is Standard light A")
        XCTAssertEqual(profile.illuminant2K, 6504, accuracy: 0.5, "code 21 is D65")

        // The full table, so a future edit cannot quietly shift one row.
        let expected: [(UInt16, Float)] = [
            (17, 2856), (18, 4874), (19, 6774), (20, 5503),
            (21, 6504), (22, 7504), (23, 5003),
        ]
        for (code, kelvin) in expected {
            XCTAssertEqual(
                DCPParser.illuminantKelvin(code), kelvin,
                "EXIF LightSource \(code) should map to \(kelvin) K")
        }
        XCTAssertNil(DCPParser.illuminantKelvin(255), "an unknown code has no temperature")

        // And the synthetic profile's tables survived the round trip.
        XCTAssertEqual(profile.lookTableDims, SIMD3<Int>(2, 2, 2))
        XCTAssertEqual(profile.lookTableData.count, 8)
        XCTAssertEqual(profile.lookTableData[0].y, 1.0, accuracy: 1e-6)
    }

    /// A DCP is not a version-42 TIFF — real profiles carry `0x4352` ("RC").
    /// A reader that insists on 42 opens none of Adobe's files, so the
    /// tolerance is worth a test of its own.
    func testDCPParser_acceptsRawCameraMagic() throws {
        let dcp = Self.makeMinimalDCP(illuminant1: 17, illuminant2: 21, version: 0x4352)
        XCTAssertNoThrow(try DCPParser.parse(data: dcp), "the shipped DCP magic must parse")

        let tiff = Self.makeMinimalDCP(illuminant1: 17, illuminant2: 21, version: 42)
        XCTAssertNoThrow(try DCPParser.parse(data: tiff), "a plain-TIFF profile must parse too")

        var junk = Self.makeMinimalDCP(illuminant1: 17, illuminant2: 21)
        junk[0] = 0x58; junk[1] = 0x58   // not II, not MM
        XCTAssertThrowsError(try DCPParser.parse(data: junk)) { error in
            XCTAssertEqual(error as? DCPParser.Error, .notADCP)
        }
    }

    /// The locator has to key on `UniqueCameraModel`, not the marketing name.
    /// Adobe names iPhone profiles by model identifier — `iPhone17,1` — which
    /// shares almost nothing with `iPhone 16 Pro`.
    func testDCPLocator_matchesByUniqueCameraModel() throws {
        try requireProfiles()
        let url = try requireFixture()
        guard let model = DngMetadata.cameraModel(url: url) else {
            throw XCTSkip("the calibration frame carries no camera model")
        }
        print("== locator ==")
        print("  UniqueCameraModel: \(model)")
        XCTAssertFalse(
            model.contains(" Pro"),
            "expected a model identifier like iPhone17,1 — got the marketing name")

        let profileURL = try DCPProfileLocator.profile(forCameraModel: model)
        print("  resolved: \(profileURL.lastPathComponent)")
        let parsed = try DCPParser.parse(url: profileURL)
        XCTAssertEqual(
            parsed.uniqueCameraModel, model,
            "the resolved profile calibrates a different camera than the frame was shot on")
    }

    // MARK: - Synthetic profile

    /// Builds a minimal but structurally real DCP in memory.
    ///
    /// Header, one IFD, out-of-line values for anything past four bytes —
    /// enough for the parser to walk exactly as it walks Adobe's, without
    /// needing Lightroom installed to test the arithmetic.
    private static func makeMinimalDCP(
        illuminant1: UInt16, illuminant2: UInt16, version: UInt16 = 0x4352
    ) -> Data {
        struct Field {
            let tag: UInt16
            let type: UInt16
            let count: UInt32
            /// Out-of-line payload, or nil when the value fits the 4-byte slot.
            let payload: [UInt8]?
            let inline: UInt32
        }

        func u32(_ v: UInt32) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        }
        func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func f32(_ v: Float) -> [UInt8] { u32(v.bitPattern) }

        // A 2×2×2 look table of identity cells: no hue shift, unit scales.
        var table: [UInt8] = []
        for _ in 0..<8 { table += f32(0) + f32(1) + f32(1) }

        let name = Array("Synthetic".utf8) + [0]

        let fields: [Field] = [
            // SHORT values sit inline in the low half of the 4-byte slot.
            Field(tag: 0xC65A, type: 3, count: 1, payload: nil, inline: UInt32(illuminant1)),
            Field(tag: 0xC65B, type: 3, count: 1, payload: nil, inline: UInt32(illuminant2)),
            Field(tag: 0xC6F8, type: 2, count: UInt32(name.count), payload: name, inline: 0),
            Field(tag: 0xC725, type: 4, count: 3, payload: u32(2) + u32(2) + u32(2), inline: 0),
            Field(tag: 0xC726, type: 11, count: 24, payload: table, inline: 0),
        ]

        let ifdOffset = 8
        let ifdBytes = 2 + fields.count * 12 + 4
        var valueCursor = ifdOffset + ifdBytes

        var entries: [UInt8] = []
        var values: [UInt8] = []
        for field in fields {
            entries += u16(field.tag) + u16(field.type) + u32(field.count)
            if let payload = field.payload {
                entries += u32(UInt32(valueCursor))
                values += payload
                valueCursor += payload.count
            } else {
                entries += u32(field.inline)
            }
        }

        var out: [UInt8] = [0x49, 0x49]      // "II"
        out += u16(version)
        out += u32(UInt32(ifdOffset))
        out += u16(UInt16(fields.count))
        out += entries
        out += u32(0)                        // no next IFD
        out += values
        return Data(out)
    }
}

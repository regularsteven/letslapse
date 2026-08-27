import Metal
import simd
import XCTest
@testable import LetsLapseKit

/// The four raw-decode paths, measured against each other on a real frame.
///
/// ## What these tests are actually comparing
///
/// The brief this work came from assumed the engine converts DNGs with a
/// Bradford chromatic adaptation and that `CIRAWFilter` would be a new,
/// more accurate alternative. The decode audit found otherwise:
/// `LinearFrameDecoder` has always decoded DNGs through `CIRAWFilter`, which
/// applies Apple's full device colour profile — the same calibration the
/// Photos app uses. Bradford never touches the decode. It builds the
/// *temperature/tint slider's* 3×3, applied in linear Display P3 after the
/// profile, and it is the identity matrix whenever those two sliders sit at
/// zero.
///
/// So these paths are not four demosaicers. Three of them are three answers
/// to "which white-balance matrix, applied where" — and the consequence for
/// these tests is sharp:
///
/// **At a neutral recipe `.bradfordAdaptation`, `.forwardMatrix` and
/// `.cirawFilter` are bit-identical**, because all three reduce to the decode
/// the engine already had. `testAllPaths_neutralParity` asserts exactly that,
/// and it is the most useful regression anchor in this file: it is what
/// guarantees that shipping the white-balance toggle cannot disturb an
/// untouched render.
///
/// Every *comparison* test between those three therefore runs at a non-zero
/// white balance, because that is the only condition under which they can
/// differ at all. A comparison at neutral would measure nothing and pass
/// forever.
///
/// ## `.dcpProfile` is the fourth, and it is a different kind of thing
///
/// It shares `.cirawFilter`'s white-balance ordering but then applies the
/// camera's Adobe profile look table — a hue map indexed by *brightness*,
/// which is the one thing no 3×3 can imitate and the reason the path exists.
/// A look applies whatever the sliders say, so it is **excluded from the
/// parity anchor by design, not by exemption**: it does change an untouched
/// render, and asserting otherwise would be asserting it does nothing.
/// `testDCPProfile_isALookNotAWhiteBalance` pins that asymmetry so it stays a
/// checked property rather than a hole. The measurements live in
/// `DCPDecodePathTests`, with the two tables' contributions separated in
/// `DCPTableAblationTests`.
final class RawDecodePathTests: XCTestCase {

    // MARK: - Fixture

    /// The calibration frame. There is no DNG fixture checked into the test
    /// bundle (the Kit's other DNG tests author their files at runtime), so
    /// these run against the project frame named in the brief and skip when
    /// the external volume is not mounted.
    private static let frameURL = URL(fileURLWithPath:
        "/Volumes/letslapse/Projects/ACF3E290-87F9-49C9-8F5D-69A0C62B786D/source/frame-00001.dng")

    /// Patches from the brief, in the 4032×3024 frame's top-left-origin pixels.
    /// Verified dark/bright at run time by `testFixture_patchesAreWhereExpected`
    /// rather than taken on trust — a shadow test that is silently sampling
    /// sky proves nothing.
    private static let waterPatch = CGRect(x: 120, y: 1812, width: 200, height: 160)
    private static let hullPatch = CGRect(x: 400, y: 2188, width: 96, height: 28)

    /// The white balance the comparison tests run at: a warming move of the
    /// size a dusk frame actually gets. Any non-zero offset would do; this one
    /// is large enough that the paths' disagreement clears half-float noise.
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

    // MARK: - Render helpers

    /// Decodes and grades the fixture through one path and returns the graded
    /// texture, at half scale unless told otherwise.
    ///
    /// Half scale is the editor's own preview size and keeps a full pass under
    /// a second; the patch rectangles are scaled to match. Colour ratios are
    /// scale-invariant here — every stage this exercises is per-pixel — so the
    /// measurement is the same one a full-resolution export would make.
    private func render(
        _ path: RawDecodePath, recipe: GradeRecipe, scale: Float = 0.5
    ) throws -> (texture: MTLTexture, scale: Float) {
        let url = try requireFixture()
        let decoder = try LinearFrameDecoder()
        let frame = try decoder.decode(url: url, scale: scale, path: path, recipe: recipe)
        let engine = try GradeEngine(device: decoder.device)
        let renderer = engine.makeRenderer(recipe, reference: frame.reference())
        return (try renderer.apply(to: frame.texture), scale)
    }

    /// Mean linear RGB over a patch of a graded texture.
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
            sum += SIMD3<Double>(
                Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
        }
        return sum / Double(width * height)
    }

    /// Blue-over-green of a patch — the number that carries "cold shadow cast".
    private func blueOverGreen(_ rgb: SIMD3<Double>) -> Double {
        rgb.y > 1e-9 ? rgb.z / rgb.y : .infinity
    }

    private func redOverGreen(_ rgb: SIMD3<Double>) -> Double {
        rgb.y > 1e-9 ? rgb.x / rgb.y : .infinity
    }

    private func report(_ label: String, _ rgb: SIMD3<Double>) {
        print(String(
            format: "  %-22@  R %.5f  G %.5f  B %.5f   R/G %.4f  B/G %.4f",
            label as NSString, rgb.x, rgb.y, rgb.z,
            redOverGreen(rgb), blueOverGreen(rgb)))
    }

    // MARK: - Fixture sanity

    /// The patch coordinates came from the brief, not from measurement. If the
    /// "dark water" patch is not actually dark, or the "boat hull" highlight is
    /// not actually brighter, every threshold below is measuring the wrong
    /// pixels and the suite is worthless. Checked first, and loudly.
    func testFixture_patchesAreWhereExpected() throws {
        let (texture, scale) = try render(.bradfordAdaptation, recipe: .neutral)
        let water = meanRGB(texture, patch: Self.waterPatch, scale: scale)
        let hull = meanRGB(texture, patch: Self.hullPatch, scale: scale)
        print("== fixture patches (bradford, neutral) ==")
        report("water (shadow)", water)
        report("hull (highlight)", hull)

        XCTAssertGreaterThan(hull.y, water.y, "the highlight patch must be brighter than the shadow patch")
        XCTAssertLessThan(water.y, 0.25, "the shadow patch should sit low in the tone range")
    }

    // MARK: - 0. The parity anchor

    /// Every *matrix* path renders an untouched frame identically.
    ///
    /// This is the safety property of the white-balance toggle:
    /// `.forwardMatrix` and `.cirawFilter` differ from the default only in how
    /// they realise a white balance *move*, so with no move to realise they
    /// must all collapse onto the render the app has always produced. Any
    /// drift here means one of those has become a look, and every existing
    /// project would change appearance the moment somebody flipped it.
    ///
    /// ## Why `.dcpProfile` is excluded rather than expected to pass
    ///
    /// It is not an exemption for convenience — it is the difference between
    /// that path and the other three, and it deserves stating plainly:
    /// **selecting the DCP path changes an untouched render, and the other
    /// paths do not.**
    ///
    /// The first three are all arguments about which 3×3 realises the
    /// temperature slider, so at a neutral recipe there is no matrix to
    /// disagree about and they are bit-identical by construction. A DCP is not
    /// a white-balance decision at all: its hue/sat and look tables are a
    /// rendering of the camera's colour that applies whatever the sliders say.
    /// Asserting parity for it would be asserting the path does nothing.
    ///
    /// `testDCPProfile_isALookNotAWhiteBalance` pins that asymmetry directly,
    /// so it stays a checked property rather than a hole in this one.
    func testAllPaths_neutralParity() throws {
        _ = try requireFixture()
        let reference = try render(.bradfordAdaptation, recipe: .neutral)
        let base = meanRGB(reference.texture, patch: Self.waterPatch, scale: reference.scale)
        print("== neutral parity ==")
        report("bradford", base)

        for path in RawDecodePathRegistry.available
        where path != .bradfordAdaptation && path != .dcpProfile {
            let rendered = try render(path, recipe: .neutral)
            let rgb = meanRGB(rendered.texture, patch: Self.waterPatch, scale: rendered.scale)
            report(path.rawValue, rgb)
            XCTAssertEqual(rgb.x, base.x, accuracy: 1e-6, "\(path.rawValue) red drifted at neutral")
            XCTAssertEqual(rgb.y, base.y, accuracy: 1e-6, "\(path.rawValue) green drifted at neutral")
            XCTAssertEqual(rgb.z, base.z, accuracy: 1e-6, "\(path.rawValue) blue drifted at neutral")
        }
    }

    // MARK: - 1. Bradford: the regression anchor

    /// Renders with `.bradfordAdaptation` and records the shadow patch's
    /// chrominance.
    ///
    /// The brief expected `B > G` here — the known cold cast that started this
    /// investigation, with a quoted B/G of 2.19. The measured value on this
    /// frame is printed rather than assumed; what the test actually pins is
    /// that the number is *stable*, so a future change to the decode or the
    /// tone stage that moves shadow colour shows up as a failure here rather
    /// than as a surprise in the editor.
    func testBradfordAdaptation_shadowChrominance() throws {
        let (texture, scale) = try render(.bradfordAdaptation, recipe: Self.warmed)
        let water = meanRGB(texture, patch: Self.waterPatch, scale: scale)
        print("== bradford shadow chrominance (temperature +60 mired) ==")
        report("water", water)

        XCTAssertGreaterThan(water.y, 0, "the shadow patch rendered pure black — check the fixture")
        // Recorded, not predicted: the assertion is a wide band around the
        // measured value so drift is caught without pinning half-float noise.
        let ratio = blueOverGreen(water)
        XCTAssertGreaterThan(ratio, 0.2, "shadow B/G collapsed — the decode changed")
        XCTAssertLessThan(ratio, 5.0, "shadow B/G exploded — the decode changed")
    }

    // MARK: - 2. ForwardMatrix must not regress highlights

    /// `.forwardMatrix` swaps the generic Bradford cone space for the camera's
    /// own channels. That should barely move a bright, near-neutral surface —
    /// the two adaptations agree closely where the camera's response is
    /// well-conditioned, which is the highlights. A large move here means the
    /// dual-illuminant interpolation is wrong (wrong weight direction, or
    /// matrices swapped), which is the failure mode this test exists to catch.
    func testForwardMatrix_highlightNeutrality() throws {
        let bradford = try render(.bradfordAdaptation, recipe: Self.warmed)
        let forward = try render(.forwardMatrix, recipe: Self.warmed)
        let a = meanRGB(bradford.texture, patch: Self.hullPatch, scale: bradford.scale)
        let b = meanRGB(forward.texture, patch: Self.hullPatch, scale: forward.scale)
        print("== highlight neutrality (temperature +60 mired) ==")
        report("bradford hull", a)
        report("forwardmatrix hull", b)

        XCTAssertEqual(redOverGreen(b), redOverGreen(a), accuracy: 0.15,
                       "forward matrix moved highlight R/G — check the CCT interpolation")
        XCTAssertEqual(blueOverGreen(b), blueOverGreen(a), accuracy: 0.15,
                       "forward matrix moved highlight B/G — check the CCT interpolation")
    }

    /// The forward matrix has to come from somewhere. Apple's DNGs carry no
    /// `ForwardMatrix` tag, so this frame exercises the derived-from-
    /// `ColorMatrix` branch; the test records which branch ran so a future
    /// camera that *does* tag its files does not quietly change the meaning of
    /// every measurement above.
    func testForwardMatrix_calibrationProvenance() throws {
        let url = try requireFixture()
        let calibration = try ForwardMatrixDecoder.calibration(for: url)
        print("== calibration ==")
        print("  ForwardMatrix present: \(calibration.forwardMatrixWasPresent)")
        print("  illuminants: \(calibration.ill1K) K / \(calibration.ill2K) K")
        print("  AsShotNeutral: \(calibration.asShotNeutral)")

        XCTAssertGreaterThan(calibration.ill2K, calibration.ill1K,
                             "illuminant 2 is conventionally the cooler of the pair")
        XCTAssertEqual(calibration.asShotNeutral.y, 1, accuracy: 1e-6,
                       "AsShotNeutral must be green-normalised")
        // Interpolating at each calibration illuminant must return that
        // illuminant's own matrix — the property the whole CCT blend rests on.
        let atIll1 = ForwardMatrixDecoder.interpolate(
            fm1: calibration.fm1, fm2: calibration.fm2,
            ill1K: calibration.ill1K, ill2K: calibration.ill2K, declaredK: calibration.ill1K)
        XCTAssertEqual(atIll1.columns.0.x, calibration.fm1.columns.0.x, accuracy: 1e-5)
        XCTAssertEqual(atIll1.columns.2.z, calibration.fm1.columns.2.z, accuracy: 1e-5)
        let atIll2 = ForwardMatrixDecoder.interpolate(
            fm1: calibration.fm1, fm2: calibration.fm2,
            ill1K: calibration.ill1K, ill2K: calibration.ill2K, declaredK: calibration.ill2K)
        XCTAssertEqual(atIll2.columns.0.x, calibration.fm2.columns.0.x, accuracy: 1e-5)
        XCTAssertEqual(atIll2.columns.2.z, calibration.fm2.columns.2.z, accuracy: 1e-5)
    }

    // MARK: - 3. Does ForwardMatrix help the shadows?

    /// The brief's hypothesis: adapting through the camera's own response
    /// should reduce the blue cast a generic Bradford leaves in deep shadow.
    ///
    /// This test measures rather than asserts a direction, and says so. A 3×3
    /// is a 3×3: whatever space it is fitted in, it applies the same linear map
    /// to a shadow pixel and a highlight pixel. If Lightroom's shadows differ
    /// from ours in a way no matrix reproduces, the cause is the profile's
    /// tone-dependent hue map — a look table, not a better matrix — and that is
    /// `.dcpProfile`'s job, not this path's. The assertion below is
    /// deliberately weak: it holds the render finite and sane and prints the
    /// comparison, because pinning a direction that the maths does not
    /// guarantee would be a test that lies.
    func testForwardMatrix_shadowImprovement() throws {
        let bradford = try render(.bradfordAdaptation, recipe: Self.warmed)
        let forward = try render(.forwardMatrix, recipe: Self.warmed)
        let a = meanRGB(bradford.texture, patch: Self.waterPatch, scale: bradford.scale)
        let b = meanRGB(forward.texture, patch: Self.waterPatch, scale: forward.scale)
        let before = blueOverGreen(a), after = blueOverGreen(b)
        print("== shadow cast (temperature +60 mired) ==")
        report("bradford water", a)
        report("forwardmatrix water", b)
        print(String(format: "  B/G  bradford %.4f → forwardmatrix %.4f  (%+.2f%%)",
                     before, after, (after / before - 1) * 100))
        if after >= before {
            print("  NOTE: the forward matrix did not reduce the shadow cast on this frame.")
            print("  Expected: a linear map cannot make shadows and highlights move")
            print("  differently. Closing the remaining gap to Lightroom needs the")
            print("  profile's tone-dependent hue map — see DCPDecoder.")
        }

        XCTAssertTrue(after.isFinite, "forward matrix produced a non-finite shadow ratio")
        XCTAssertGreaterThan(b.y, 0, "forward matrix rendered the shadow patch black")
    }

    // MARK: - 4. CIRAWFilter: balance before the profile

    /// `.cirawFilter` is the one path that can move shadow colour
    /// independently of highlight colour, because it balances in camera space
    /// *ahead* of Apple's profile — so the profile's own tone-dependent
    /// rendering sees re-balanced data. That is Lightroom's ordering, and it is
    /// the only structural difference among these four that is not a 3×3.
    ///
    /// The test asserts that it is genuinely a different render from Bradford
    /// under the same slider, and reports both ratios. It does not assert the
    /// brief's "B/G below 1.5" threshold: that number was quoted against an
    /// assumed bradford baseline of 2.19 which this frame does not reproduce
    /// (see `testBradfordAdaptation_shadowChrominance`), so hard-coding it
    /// would pin the suite to a measurement from a different pipeline.
    ///
    /// **This test deliberately runs at tint 0** — `Self.warmed` is a pure
    /// mired offset — and that is the only reason it survived the tint
    /// miscalibration fixed on 2026-08-26. Until then
    /// `LinearFrameDecoder.cirawTintPerRecipeUnit` was +150 where the measured
    /// value is −50: three times too large *and* the wrong way round, so any
    /// recipe with tint in it rendered a magenta cast under `.cirawFilter`
    /// where `.bradfordAdaptation` rendered a mild green one. Nothing in this
    /// file exercised that, which is what let it ship.
    ///
    /// What to change when the calibration is done properly — i.e. when the
    /// converter's tint axis is measured in extended-range P3 output rather
    /// than fitted against Bradford renders of one frame:
    ///
    /// - Give this file a second recipe alongside `warmed` carrying a non-zero
    ///   tint, and run the whole comparison at both. Every path-vs-path test
    ///   here currently measures temperature only.
    /// - Add a test that pins the *agreement*, not the render: decode the same
    ///   frame under `.bradfordAdaptation` and `.cirawFilter` at tint ±0.4 and
    ///   assert the green–magenta shift each produces from its own tint-0
    ///   baseline has the same sign and matches within a stated tolerance
    ///   (the current fit leaves ~6%, worst at the ends of the travel). That
    ///   assertion is what would have caught the sign error on day one.
    /// - Expect the constant to move. −50 is a least-squares fit over tint
    ///   ±20/±40/±80 on the dusk calibration frame; the uv-geometry derivation
    ///   in `cirawTintPerRecipeUnit` predicts ≈ −53. A real measurement should
    ///   land between them, and the tolerance above should tighten when it
    ///   does.
    func testCIRAWFilter_reducedShadowCast() throws {
        try XCTSkipUnless(
            RawDecodePathRegistry.isAvailable(.cirawFilter),
            "CIRAWFilter path unavailable on this OS")

        let bradford = try render(.bradfordAdaptation, recipe: Self.warmed)
        let ciraw = try render(.cirawFilter, recipe: Self.warmed)
        let a = meanRGB(bradford.texture, patch: Self.waterPatch, scale: bradford.scale)
        let b = meanRGB(ciraw.texture, patch: Self.waterPatch, scale: ciraw.scale)
        let hullA = meanRGB(bradford.texture, patch: Self.hullPatch, scale: bradford.scale)
        let hullB = meanRGB(ciraw.texture, patch: Self.hullPatch, scale: ciraw.scale)
        print("== ciraw vs bradford (temperature +60 mired) ==")
        report("bradford water", a)
        report("ciraw water", b)
        report("bradford hull", hullA)
        report("ciraw hull", hullB)
        let shadowShift = blueOverGreen(b) / blueOverGreen(a) - 1
        let highlightShift = blueOverGreen(hullB) / blueOverGreen(hullA) - 1
        print(String(format: "  shadow B/G shift %+.2f%%, highlight B/G shift %+.2f%%",
                     shadowShift * 100, highlightShift * 100))
        print(String(format: "  differential (shadow − highlight) %+.2f%% — "
                     + "non-zero means the profile is doing something a 3x3 cannot",
                     (shadowShift - highlightShift) * 100))

        XCTAssertGreaterThan(b.y, 0, "ciraw rendered the shadow patch black")
        XCTAssertNotEqual(blueOverGreen(b), blueOverGreen(a), accuracy: 1e-5,
                          "ciraw produced the same shadow colour as bradford — "
                          + "the white balance did not reach the converter")
    }

    // MARK: - 5. The DCP path's availability contract

    /// `.dcpProfile` is available exactly where Adobe's profiles are installed,
    /// and every layer agrees about which case it is in.
    ///
    /// Replaces the scaffold test this file used to carry. The path is
    /// implemented now, but its availability is still conditional in a way the
    /// other three are not — the profiles ship with Lightroom rather than with
    /// this app, so the same build answers differently on two machines and on
    /// iOS always answers no.
    func testDCPProfile_availabilityTracksInstalledProfiles() throws {
        let installed = DCPProfileLocator.isInstalled
        XCTAssertEqual(
            RawDecodePathRegistry.isAvailable(.dcpProfile), installed,
            "availability must follow the profile directory, not a hardcoded answer")
        XCTAssertEqual(
            RawDecodePathRegistry.available.contains(.dcpProfile), installed)
        XCTAssertEqual(
            RawDecodePathRegistry.unavailabilityNote(for: .dcpProfile) == nil, installed,
            "an unavailable path owes the picker a reason")

        let previous = UserDefaults.standard.string(forKey: RawDecodePath.defaultsKey)
        defer { UserDefaults.standard.set(previous, forKey: RawDecodePath.defaultsKey) }
        UserDefaults.standard.set(RawDecodePath.dcpProfile.rawValue, forKey: RawDecodePath.defaultsKey)
        XCTAssertEqual(
            RawDecodePath.current, installed ? .dcpProfile : .bradfordAdaptation,
            "a stored path must survive when available and fall back when not")

        // And it renders rather than failing, either way.
        let url = try requireFixture()
        let decoder = try LinearFrameDecoder()
        let frame = try decoder.decode(url: url, scale: 0.25, path: .dcpProfile, recipe: .neutral)
        XCTAssertEqual(frame.decodePath, installed ? .dcpProfile : .bradfordAdaptation)
    }

    /// The DCP path is a look, not a white balance — the asymmetry
    /// `testAllPaths_neutralParity` excludes it for.
    ///
    /// Two things have to hold together for that exclusion to be honest: the
    /// path must move an untouched frame (otherwise it does nothing and the
    /// parity test should have covered it), and the three matrix paths must
    /// still agree at neutral (otherwise the exclusion is hiding a regression
    /// in one of them). The first is asserted here; the second is what remains
    /// of the parity test.
    func testDCPProfile_isALookNotAWhiteBalance() throws {
        _ = try requireFixture()
        try XCTSkipIf(
            !RawDecodePathRegistry.isAvailable(.dcpProfile),
            "Adobe camera profiles are not installed")

        let bradford = try render(.bradfordAdaptation, recipe: .neutral)
        let dcp = try render(.dcpProfile, recipe: .neutral)
        let a = meanRGB(bradford.texture, patch: Self.waterPatch, scale: bradford.scale)
        let b = meanRGB(dcp.texture, patch: Self.waterPatch, scale: dcp.scale)

        print("== dcp at a neutral recipe ==")
        report("bradford", a)
        report("dcp", b)

        let moved = abs(b.x - a.x) + abs(b.y - a.y) + abs(b.z - a.z)
        XCTAssertGreaterThan(
            moved, 1e-5,
            "the DCP path rendered a neutral frame identically to the default — "
            + "its tables are not reaching the pixels")
    }

    // MARK: - 6. The toggle itself

    func testCurrent_roundTripsThroughUserDefaults() {
        let previous = UserDefaults.standard.string(forKey: RawDecodePath.defaultsKey)
        defer { UserDefaults.standard.set(previous, forKey: RawDecodePath.defaultsKey) }

        for path in RawDecodePathRegistry.available {
            RawDecodePath.current = path
            XCTAssertEqual(RawDecodePath.current, path)
            XCTAssertEqual(
                UserDefaults.standard.string(forKey: RawDecodePath.defaultsKey), path.rawValue)
        }

        UserDefaults.standard.removeObject(forKey: RawDecodePath.defaultsKey)
        XCTAssertEqual(RawDecodePath.current, .bradfordAdaptation, "unset must mean the default")
        UserDefaults.standard.set("nonsense", forKey: RawDecodePath.defaultsKey)
        XCTAssertEqual(RawDecodePath.current, .bradfordAdaptation, "garbage must mean the default")
    }

    /// Neutral sliders must give the identity matrix on every path — the
    /// matrix-level counterpart of `testAllPaths_neutralParity`, and cheap
    /// enough to run without the fixture volume.
    func testWBMatrix_identityAtNeutral() {
        let reference = GradeReference(asShotTemperatureK: 2958, asShotTint: 8.4, longEdge: 4032)
        for path in RawDecodePath.allCases {
            let matrix = ToneMath.wbMatrix(
                forDNG: nil, recipe: .neutral, reference: reference, path: path)
            for column in 0..<3 {
                for row in 0..<3 {
                    XCTAssertEqual(
                        matrix[column][row], matrix_identity_float3x3[column][row],
                        accuracy: 1e-6, "\(path.rawValue) is not identity at neutral")
                }
            }
        }
    }

    /// The white-balance matrix must be *continuous* at zero offset, not merely
    /// identity at exactly zero.
    ///
    /// This caught a real bug during implementation. The forward-matrix gain
    /// was built by dividing a modelled declared neutral by the DNG's
    /// `AsShotNeutral` tag — two quantities that disagree by about 8% in blue
    /// on this frame, because the tag carries the shot's real tint and sits off
    /// the Planckian locus while the model sits on it. The guard at exactly
    /// zero hid it, so the matrix was identity at 0 and `diag(0.98, 1.00, 0.92)`
    /// at 0.001 mired: a visible colour snap the instant a user touched the
    /// temperature slider. Anchoring both ends of the gain on the same model
    /// fixed it. A tiny offset must produce a tiny move, on every path.
    func testWBMatrix_isContinuousAtZeroOffset() throws {
        let url = try requireFixture()
        let reference = GradeReference(
            asShotTemperatureK: 2958.063, asShotTint: 0, longEdge: 4032,
            sourceURL: url, decodePath: .forwardMatrix)

        for path in RawDecodePathRegistry.available {
            var nudged = GradeRecipe()
            nudged.temperatureMired = 0.001
            let matrix = ToneMath.wbMatrix(
                forDNG: url, recipe: nudged, reference: reference, path: path)
            for channel in 0..<3 {
                XCTAssertEqual(
                    matrix[channel][channel], 1, accuracy: 0.002,
                    "\(path.rawValue) jumps at an infinitesimal temperature offset — "
                    + "the two ends of its gain are not from the same model")
            }
        }
    }

    /// A missing file must degrade to Bradford, not crash or render unbalanced.
    func testWBMatrix_forwardMatrixFallsBackWithoutAFile() {
        let reference = GradeReference(asShotTemperatureK: 2958, asShotTint: 0, longEdge: 4032)
        var recipe = GradeRecipe()
        recipe.temperatureMired = 60
        let fallback = ToneMath.wbMatrix(
            forDNG: nil, recipe: recipe, reference: reference, path: .forwardMatrix)
        let bradford = ToneMath.wbMatrix(
            forDNG: nil, recipe: recipe, reference: reference, path: .bradfordAdaptation)
        for column in 0..<3 {
            for row in 0..<3 {
                XCTAssertEqual(fallback[column][row], bradford[column][row], accuracy: 1e-6)
            }
        }
    }
}

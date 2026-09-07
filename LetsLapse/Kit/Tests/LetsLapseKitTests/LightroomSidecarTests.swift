import XCTest
@testable import LetsLapseKit

/// Reading Lightroom's sidecar, and turning it into a grade.
///
/// The fixture is a REAL export — `_WEX3825.xmp` from a Sony A7 IV, Lightroom
/// 17.5, with the AI mask's 229 KB payload trimmed to a stand-in. Everything
/// asserted below is a fact about that file, so a change in Adobe's schema
/// shows up here rather than as a quietly wrong import.
final class LightroomSidecarTests: XCTestCase {

    private func fixture() throws -> LightroomSidecar {
        guard let url = Bundle.module.url(
            forResource: "lightroom-_WEX3825", withExtension: "xmp") else {
            throw XCTSkip("fixture missing from the test bundle")
        }
        return try LightroomSidecar.read(contentsOf: url)
    }

    // MARK: - Parsing

    func testReadsTheGlobalSliders() throws {
        let sidecar = try fixture()
        XCTAssertEqual(sidecar.double("Exposure2012"), 0.29)
        XCTAssertEqual(sidecar.double("Contrast2012"), 6)
        XCTAssertEqual(sidecar.double("Highlights2012"), -78)
        XCTAssertEqual(sidecar.double("Shadows2012"), 60)
        XCTAssertEqual(sidecar.double("Whites2012"), 16)
        XCTAssertEqual(sidecar.double("Blacks2012"), -17)
        XCTAssertEqual(sidecar.double("Vibrance"), 15)
        XCTAssertEqual(sidecar.double("Sharpness"), 40)
        XCTAssertEqual(sidecar.double("ColorNoiseReduction"), 25)
    }

    func testReadsTheIdentifyingHeader() throws {
        let sidecar = try fixture()
        XCTAssertEqual(sidecar.rawFileName, "_WEX3825.ARW")
        XCTAssertEqual(sidecar.cameraProfile, "Adobe Standard")
        XCTAssertEqual(sidecar.whiteBalance, "As Shot")
        XCTAssertEqual(sidecar.processVersion, "15.4")
        XCTAssertFalse(sidecar.hasCrop)
    }

    func testAPlusPrefixedValueParsesAsPositive() throws {
        // Lightroom writes "+0.29" and "-78"; both have to read as numbers.
        let sidecar = try fixture()
        XCTAssertEqual(sidecar.settings["Exposure2012"], "+0.29")
        XCTAssertEqual(sidecar.double("Exposure2012"), 0.29)
    }

    func testTheImageCurveIsLinearAndTheProfileLookCurveIsNot() throws {
        let sidecar = try fixture()
        // The image's own curve is untouched…
        XCTAssertEqual(sidecar.settings["ToneCurveName2012"], "Linear")
        XCTAssertTrue(sidecar.toneCurve.allSatisfy(\.isNeutral),
                      "the image curve should be the identity in this file")
        // …but Adobe Color's is a real S-curve, and it is what makes the
        // profile look like itself. Seven points, lifting 224 to 230.
        XCTAssertEqual(sidecar.lookToneCurve.count, 7)
        XCTAssertFalse(sidecar.lookToneCurve.allSatisfy(\.isNeutral))
        XCTAssertEqual(sidecar.lookToneCurve.first, .init(input: 0, output: 0))
        XCTAssertTrue(sidecar.lookToneCurve.contains(.init(input: 224, output: 230)))
        XCTAssertTrue(sidecar.lookToneCurve.contains(.init(input: 22, output: 16)))
    }

    func testReadsBothCorrectionsAndTheirMasks() throws {
        let sidecar = try fixture()
        XCTAssertEqual(sidecar.corrections.count, 2)

        let sky = sidecar.corrections[0]
        XCTAssertEqual(sky.name, "Mask 1")
        XCTAssertTrue(sky.isActive)
        XCTAssertFalse(sky.isNeutral)
        XCTAssertEqual(sky.double("Clarity2012"), 0.947978)
        XCTAssertEqual(sky.double("Temperature"), -0.343056)
        XCTAssertEqual(sky.masks.count, 1)
        XCTAssertTrue(sky.masks[0].isImage)
        XCTAssertEqual(sky.masks[0].name, "Sky 1")

        let radial = sidecar.corrections[1]
        XCTAssertEqual(radial.name, "Mask 2")
        XCTAssertEqual(radial.double("Clarity2012"), 0.225905)
        XCTAssertEqual(radial.double("Temperature"), 1)
        XCTAssertEqual(radial.masks.count, 1)
        XCTAssertTrue(radial.masks[0].isRadialGradient)
        XCTAssertEqual(radial.masks[0].name, "Radial Gradient 1")
    }

    func testTheAIMaskCarriesItsBitmapKeyedByDigest() throws {
        let sidecar = try fixture()
        let mask = sidecar.corrections[0].masks[0]
        let digest = try XCTUnwrap(mask.digest)
        XCTAssertEqual(digest, "9945A8A33C5B19384EB3EB5674D278C2")
        // The whole point: Lightroom ships the AI mask's pixels, so a future
        // decoder does not need Adobe's segmentation model — only their
        // encoding.
        XCTAssertNotNil(sidecar.maskTables[digest],
                        "the sidecar's crs:Table_<digest> should be keyed by the mask's digest")
    }

    func testAMaskTableIsNotMistakenForASetting() throws {
        let sidecar = try fixture()
        XCTAssertNil(sidecar.settings["Table_9945A8A33C5B19384EB3EB5674D278C2"],
                     "the payload belongs in maskTables, not among the sliders")
    }

    func testAnEmptyDocumentIsRejectedRatherThanReadAsNeutral() {
        let notASidecar = Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"></x:xmpmeta>".utf8)
        XCTAssertThrowsError(try LightroomSidecar.parse(notASidecar)) { error in
            XCTAssertEqual(error as? LightroomSidecar.ParseError, .notALightroomSidecar)
        }
    }

    func testTornXMLThrowsRatherThanReturningHalfAGrade() {
        let torn = Data("<x:xmpmeta><rdf:Description crs:Exposure2012=\"+1\"".utf8)
        XCTAssertThrowsError(try LightroomSidecar.parse(torn))
    }

    // MARK: - What it admits it cannot do

    func testTheProfileLookCurveIsReportedAsUnsupported() throws {
        let sidecar = try fixture()
        XCTAssertTrue(
            sidecar.unsupported.contains { $0.contains("look curve") },
            "the profile's own curve is a real part of the render and must be reported; got \(sidecar.unsupported)")
    }

    func testTheAIMaskIsReportedAsUnsupported() throws {
        let sidecar = try fixture()
        XCTAssertTrue(
            sidecar.unsupported.contains { $0.contains("Sky 1") && $0.contains("AI mask") },
            "got \(sidecar.unsupported)")
    }

    func testAnUntouchedPanelIsNotReportedAsLost() throws {
        let sidecar = try fixture()
        // Every HSL slider in this file is 0, so nothing about HSL should be
        // claimed as lost — an import that cries about controls the
        // photographer never moved is noise.
        XCTAssertFalse(sidecar.unsupported.contains { $0.contains("HSL") },
                       "got \(sidecar.unsupported)")
        XCTAssertFalse(sidecar.unsupported.contains { $0.contains("Dehaze") })
        XCTAssertFalse(sidecar.unsupported.contains { $0.contains("Crop") })
    }

    // MARK: - Mapping

    func testExposureTransfersExactly() throws {
        let map = LightroomImport.map(try fixture())
        // Both sides are EV. This one number should need no interpretation.
        XCTAssertEqual(try XCTUnwrap(map.adjustments["exposure"]), 0.29, accuracy: 1e-9)
        XCTAssertTrue(map.applied.contains { $0.contains("exposure") && $0.contains("exact") })
    }

    func testHundredScaleSlidersLandOnTheEngineScale() throws {
        let map = LightroomImport.map(try fixture())
        XCTAssertEqual(try XCTUnwrap(map.adjustments["highlights"]), -0.78, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(map.adjustments["shadows"]), 0.60, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(map.adjustments["whites"]), 0.16, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(map.adjustments["blacks"]), -0.17, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(map.adjustments["vibrance"]), 0.15, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(map.adjustments["sharpen"]), 0.40, accuracy: 1e-9)
    }

    func testAnUntouchedSliderIsLeftOutRatherThanWrittenAsZero() throws {
        let map = LightroomImport.map(try fixture())
        // Saturation and Texture are 0 in the file. Writing them would be
        // harmless but would make the import report claim work it did not do.
        XCTAssertNil(map.adjustments["saturation"])
        XCTAssertNil(map.adjustments["texture"])
        XCTAssertNil(map.adjustments["clarity"])
    }

    func testAsShotWhiteBalanceIsNotTurnedIntoAnOwnedWhite() throws {
        let map = LightroomImport.map(try fixture())
        // "As Shot" is our default too — owning a white here would pin a
        // decision the photographer never made.
        XCTAssertNil(map.adjustments["whiteMired"])
        XCTAssertNil(map.adjustments["whiteTint"])
    }

    // MARK: - The radial mask's geometry

    func testTheRadialMaskBecomesAMaskShape() throws {
        let map = LightroomImport.map(try fixture())
        XCTAssertEqual(map.masks.count, 1, "only the radial has a shape we can rebuild")
        let imported = try XCTUnwrap(map.masks.first)
        XCTAssertEqual(imported.shape.kind, .radial)
        // Top -0.025958 Left -0.30958 Bottom 0.644092 Right 0.786439.
        XCTAssertEqual(Double(imported.shape.center.x), 0.2384295, accuracy: 1e-6)
        XCTAssertEqual(Double(imported.shape.center.y), 0.309067, accuracy: 1e-6)
        XCTAssertEqual(imported.shape.radiusX, 0.5480095, accuracy: 1e-6)
        XCTAssertEqual(imported.shape.radiusY, 0.335025, accuracy: 1e-6)
        XCTAssertEqual(imported.shape.rotationDegrees, 0, accuracy: 1e-9)
        XCTAssertEqual(imported.shape.feather, 0.5, accuracy: 1e-9)
    }

    func testTheBoundingBoxRoundTripsBackToLightroomsOwnEdges() throws {
        // The mapping is only right if the ellipse it builds has the same
        // edges Adobe named — centre ± radius, in each axis.
        let map = LightroomImport.map(try fixture())
        let shape = try XCTUnwrap(map.masks.first).shape
        XCTAssertEqual(Double(shape.center.x) - shape.radiusX, -0.30958, accuracy: 1e-6)
        XCTAssertEqual(Double(shape.center.x) + shape.radiusX, 0.786439, accuracy: 1e-6)
        XCTAssertEqual(Double(shape.center.y) - shape.radiusY, -0.025958, accuracy: 1e-6)
        XCTAssertEqual(Double(shape.center.y) + shape.radiusY, 0.644092, accuracy: 1e-6)
    }

    func testTheRadialsLocalValuesLandOnTheMaskedGrade() throws {
        let map = LightroomImport.map(try fixture())
        let imported = try XCTUnwrap(map.masks.first)
        // LocalClarity2012 0.225905 -> clarity 0.2259 (both ±1).
        XCTAssertEqual(try XCTUnwrap(imported.adjustments["clarity"]), 0.225905, accuracy: 1e-6)
        // LocalTemperature 1 -> the full ±25 mired our masked Temp travels.
        XCTAssertEqual(try XCTUnwrap(imported.adjustments["temperature"]), 25, accuracy: 1e-9)
    }

    func testFlippedAndInvertedComposeToPutTheGradeInside() throws {
        // Flipped="true", MaskInverted="false" — exactly one says inside, so
        // the grade lands inside the ellipse. THE ONE INFERRED MAPPING in the
        // importer: a reference render is what confirms it.
        let sidecar = try fixture()
        let mask = sidecar.corrections[1].masks[0]
        XCTAssertEqual(mask.bool("Flipped"), true)
        XCTAssertFalse(mask.isInverted)
        XCTAssertFalse(LightroomImport.appliesOutside(mask))
    }

    func testBothFlagsAgreeingPutsTheGradeOutside() throws {
        var mask = LightroomSidecar.Mask()
        mask.kind = "CircularGradient"
        mask.attributes = ["Flipped": "true", "Top": "0", "Left": "0", "Bottom": "1", "Right": "1"]
        mask.isInverted = true
        XCTAssertTrue(LightroomImport.appliesOutside(mask),
                      "flipped AND inverted cancel back to the legacy outside default")
        mask.attributes["Flipped"] = "false"
        mask.isInverted = false
        XCTAssertTrue(LightroomImport.appliesOutside(mask))
    }

    func testTheSkyCorrectionIsDroppedButSaidOutLoud() throws {
        let map = LightroomImport.map(try fixture())
        // Its only mask is an AI bitmap, so there is nowhere for its Clarity
        // and Temp to go — and the report has to carry that.
        XCTAssertEqual(map.masks.count, 1)
        XCTAssertTrue(map.unsupported.contains { $0.contains("Sky 1") })
    }

    func testAnInactiveCorrectionIsIgnored() throws {
        var correction = LightroomSidecar.Correction()
        correction.isActive = false
        correction.locals = ["Exposure2012": "1"]
        var sidecar = LightroomSidecar()
        sidecar.settings["Exposure2012"] = "0"
        sidecar.corrections = [correction]
        XCTAssertTrue(LightroomImport.map(sidecar).masks.isEmpty)
    }

    // MARK: - Finding the sidecar

    func testFindsTheSidecarBesideARawFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = directory.appendingPathComponent("_WEX3825.ARW")
        try Data().write(to: raw)
        XCTAssertNil(LightroomSidecar.sidecarURL(forRawFile: raw))
        let sidecar = directory.appendingPathComponent("_WEX3825.xmp")
        try Data().write(to: sidecar)
        XCTAssertEqual(LightroomSidecar.sidecarURL(forRawFile: raw), sidecar)
    }
}

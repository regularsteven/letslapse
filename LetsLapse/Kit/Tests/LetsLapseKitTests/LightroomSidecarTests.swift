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

    func testASkyIsNotReportedAsLostBecauseItIsSubstituted() throws {
        let sidecar = try fixture()
        // Adobe's sky bitmap is undecodable, but "the sky" is a fact about the
        // photograph rather than an Adobe idea — so it is routed onto our own
        // segmentation and reported as carried, with the caveat.
        XCTAssertFalse(
            sidecar.unsupported.contains { $0.contains("Sky 1") },
            "got \(sidecar.unsupported)")
    }

    func testANonSkyAIMaskIsStillReportedAsUnsupported() throws {
        var mask = LightroomSidecar.Mask()
        mask.kind = "Image"
        mask.name = "Subject 1"
        mask.attributes = ["MaskSubType": "1", "MaskDigest": "ABC"]
        var correction = LightroomSidecar.Correction()
        correction.locals = ["Exposure2012": "0.5"]
        correction.masks = [mask]
        var sidecar = LightroomSidecar()
        sidecar.settings["Exposure2012"] = "0"
        sidecar.corrections = [correction]
        // We have no "subject" region, so there is nowhere for it to go.
        XCTAssertFalse(LightroomImport.isSky(mask))
        XCTAssertTrue(LightroomImport.map(sidecar).masks.isEmpty)
    }

    func testSkyIsRecognisedBySubtypeAndByName() throws {
        var bySubtype = LightroomSidecar.Mask()
        bySubtype.kind = "Image"
        bySubtype.name = "Renamed by the photographer"
        bySubtype.attributes = ["MaskSubType": "2"]
        XCTAssertTrue(LightroomImport.isSky(bySubtype))

        var byName = LightroomSidecar.Mask()
        byName.kind = "Image"
        byName.name = "sky 3"
        XCTAssertTrue(LightroomImport.isSky(byName))

        // A gradient is never an AI mask, whatever it is called.
        var gradient = LightroomSidecar.Mask()
        gradient.kind = "CircularGradient"
        gradient.name = "Sky glow"
        XCTAssertFalse(LightroomImport.isSky(gradient))
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

    func testExposureTransfersExactlyThenTakesTheCalibration() throws {
        let map = LightroomImport.map(try fixture())
        // Both sides are EV, so the sidecar's +0.29 transfers unchanged — and
        // then the calibration's trim goes on, because our renderer's baseline
        // sits brighter than Lightroom's on every file measured.
        let expected = 0.29 + LightroomImport.calibration.exposureOffsetEV
        XCTAssertEqual(try XCTUnwrap(map.adjustments["exposure"]), expected, accuracy: 1e-9)
        XCTAssertTrue(map.applied.contains { $0.contains("exposure") && $0.contains("exact") })
        XCTAssertTrue(map.applied.contains { $0.contains("Calibration") })
        XCTAssertEqual(map.calibrationID, LightroomImport.calibration.id)
    }

    func testTheCalibrationIsAppliedEvenWhenTheSidecarMovedNothing() throws {
        // It corrects one renderer against another, which is as true at
        // +0.00 EV as at +0.29 — so it must not be conditional on the file
        // having touched exposure.
        var sidecar = LightroomSidecar()
        sidecar.settings["Exposure2012"] = "0"
        let map = LightroomImport.map(sidecar)
        XCTAssertEqual(try XCTUnwrap(map.adjustments["exposure"]),
                       LightroomImport.calibration.exposureOffsetEV, accuracy: 1e-9)
    }

    func testHundredScaleSlidersLandOnTheEngineScale() throws {
        let map = LightroomImport.map(try fixture())
        XCTAssertEqual(try XCTUnwrap(map.adjustments["highlights"]), -0.78, accuracy: 1e-9)
        // Shadows takes the calibration's scale: ours lift further than
        // Lightroom's for the same number.
        XCTAssertEqual(try XCTUnwrap(map.adjustments["shadows"]),
                       0.60 * LightroomImport.calibration.shadowsScale, accuracy: 1e-9)
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

    /// The radial, which is the one with a rebuildable shape.
    private func radial(_ map: LightroomImport) throws -> LightroomImport.MaskedGrade {
        try XCTUnwrap(map.masks.first { $0.shape != nil })
    }

    func testBothMasksArriveNowThatSkyIsSubstituted() throws {
        let map = LightroomImport.map(try fixture())
        XCTAssertEqual(map.masks.count, 2)
        let sky = try XCTUnwrap(map.masks.first { $0.shape == nil })
        XCTAssertEqual(sky.target, .semantic("sky"))
        XCTAssertEqual(sky.name, "Sky 1")
        // Its correction's values come with it — the whole point of the
        // substitution is that the EDIT survives even though the boundary
        // is ours.
        XCTAssertEqual(try XCTUnwrap(sky.adjustments["clarity"]), 0.947978, accuracy: 1e-6)
        XCTAssertNotNil(sky.adjustments["temperature"])
    }

    func testTheRadialMaskBecomesAMaskShape() throws {
        let map = LightroomImport.map(try fixture())
        let imported = try radial(map)
        XCTAssertEqual(try XCTUnwrap(imported.shape).kind, .radial)
        // Top -0.025958 Left -0.30958 Bottom 0.644092 Right 0.786439.
        let shape = try XCTUnwrap(imported.shape)
        XCTAssertEqual(Double(shape.center.x), 0.2384295, accuracy: 1e-6)
        XCTAssertEqual(Double(shape.center.y), 0.309067, accuracy: 1e-6)
        XCTAssertEqual(shape.radiusX, 0.5480095, accuracy: 1e-6)
        XCTAssertEqual(shape.radiusY, 0.335025, accuracy: 1e-6)
        XCTAssertEqual(shape.rotationDegrees, 0, accuracy: 1e-9)
        XCTAssertEqual(shape.feather, 0.5, accuracy: 1e-9)
    }

    func testTheBoundingBoxRoundTripsBackToLightroomsOwnEdges() throws {
        // The mapping is only right if the ellipse it builds has the same
        // edges Adobe named — centre ± radius, in each axis.
        let map = LightroomImport.map(try fixture())
        let shape = try XCTUnwrap(try radial(map).shape)
        XCTAssertEqual(Double(shape.center.x) - shape.radiusX, -0.30958, accuracy: 1e-6)
        XCTAssertEqual(Double(shape.center.x) + shape.radiusX, 0.786439, accuracy: 1e-6)
        XCTAssertEqual(Double(shape.center.y) - shape.radiusY, -0.025958, accuracy: 1e-6)
        XCTAssertEqual(Double(shape.center.y) + shape.radiusY, 0.644092, accuracy: 1e-6)
    }

    func testTheRadialsLocalValuesLandOnTheMaskedGrade() throws {
        let map = LightroomImport.map(try fixture())
        let imported = try radial(map)
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

    func testTheSkySubstitutionIsSaidOutLoud() throws {
        let map = LightroomImport.map(try fixture())
        // Carried, but with the caveat: the edit is Adobe's, the boundary is
        // ours, and a photographer comparing the two should hear that from us.
        XCTAssertTrue(
            map.applied.contains { $0.contains("Sky 1") && $0.contains("Sky region") },
            "got \(map.applied)")
        XCTAssertTrue(map.applied.contains { $0.contains(LightroomImport.skySubstitutionNote) })
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

// MARK: - Geometry is written in the sensor frame

/// Lightroom's crop rect and its gradient masks describe the SENSOR's frame;
/// a portrait shot off a landscape sensor is only turned on display. Measured
/// 2026-09-07 on `_WEB5253` (orientation 8): read through the sensor frame
/// its linear gradient correlates +0.34 with what Lightroom rendered, read
/// through the display frame +0.03. These pin the turn.
final class LightroomMaskOrientationTests: XCTestCase {

    private func sidecar(orientation: Int, mask: LightroomSidecar.Mask) -> LightroomSidecar {
        var correction = LightroomSidecar.Correction()
        correction.locals = ["Exposure2012": "0.1"]
        correction.masks = [mask]
        var sidecar = LightroomSidecar()
        sidecar.settings["Exposure2012"] = "0"
        sidecar.orientation = orientation
        sidecar.corrections = [correction]
        return sidecar
    }

    private var portraitLinear: LightroomSidecar.Mask {
        // _WEB5253's own gradient: full on the sensor's right, fading left.
        var mask = LightroomSidecar.Mask()
        mask.kind = "Gradient"
        mask.attributes = ["ZeroX": "0.307433", "ZeroY": "0.525871",
                           "FullX": "0.626961", "FullY": "0.525871"]
        return mask
    }

    func testOrientationIsReadFromTheRootDescription() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          xmlns:tiff="http://ns.adobe.com/tiff/1.0/" tiff:Orientation="8" crs:Exposure2012="+0.10"/>
        </rdf:RDF></x:xmpmeta>
        """
        let parsed = try LightroomSidecar.parse(Data(xml.utf8))
        XCTAssertEqual(parsed.orientation, 8)
        XCTAssertNil(parsed.settings["Orientation"], "a tiff: attribute is not a crs: setting")
    }

    func testAnUprightFileKeepsItsShapesAsWritten() throws {
        let map = LightroomImport.map(sidecar(orientation: 1, mask: portraitLinear))
        let shape = try XCTUnwrap(map.masks.first?.shape)
        XCTAssertEqual(Double(shape.start.x), 0.626961, accuracy: 1e-6)
        XCTAssertEqual(Double(shape.end.x), 0.307433, accuracy: 1e-6)
        XCTAssertEqual(Double(shape.start.y), 0.525871, accuracy: 1e-6)
    }

    func testAPortraitFilesLinearGradientTurnsWithThePicture() throws {
        // Orientation 8 turns the sensor 90° anticlockwise: sensor (x, y)
        // lands at (y, 1 − x). The sensor's right-hand FULL end is the
        // picture's top; ZERO, on the sensor's left, is the picture's bottom.
        let map = LightroomImport.map(sidecar(orientation: 8, mask: portraitLinear))
        let shape = try XCTUnwrap(map.masks.first?.shape)
        XCTAssertEqual(shape.kind, .linear)
        XCTAssertEqual(Double(shape.start.x), 0.525871, accuracy: 1e-6)
        XCTAssertEqual(Double(shape.start.y), 1 - 0.626961, accuracy: 1e-6, "full end at the top")
        XCTAssertEqual(Double(shape.end.x), 0.525871, accuracy: 1e-6)
        XCTAssertEqual(Double(shape.end.y), 1 - 0.307433, accuracy: 1e-6, "zero end at the bottom")
    }

    func testAQuarterTurnSwapsARadialsRadiiAndKeepsItsAngle() throws {
        var mask = LightroomSidecar.Mask()
        mask.kind = "CircularGradient"
        mask.attributes = ["Top": "0.1", "Left": "0.2", "Bottom": "0.5", "Right": "0.8",
                           "Feather": "50", "Angle": "20", "Flipped": "true"]
        let sensor = try XCTUnwrap(LightroomImport.shape(from: mask))
        XCTAssertEqual(sensor.radiusX, 0.3, accuracy: 1e-9)
        XCTAssertEqual(sensor.radiusY, 0.2, accuracy: 1e-9)
        let turned = try XCTUnwrap(LightroomImport.shape(from: mask, orientation: 6))
        // Orientation 6 turns the sensor 90° clockwise: (x, y) → (1 − y, x).
        XCTAssertEqual(Double(turned.center.x), 1 - 0.3, accuracy: 1e-9)
        XCTAssertEqual(Double(turned.center.y), 0.5, accuracy: 1e-9)
        XCTAssertEqual(turned.radiusX, 0.2, accuracy: 1e-9)
        XCTAssertEqual(turned.radiusY, 0.3, accuracy: 1e-9)
        XCTAssertEqual(turned.rotationDegrees, sensor.rotationDegrees, accuracy: 1e-9)
        XCTAssertEqual(turned.feather, sensor.feather, accuracy: 1e-9)
    }

    func testAHalfTurnMirrorsBothAxes() {
        let shape = MaskShape(kind: .radial, center: CGPoint(x: 0.2, y: 0.3),
                              radiusX: 0.1, radiusY: 0.4)
        let turned = shape.fromSensorFrame(exifOrientation: 3)
        XCTAssertEqual(Double(turned.center.x), 0.8, accuracy: 1e-9)
        XCTAssertEqual(Double(turned.center.y), 0.7, accuracy: 1e-9)
        XCTAssertEqual(turned.radiusX, 0.1, accuracy: 1e-9)
        XCTAssertEqual(turned.radiusY, 0.4, accuracy: 1e-9)
    }

    func testTheTurnedEllipseCoversTheSamePixels() {
        // The whole reason the radii swap: a point inside the sensor-frame
        // ellipse must still be inside once both the picture and the shape
        // have been turned.
        let shape = MaskShape(kind: .radial, center: CGPoint(x: 0.3, y: 0.6),
                              radiusX: 0.25, radiusY: 0.1, rotationDegrees: 15, feather: 0)
        let sensorSize = CGSize(width: 600, height: 400)
        let displaySize = CGSize(width: 400, height: 600)
        let turned = shape.fromSensorFrame(exifOrientation: 8)
        for (x, y) in [(0.3, 0.6), (0.45, 0.62), (0.1, 0.55), (0.3, 0.75), (0.5, 0.5), (0.9, 0.9)] {
            let sensorPoint = CGPoint(x: x * 600, y: y * 400)
            let displayPoint = CGPoint(x: y * 400, y: (1 - x) * 600)
            XCTAssertEqual(
                shape.coverage(at: sensorPoint, in: sensorSize),
                turned.coverage(at: displayPoint, in: displaySize), accuracy: 1e-6,
                "at (\(x), \(y))")
        }
    }
}

// MARK: - Straighten, dehaze and the panel travel on the import

final class LightroomImportControlsTests: XCTestCase {

    private func sidecar(_ settings: [String: String]) -> LightroomSidecar {
        var sidecar = LightroomSidecar()
        sidecar.settings = settings
        sidecar.settings["Exposure2012"] = sidecar.settings["Exposure2012"] ?? "0"
        return sidecar
    }

    func testTheStraightenAngleBecomesTheLevelWithItsSignFlipped() throws {
        // Lightroom's +0.797° turns the picture anticlockwise (the bench's
        // sweep bottoms out at −0.64° applied on _DSC6509); ours is positive
        // clockwise, so the level is −0.797. Parsed rather than built, so the
        // sidecar's own "not carried" list is exercised too.
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          crs:Exposure2012="0.00" crs:HasCrop="True" crs:CropAngle="0.797294"
          crs:CropLeft="0.014768" crs:CropRight="0.985232" crs:CropTop="0" crs:CropBottom="1"/>
        </rdf:RDF></x:xmpmeta>
        """
        let map = LightroomImport.map(try LightroomSidecar.parse(Data(xml.utf8)))
        XCTAssertEqual(try XCTUnwrap(map.adjustments["rotation"]), -0.797294, accuracy: 1e-9)
        XCTAssertTrue(map.applied.contains { $0.contains("CropAngle") && $0.contains("level") })
        XCTAssertTrue(map.unsupported.contains { $0.contains("Crop rect") },
                      "the rect is still lost, and still said")
    }

    func testAStraightenBeyondTheLevelsTravelIsReportedNotClamped() {
        let map = LightroomImport.map(sidecar(["CropAngle": "23.5", "HasCrop": "True"]))
        XCTAssertNil(map.adjustments["rotation"])
        XCTAssertTrue(map.unsupported.contains { $0.contains("CropAngle") && $0.contains("beyond") })
    }

    func testNoStraightenWritesNoLevel() {
        let map = LightroomImport.map(sidecar(["CropAngle": "0", "HasCrop": "False"]))
        XCTAssertNil(map.adjustments["rotation"])
        XCTAssertFalse(map.unsupported.contains { $0.contains("Crop") })
    }

    func testDehazeIsCarriedThroughTheFittedResponse() throws {
        let map = LightroomImport.map(sidecar(["Dehaze": "+45"]))
        let amount = try XCTUnwrap(map.adjustments["dehaze"])
        XCTAssertEqual(amount, LightroomImport.dehazeAmount(forSidecarValue: 45), accuracy: 1e-12)
        XCTAssertGreaterThan(amount, 0)
        XCTAssertTrue(map.applied.contains { $0.contains("Dehaze +45") && $0.contains(DehazeCalibration.current.id) })
        XCTAssertFalse(map.unsupported.contains { $0.contains("Dehaze") })
    }

    func testTheDehazeResponseIsOddMonotoneAndCapped() {
        let calibration = DehazeCalibration.current
        XCTAssertEqual(calibration.id, "dh1")
        XCTAssertEqual(calibration.amount(forSidecarValue: 0), 0)
        XCTAssertEqual(calibration.amount(forSidecarValue: -30), -calibration.amount(forSidecarValue: 30), accuracy: 1e-12)
        var previous = 0.0
        for value in stride(from: 5.0, through: 100, by: 5) {
            let amount = calibration.amount(forSidecarValue: value)
            XCTAssertGreaterThanOrEqual(amount, previous, "never falls")
            XCTAssertLessThanOrEqual(amount, calibration.ceiling + 1e-9, "never past the ceiling")
            previous = amount
        }
        // dh1 is the slider's own number: 45 → 0.45, 89 → 0.89.
        XCTAssertEqual(calibration.amount(forSidecarValue: 45), 0.45, accuracy: 1e-12)
        XCTAssertEqual(calibration.amount(forSidecarValue: 89), 0.89, accuracy: 1e-12)
        // And a value past the slider's travel cannot run the recovery away.
        XCTAssertEqual(calibration.amount(forSidecarValue: 250), calibration.ceiling, accuracy: 1e-12)
    }

    func testALocalDehazeRidesTheMaskedGrade() throws {
        var correction = LightroomSidecar.Correction()
        correction.locals = ["Dehaze": "0.276687", "Clarity2012": "0.308813"]
        var mask = LightroomSidecar.Mask()
        mask.kind = "Image"
        mask.name = "Sky 1"
        mask.attributes = ["MaskSubType": "2"]
        correction.masks = [mask]
        var sidecar = LightroomSidecar()
        sidecar.settings["Exposure2012"] = "0"
        sidecar.corrections = [correction]
        let map = LightroomImport.map(sidecar)
        let sky = try XCTUnwrap(map.masks.first)
        XCTAssertEqual(try XCTUnwrap(sky.adjustments["dehaze"]), 0.276687, accuracy: 1e-6)
        XCTAssertEqual(sky.displayGrade.dehaze, 0.276687, accuracy: 1e-6)
        XCTAssertFalse(map.unsupported.contains { $0.contains("LocalDehaze") })
    }
}

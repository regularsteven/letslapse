import XCTest
import simd
@testable import LetsLapseKit

/// The declared-anchor white balance: what makes the same Temp/Tint mean the
/// same white on every frame of a shoot whose camera moved its own.
final class DeclaredWhiteBalanceTests: XCTestCase {

    private func reference(asShotK: Double, asShotTint: Double = 0) -> GradeReference {
        GradeReference(asShotTemperatureK: asShotK, asShotTint: asShotTint, longEdge: 4608)
    }

    private func declared(kelvin: Float?, tint: Float? = nil, offset: Float = 0) -> GradeRecipe {
        var recipe = GradeRecipe()
        recipe.declaredKelvin = kelvin
        recipe.declaredTint = tint
        recipe.temperatureMired = offset
        return recipe
    }

    private func assertClose(
        _ a: simd_float3x3, _ b: simd_float3x3, accuracy: Float = 1e-4,
        _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        for column in 0..<3 {
            for row in 0..<3 {
                XCTAssertEqual(a[column][row], b[column][row], accuracy: accuracy,
                               message, file: file, line: line)
            }
        }
    }

    // MARK: - Nothing declared is exactly what it was

    /// The whole change has to be invisible to every project that has not
    /// asked for it: no declared anchor, and the matrix is bit-for-bit the one
    /// the old code built — including the destination tint, which is only read
    /// once an anchor exists.
    func testNoDeclaredAnchor_ignoresAsShotTint() {
        var warmed = GradeRecipe()
        warmed.temperatureMired = 60
        warmed.tint = 0.3
        // Two references that differ ONLY in as-shot tint must, with nothing
        // declared, produce the same matrix — as they always did.
        let a = ToneMath.whiteBalanceMatrix(recipe: warmed, reference: reference(asShotK: 5635))
        let b = ToneMath.whiteBalanceMatrix(
            recipe: warmed, reference: reference(asShotK: 5635, asShotTint: 40))
        assertClose(a, b, accuracy: 1e-6, "as-shot tint leaked into an un-anchored render")
    }

    func testNeutralRecipe_isIdentityOnEveryPath() {
        let reference = reference(asShotK: 3408, asShotTint: -9.7)
        for path in RawDecodePath.allCases {
            let matrix = ToneMath.wbMatrix(
                forDNG: nil, recipe: .neutral, reference: reference, path: path)
            assertClose(matrix, matrix_identity_float3x3, accuracy: 1e-6, path.rawValue)
        }
    }

    // MARK: - Declaring a frame's own white changes nothing

    /// Pinning the anchor at exactly what the file was shot at is a no-op —
    /// the frame is already there. This is the test that pins the *direction*
    /// of the whole feature: get the sign wrong and this is a double move.
    func testDeclaringTheFilesOwnWhite_isIdentity() {
        let recipe = declared(kelvin: 5634.671, tint: 16.11278)
        let matrix = ToneMath.whiteBalanceMatrix(
            recipe: recipe, reference: reference(asShotK: 5634.671, asShotTint: 16.11278))
        assertClose(matrix, matrix_identity_float3x3, accuracy: 1e-5)
    }

    /// A declared Kelvin with no declared tint moves along the Kelvin axis
    /// alone: the file keeps its own green–magenta rather than being silently
    /// neutralised.
    func testDeclaredKelvinOnly_keepsTheFilesTint() {
        let recipe = declared(kelvin: 5634.671)
        let matrix = ToneMath.whiteBalanceMatrix(
            recipe: recipe, reference: reference(asShotK: 5634.671, asShotTint: 16.11278))
        assertClose(matrix, matrix_identity_float3x3, accuracy: 1e-5)
    }

    // MARK: - The invariant the feature exists for

    /// **The as-shot reading cancels.** White balancing divides by the
    /// illuminant, so a decode at as-shot A followed by an adaptation from the
    /// declared white D to A leaves 1/D — with no A in it at all. That is the
    /// entire claim of the feature, and it shows up algebraically as
    ///
    ///     M(D → A₂) == M(D → A₁) · M(A₁ → A₂)
    ///
    /// Two frames whose camera disagreed by 116 mired therefore land on the
    /// same white when they declare the same one. These are the real readings
    /// from `_WEX4301` and `_WEX4302`.
    func testSameDeclaredWhite_cancelsTheAsShotDifference() {
        let a1 = 5634.671, t1 = 16.11278
        let a2 = 3408.253, t2 = -9.68293
        let declaredK: Float = 5634.671, declaredTint: Float = 16.11278

        let m1 = ToneMath.whiteBalanceMatrix(
            recipe: declared(kelvin: declaredK, tint: declaredTint),
            reference: reference(asShotK: a1, asShotTint: t1))
        let m2 = ToneMath.whiteBalanceMatrix(
            recipe: declared(kelvin: declaredK, tint: declaredTint),
            reference: reference(asShotK: a2, asShotTint: t2))
        // The adaptation between the two as-shot whites, built from the same
        // public function so the test cannot drift from the implementation.
        let between = ToneMath.whiteBalanceMatrix(
            recipe: declared(kelvin: Float(a1), tint: Float(t1)),
            reference: reference(asShotK: a2, asShotTint: t2))

        assertClose(m1 * between, m2, accuracy: 1e-4,
                    "the declared white did not cancel the as-shot difference")
    }

    /// Without an anchor the same two frames do NOT cancel — which is the bug
    /// being fixed, pinned by the same identity so it cannot come back by
    /// accident. A relative offset lands each frame on a *different* white
    /// (its own as-shot, moved by the offset), so `M · between` misses `M₂` by
    /// most of the camera's step rather than by nothing.
    func testWithoutAnAnchor_theAsShotDifferenceSurvives() {
        let a1 = 5634.671, t1 = 16.11278
        let a2 = 3408.253, t2 = -9.68293
        var offsetOnly = GradeRecipe()
        offsetOnly.temperatureMired = -38.7   // what Steven's keyframes resolved to at 0.875

        let m1 = ToneMath.whiteBalanceMatrix(
            recipe: offsetOnly, reference: reference(asShotK: a1, asShotTint: t1))
        let m2 = ToneMath.whiteBalanceMatrix(
            recipe: offsetOnly, reference: reference(asShotK: a2, asShotTint: t2))
        let between = ToneMath.whiteBalanceMatrix(
            recipe: declared(kelvin: Float(a1), tint: Float(t1)),
            reference: reference(asShotK: a2, asShotTint: t2))

        let residual = m1 * between
        var maximum: Float = 0
        for column in 0..<3 {
            for row in 0..<3 { maximum = max(maximum, abs(residual[column][row] - m2[column][row])) }
        }
        XCTAssertGreaterThan(maximum, 0.2,
                             "a relative offset should ride the camera's step, not cancel it")
    }

    /// The offset still layers on top of a declared anchor, so a preset's
    /// "warm it a little" survives being pinned.
    func testOffsetStillAppliesOverADeclaredAnchor() {
        let reference = reference(asShotK: 5000, asShotTint: 0)
        let pinned = ToneMath.whiteBalanceMatrix(
            recipe: declared(kelvin: 5000, tint: 0), reference: reference)
        let warmed = ToneMath.whiteBalanceMatrix(
            recipe: declared(kelvin: 5000, tint: 0, offset: 40), reference: reference)
        assertClose(pinned, matrix_identity_float3x3, accuracy: 1e-5)
        // Warmer means the red channel gains on the blue one.
        XCTAssertGreaterThan(warmed[0][0] / warmed[2][2], 1.05,
                             "a positive mired offset over a declared anchor did not warm")
    }

    /// The converter's tint axis runs the other way and at a different scale;
    /// the constant is measured, and its sign is the half that has been wrong
    /// before.
    func testConverterTintConversion_signAndScale() {
        XCTAssertEqual(ToneMath.recipeTint(converter: -50), 1, accuracy: 1e-6)
        XCTAssertEqual(ToneMath.recipeTint(converter: 50), -1, accuracy: 1e-6)
    }

    // MARK: - Cache keys

    func testCacheToken_isUnchangedWithoutAnAnchorAndMovesWithOne() {
        var recipe = GradeRecipe()
        recipe.temperatureMired = 20
        let plain = recipe.cacheToken
        XCTAssertFalse(recipe.hasDeclaredWhiteBalance)
        recipe.declaredKelvin = 5200
        XCTAssertTrue(recipe.hasDeclaredWhiteBalance)
        XCTAssertNotEqual(recipe.cacheToken, plain)
        XCTAssertTrue(recipe.cacheToken.hasPrefix(plain))
    }
}

/// Measuring a shoot's white balance, and taking the camera back out of it.
final class WhiteBalanceSeriesTests: XCTestCase {

    /// A dusk run the way a camera actually delivers one: real light walking
    /// steadily warmer, handed over in eighty-frame plateaus, with one
    /// re-decision two-thirds of the way through.
    private func staircase(
        count: Int = 400, startMired: Double = 150, endMired: Double = 200,
        plateau: Int = 40, lurchAt: Int? = 260, lurchMired: Double = 90
    ) -> WhiteBalanceSeries {
        var samples: [WhiteBalanceSample] = []
        var lurch = 0.0
        for frame in 0..<count {
            let progress = Double(frame) / Double(count - 1)
            let smooth = startMired + (endMired - startMired) * progress
            // Quantise onto plateaus: the camera holds a value, then jumps.
            let step = (endMired - startMired) / Double(count / plateau)
            let held = startMired + (smooth - startMired / 1) .rounded(.down) * 0
                + Double(Int((smooth - startMired) / step)) * step
            if let lurchAt, frame >= lurchAt { lurch = lurchMired }
            samples.append(WhiteBalanceSample(
                frame: frame, file: String(format: "F%04d.ARW", frame),
                kelvin: Float(1e6 / (held + lurch)), tint: 0,
                seconds: Double(frame) * 2.63))
        }
        return WhiteBalanceSeries(samples: samples)
    }

    func testCorrection_removesTheLurchAndKeepsTheDrift() {
        let series = staircase()
        let corrected = series.correctedDeclarations()
        let mireds = corrected.map(\.mired)

        // The 90-mired re-decision is gone: nothing steps visibly any more.
        let steps = zip(mireds, mireds.dropFirst()).map { abs($1 - $0) }
        XCTAssertLessThan(steps.max() ?? 0, WhiteBalanceSeries.visibleStepMired,
                          "a visible step survived the correction")

        // …and the run's real 50-mired drift is still there, not flattened.
        let travel = (mireds.max() ?? 0) - (mireds.min() ?? 0)
        XCTAssertGreaterThan(travel, 35, "the real drift was flattened away")
        XCTAssertLessThan(travel, 65, "the lurch leaked into the corrected drift")
    }

    /// The anchor decides the level, not the shape: whichever frame is
    /// nominated, the corrected curve passes through that frame's own reading.
    func testCorrection_passesThroughTheAnchorFramesOwnReading() {
        let series = staircase()
        for position in [0.0, 0.5, 1.0] {
            let corrected = series.correctedDeclarations(anchorPosition: position)
            let index = Int((Double(series.samples.count - 1) * position).rounded())
            XCTAssertEqual(corrected[index].mired, series.samples[index].mired, accuracy: 0.5,
                           "anchor \(position) did not pass through its own frame")
        }
    }

    func testGrossStepLimit_scalesWithTheRunAndHasAFloor() {
        // A still run: the floor decides.
        XCTAssertEqual(WhiteBalanceSeries.grossStepLimit(mireds: Array(repeating: 150, count: 50)),
                       WhiteBalanceSeries.grossStepMired, accuracy: 1e-9)
        // A run that travels 200 mired: a third of that.
        let travelling = (0..<200).map { 150.0 + Double($0) }
        XCTAssertGreaterThan(WhiteBalanceSeries.grossStepLimit(mireds: travelling), 50)
    }

    func testCorrection_isANoOpOnAShortOrEmptySeries() {
        XCTAssertEqual(WhiteBalanceSeries(samples: []).correctedDeclarations().count, 0)
        let one = WhiteBalanceSeries(samples: [
            WhiteBalanceSample(frame: 0, file: "a.ARW", kelvin: 5000, tint: 3),
        ])
        XCTAssertEqual(one.correctedDeclarations(), one.samples)
    }

    // MARK: - The sidecar

    func testSidecar_roundTripsAndSurvivesATornLine() throws {
        let series = WhiteBalanceSeries(samples: [
            WhiteBalanceSample(frame: 0, file: "a.ARW", kelvin: 5634.671, tint: 16.11278, seconds: 0),
            WhiteBalanceSample(frame: 1, file: "b.ARW", kelvin: 3408.253, tint: -9.68293, seconds: 2.63),
        ])
        let text = try series.encoded()
        XCTAssertEqual(WhiteBalanceSeries.decode(text), series)

        // A measuring pass killed mid-write leaves a half-line; every good
        // line before it must survive.
        let torn = text + "{\"frame\":2,\"file\":\"c.AR"
        XCTAssertEqual(WhiteBalanceSeries.decode(torn), series)
    }

    // MARK: - Resolving a track

    func testTrack_asShotDeclaresNothing() {
        let track = WhiteBalanceTrack.resolve(source: .asShot, series: nil)
        XCTAssertNil(track.declared(atPosition: 0))
        XCTAssertNil(track.declared(atPosition: 0.9))
    }

    func testTrack_fixedDeclaresTheSameWhiteEverywhere() {
        let track = WhiteBalanceTrack.resolve(source: .fixed(kelvin: 5200, tint: 4), series: nil)
        for position in [0.0, 0.42, 1.0] {
            let declared = track.declared(atPosition: position)
            XCTAssertEqual(declared?.kelvin, 5200)
            XCTAssertEqual(declared?.tint, 4)
        }
    }

    /// Asking for a smoothed track before anything has been measured must
    /// declare nothing rather than guess — the picture stays as-shot until the
    /// pass has run.
    func testTrack_smoothedWithoutASeriesDeclaresNothing() {
        let track = WhiteBalanceTrack.resolve(source: .smoothed(anchorPosition: 0), series: nil)
        XCTAssertNil(track.declared(atPosition: 0.5))
    }

    // MARK: - Persistence

    /// The source is stored on the capture record and lands in `library.json`,
    /// so its coding has to survive a round trip — an enum with associated
    /// values is exactly the shape that decodes back as something else without
    /// anyone noticing until a shoot renders wrong.
    func testSource_roundTripsThroughJSON() throws {
        let cases: [WhiteBalanceSource] = [
            .asShot,
            .fixed(kelvin: 5634.671, tint: 16.11278),
            .smoothed(anchorPosition: 0.875),
        ]
        for source in cases {
            let data = try JSONEncoder().encode(source)
            XCTAssertEqual(try JSONDecoder().decode(WhiteBalanceSource.self, from: data), source)
        }
    }

    /// A project that never pinned a white stores nothing at all, so no
    /// existing record in the library grows a key or changes a byte.
    func testAsShotIsTheAbsentState() throws {
        struct Record: Codable, Equatable {
            var name: String
            var whiteBalanceSource: WhiteBalanceSource?
        }
        let data = try JSONEncoder().encode(Record(name: "Vltava", whiteBalanceSource: nil))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("whiteBalanceSource"), "nil wrote a key: \(json)")
        // …and a record written before the field existed still decodes.
        let legacy = Data(#"{"name":"Vltava"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(Record.self, from: legacy).whiteBalanceSource)
    }

    func testTrack_smoothedWalksTheCorrectedCurve() {
        let series = staircase()
        let track = WhiteBalanceTrack.resolve(
            source: .smoothed(anchorPosition: 0), series: series)
        XCTAssertEqual(track.perFrame.count, series.samples.count)
        let start = try? XCTUnwrap(track.declared(atPosition: 0))
        let end = try? XCTUnwrap(track.declared(atPosition: 1))
        XCTAssertNotNil(start)
        XCTAssertNotNil(end)
        // Warmer light at the end means a lower Kelvin.
        XCTAssertLessThan(end!.kelvin, start!.kelvin)
    }
}

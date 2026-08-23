import simd
import XCTest
@testable import LetsLapseKit

/// CPU-side invariants of the tone engine. The curve must be monotone at
/// every parameter corner (a non-monotone tone curve reads as solarization),
/// identity at neutral, and finite everywhere.
final class ToneMathTests: XCTestCase {
    func testNeutralCurveIsTheBaseLook() {
        // Neutral is deliberately NOT identity: the hidden base curve makes
        // the engine's untouched render match ImageIO's default DNG look, so
        // existing projects keep their appearance.
        let lut = ToneMath.toneLUT(for: .neutral)
        for (index, value) in lut.enumerated() {
            let x = Float(index) / Float(lut.count - 1)
            XCTAssertEqual(value, ToneMath.baseCurve(x), accuracy: 1e-4)
        }
        // And the base curve itself is anchored and monotone.
        XCTAssertEqual(ToneMath.baseCurve(0), 0, accuracy: 1e-5)
        XCTAssertEqual(ToneMath.baseCurve(1), 1, accuracy: 1e-5)
        var previous: Float = -1
        for step in 0...300 {
            let value = ToneMath.baseCurve(Float(step) / 250)  // past 1.0 too
            XCTAssertGreaterThanOrEqual(value, previous - 1e-5)
            previous = value
        }
    }

    func testCurveMonotoneAtEveryParameterCorner() {
        let corners: [Float] = [-1, 0, 1]
        for contrast in corners {
            for highlights in corners {
                for shadows in corners {
                    for whites in corners {
                        for blacks in corners {
                            var recipe = GradeRecipe()
                            recipe.contrast = contrast
                            recipe.highlights = highlights
                            recipe.shadows = shadows
                            recipe.whites = whites
                            recipe.blacks = blacks
                            let lut = ToneMath.toneLUT(for: recipe)
                            for value in lut {
                                XCTAssertTrue(value.isFinite, "non-finite curve at \(recipe)")
                            }
                            for i in 1..<lut.count {
                                XCTAssertGreaterThanOrEqual(
                                    lut[i], lut[i - 1] - 1e-4,
                                    "curve not monotone at sample \(i) for \(recipe)")
                            }
                        }
                    }
                }
            }
        }
    }

    func testRecoveryIsMonotoneCompressiveAndFinite() {
        for recovery: Float in [0, 0.25, 0.5, 1] {
            var previous: Float = -1
            for step in 0...400 {
                let y = Float(step) * 0.01
                let recovered = ToneMath.recoveredLuminance(y, recovery: recovery)
                XCTAssertTrue(recovered.isFinite)
                XCTAssertLessThanOrEqual(recovered, y + 1e-5, "recovery must never brighten")
                XCTAssertGreaterThanOrEqual(recovered, previous - 1e-5, "recovery must stay monotone")
                previous = recovered
            }
        }
        // Full recovery pulls the 2-stop headroom under white.
        XCTAssertLessThan(ToneMath.recoveredLuminance(4.0, recovery: 1), 1.0)
        // At neutral only the far top rolls: mid-tones are untouched.
        XCTAssertEqual(ToneMath.recoveredLuminance(0.5, recovery: 0), 0.5)
        XCTAssertEqual(ToneMath.recoveredLuminance(0.9, recovery: 0), 0.9)
    }

    func testNeutralKeepsGreysGreyAndPreservesHue() {
        let lut = ToneMath.toneLUT(for: .neutral)
        // Greys stay grey (the base look is tone-only), and brighter in stays
        // brighter out.
        var previous: Float = -1
        for step in stride(from: Float(0.02), through: 0.9, by: 0.02) {
            let out = ToneMath.evaluate(
                SIMD3(repeating: step), recipe: .neutral,
                whiteBalance: matrix_identity_float3x3, lut: lut)
            XCTAssertEqual(out.x, out.y, accuracy: 1e-4)
            XCTAssertEqual(out.y, out.z, accuracy: 1e-4)
            XCTAssertGreaterThan(out.x, previous)
            previous = out.x
        }
        // Hue preservation: the ratio application keeps channel ordering and
        // proportion for a chromatic pixel.
        let out = ToneMath.evaluate(
            SIMD3(0.4, 0.2, 0.1), recipe: .neutral,
            whiteBalance: matrix_identity_float3x3, lut: lut)
        XCTAssertGreaterThan(out.x, out.y)
        XCTAssertGreaterThan(out.y, out.z)
        XCTAssertEqual(out.x / out.y, 2.0, accuracy: 0.25)
    }

    func testEvaluateStaysFiniteAndBoundedAtExtremes() {
        var extremes: [GradeRecipe] = []
        for values in [[-1, -1, -1, -1, -1], [1, 1, 1, 1, 1], [-1, 1, -1, 1, -1]] as [[Float]] {
            var recipe = GradeRecipe()
            recipe.contrast = values[0]
            recipe.highlights = values[1]
            recipe.shadows = values[2]
            recipe.whites = values[3]
            recipe.blacks = values[4]
            recipe.exposure = values[0] * 5
            recipe.vibrance = values[1]
            recipe.saturation = values[2]
            extremes.append(recipe)
        }
        let pixels: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(4, 4, 4), SIMD3(1e-7, 1e-7, 1e-7),
            SIMD3(4, 0, 0), SIMD3(0.001, 0.5, 3.9),
        ]
        for recipe in extremes {
            let lut = ToneMath.toneLUT(for: recipe)
            let wb = ToneMath.whiteBalanceMatrix(recipe: recipe, reference: GradeReference())
            for pixel in pixels {
                let out = ToneMath.evaluate(pixel, recipe: recipe, whiteBalance: wb, lut: lut)
                for channel in [out.x, out.y, out.z] {
                    XCTAssertTrue(channel.isFinite)
                    XCTAssertGreaterThanOrEqual(channel, 0)
                    XCTAssertLessThanOrEqual(channel, 1)
                }
            }
        }
    }

    func testWhiteBalanceNeutralIsIdentityAndWarmWarms() {
        let identity = ToneMath.whiteBalanceMatrix(recipe: .neutral, reference: GradeReference())
        for column in 0..<3 {
            for row in 0..<3 {
                let expected: Float = column == row ? 1 : 0
                XCTAssertEqual(identity[column][row], expected, accuracy: 1e-5)
            }
        }

        var warm = GradeRecipe()
        warm.temperatureMired = 50
        let matrix = ToneMath.whiteBalanceMatrix(recipe: warm, reference: GradeReference())
        let white = matrix * SIMD3<Float>(1, 1, 1)
        XCTAssertGreaterThan(white.x, white.z, "a positive mired offset must render warmer")

        var cool = GradeRecipe()
        cool.temperatureMired = -50
        let coolWhite = ToneMath.whiteBalanceMatrix(recipe: cool, reference: GradeReference()) * SIMD3<Float>(1, 1, 1)
        XCTAssertLessThan(coolWhite.x, coolWhite.z, "a negative mired offset must render cooler")
    }

    // MARK: - Local tone

    func testLocalWeightsPartitionTheTonalRange() {
        // Shadows weight: a hump — full in the deep shadows, gone by the
        // midtones, and rolled back off at the sensor's noise floor (true
        // black must stay black; there is nothing down there to reveal).
        XCTAssertGreaterThan(ToneMath.shadowWeight(baseLog2: -8), 0.95)
        XCTAssertGreaterThan(ToneMath.shadowWeight(baseLog2: -6), 0.8)
        XCTAssertLessThan(ToneMath.shadowWeight(baseLog2: 0), 0.15)
        XCTAssertLessThan(ToneMath.shadowWeight(baseLog2: -12), 0.01)
        // Highlights weight: the monotone mirror.
        XCTAssertGreaterThan(ToneMath.highlightWeight(baseLog2: 0), 0.6)
        XCTAssertLessThan(ToneMath.highlightWeight(baseLog2: -6), 0.01)
        var previousHighlight: Float = -1
        for step in stride(from: Float(-14), through: 2, by: 0.25) {
            let h = ToneMath.highlightWeight(baseLog2: step)
            XCTAssertGreaterThanOrEqual(h, previousHighlight - 1e-6)
            previousHighlight = h
        }
        // The shadow hump is single-peaked: monotone up to the toe's top,
        // monotone down after it.
        var previous: Float = -1
        for step in stride(from: Float(-14), through: -8, by: 0.25) {
            let s = ToneMath.shadowWeight(baseLog2: step)
            XCTAssertGreaterThanOrEqual(s, previous - 1e-6)
            previous = s
        }
        previous = 2
        for step in stride(from: Float(-8), through: 2, by: 0.25) {
            let s = ToneMath.shadowWeight(baseLog2: step)
            XCTAssertLessThanOrEqual(s, previous + 1e-6)
            previous = s
        }
    }

    func testShadowsLiftKeysOnTheNeighbourhoodBase() {
        // The same dark pixel, lifted hard when its neighbourhood is dark and
        // spared when its neighbourhood is bright — the "contained to darker
        // regions" behaviour a global curve cannot have.
        var recipe = GradeRecipe()
        recipe.shadows = 1
        let lut = ToneMath.toneLUT(for: recipe)
        let pixel = SIMD3<Float>(repeating: 0.02)
        let deepRegion = ToneMath.evaluate(
            pixel, recipe: recipe, whiteBalance: matrix_identity_float3x3, lut: lut,
            baseLog2: -6, smoothed: pixel)
        let brightRegion = ToneMath.evaluate(
            pixel, recipe: recipe, whiteBalance: matrix_identity_float3x3, lut: lut,
            baseLog2: 0, smoothed: pixel)
        XCTAssertGreaterThan(deepRegion.x, brightRegion.x * 2,
                             "a dark pixel in a dark region must lift far more than in a bright one")
    }

    func testChromaProtectionSteersDeepLiftsTowardNeighbourhoodChroma() {
        // A deep pixel whose colour is sensor noise (bluish) inside a
        // neighbourhood that is actually neutral: a hard lift must render it
        // near-neutral, not as a saturated blue blob.
        var recipe = GradeRecipe()
        recipe.shadows = 1
        recipe.blacks = 0.4
        let lut = ToneMath.toneLUT(for: recipe)
        let noisy = SIMD3<Float>(0.001, 0.004, 0.010)
        let neighbourhood = SIMD3<Float>(repeating: 0.005)

        func saturation(_ v: SIMD3<Float>) -> Float {
            let maxc = max(v.x, max(v.y, v.z))
            let minc = min(v.x, min(v.y, v.z))
            return (maxc - minc) / max(maxc, 1e-5)
        }
        let protected = ToneMath.evaluate(
            noisy, recipe: recipe, whiteBalance: matrix_identity_float3x3, lut: lut,
            baseLog2: -8, smoothed: neighbourhood)
        let unprotected = ToneMath.evaluate(
            noisy, recipe: recipe, whiteBalance: matrix_identity_float3x3, lut: lut,
            baseLog2: -8, smoothed: noisy)
        XCTAssertLessThan(saturation(protected), saturation(unprotected) * 0.4,
                          "the neighbourhood chroma must win in a hard-lifted deep shadow")
        // And with no lift at all, the pixel's own chroma is untouched even
        // with a wild neighbourhood value supplied.
        let neutralLUT = ToneMath.toneLUT(for: .neutral)
        let untouched = ToneMath.evaluate(
            noisy, recipe: .neutral, whiteBalance: matrix_identity_float3x3, lut: neutralLUT,
            baseLog2: -8, smoothed: SIMD3<Float>(1, 0, 0))
        let reference = ToneMath.evaluate(
            noisy, recipe: .neutral, whiteBalance: matrix_identity_float3x3, lut: neutralLUT)
        XCTAssertEqual(untouched.x, reference.x, accuracy: 1e-6)
        XCTAssertEqual(untouched.z, reference.z, accuracy: 1e-6)
    }

    func testHighlightPullKeepsColourBelowClip() {
        // Pulling highlights down must not grey a sunset: with no channel past
        // the display ceiling, desaturation stays at the gentle neutral floor.
        var recipe = GradeRecipe()
        recipe.highlights = -1
        let lut = ToneMath.toneLUT(for: recipe)
        let sunset = SIMD3<Float>(0.9, 0.5, 0.2)
        let out = ToneMath.evaluate(
            sunset, recipe: recipe, whiteBalance: matrix_identity_float3x3, lut: lut)
        let maxc = max(out.x, max(out.y, out.z))
        let minc = min(out.x, min(out.y, out.z))
        XCTAssertGreaterThan((maxc - minc) / max(maxc, 1e-5), 0.5,
                             "a strongly coloured highlight must keep its colour under recovery")
        XCTAssertGreaterThan(out.x, out.y)
        XCTAssertGreaterThan(out.y, out.z)
    }

    func testReferenceRecipeBehavesLikeTheLightroomEdit() {
        // The user's calibration edit: highlights −100, shadows +49,
        // whites −11, blacks +26 — loose shape checks, exact matching is the
        // CLI regression rig's job.
        var recipe = GradeRecipe()
        recipe.highlights = -1
        recipe.shadows = 0.49
        recipe.whites = -0.11
        recipe.blacks = 0.26
        let lut = ToneMath.toneLUT(for: recipe)

        // Shadows lift the lower mids.
        XCTAssertGreaterThan(ToneMath.sampleLUT(lut, at: 0.25), 0.25)
        // Negative whites pull the white point down.
        XCTAssertLessThan(lut[lut.count - 1], 1.0)
        // Positive blacks lift the black point to matte.
        XCTAssertGreaterThan(lut[0], 0.0)
        // And the full pipeline keeps a hard highlight under control: a pixel
        // at twice diffuse white must land below 1 after recovery.
        let wb = matrix_identity_float3x3
        let out = ToneMath.evaluate(SIMD3(2.0, 1.9, 1.8), recipe: recipe, whiteBalance: wb, lut: lut)
        XCTAssertLessThan(max(out.x, max(out.y, out.z)), 1.0)
    }
}

/// Deterministic generator so test pixels are reproducible run to run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

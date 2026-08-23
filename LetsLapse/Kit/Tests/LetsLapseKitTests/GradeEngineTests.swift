import Metal
import simd
import XCTest
@testable import LetsLapseKit

/// GPU/CPU parity for the tone engine: the Metal kernel and `ToneMath` must
/// be the same math. A drift between them means the editor preview (GPU) and
/// the tests' ground truth (CPU) disagree — which is exactly the
/// preview-vs-export mismatch this engine exists to eliminate.
///
/// The engine's tonal stage is spatially adaptive (shadows/highlights/clarity
/// key on a guided-filter base), so parity comes in two forms:
///  - random-pixel parity for recipes whose active controls are purely
///    per-pixel (exposure, contrast, WB, saturation…), and
///  - uniform-image parity for the local controls: on a flat field the guided
///    base *is* the pixel's own log-luma, so the full GPU path — base
///    generation included — must match `ToneMath.evaluate` fed that base.
final class GradeEngineTests: XCTestCase {
    private func makeTexture(_ engine: GradeEngine, pixels: [Float16], width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(engine.device.makeTexture(descriptor: descriptor))
        pixels.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: raw.baseAddress!, bytesPerRow: width * 8)
        }
        return texture
    }

    private func readBack(_ texture: MTLTexture) -> [Float16] {
        var pixels = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!, bytesPerRow: texture.width * 8,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return pixels
    }

    private func randomPixels(width: Int, height: Int, upTo limit: Float, seed: UInt64) -> [Float16] {
        var generator = SeededGenerator(seed: seed)
        var pixels = [Float16]()
        pixels.reserveCapacity(width * height * 4)
        for _ in 0..<(width * height) {
            pixels.append(Float16(Float.random(in: 0...limit, using: &generator)))
            pixels.append(Float16(Float.random(in: 0...limit, using: &generator)))
            pixels.append(Float16(Float.random(in: 0...limit, using: &generator)))
            pixels.append(1)
        }
        return pixels
    }

    private func uniformPixels(_ rgb: SIMD3<Float>, width: Int, height: Int) -> [Float16] {
        var pixels = [Float16]()
        pixels.reserveCapacity(width * height * 4)
        for _ in 0..<(width * height) {
            pixels.append(Float16(rgb.x))
            pixels.append(Float16(rgb.y))
            pixels.append(Float16(rgb.z))
            pixels.append(1)
        }
        return pixels
    }

    // MARK: - Parity

    /// Random-pixel parity — valid only for recipes with no spatial terms
    /// (shadows, highlights, clarity all zero; blacks not positive), because
    /// the GPU keys those on the neighbourhood and the CPU has none here.
    private func assertRandomParity(recipe: GradeRecipe, reference: GradeReference = GradeReference(),
                                    tolerance: Float, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(recipe.shadows, 0, "random parity needs a non-spatial recipe", file: file, line: line)
        XCTAssertEqual(recipe.highlights, 0, "random parity needs a non-spatial recipe", file: file, line: line)
        XCTAssertEqual(recipe.clarity, 0, "random parity needs a non-spatial recipe", file: file, line: line)
        XCTAssertLessThanOrEqual(recipe.blacks, 0, "positive blacks engage chroma protection", file: file, line: line)

        let engine = try GradeEngine()
        let width = 64, height = 64
        let input = randomPixels(width: width, height: height, upTo: 1.3, seed: 42)
        let texture = try makeTexture(engine, pixels: input, width: width, height: height)

        let renderer = engine.makeRenderer(recipe, reference: reference)
        let output = try renderer.apply(to: texture)
        let gpu = readBack(output)

        let lut = ToneMath.toneLUT(for: recipe)
        let wb = ToneMath.whiteBalanceMatrix(recipe: recipe, reference: reference)
        var worst: Float = 0
        for pixel in 0..<(width * height) {
            let base = pixel * 4
            let rgb = SIMD3<Float>(Float(input[base]), Float(input[base + 1]), Float(input[base + 2]))
            let expected = ToneMath.evaluate(rgb, recipe: recipe, whiteBalance: wb, lut: lut)
            let actual = SIMD3<Float>(Float(gpu[base]), Float(gpu[base + 1]), Float(gpu[base + 2]))
            worst = max(worst, simd_reduce_max(simd_abs(expected - actual)))
        }
        XCTAssertLessThanOrEqual(
            worst, tolerance,
            "GPU kernel and ToneMath disagree by \(worst)", file: file, line: line)
    }

    /// Uniform-image parity — exercises the *whole* GPU path including the
    /// guided-filter base and the chroma-protection texture: on a flat field
    /// both resolve to the pixel's own values, which is what
    /// `ToneMath.evaluate`'s defaults model. Tolerance is looser than the
    /// random parity because the base rides through half-float textures.
    private func assertUniformParity(recipe: GradeRecipe, reference: GradeReference = GradeReference(),
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let engine = try GradeEngine()
        let lut = ToneMath.toneLUT(for: recipe)
        let wb = ToneMath.whiteBalanceMatrix(recipe: recipe, reference: reference)
        let levels: [SIMD3<Float>] = [
            SIMD3(0.004, 0.004, 0.004),
            SIMD3(0.02, 0.02, 0.02),
            SIMD3(0.18, 0.18, 0.18),
            SIMD3(0.6, 0.6, 0.6),
            SIMD3(1.1, 1.1, 1.1),
            SIMD3(0.06, 0.02, 0.01),   // warm deep shadow
            SIMD3(0.3, 0.5, 0.9),      // cool bright
        ]
        let width = 64, height = 64
        let renderer = engine.makeRenderer(recipe, reference: reference)
        for level in levels {
            let texture = try makeTexture(
                engine, pixels: uniformPixels(level, width: width, height: height),
                width: width, height: height)
            let output = try renderer.apply(to: texture)
            let gpu = readBack(output)
            // The f16 texture already rounded the input; compare against what
            // the GPU actually read.
            let stored = SIMD3<Float>(
                Float(Float16(level.x)), Float(Float16(level.y)), Float(Float16(level.z)))
            let expected = ToneMath.evaluate(stored, recipe: recipe, whiteBalance: wb, lut: lut)
            let centre = ((height / 2) * width + width / 2) * 4
            let actual = SIMD3<Float>(Float(gpu[centre]), Float(gpu[centre + 1]), Float(gpu[centre + 2]))
            let error = simd_reduce_max(simd_abs(expected - actual))
            XCTAssertLessThanOrEqual(
                error, 0.02,
                "uniform parity off by \(error) at level \(level) for \(recipe)",
                file: file, line: line)
        }
    }

    func testParityOnTheNeutralRecipe() throws {
        try assertRandomParity(recipe: .neutral, tolerance: 5e-3)
    }

    func testParityWithWhiteBalanceAndExposure() throws {
        var recipe = GradeRecipe()
        recipe.exposure = 0.7
        recipe.contrast = 0.4
        recipe.temperatureMired = 35
        recipe.tint = 0.3
        recipe.saturation = -0.2
        try assertRandomParity(recipe: recipe, tolerance: 5e-3)
    }

    func testParityWithEndpointControls() throws {
        var recipe = GradeRecipe()
        recipe.whites = -0.11
        recipe.blacks = -0.3
        recipe.vibrance = 0.53
        try assertRandomParity(recipe: recipe, tolerance: 5e-3)
    }

    func testUniformParityOnTheReferenceEdit() throws {
        var recipe = GradeRecipe()
        recipe.highlights = -1
        recipe.shadows = 0.49
        recipe.whites = -0.11
        recipe.blacks = 0.26
        recipe.vibrance = 0.53
        try assertUniformParity(recipe: recipe)
    }

    func testUniformParityOnStrongLocalMoves() throws {
        var lift = GradeRecipe()
        lift.shadows = 1
        lift.blacks = 0.43
        try assertUniformParity(recipe: lift)

        var rescue = GradeRecipe()
        rescue.highlights = -1
        try assertUniformParity(recipe: rescue)

        var punch = GradeRecipe()
        punch.clarity = 1
        try assertUniformParity(recipe: punch)

        var smooth = GradeRecipe()
        smooth.clarity = -1
        try assertUniformParity(recipe: smooth)
    }

    // MARK: - Locality

    /// The point of engine v2: Shadows must reach the dark *region* and spare
    /// the bright one — and the edge between them must stay clean (no halo
    /// band beyond the far-field values).
    func testShadowLiftIsLocalAndHaloFree() throws {
        let engine = try GradeEngine()
        let width = 512, height = 128
        let darkLevel: Float16 = 0.02, brightLevel: Float16 = 1.0
        var pixels = [Float16]()
        pixels.reserveCapacity(width * height * 4)
        for _ in 0..<height {
            for x in 0..<width {
                let v: Float16 = x < width / 2 ? darkLevel : brightLevel
                pixels.append(contentsOf: [v, v, v, 1])
            }
        }
        let texture = try makeTexture(engine, pixels: pixels, width: width, height: height)

        var recipe = GradeRecipe()
        recipe.shadows = 1
        let lifted = readBack(try engine.makeRenderer(recipe, reference: GradeReference()).apply(to: texture))
        let neutral = readBack(try engine.makeRenderer(.neutral, reference: GradeReference()).apply(to: texture))

        func red(_ buffer: [Float16], _ x: Int, _ y: Int) -> Float {
            Float(buffer[(y * width + x) * 4])
        }
        let row = height / 2
        let farDark = 32, farBright = width - 32
        let darkGain = red(lifted, farDark, row) / max(red(neutral, farDark, row), 1e-5)
        let brightGain = red(lifted, farBright, row) / max(red(neutral, farBright, row), 1e-5)

        XCTAssertGreaterThan(darkGain, 2.0, "shadows +100 must lift a deep region by stops")
        XCTAssertLessThan(brightGain, 1.35, "shadows must largely spare the bright region")
        XCTAssertGreaterThan(darkGain, brightGain * 2.2, "the lift must be local, not global")

        // No halo: near the edge, values stay within a small band of the
        // far-field value on each side.
        let farBrightValue = red(lifted, farBright, row)
        let farDarkValue = red(lifted, farDark, row)
        for x in (width / 2 + 2)..<(width / 2 + 64) {
            XCTAssertEqual(red(lifted, x, row), farBrightValue, accuracy: 0.08,
                           "bright-side halo at column \(x)")
        }
        for x in (width / 2 - 64)..<(width / 2 - 2) {
            XCTAssertEqual(red(lifted, x, row), farDarkValue, accuracy: 0.08,
                           "dark-side halo at column \(x)")
        }
    }

    /// Clarity as detail gain: positive amplifies mid-frequency ripple,
    /// negative smooths it, and both stay bounded.
    func testClarityAmplifiesAndSmoothsDetail() throws {
        let engine = try GradeEngine()
        let width = 512, height = 64
        var pixels = [Float16]()
        pixels.reserveCapacity(width * height * 4)
        for _ in 0..<height {
            for x in 0..<width {
                let ripple = 0.3 + 0.1 * sin(Float(x) * (2 * .pi / 64))
                let v = Float16(ripple)
                pixels.append(contentsOf: [v, v, v, 1])
            }
        }
        let texture = try makeTexture(engine, pixels: pixels, width: width, height: height)

        func rippleAmplitude(_ clarity: Float) throws -> Float {
            var recipe = GradeRecipe()
            recipe.clarity = clarity
            let output = readBack(try engine.makeRenderer(recipe, reference: GradeReference()).apply(to: texture))
            let row = height / 2
            var low: Float = 1, high: Float = 0
            for x in 64..<(width - 64) {
                let v = Float(output[(row * width + x) * 4])
                XCTAssertTrue(v.isFinite)
                XCTAssertGreaterThanOrEqual(v, 0)
                XCTAssertLessThanOrEqual(v, 1)
                low = min(low, v)
                high = max(high, v)
            }
            return high - low
        }

        let flat = try rippleAmplitude(0)
        let punched = try rippleAmplitude(1)
        let smoothed = try rippleAmplitude(-1)
        XCTAssertGreaterThan(punched, flat * 1.25, "positive clarity must amplify detail")
        XCTAssertLessThan(smoothed, flat * 0.8, "negative clarity must smooth detail")
    }

    func testVignetteDarkensCorners() throws {
        let engine = try GradeEngine()
        let width = 128, height = 96
        let texture = try makeTexture(
            engine, pixels: uniformPixels(SIMD3(0.5, 0.5, 0.5), width: width, height: height),
            width: width, height: height)
        var recipe = GradeRecipe()
        recipe.vignette = 0.6
        let output = readBack(try engine.makeRenderer(recipe, reference: GradeReference()).apply(to: texture))
        let centre = Float(output[((height / 2) * width + width / 2) * 4])
        let corner = Float(output[0])
        XCTAssertLessThan(corner, centre - 0.05, "corner should be attenuated")
        for value in output {
            XCTAssertTrue(Float(value).isFinite)
        }
    }

    /// The dither pass: adds sub-LSB noise (so 8-bit output can't band)
    /// without moving the mean or leaving the range.
    func testDitherAddsNoiseWithoutShiftingTheMean() throws {
        let engine = try GradeEngine()
        let width = 64, height = 64
        let texture = try makeTexture(
            engine, pixels: uniformPixels(SIMD3(0.31, 0.31, 0.31), width: width, height: height),
            width: width, height: height)
        let renderer = engine.makeRenderer(.neutral, reference: GradeReference())
        let plain = readBack(try renderer.apply(to: texture))
        let dithered = readBack(try renderer.apply(to: texture, ditherFor8Bit: true))

        var sumPlain: Float = 0, sumDithered: Float = 0
        var maxDelta: Float = 0
        var distinct = Set<Float16>()
        for pixel in 0..<(width * height) {
            let p = Float(plain[pixel * 4])
            let d = Float(dithered[pixel * 4])
            sumPlain += p
            sumDithered += d
            maxDelta = max(maxDelta, abs(d - p))
            distinct.insert(dithered[pixel * 4])
            XCTAssertGreaterThanOrEqual(d, 0)
            XCTAssertLessThanOrEqual(d, 1)
        }
        let count = Float(width * height)
        // Tolerance: the noise re-quantises through the f16 scratch, which can
        // bias the mean by up to half an f16 ULP — far below the 8-bit LSB
        // (1/255 ≈ 3.9e-3) the dither exists to break up.
        XCTAssertEqual(sumPlain / count, sumDithered / count, accuracy: 1e-3,
                       "dither must not shift the mean")
        XCTAssertLessThanOrEqual(maxDelta, 1.0 / 255.0 + 1e-3, "dither must stay within one LSB")
        XCTAssertGreaterThan(distinct.count, 4, "dither must actually vary the output")
    }
}

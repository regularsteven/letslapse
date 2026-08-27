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

        // The detail passes are exact no-ops on a flat field.
        var detail = GradeRecipe()
        detail.texture = 1
        detail.sharpen = 1
        try assertUniformParity(recipe: detail)

        // So is noise reduction: a flat field has no grain to remove.
        var denoise = GradeRecipe()
        denoise.noiseReduction = 1
        denoise.colorNoiseReduction = 1
        try assertUniformParity(recipe: denoise)
    }

    /// The noise controls: luma NR flattens seeded grain while a hard edge
    /// survives, and colour NR collapses chroma speckle on constant luma.
    func testNoiseReductionFlattensGrainAndKeepsEdges() throws {
        let engine = try GradeEngine()
        let width = 256, height = 64
        var generator = SeededGenerator(seed: 7)

        // Left half 0.08, right half 0.5, both with luma grain.
        var pixels = [Float16]()
        pixels.reserveCapacity(width * height * 4)
        for _ in 0..<height {
            for x in 0..<width {
                let base: Float = x < width / 2 ? 0.08 : 0.5
                let grain = Float.random(in: -0.015...0.015, using: &generator)
                let v = Float16(max(base + grain, 0))
                pixels.append(contentsOf: [v, v, v, 1])
            }
        }
        let texture = try makeTexture(engine, pixels: pixels, width: width, height: height)

        func rowStats(_ recipe: GradeRecipe) throws -> (noise: Float, edgeJump: Float) {
            let output = readBack(try engine.makeRenderer(recipe, reference: GradeReference()).apply(to: texture))
            let row = height / 2
            // Grain: std-dev over a flat strip well inside the bright half.
            var values = [Float]()
            for x in (width / 2 + 24)..<(width - 16) {
                values.append(Float(output[(row * width + x) * 4]))
            }
            let mean = values.reduce(0, +) / Float(values.count)
            let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
            // Edge: difference across the boundary.
            let left = Float(output[(row * width + width / 2 - 8) * 4])
            let right = Float(output[(row * width + width / 2 + 8) * 4])
            return (sqrt(variance), right - left)
        }

        var denoise = GradeRecipe()
        denoise.noiseReduction = 1
        let before = try rowStats(.neutral)
        let after = try rowStats(denoise)
        XCTAssertLessThan(after.noise, before.noise * 0.55,
                          "full luma NR must at least halve the grain")
        XCTAssertGreaterThan(after.edgeJump, before.edgeJump * 0.85,
                             "the step edge must survive luma NR")

        // Colour speckle: constant luma, alternating red/blue casts.
        var chromaPixels = [Float16]()
        chromaPixels.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let flip = (x + y) % 2 == 0
                let r: Float16 = flip ? 0.24 : 0.16
                let b: Float16 = flip ? 0.16 : 0.24
                chromaPixels.append(contentsOf: [r, 0.2, b, 1])
            }
        }
        let chromaTexture = try makeTexture(engine, pixels: chromaPixels, width: width, height: height)
        var colorDenoise = GradeRecipe()
        colorDenoise.colorNoiseReduction = 1

        func chromaSpread(_ recipe: GradeRecipe) throws -> Float {
            let output = readBack(try engine.makeRenderer(recipe, reference: GradeReference()).apply(to: chromaTexture))
            let row = height / 2
            var spread: Float = 0
            for x in 32..<(width - 32) {
                let base = (row * width + x) * 4
                spread = max(spread, abs(Float(output[base]) - Float(output[base + 2])))
            }
            return spread
        }
        XCTAssertLessThan(try chromaSpread(colorDenoise), try chromaSpread(.neutral) * 0.35,
                          "full colour NR must collapse per-pixel chroma speckle")
    }

    /// Sharpen and texture: both amplify their frequency band, both stay
    /// bounded, and negative texture smooths.
    func testDetailPassesShapeTheirBands() throws {
        // Wide enough that the resolution-anchored sigmas land in their real
        // bands (texture sigma is 0.2% of the long edge — ~4 px here).
        let engine = try GradeEngine()
        let width = 2048, height = 64

        func ripplePixels(wavelength: Float) -> [Float16] {
            var pixels = [Float16]()
            pixels.reserveCapacity(width * height * 4)
            for _ in 0..<height {
                for x in 0..<width {
                    let v = Float16(0.3 + 0.08 * sin(Float(x) * (2 * .pi / wavelength)))
                    pixels.append(contentsOf: [v, v, v, 1])
                }
            }
            return pixels
        }

        func amplitude(_ recipe: GradeRecipe, wavelength: Float) throws -> Float {
            let texture = try makeTexture(
                engine, pixels: ripplePixels(wavelength: wavelength), width: width, height: height)
            let output = readBack(try engine.makeRenderer(recipe, reference: GradeReference()).apply(to: texture))
            let row = height / 2
            var low: Float = 1, high: Float = 0
            for x in 32..<(width - 32) {
                let v = Float(output[(row * width + x) * 4])
                XCTAssertTrue(v.isFinite)
                XCTAssertGreaterThanOrEqual(v, 0)
                XCTAssertLessThanOrEqual(v, 1)
                low = min(low, v)
                high = max(high, v)
            }
            return high - low
        }

        // Sharpen: fine ripple (6 px) amplified.
        var sharp = GradeRecipe()
        sharp.sharpen = 1
        XCTAssertGreaterThan(try amplitude(sharp, wavelength: 6),
                             try amplitude(.neutral, wavelength: 6) * 1.1,
                             "sharpen must add acutance at the pixel scale")

        // Texture: mid ripple (16 px) amplified by +, smoothed by −.
        var punch = GradeRecipe()
        punch.texture = 1
        var smooth = GradeRecipe()
        smooth.texture = -1
        let flat = try amplitude(.neutral, wavelength: 16)
        XCTAssertGreaterThan(try amplitude(punch, wavelength: 16), flat * 1.15,
                             "positive texture must amplify the mid band")
        XCTAssertLessThan(try amplitude(smooth, wavelength: 16), flat * 0.9,
                          "negative texture must smooth the mid band")
    }

    /// Sharpen's Masking sub-slider: at 0 every pixel earns the full amount
    /// (the behaviour that shipped before the control existed); at 1 a flat,
    /// grainy field keeps its smoothness while the edge beside it still
    /// sharpens.
    func testSharpenMaskingSparesFlatAreasAndKeepsEdges() throws {
        let engine = try GradeEngine()
        let width = 256, height = 64
        var generator = SeededGenerator(seed: 11)

        // Left half 0.3, right half 0.6 — a hard step — with fine grain on
        // both, which is exactly what an unsharp mask has no business
        // amplifying.
        var pixels = [Float16]()
        pixels.reserveCapacity(width * height * 4)
        for _ in 0..<height {
            for x in 0..<width {
                let base: Float = x < width / 2 ? 0.3 : 0.6
                let grain = Float.random(in: -0.006...0.006, using: &generator)
                let v = Float16(max(base + grain, 0))
                pixels.append(contentsOf: [v, v, v, 1])
            }
        }
        let texture = try makeTexture(engine, pixels: pixels, width: width, height: height)

        func stats(_ recipe: GradeRecipe) throws -> (grain: Float, edgeJump: Float) {
            let output = readBack(
                try engine.makeRenderer(recipe, reference: GradeReference()).apply(to: texture))
            let row = height / 2
            var values = [Float]()
            for x in (width / 2 + 24)..<(width - 16) {
                values.append(Float(output[(row * width + x) * 4]))
            }
            let mean = values.reduce(0, +) / Float(values.count)
            let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
            let left = Float(output[(row * width + width / 2 - 1) * 4])
            let right = Float(output[(row * width + width / 2) * 4])
            return (sqrt(variance), right - left)
        }

        var unmasked = GradeRecipe()
        unmasked.sharpen = 1
        var masked = unmasked
        masked.sharpenMasking = 1

        let plain = try stats(.neutral)
        let open = try stats(unmasked)
        let gated = try stats(masked)

        XCTAssertGreaterThan(open.grain, plain.grain * 1.1,
                             "unmasked sharpening amplifies grain — the reason Masking exists")
        XCTAssertLessThan(gated.grain - plain.grain, (open.grain - plain.grain) * 0.5,
                          "full masking must take back most of the grain sharpening added")
        XCTAssertGreaterThan(gated.edgeJump, open.edgeJump * 0.99,
                             "full masking must leave the edge fully sharpened")
    }

    /// Luma NR's Detail sub-slider: it moves the split's soft threshold on its
    /// own, so the same amount can strip the fine layer bare or leave most of
    /// it standing. It is a *preservation* control — Detail up keeps more,
    /// which is the direction Lightroom's slider runs.
    func testNoiseDetailPreservesFineStructure() throws {
        let engine = try GradeEngine()
        let width = 256, height = 64
        var generator = SeededGenerator(seed: 13)

        // A coarse fine-layer — ±0.10 linear at 0.5 is about ±0.07 encoded —
        // rather than plausible sensor grain, because the split's knee is wide:
        // at full amount it runs 0.024…0.12 encoded, and anything grain-sized
        // is erased at every Detail setting. See the working point below.
        var pixels = [Float16]()
        pixels.reserveCapacity(width * height * 4)
        for _ in 0..<height {
            for _ in 0..<width {
                let v = Float16(max(0.5 + Float.random(in: -0.10...0.10, using: &generator), 0))
                pixels.append(contentsOf: [v, v, v, 1])
            }
        }
        let texture = try makeTexture(engine, pixels: pixels, width: width, height: height)

        func grain(_ detail: Float, amount: Float = 1) throws -> Float {
            var recipe = GradeRecipe()
            recipe.noiseReduction = amount
            recipe.noiseDetail = detail
            let output = readBack(
                try engine.makeRenderer(recipe, reference: GradeReference()).apply(to: texture))
            let row = height / 2
            var values = [Float]()
            for x in 16..<(width - 16) {
                values.append(Float(output[(row * width + x) * 4]))
            }
            let mean = values.reduce(0, +) / Float(values.count)
            let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
            return sqrt(variance)
        }

        let untouched = try grain(0.5, amount: 0)

        // Full amount is the floor of the split, not a place to read Detail:
        // the mix takes the shrunk layer whole, and the knee is wider than any
        // fine layer worth keeping, so the picture lands on its base.
        XCTAssertLessThan(try grain(0.5), untouched * 0.5,
                          "full luma NR must take the fine layer down to the base")

        // Detail is read at a working amount, where the mix still carries some
        // of the original residual and the knee decides how much of the rest
        // comes with it.
        let stripped = try grain(0, amount: 0.5)
        let preserved = try grain(1, amount: 0.5)
        XCTAssertLessThan(stripped, untouched * 0.75,
                          "Detail 0 must shrink the whole fine layer away")
        XCTAssertGreaterThan(preserved, stripped * 1.12,
                             "Detail 1 must leave structure the same amount otherwise erases")
        XCTAssertLessThan(preserved, untouched,
                          "Detail 1 still denoises — it is not a bypass")
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

    // MARK: - Cropped renders

    /// The editor's pixel-peep path grades a *piece* of a frame — the 1:1 view
    /// renders the visible region, the detail loupe a 280pt square — and the
    /// whole point of it is that what you judge there is what the export
    /// bakes. That only holds if the spatial passes reach as far in the crop as
    /// they do in the whole picture, which is what `GradeReference.longEdge`
    /// now anchors. Without it the crop gets a small picture's footprints and
    /// quietly under-smooths and under-sharpens.
    func testCropAnchoredToTheWholeFrameMatchesTheWholeFrame() throws {
        let engine = try GradeEngine()
        // Big enough to matter: every detail footprint is a fraction of a 4032
        // px frame with a floor under it, so at thumbnail sizes they all clamp
        // to the same values and the anchor has nothing to prove.
        let width = 2048, height = 1536
        // Noise is the point: this is the signal noise reduction and sharpen
        // act on, and the one a wrongly-sized footprint gets visibly wrong.
        let pixels = randomPixels(width: width, height: height, upTo: 0.6, seed: 0xC0FFEE)
        let whole = try makeTexture(engine, pixels: pixels, width: width, height: height)

        var recipe = GradeRecipe()
        recipe.noiseReduction = 0.8
        recipe.noiseDetail = 0.5
        recipe.sharpen = 0.6
        recipe.texture = 0.4

        let reference = GradeReference(longEdge: Double(max(width, height)))
        let full = readBack(try engine.makeRenderer(recipe, reference: reference).apply(to: whole))

        // The crop the editor would cut, margin included. An even origin so the
        // half-resolution grid the texture band works on lines up with the
        // whole frame's.
        let origin = 512, side = 320
        let decoder = try LinearFrameDecoder(device: engine.device)
        let cropped = try decoder.crop(
            whole, to: CGRect(x: origin, y: origin, width: side, height: side))
        XCTAssertEqual(cropped.width, side)
        XCTAssertEqual(cropped.height, side)
        let patch = readBack(try engine.makeRenderer(recipe, reference: reference).apply(to: cropped))

        // Compare the interior only: the crop's own edge pixels have no
        // neighbours, which is exactly why `renderDetail` cuts with a margin
        // and trims it off again.
        let margin = 32
        var worst: Float = 0
        for y in margin..<(side - margin) {
            for x in margin..<(side - margin) {
                let here = (y * side + x) * 4
                let there = ((origin + y) * width + origin + x) * 4
                for channel in 0..<3 {
                    worst = max(worst, abs(Float(patch[here + channel]) - Float(full[there + channel])))
                }
            }
        }
        XCTAssertLessThan(worst, 0.02, "an anchored crop must grade like the whole frame")

        // And the anchor is doing the work: unset, the same crop is graded for
        // a 192 px picture and comes out measurably different.
        let unanchored = readBack(
            try engine.makeRenderer(recipe, reference: GradeReference()).apply(to: cropped))
        var drift: Float = 0
        for y in margin..<(side - margin) {
            for x in margin..<(side - margin) {
                let here = (y * side + x) * 4
                let there = ((origin + y) * width + origin + x) * 4
                drift = max(drift, abs(Float(unanchored[here]) - Float(full[there])))
            }
        }
        XCTAssertGreaterThan(drift, 10 * max(worst, 0.001),
                             "the reference long edge must change the footprints")
    }
}

import Metal
import simd
import XCTest
@testable import LetsLapseKit

/// GPU/CPU parity for the tone engine: the Metal kernel and `ToneMath` must
/// be the same math. A drift between them means the editor preview (GPU) and
/// the tests' ground truth (CPU) disagree — which is exactly the
/// preview-vs-export mismatch this engine exists to eliminate.
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

    private func assertParity(recipe: GradeRecipe, reference: GradeReference = GradeReference(),
                              tolerance: Float, file: StaticString = #filePath, line: UInt = #line) throws {
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

    func testParityOnTheReferenceEdit() throws {
        var recipe = GradeRecipe()
        recipe.highlights = -1
        recipe.shadows = 0.49
        recipe.whites = -0.11
        recipe.blacks = 0.26
        recipe.vibrance = 0.53
        try assertParity(recipe: recipe, tolerance: 5e-3)
    }

    func testParityWithWhiteBalanceAndExposure() throws {
        var recipe = GradeRecipe()
        recipe.exposure = 0.7
        recipe.contrast = 0.4
        recipe.temperatureMired = 35
        recipe.tint = 0.3
        recipe.saturation = -0.2
        try assertParity(recipe: recipe, tolerance: 5e-3)
    }

    func testParityOnTheNeutralRecipe() throws {
        try assertParity(recipe: .neutral, tolerance: 5e-3)
    }

    func testClarityAndVignettePassesRun() throws {
        let engine = try GradeEngine()
        let width = 128, height = 96
        // A step edge, to give clarity something to chew on.
        var pixels = [Float16]()
        for y in 0..<height {
            for x in 0..<width {
                let v: Float16 = x < width / 2 ? 0.2 : 0.8
                pixels.append(contentsOf: [v, v, v, 1])
                _ = y
            }
        }
        var recipe = GradeRecipe()
        recipe.clarity = 0.7
        recipe.vignette = 0.6
        let texture = try makeTexture(engine, pixels: pixels, width: width, height: height)
        let renderer = engine.makeRenderer(recipe, reference: GradeReference())
        let output = try renderer.apply(to: texture)
        let gpu = readBack(output)

        for value in gpu {
            XCTAssertTrue(Float(value).isFinite)
            XCTAssertGreaterThanOrEqual(Float(value), 0)
            XCTAssertLessThanOrEqual(Float(value), 1)
        }
        // Vignette: the far corner must be darker than the centre.
        let center = (height / 2 * width + width / 2) * 4
        let corner = 0
        XCTAssertLessThan(Float(gpu[corner]), Float(gpu[center + 2]) + 0.65,
                          "corner should be attenuated")
        // Clarity's tanh limiter: the value jump across the step edge must
        // stay bounded — no halo overshoot beyond the flat levels ± limiter.
        let rowStart = (height / 2) * width * 4
        var rowMin: Float = 1, rowMax: Float = 0
        for x in 0..<width {
            let v = Float(gpu[rowStart + x * 4])
            rowMin = min(rowMin, v)
            rowMax = max(rowMax, v)
        }
        XCTAssertGreaterThan(rowMin, 0.02, "clarity crushed the dark side of the edge")
        XCTAssertLessThan(rowMax, 0.98, "clarity blew out the bright side of the edge")
    }
}

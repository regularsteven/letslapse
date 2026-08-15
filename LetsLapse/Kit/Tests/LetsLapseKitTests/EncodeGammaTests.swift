import Metal
import XCTest
@testable import LetsLapseKit

/// The blend kernels ship twice — as a bundled `.metal` resource and as the
/// `embeddedKernelSource` string fallback — and both are hand-maintained.
/// This test is the tripwire for the two drifting apart.
final class KernelSourceSyncTests: XCTestCase {
    func testEmbeddedKernelSourceMatchesBundledFile() throws {
        let bundled = try XCTUnwrap(
            BlendCore.bundledKernelSource(),
            "bundled BlendKernels.metal missing from the module bundle")
        XCTAssertEqual(
            normalized(bundled), normalized(BlendCore.embeddedKernelSource),
            "BlendKernels.metal and BlendCore.embeddedKernelSource have drifted apart")
    }

    private func normalized(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }
}

/// `encodeGamma` is the pipeline's single quantization point: transfer encode
/// plus triangular-PDF dither. A mean that falls exactly between two 8-bit
/// codes must quantize to a roughly even mix of both — that mix is what reads
/// as a smooth gradient instead of a contour.
final class EncodeGammaTests: XCTestCase {
    private func makeConstantTexture(_ core: BlendCore, value: UInt8, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(core.device.makeTexture(descriptor: descriptor))
        var pixels = [UInt8](repeating: value, count: width * height * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        pixels.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: raw.baseAddress!, bytesPerRow: width * 4)
        }
        return texture
    }

    func testDitherStraddlesTheHalfCodeBoundary() throws {
        let core = try BlendCore()
        let width = 64, height = 64

        // Two constant frames, codes 127 and 128, accumulated verbatim (no
        // sRGB linearization) so the mean sits exactly on the half-code line.
        let accumulator = FrameAccumulator(core: core)
        let mean = try core.makeMeanTexture(width: width, height: height)

        let destinationDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        destinationDescriptor.usage = [.shaderWrite, .shaderRead]
        destinationDescriptor.storageMode = .shared
        let destination = try XCTUnwrap(core.device.makeTexture(descriptor: destinationDescriptor))

        let commandBuffer = try XCTUnwrap(core.commandQueue.makeCommandBuffer())
        try accumulator.reset(width: width, height: height, commandBuffer: commandBuffer)
        try accumulator.accumulate(
            try makeConstantTexture(core, value: 127, width: width, height: height),
            commandBuffer: commandBuffer)
        try accumulator.accumulate(
            try makeConstantTexture(core, value: 128, width: width, height: height),
            commandBuffer: commandBuffer)
        try accumulator.finalizeMean(into: mean, commandBuffer: commandBuffer)
        try core.encodeGamma(
            from: mean, to: destination,
            ditherLSB: 1.0 / 255.0, frameIndex: 0, applySRGB: false,
            commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            destination.getBytes(
                raw.baseAddress!, bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }

        var histogram = [Int](repeating: 0, count: 256)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            histogram[Int(pixels[i])] += 1  // blue channel is enough
        }
        let total = width * height
        // TPDF of ±1 LSB around code 127.5 can only land on 127 or 128.
        XCTAssertEqual(histogram[127] + histogram[128], total,
                       "dither pushed values beyond the adjacent codes")
        // A mean-zero dither leaves roughly half the pixels on each side.
        let fraction128 = Double(histogram[128]) / Double(total)
        XCTAssertGreaterThan(fraction128, 0.3)
        XCTAssertLessThan(fraction128, 0.7)
    }

    func testZeroDitherIsDeterministicRounding() throws {
        let core = try BlendCore()
        let width = 8, height = 8

        let accumulator = FrameAccumulator(core: core)
        let mean = try core.makeMeanTexture(width: width, height: height)
        let destinationDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        destinationDescriptor.usage = [.shaderWrite, .shaderRead]
        destinationDescriptor.storageMode = .shared
        let destination = try XCTUnwrap(core.device.makeTexture(descriptor: destinationDescriptor))

        let commandBuffer = try XCTUnwrap(core.commandQueue.makeCommandBuffer())
        try accumulator.reset(width: width, height: height, commandBuffer: commandBuffer)
        try accumulator.accumulate(
            try makeConstantTexture(core, value: 100, width: width, height: height),
            commandBuffer: commandBuffer)
        try accumulator.finalizeMean(into: mean, commandBuffer: commandBuffer)
        try core.encodeGamma(
            from: mean, to: destination,
            ditherLSB: 0, frameIndex: 0, applySRGB: false,
            commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            destination.getBytes(
                raw.baseAddress!, bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        for i in stride(from: 0, to: pixels.count, by: 4) {
            XCTAssertEqual(pixels[i], 100)
        }
    }
}

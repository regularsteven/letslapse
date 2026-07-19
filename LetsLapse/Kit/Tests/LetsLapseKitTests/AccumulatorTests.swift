import XCTest
import Metal
@testable import LetsLapseKit

final class AccumulatorTests: XCTestCase {
    /// Averages two solid frames in plain (non-sRGB) byte space, where the
    /// result is exact: (40 + 200) / 2 = 120.
    func testAverageOfTwoSolidFrames() throws {
        let core = try makeCore()
        let width = 64
        let height = 64

        func solidTexture(_ value: UInt8) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead]
            guard let texture = core.device.makeTexture(descriptor: descriptor) else {
                throw LapseError.textureCreationFailed("test texture")
            }
            var bytes = [UInt8](repeating: value, count: width * height * 4)
            for index in 0..<(width * height) { bytes[index * 4 + 3] = 255 }
            bytes.withUnsafeBytes { raw in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: raw.baseAddress!, bytesPerRow: width * 4)
            }
            return texture
        }

        let accumulator = FrameAccumulator(core: core)
        guard let commandBuffer = core.commandQueue.makeCommandBuffer() else {
            throw LapseError.gpuSetupFailed("command buffer")
        }
        try accumulator.reset(width: width, height: height, commandBuffer: commandBuffer)
        try accumulator.accumulate(try solidTexture(40), commandBuffer: commandBuffer)
        try accumulator.accumulate(try solidTexture(200), commandBuffer: commandBuffer)

        let destinationDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        destinationDescriptor.usage = [.shaderWrite, .shaderRead]
        destinationDescriptor.storageMode = .private
        let destination = try XCTUnwrap(core.device.makeTexture(descriptor: destinationDescriptor))
        try accumulator.finalize(into: destination, commandBuffer: commandBuffer)

        let buffer = try XCTUnwrap(core.device.makeBuffer(
            length: width * height * 4, options: .storageModeShared))
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: destination, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer, destinationOffset: 0,
            destinationBytesPerRow: width * 4,
            destinationBytesPerImage: width * height * 4)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)
        XCTAssertEqual(accumulator.frameCount, 2)

        let pixels = buffer.contents().assumingMemoryBound(to: UInt8.self)
        for index in 0..<(width * height) {
            for channel in 0..<3 {
                let value = pixels[index * 4 + channel]
                XCTAssertLessThanOrEqual(abs(Int(value) - 120), 1,
                    "pixel \(index) channel \(channel) = \(value), expected ≈120")
            }
            XCTAssertEqual(pixels[index * 4 + 3], 255)
        }
    }
}

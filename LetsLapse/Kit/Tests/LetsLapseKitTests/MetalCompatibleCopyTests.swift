import XCTest
import CoreVideo
import Metal
@testable import LetsLapseKit

/// A frame Metal refuses to wrap (-6684) is copied into one it can, never
/// dropped: the iPhone 18 Pro's 4224×3024 JPEG blends saved no frame at all
/// until this. The buffers here have no IOSurface — the kind Metal refuses.
final class MetalCompatibleCopyTests: XCTestCase {

    private func plainBuffer(_ width: Int, _ height: Int, _ format: OSType) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        // No IOSurface properties: plain memory, which Metal will not wrap.
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &made), kCVReturnSuccess)
        let buffer = try XCTUnwrap(made)
        XCTAssertNil(CVPixelBufferGetIOSurface(buffer))
        return buffer
    }

    func testABGRAFrameWithoutAnIOSurfaceIsWrappedThroughACopy() throws {
        let core = try BlendCore()
        let buffer = try plainBuffer(64, 48, kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<48 {
            for x in 0..<64 {
                let pixel = base + y * stride + x * 4
                pixel[0] = UInt8(x); pixel[1] = UInt8(y); pixel[2] = 200; pixel[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let (texture, holder) = try core.makeTexture(from: buffer, srgb: false)
        withExtendedLifetime(holder) {
            XCTAssertEqual(texture.width, 64)
            XCTAssertEqual(texture.height, 48)
            var pixel = [UInt8](repeating: 0, count: 4)
            texture.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(10, 7, 1, 1), mipmapLevel: 0)
            XCTAssertEqual(pixel, [10, 7, 200, 255])
        }
    }

    func testTheCopyIsIOSurfaceBackedAndCarriesEveryPlane() throws {
        let core = try BlendCore()
        let buffer = try plainBuffer(32, 16, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            memset(base, Int32(100 + plane), CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                   * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let copy = try core.metalCompatibleCopy(of: buffer)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(copy))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(copy), kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        CVPixelBufferLockBaseAddress(copy, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(copy, .readOnly) }
        for plane in 0..<2 {
            let first = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(copy, plane)).assumingMemoryBound(to: UInt8.self)
            XCTAssertEqual(first[0], UInt8(100 + plane))
        }
        // The planes wrap as textures now, which the original could not.
        XCTAssertNoThrow(try core.makeYUVTextures(from: buffer))
    }
}

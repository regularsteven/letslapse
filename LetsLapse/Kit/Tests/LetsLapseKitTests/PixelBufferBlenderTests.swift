import XCTest
import CoreVideo
@testable import LetsLapseKit

final class PixelBufferBlenderTests: XCTestCase {
    /// Solid-gray BGRA pixel buffer with the Metal/IOSurface attributes the
    /// live capture path uses.
    private func makePixelBuffer(width: Int, height: Int, value: UInt8) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw LapseError.textureCreationFailed("test pixel buffer (\(status))")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw LapseError.textureCreationFailed("test pixel buffer base address")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<height {
            let rowPointer = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for column in 0..<width {
                rowPointer[column * 4 + 0] = value
                rowPointer[column * 4 + 1] = value
                rowPointer[column * 4 + 2] = value
                rowPointer[column * 4 + 3] = 255
            }
        }
        return buffer
    }

    /// In plain byte space the average is exact: (40 + 200) / 2 = 120.
    func testAverageOfTwoSolidBuffers() throws {
        let core = try makeCore()
        let blender = PixelBufferBlender(core: core, linearLight: false)
        try blender.accumulate(makePixelBuffer(width: 64, height: 64, value: 40))
        try blender.accumulate(makePixelBuffer(width: 64, height: 64, value: 200))
        XCTAssertEqual(blender.frameCount, 2)

        let image = try blender.finalizeImage()
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 64)
        for value in grayValues(of: image) {
            XCTAssertLessThanOrEqual(abs(Int(value) - 120), 1)
        }
    }

    /// Linear-light averaging brightens the mid-point of 40 and 200 versus the
    /// byte-space average; the reference transfer functions predict the value.
    func testLinearLightAverage() throws {
        let core = try makeCore()
        let blender = PixelBufferBlender(core: core, linearLight: true)
        try blender.accumulate(makePixelBuffer(width: 64, height: 64, value: 40))
        try blender.accumulate(makePixelBuffer(width: 64, height: 64, value: 200))

        let linearMean = (srgbToLinear(40.0 / 255.0) + srgbToLinear(200.0 / 255.0)) / 2
        let expected = linearToSRGB(linearMean) * 255.0
        for value in grayValues(of: try blender.finalizeImage()) {
            XCTAssertLessThanOrEqual(abs(Double(value) - expected), 2.0,
                "expected ≈\(expected), got \(value)")
        }
    }

    /// One instance serves consecutive windows: finalize closes a window and
    /// the next accumulate starts a fresh average.
    func testReuseAcrossWindows() throws {
        let core = try makeCore()
        let blender = PixelBufferBlender(core: core, linearLight: false)

        try blender.accumulate(makePixelBuffer(width: 64, height: 64, value: 10))
        try blender.accumulate(makePixelBuffer(width: 64, height: 64, value: 30))
        for value in grayValues(of: try blender.finalizeImage()) {
            XCTAssertLessThanOrEqual(abs(Int(value) - 20), 1)
        }

        try blender.accumulate(makePixelBuffer(width: 64, height: 64, value: 100))
        XCTAssertEqual(blender.frameCount, 1)
        try blender.accumulate(makePixelBuffer(width: 64, height: 64, value: 200))
        for value in grayValues(of: try blender.finalizeImage()) {
            XCTAssertLessThanOrEqual(abs(Int(value) - 150), 1)
        }
    }

    /// A single-frame window is a valid fallback: the average of one frame is
    /// the frame itself.
    func testSingleFrameFallback() throws {
        let core = try makeCore()
        let blender = PixelBufferBlender(core: core, linearLight: false)
        try blender.accumulate(makePixelBuffer(width: 64, height: 64, value: 77))
        for value in grayValues(of: try blender.finalizeImage()) {
            XCTAssertLessThanOrEqual(abs(Int(value) - 77), 1)
        }
    }

    func testFinalizeWithoutFramesThrows() throws {
        let core = try makeCore()
        let blender = PixelBufferBlender(core: core)
        XCTAssertThrowsError(try blender.finalizeImage())
    }

    func testSizeMismatchMidWindowThrows() throws {
        let core = try makeCore()
        let blender = PixelBufferBlender(core: core)
        try blender.accumulate(makePixelBuffer(width: 64, height: 64, value: 50))
        XCTAssertThrowsError(try blender.accumulate(makePixelBuffer(width: 32, height: 32, value: 50)))
        // The failed frame must not poison the window: finalize still works.
        _ = try blender.finalizeImage()
    }

    /// Renders a CGImage into a BGRA pixel buffer with the same byte layout
    /// `ImageStacker.uploadTexture` uses, so both paths see identical input.
    private func makePixelBuffer(from image: CGImage) throws -> CVPixelBuffer {
        let width = image.width
        let height = image.height
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw LapseError.textureCreationFailed("test pixel buffer (\(status))")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: base, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw LapseError.gpuSetupFailed("test pixel buffer context")
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    /// The live path must be visually identical to the offline blend the app
    /// already ships: same images through `ImageStacker.stack` and through
    /// `PixelBufferBlender` may differ by at most one 8-bit step.
    func testMatchesOfflineImageStacker() throws {
        let core = try makeCore()
        let width = 64
        let height = 64
        let images = (0..<3).map { k in
            makeGrayImage(width: width, height: height, values: (0..<(width * height)).map {
                UInt8(($0 * (k * 7 + 3)) % 251)
            })
        }

        let offline = try ImageStacker(core: core).stack(images: images, linearLight: true)

        let blender = PixelBufferBlender(core: core, linearLight: true)
        for image in images {
            try blender.accumulate(makePixelBuffer(from: image))
        }
        let live = try blender.finalizeImage()

        for (offlineValue, liveValue) in zip(grayValues(of: offline), grayValues(of: live)) {
            XCTAssertLessThanOrEqual(abs(Int(offlineValue) - Int(liveValue)), 1)
        }
    }

    func testDiscardWindowResets() throws {
        let core = try makeCore()
        let blender = PixelBufferBlender(core: core, linearLight: false)
        try blender.accumulate(makePixelBuffer(width: 64, height: 64, value: 250))
        blender.discardWindow()
        XCTAssertThrowsError(try blender.finalizeImage())

        try blender.accumulate(makePixelBuffer(width: 64, height: 64, value: 60))
        for value in grayValues(of: try blender.finalizeImage()) {
            XCTAssertLessThanOrEqual(abs(Int(value) - 60), 1,
                "discarded frames must not leak into the next window")
        }
    }
}

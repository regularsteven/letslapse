import Foundation
import Accelerate
import CoreVideo

/// Errors from the Bayer/DNG path, kept separate from `LapseError` so the
/// DNG spike stays self-contained.
public enum DNGError: Error, LocalizedError {
    case unsupportedBuffer(String)
    case sizeMismatch(expected: String, actual: String)
    case noInputFrames
    case malformedDNG(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedBuffer(let detail): return "Unsupported buffer: \(detail)"
        case .sizeMismatch(let expected, let actual): return "Size mismatch: expected \(expected), got \(actual)"
        case .noInputFrames: return "No frames were accumulated"
        case .malformedDNG(let detail): return "Malformed DNG: \(detail)"
        case .writeFailed(let detail): return "DNG write failed: \(detail)"
        }
    }
}

/// Equal-weight average of same-format Bayer sensor mosaics. Averaging the
/// mosaic before demosaic is photometrically valid for equal-exposure frames
/// and is what makes the blended output a *real* raw file: nothing about
/// white balance or tone has been decided yet.
///
/// Accepts any single-plane 16-bits-per-pixel CVPixelBuffer (the
/// kCVPixelFormatType_14Bayer_* family delivers 16-bit containers).
/// Not thread-safe; drive from one serial queue.
public final class BayerAccumulator {
    public private(set) var frameCount = 0
    public private(set) var width = 0
    public private(set) var height = 0
    private var accumulator: [Float] = []
    private var frameAsFloat: [Float] = []

    public init() {}

    public func accumulate(_ pixelBuffer: CVPixelBuffer) throws {
        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard !CVPixelBufferIsPlanar(pixelBuffer) else {
            throw DNGError.unsupportedBuffer("planar buffer")
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw DNGError.unsupportedBuffer("no base address")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard bytesPerRow >= bufferWidth * 2 else {
            throw DNGError.unsupportedBuffer("bytesPerRow \(bytesPerRow) below 16-bit row size")
        }

        if frameCount == 0 {
            width = bufferWidth
            height = bufferHeight
            accumulator = [Float](repeating: 0, count: width * height)
            if frameAsFloat.count != width * height {
                frameAsFloat = [Float](repeating: 0, count: width * height)
            }
        } else {
            guard bufferWidth == width, bufferHeight == height else {
                throw DNGError.sizeMismatch(
                    expected: "\(width)x\(height)",
                    actual: "\(bufferWidth)x\(bufferHeight)")
            }
        }

        // Convert row by row (the stride usually exceeds the pixel row) and
        // add into the running sum.
        frameAsFloat.withUnsafeMutableBufferPointer { floatBuffer in
            for row in 0..<height {
                let source = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt16.self)
                vDSP_vfltu16(source, 1, floatBuffer.baseAddress! + row * width, 1, vDSP_Length(width))
            }
        }
        accumulator.withUnsafeMutableBufferPointer { sum in
            frameAsFloat.withUnsafeBufferPointer { frame in
                vDSP_vadd(sum.baseAddress!, 1, frame.baseAddress!, 1, sum.baseAddress!, 1, vDSP_Length(width * height))
            }
        }
        frameCount += 1
    }

    /// Mean mosaic as 16-bit little-endian data, ready for the DNG strip.
    /// Closes the window; the next `accumulate` starts a new average.
    public func finalizeMosaic() throws -> Data {
        guard frameCount > 0 else { throw DNGError.noInputFrames }
        defer { discardWindow() }

        var mean = [Float](repeating: 0, count: width * height)
        var divisor = Float(frameCount)
        accumulator.withUnsafeBufferPointer { sum in
            vDSP_vsdiv(sum.baseAddress!, 1, &divisor, &mean, 1, vDSP_Length(width * height))
        }
        var pixels = [UInt16](repeating: 0, count: width * height)
        mean.withUnsafeBufferPointer { source in
            vDSP_vfixru16(source.baseAddress!, 1, &pixels, 1, vDSP_Length(width * height))
        }
        return pixels.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public func discardWindow() {
        frameCount = 0
        // Keep the allocations for the next window; sizes rarely change.
        if !accumulator.isEmpty {
            accumulator.withUnsafeMutableBufferPointer { sum in
                vDSP_vclr(sum.baseAddress!, 1, vDSP_Length(sum.count))
            }
        }
    }
}

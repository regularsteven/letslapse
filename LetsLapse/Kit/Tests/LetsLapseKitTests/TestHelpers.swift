import XCTest
import Metal
import CoreGraphics
@testable import LetsLapseKit

func makeCore() throws -> BlendCore {
    guard MTLCreateSystemDefaultDevice() != nil else {
        throw XCTSkip("no Metal device available")
    }
    return try BlendCore()
}

// Reference sRGB transfer functions — mirror what the GPU does when reading
// and writing *_srgb textures, so tests can compute expected blend output.
func srgbToLinear(_ c: Double) -> Double {
    c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}

func linearToSRGB(_ c: Double) -> Double {
    c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055
}

/// Thread-safe progress sink for engine callbacks that fire off the main task.
final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Deterministic 64-bit RNG so noise tests are reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Builds a grayscale CGImage from per-pixel byte values (BGRA layout, sRGB).
func makeGrayImage(width: Int, height: Int, values: [UInt8]) -> CGImage {
    precondition(values.count == width * height)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for (index, value) in values.enumerated() {
        bytes[index * 4 + 0] = value
        bytes[index * 4 + 1] = value
        bytes[index * 4 + 2] = value
        bytes[index * 4 + 3] = 255
    }
    let data = Data(bytes)
    let provider = CGDataProvider(data: data as CFData)!
    return CGImage(
        width: width, height: height,
        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false,
        intent: .defaultIntent)!
}

/// Reads back the red channel of a CGImage as bytes.
func grayValues(of image: CGImage) -> [UInt8] {
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
        data: &bytes, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (0..<(width * height)).map { bytes[$0 * 4 + 2] }
}

func meanAbsoluteDeviation(_ values: [UInt8], from center: Double) -> Double {
    values.map { abs(Double($0) - center) }.reduce(0, +) / Double(values.count)
}

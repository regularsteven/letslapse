import XCTest
import CoreGraphics
import CoreImage
import ImageIO
import Metal
import UniformTypeIdentifiers
@testable import LetsLapseKit

/// `OrientedDecode` — the app's one way of decoding a still as it reads.
///
/// Two things are pinned. First, that our own orientation bake agrees with
/// ImageIO's for all eight EXIF values on a small picture (where ImageIO is
/// right everywhere). Second, the regression the helper exists for: a
/// quarter-turned still above 2²⁴ pixels on ImageIO's tiled path — an Apple
/// multi-picture JPEG, or any HEIC — decoded through the grader comes out
/// whole. On iOS 18.6/26.1 the transformed-thumbnail path this replaced
/// rendered it as sixteen scrambled 1024-px tiles (2026-09-16); macOS was
/// never affected, so on a Mac the regression test guards the contract
/// rather than reproducing the fault.
final class OrientedDecodeTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrientedDecodeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Pictures

    /// An RGB picture with no symmetry: red rises with x, green with y, and a
    /// blue diagonal stripe — so any rotation, flip or tile swap moves values.
    private func gradientImage(width: Int, height: Int) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = UInt8(255 * x / max(1, width - 1))
                bytes[i + 1] = UInt8(255 * y / max(1, height - 1))
                bytes[i + 2] = abs(x - y) < max(width, height) / 20 ? 255 : 40
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func write(_ image: CGImage, type: UTType, name: String, orientation: Int, quality: Double = 0.6) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "could not write \(name)")
        return url
    }

    /// Marks a JPEG the way an iPhone HDR photo is marked — `AMPF` appended
    /// to its JFIF APP0 — which is what puts it on ImageIO's tiled decoder.
    private func markedAsAppleMultiPicture(_ url: URL) throws -> URL {
        var data = try Data(contentsOf: url)
        // SOI, then APP0 at offset 2: FF E0 <len16> "JFIF\0" …
        guard data.count > 20, data[2] == 0xFF, data[3] == 0xE0 else {
            throw XCTSkip("ImageIO wrote no JFIF APP0 first; cannot stage the multi-picture marker")
        }
        let length = Int(data[4]) << 8 | Int(data[5])
        let end = 4 + length
        data.insert(contentsOf: Array("AMPF".utf8), at: end)
        let newLength = length + 4
        data[4] = UInt8(newLength >> 8)
        data[5] = UInt8(newLength & 0xFF)
        let marked = url.deletingPathExtension().appendingPathExtension("ampf.jpg")
        try data.write(to: marked)
        return marked
    }

    // MARK: - Comparing

    /// Both pictures drawn through CoreGraphics at a small size and compared
    /// channel by channel: the mean absolute difference in 8-bit codes.
    private func meanAbsoluteDifference(_ a: CGImage, _ b: CGImage, size: Int = 96) -> Double {
        func samples(_ image: CGImage) -> [UInt8] {
            let s = Double(size) / Double(max(image.width, image.height))
            let w = max(1, Int(Double(image.width) * s)), h = max(1, Int(Double(image.height) * s))
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            let context = CGContext(
                data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return bytes
        }
        let x = samples(a), y = samples(b)
        guard x.count == y.count else { return .infinity }
        return Double(zip(x, y).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(x.count)
    }

    /// ImageIO's own oriented decode, drawn through CoreGraphics — correct on
    /// every platform, so the reference the helper is held to.
    private func imageIOReference(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 20000,
        ] as CFDictionary))
    }

    // MARK: - The bake agrees with ImageIO

    func testEveryOrientationMatchesImageIO() throws {
        let picture = gradientImage(width: 37, height: 23)
        for orientation in 1...8 {
            let url = try write(picture, type: .tiff, name: "o\(orientation).tiff", orientation: orientation)
            let reference = try imageIOReference(url)
            let ours = try XCTUnwrap(OrientedDecode.cgImage(url: url, maxPixelSize: 20000))
            XCTAssertEqual(ours.width, reference.width, "orientation \(orientation) width")
            XCTAssertEqual(ours.height, reference.height, "orientation \(orientation) height")
            let quarterTurn = (5...8).contains(orientation)
            XCTAssertEqual(ours.width, quarterTurn ? 23 : 37, "orientation \(orientation) swaps axes iff quarter-turned")
            let difference = meanAbsoluteDifference(ours, reference, size: 37)
            XCTAssertLessThan(difference, 1.5, "orientation \(orientation): bake differs from ImageIO by \(difference) codes")
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let inGraph = try XCTUnwrap(OrientedDecode.ciImage(source: source, maxPixelSize: 20000))
            XCTAssertEqual(inGraph.extent, CGRect(x: 0, y: 0, width: ours.width, height: ours.height),
                           "orientation \(orientation): the Core Image form sits at the origin at the oriented size")
        }
    }

    func testUprightPictureIsReturnedWithoutARedraw() throws {
        let url = try write(gradientImage(width: 16, height: 9), type: .png, name: "up.png", orientation: 1)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let stored = try XCTUnwrap(OrientedDecode.stored(source: source, maxPixelSize: 20000))
        XCTAssertEqual(stored.orientation, .up)
        XCTAssertTrue(OrientedDecode.oriented(stored.image, .up) === stored.image)
    }

    func testRedrawKeepsTheSourceColourSpaceAndDepth() throws {
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 12, height: 8, bitsPerComponent: 16, bytesPerRow: 0, space: p3,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue))
        context.setFillColor(CGColor(colorSpace: p3, components: [0.9, 0.2, 0.1, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        let deep = try XCTUnwrap(context.makeImage())
        let turned = OrientedDecode.oriented(deep, .right)
        XCTAssertEqual(turned.width, 8)
        XCTAssertEqual(turned.height, 12)
        XCTAssertEqual(turned.bitsPerComponent, 16)
        XCTAssertEqual(turned.colorSpace?.name, p3.name)
    }

    // MARK: - The regression: a quarter-turned still above 16 MP, through the grader

    /// 4100×4100 is the smallest square past 2²⁴ pixels — 4096×4096 decodes
    /// whole, this does not.
    private static let largeEdge = 4100

    private func assertGraderDecodesWhole(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let reference = try imageIOReference(url)
        XCTAssertEqual(reference.width, Self.largeEdge, file: file, line: line)
        let decoder = try LinearFrameDecoder()
        // Quarter scale: the tiles scramble at every scale, and a 16 MP
        // half-float texture is more than this needs.
        let frame = try decoder.decode(url: url, scale: 0.25)
        let rendered = try decoder.cgImage(from: frame.texture)
        XCTAssertEqual(rendered.width, Self.largeEdge / 4, file: file, line: line)
        XCTAssertEqual(rendered.height, Self.largeEdge / 4, file: file, line: line)
        let difference = meanAbsoluteDifference(rendered, reference)
        // The scramble measured 45–65 codes; resampling and the P3 round
        // trip stay under 3.
        XCTAssertLessThan(difference, 6, "\(url.lastPathComponent): grader output differs from ImageIO by \(difference) codes — the tiled-decode scramble", file: file, line: line)

        let cgForm = try XCTUnwrap(OrientedDecode.cgImage(url: url, maxPixelSize: 20000))
        let cgDifference = meanAbsoluteDifference(cgForm, reference)
        XCTAssertLessThan(cgDifference, 3, "\(url.lastPathComponent): the bitmap form differs from ImageIO by \(cgDifference) codes", file: file, line: line)
    }

    func testQuarterTurnedAppleMultiPictureJPEGAbove16MPDecodesWhole() throws {
        let edge = Self.largeEdge
        let plain = try write(gradientImage(width: edge, height: edge), type: .jpeg, name: "large.jpg", orientation: 6, quality: 0.3)
        let marked = try markedAsAppleMultiPicture(plain)
        try assertGraderDecodesWhole(marked)
    }

    func testQuarterTurnedHEICAbove16MPDecodesWhole() throws {
        let edge = Self.largeEdge
        guard CGImageDestinationCreateWithURL(
            directory.appendingPathComponent("probe.heic") as CFURL, UTType.heic.identifier as CFString, 1, nil) != nil
        else { throw XCTSkip("no HEIC encoder on this machine") }
        let url = try write(gradientImage(width: edge, height: edge), type: .heic, name: "large.heic", orientation: 6, quality: 0.3)
        try assertGraderDecodesWhole(url)
    }
}

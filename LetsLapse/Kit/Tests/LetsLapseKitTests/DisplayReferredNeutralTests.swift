import CoreGraphics
import CoreVideo
import CoreImage
import ImageIO
import Metal
import XCTest
@testable import LetsLapseKit

/// End to end, the bug a Lightroom-exported sequence hit: an sRGB JPEG decoded
/// through `LinearFrameDecoder` and rendered at neutral must come back as its
/// own pixels — through the still path (`cgImage(from:)`) and through the
/// blend path (`BlendWindowRenderer` + the grade hook). The raw path keeps
/// its base look; that guard lives here too.
final class DisplayReferredNeutralTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("display-referred-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        scratch = nil
        super.tearDown()
    }

    /// 16 grey blocks, codes 8…248, across a 64-wide image (4 px per block).
    private static let greyCodes: [UInt8] = (0..<16).map { UInt8(8 + 16 * $0) }

    private func greyBlocksImage(width: Int = 64, height: Int = 16) -> CGImage {
        let values = (0..<(width * height)).map { index in
            Self.greyCodes[(index % width) * Self.greyCodes.count / width]
        }
        return makeGrayImage(width: width, height: height, values: values)
    }

    /// An sRGB image of one solid colour.
    private func solidImage(_ rgb: (UInt8, UInt8, UInt8), width: Int = 16, height: Int = 16) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            bytes[index * 4 + 0] = rgb.2
            bytes[index * 4 + 1] = rgb.1
            bytes[index * 4 + 2] = rgb.0
            bytes[index * 4 + 3] = 255
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func rgbValues(of image: CGImage) -> [(UInt8, UInt8, UInt8)] {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &bytes, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (0..<(width * height)).map { (bytes[$0 * 4 + 2], bytes[$0 * 4 + 1], bytes[$0 * 4]) }
    }

    private func write(_ image: CGImage, as format: ImageFormat, name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try ImageExporter.write(image, to: url, format: format)
        return url
    }

    // MARK: - The decoder flags what it rendered

    func testDecoderFlagsImageIOSourcesAsDisplayReferred() throws {
        let decoder = try LinearFrameDecoder()
        for (format, name) in [(ImageFormat.png, "grey.png"), (.jpeg, "grey.jpg")] {
            let url = try write(greyBlocksImage(), as: format, name: name)
            let frame = try decoder.decode(url: url)
            XCTAssertTrue(frame.displayReferred, "\(name) is a rendered picture")
            XCTAssertTrue(frame.reference().displayReferred, "the flag must ride the reference")
            XCTAssertEqual(frame.texture.width, 64)
        }
    }

    // MARK: - Still path

    /// Codes in, the same codes out: the base look, the neutral roll-off and
    /// the desaturation floor are all gone for a display-referred source.
    /// Before the gate this read 198 → 228 at mid-grey.
    func testNeutralRoundTripsAnSRGBStillWithinOneCode() throws {
        let decoder = try LinearFrameDecoder()
        let engine = try GradeEngine()
        let url = try write(greyBlocksImage(), as: .png, name: "blocks.png")
        let frame = try decoder.decode(url: url)
        let renderer = engine.makeRenderer(.neutral, reference: frame.reference())
        let output = try renderer.apply(to: frame.texture)

        for space in [CGColorSpace.displayP3, CGColorSpace.sRGB] {
            let image = try decoder.cgImage(from: output, colorSpace: space)
            let values = grayValues(of: image)
            let expected = greyBlocksImage()
            let source = grayValues(of: expected)
            var worst = 0
            for (got, want) in zip(values, source) { worst = max(worst, abs(Int(got) - Int(want))) }
            XCTAssertLessThanOrEqual(worst, 1, "neutral moved a grey by \(worst) codes in \(space)")
        }
        // The export space is honoured by the CGImage itself.
        let sRGB = try decoder.cgImage(from: output, colorSpace: CGColorSpace.sRGB)
        XCTAssertEqual(sRGB.colorSpace?.name, CGColorSpace.sRGB)
        let p3 = try decoder.cgImage(from: output)
        XCTAssertEqual(p3.colorSpace?.name, CGColorSpace.displayP3)
    }

    func testNeutralKeepsSaturatedColoursWithinTwoCodes() throws {
        let decoder = try LinearFrameDecoder()
        let engine = try GradeEngine()
        let colours: [(UInt8, UInt8, UInt8)] = [
            (230, 40, 30), (30, 200, 60), (40, 60, 240), (250, 240, 200), (245, 250, 255),
        ]
        for (index, colour) in colours.enumerated() {
            let url = try write(solidImage(colour), as: .png, name: "colour-\(index).png")
            let frame = try decoder.decode(url: url)
            let renderer = engine.makeRenderer(.neutral, reference: frame.reference())
            let output = try renderer.apply(to: frame.texture)
            let image = try decoder.cgImage(from: output, colorSpace: CGColorSpace.sRGB)
            let centre = rgbValues(of: image)[8 * 16 + 8]
            XCTAssertLessThanOrEqual(abs(Int(centre.0) - Int(colour.0)), 2, "R of \(colour) came back \(centre)")
            XCTAssertLessThanOrEqual(abs(Int(centre.1) - Int(colour.1)), 2, "G of \(colour) came back \(centre)")
            XCTAssertLessThanOrEqual(abs(Int(centre.2) - Int(colour.2)), 2, "B of \(colour) came back \(centre)")
        }
    }

    // MARK: - Blend path

    /// Two stills through the exact shape of `PhotoGrader.blendSupport`:
    /// linear decode → accumulate → grade hook at neutral → `encodeGamma`.
    /// The output frame must be the linear-light mean of the two codes.
    func testNeutralBlendOfTwoStillsIsTheirLinearMean() throws {
        let core = try makeCore()
        let decoder = try LinearFrameDecoder()
        let engine = try GradeEngine()
        let codes: [UInt8] = [64, 192]
        let urls = try codes.enumerated().map { index, code in
            try write(solidImage((code, code, code), width: 32, height: 32), as: .png, name: "blend-\(index).png")
        }
        let frames = try urls.map { try decoder.decode(url: $0) }
        let renderer = engine.makeRenderer(.neutral, reference: frames[0].reference())

        let policy = VideoEncodePolicy(profile: .h264High8Bit, width: 32, height: 32, fps: 30)
        var pool: CVPixelBufferPool?
        XCTAssertEqual(
            CVPixelBufferPoolCreate(nil, nil, policy.pixelBufferAttributes as CFDictionary, &pool),
            kCVReturnSuccess)
        let windowRenderer = try BlendWindowRenderer.linear(core: core, width: 32, height: 32, policy: policy)
        let buffer = try windowRenderer.render(
            frameCount: frames.count,
            texture: { frames[$0].texture },
            sourcePosition: 0, frameIndex: 0,
            pool: try XCTUnwrap(pool),
            outputGrade: { texture, commandBuffer, _ in
                try renderer.encode(from: texture, commandBuffer: commandBuffer)
            },
            overlayComposite: nil)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let centre = base + 16 * rowBytes + 16 * 4
        let expected = linearToSRGB(
            (srgbToLinear(Double(codes[0]) / 255) + srgbToLinear(Double(codes[1]) / 255)) / 2) * 255
        for channel in 0..<3 {
            XCTAssertEqual(
                Double(centre[channel]), expected, accuracy: 1.5,
                "blend channel \(channel) is \(centre[channel]), expected the linear mean \(expected)")
        }
    }

    // MARK: - Raw keeps its look

    /// The app's own DNGs are scene-referred and must still get the base
    /// look: a linear 18 % grey renders well above 18 % at neutral.
    func testLinearDNGStillGetsTheBaseLook() throws {
        // CoreRAW declines very small LinearRaw frames ("empty image" at
        // 64×64); this matches the fixture size `LinearDNGTests` has proven.
        let width = 512, height = 384
        var rgb = Data(capacity: width * height * 6)
        var grey = UInt16(Double(65535) * 0.18).littleEndian
        for _ in 0..<(width * height) {
            withUnsafeBytes(of: &grey) { bytes in
                rgb.append(contentsOf: bytes); rgb.append(contentsOf: bytes); rgb.append(contentsOf: bytes)
            }
        }
        let url = scratch.appendingPathComponent("grey18.dng")
        try DNGAuthor.writeLinearDNG(rgb16: rgb, width: width, height: height, preview: nil, to: url)
        guard CIRAWFilter(imageURL: url) != nil else {
            throw XCTSkip("CoreRAW does not claim the authored LinearRaw DNG on this OS")
        }
        let decoder = try LinearFrameDecoder()
        let engine = try GradeEngine()
        let frame = try decoder.decode(url: url)
        XCTAssertFalse(frame.displayReferred, "a raw decode is scene-referred")
        let renderer = engine.makeRenderer(.neutral, reference: frame.reference())
        let output = try renderer.apply(to: frame.texture)
        let image = try decoder.cgImage(from: output, colorSpace: CGColorSpace.sRGB)
        let centre = grayValues(of: image)[(height / 2) * width + width / 2]
        // Linear 0.18 is sRGB code 118; the base look lifts it.
        XCTAssertGreaterThan(Int(centre), 130, "the raw neutral must still carry the base look, got \(centre)")
    }
}

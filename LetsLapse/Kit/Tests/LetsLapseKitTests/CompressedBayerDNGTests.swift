import XCTest
import ImageIO
import CoreImage
@testable import LetsLapseKit

final class CompressedBayerDNGTests: XCTestCase {
    private func cameraTags() -> [DNGTagValue] {
        func srationals(_ values: [Double]) -> Data {
            var data = Data()
            for value in values {
                data.appendU32(UInt32(bitPattern: Int32((value * 10000).rounded())))
                data.appendU32(10000)
            }
            return data
        }
        func rationals(_ values: [Double]) -> Data {
            var data = Data()
            for value in values {
                data.appendU32(UInt32((value * 10000).rounded()))
                data.appendU32(10000)
            }
            return data
        }
        var illuminant = Data()
        illuminant.appendU16(21)
        return [
            DNGTagValue(tag: 50721, type: 10, count: 9, payload: srationals([
                3.2406, -1.5372, -0.4986,
                -0.9689, 1.8758, 0.0415,
                0.0557, -0.2040, 1.0570,
            ])),
            DNGTagValue(tag: 50728, type: 5, count: 3, payload: rationals([1, 1, 1])),
            DNGTagValue(tag: 50778, type: 3, count: 1, payload: illuminant),
        ]
    }

    /// ImageIO must claim and demosaic our tiled lossless-JPEG CFA DNG —
    /// the exact shape camera vendors ship.
    func testTiledCompressedBayerDecodesThroughImageIO() throws {
        let width = 1024
        let height = 768
        var mosaic = [UInt16](repeating: 0, count: width * height)
        for index in 0..<mosaic.count {
            mosaic[index] = UInt16(2000 + (index % 4000))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bayer-lj-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: url) }
        try DNGAuthor.writeCompressedBayerDNG(
            mosaic: mosaic, width: width, height: height,
            cfaPattern: [0, 1, 1, 2],
            cameraColor: cameraTags(),
            preview: nil, to: url)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.adobe.raw-image",
                       "tiled LJ92 CFA must be claimed by the RAW codec")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, height)
    }

    /// The full Phase-2 pipeline on a real iPhone frame: camera-native
    /// transform → re-mosaic → tiled lossless JPEG → ImageIO render must
    /// match Apple's direct rendering, at a fraction of the size.
    func testRealIPhoneCompressedBayerMatchesAppleRendering() throws {
        let realURL = URL(fileURLWithPath: "/Users/stevenwright/Downloads/frame-00001.DNG")
        guard FileManager.default.fileExists(atPath: realURL.path) else {
            throw XCTSkip("no local iPhone reference DNG")
        }
        let referenceData = try Data(contentsOf: realURL)
        let reference = try DNGDocument.parseReference(referenceData)
        let model = try CameraColorTransform.model(from: reference)

        let directSource = try XCTUnwrap(CGImageSourceCreateWithURL(realURL as CFURL, nil))
        let direct = try XCTUnwrap(CGImageSourceCreateImageAtIndex(directSource, 0, nil))

        let rawFilter = try XCTUnwrap(CIRAWFilter(imageData: referenceData, identifierHint: nil))
        rawFilter.boostAmount = 0
        let linearImage = try XCTUnwrap(rawFilter.outputImage)
        let headroomScale = 0.25
        let rows = model.transformRows
        let transformed = linearImage.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: rows[0][0] * headroomScale, y: rows[0][1] * headroomScale, z: rows[0][2] * headroomScale, w: 0),
            "inputGVector": CIVector(x: rows[1][0] * headroomScale, y: rows[1][1] * headroomScale, z: rows[1][2] * headroomScale, w: 0),
            "inputBVector": CIVector(x: rows[2][0] * headroomScale, y: rows[2][1] * headroomScale, z: rows[2][2] * headroomScale, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let width = Int(transformed.extent.width)
        let height = Int(transformed.extent.height)
        let linearSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let context = CIContext(options: [
            .workingColorSpace: linearSpace,
            .workingFormat: CIFormat.RGBAh.rawValue,
        ])
        var rgba = [UInt16](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { buffer in
            context.render(
                transformed, toBitmap: buffer.baseAddress!, rowBytes: width * 8,
                bounds: transformed.extent, format: .RGBA16, colorSpace: nil)
        }
        let start = Date()
        let mosaic = DNGAuthor.mosaic(fromRGBA16: rgba, width: width, height: height, pattern: [0, 1, 1, 2])
        let mosaicMillis = Date().timeIntervalSince(start) * 1000

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bayer-real-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: url) }
        let writeStart = Date()
        try DNGAuthor.writeCompressedBayerDNG(
            mosaic: mosaic, width: width, height: height,
            cfaPattern: [0, 1, 1, 2],
            cameraColor: model.tags,
            headroomStops: 2,
            preview: nil, to: url)
        let writeMillis = Date().timeIntervalSince(writeStart) * 1000
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        print("BAYERLJ size \(String(format: "%.1f", Double(bytes) / 1_048_576)) MB · mosaic \(Int(mosaicMillis))ms · encode+write \(Int(writeMillis))ms")

        let mineSource = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(mineSource) as String?, "com.adobe.raw-image")
        let mine = try XCTUnwrap(CGImageSourceCreateImageAtIndex(mineSource, 0, nil))

        let directMeans = channelMeans(of: direct)
        let mineMeans = channelMeans(of: mine)
        print("BAYERLJ direct \(directMeans) mine \(mineMeans)")
        for channel in 0..<3 {
            let ratio = mineMeans[channel] / max(0.001, directMeans[channel])
            XCTAssertGreaterThan(ratio, 0.7, "channel \(channel) far darker than Apple render")
            XCTAssertLessThan(ratio, 1.4, "channel \(channel) far brighter than Apple render")
        }
        let directRG = directMeans[0] / directMeans[1]
        let mineRG = mineMeans[0] / mineMeans[1]
        let directBG = directMeans[2] / directMeans[1]
        let mineBG = mineMeans[2] / mineMeans[1]
        XCTAssertLessThanOrEqual(abs(mineRG - directRG) / directRG, 0.12, "red/green cast vs Apple render")
        XCTAssertLessThanOrEqual(abs(mineBG - directBG) / directBG, 0.12, "blue/green cast vs Apple render")
        XCTAssertLessThan(bytes, 25_000_000, "compressed Bayer should be far below LinearRaw's ~73MB")
    }

    private func channelMeans(of image: CGImage) -> [Double] {
        let width = 256
        let height = 256
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &bytes, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sums = [0.0, 0.0, 0.0]
        for index in 0..<(width * height) {
            sums[0] += Double(bytes[index * 4 + 2])
            sums[1] += Double(bytes[index * 4 + 1])
            sums[2] += Double(bytes[index * 4])
        }
        return sums.map { $0 / Double(width * height) }
    }
}

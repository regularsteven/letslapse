import XCTest
import ImageIO
import CoreImage
@testable import LetsLapseKit

final class CameraColorTransformTests: XCTestCase {
    private func srationals(_ values: [Double]) -> Data {
        var data = Data()
        for value in values {
            data.appendU32(UInt32(bitPattern: Int32((value * 10000).rounded())))
            data.appendU32(10000)
        }
        return data
    }

    private func rationals(_ values: [Double]) -> Data {
        var data = Data()
        for value in values {
            data.appendU32(UInt32((value * 10000).rounded()))
            data.appendU32(10000)
        }
        return data
    }

    private func shorts(_ values: [UInt16]) -> Data {
        var data = Data()
        for value in values { data.appendU16(value) }
        return data
    }

    private func syntheticReference() -> DNGReference {
        DNGReference(
            ifd0: [
                DNGTagValue(tag: 271, type: 2, count: 6, payload: Data("Apple\0".utf8)),
                DNGTagValue(tag: 50721, type: 10, count: 9, payload: srationals([
                    1.05, -0.30, -0.10,
                    -0.40, 1.20, 0.20,
                    -0.05, 0.20, 0.60,
                ])),
                DNGTagValue(tag: 50722, type: 10, count: 9, payload: srationals([
                    0.90, -0.25, -0.08,
                    -0.35, 1.15, 0.18,
                    -0.04, 0.18, 0.65,
                ])),
                DNGTagValue(tag: 50728, type: 5, count: 3, payload: rationals([0.42, 1.0, 0.56])),
                DNGTagValue(tag: 50778, type: 3, count: 1, payload: shorts([17])),
                DNGTagValue(tag: 50779, type: 3, count: 1, payload: shorts([21])),
            ],
            raw: [])
    }

    /// By construction, sRGB white must land exactly on the as-shot neutral
    /// (green-normalised) — the core invariant of the transform.
    func testSRGBWhiteMapsToNeutral() throws {
        let model = try CameraColorTransform.model(from: syntheticReference())
        let white = CameraColorTransform.multiply(model.transformRows, [1, 1, 1])
        XCTAssertEqual(white[1], 1.0, accuracy: 1e-9)
        XCTAssertEqual(white[0], 0.42, accuracy: 1e-6)
        XCTAssertEqual(white[2], 0.56, accuracy: 1e-6)
    }

    func testCarriesIdentityAndMatrixTags() throws {
        let model = try CameraColorTransform.model(from: syntheticReference())
        let tags = Set(model.tags.map(\.tag))
        XCTAssertTrue(tags.contains(271))
        XCTAssertTrue(tags.contains(50721))
        XCTAssertTrue(tags.contains(50722))
        XCTAssertTrue(tags.contains(50728))
        XCTAssertFalse(tags.contains(274), "orientation must not be carried — samples are display-oriented")
    }

    func testMissingMatrixThrows() {
        let reference = DNGReference(
            ifd0: [DNGTagValue(tag: 50728, type: 5, count: 3, payload: rationals([0.5, 1, 0.6]))],
            raw: [])
        XCTAssertThrowsError(try CameraColorTransform.model(from: reference))
    }

    /// The decisive gate: transform a real iPhone frame into camera-native
    /// space, author with the camera's own tags, and require ImageIO's
    /// develop (matrices + as-shot neutral) to reproduce Apple's direct
    /// rendering of the original — same tone, same casts.
    func testRealIPhoneCameraNativeMatchesAppleRendering() throws {
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
        var rgb = Data(count: width * height * 6)
        rgb.withUnsafeMutableBytes { destination in
            rgba.withUnsafeBytes { source in
                let src = source.bindMemory(to: UInt16.self)
                let dst = destination.bindMemory(to: UInt16.self)
                for index in 0..<(width * height) {
                    dst[index * 3] = src[index * 4]
                    dst[index * 3 + 1] = src[index * 4 + 1]
                    dst[index * 3 + 2] = src[index * 4 + 2]
                }
            }
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("camera-native-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: url) }
        try DNGAuthor.writeLinearDNG(
            rgb16: rgb, width: width, height: height,
            headroomStops: 2, cameraColor: model.tags,
            preview: nil, to: url)

        let mineSource = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(mineSource) as String?, "com.adobe.raw-image")
        let mine = try XCTUnwrap(CGImageSourceCreateImageAtIndex(mineSource, 0, nil))

        let directMeans = channelMeans(of: direct)
        let mineMeans = channelMeans(of: mine)
        print("CAMNATIVE direct \(directMeans) mine \(mineMeans)")
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

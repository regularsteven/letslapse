import XCTest
import ImageIO
import CoreImage
import Accelerate
@testable import LetsLapseKit

final class LinearDNGTests: XCTestCase {
    /// A LinearRaw DNG with known linear values must be claimed by the RAW
    /// codec and render neutrally: linear 18% gray comes back as sRGB ~118
    /// with R≈G≈B — the color-correctness contract of the linear path.
    func testLinearGrayRendersNeutral() throws {
        let width = 1024
        let height = 768
        var rgb = Data(capacity: width * height * 6)
        let gray = UInt16(Double(65535) * 0.18)
        let bright = UInt16(Double(65535) * 0.7)
        for index in 0..<(width * height) {
            let value = (index % width) < width / 2 ? gray : bright
            var pixel = value.littleEndian
            withUnsafeBytes(of: &pixel) { bytes in
                rgb.append(contentsOf: bytes)
                rgb.append(contentsOf: bytes)
                rgb.append(contentsOf: bytes)
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("linear-dng-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: url) }
        try DNGAuthor.writeLinearDNG(rgb16: rgb, width: width, height: height, preview: nil, to: url)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.adobe.raw-image")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, width)

        let values = grayValuesRGB(of: image)
        // Sample the middle of each half.
        let leftIndex = (height / 2) * width + width / 4
        let rightIndex = (height / 2) * width + (3 * width) / 4
        let left = values[leftIndex]
        let right = values[rightIndex]
        // Neutrality is the contract: channels within 3 steps of each other.
        // (Absolute tone varies with CoreRAW's base curve, so only bounds and
        // ordering are asserted.)
        XCTAssertLessThanOrEqual(abs(Int(left.0) - Int(left.1)), 3)
        XCTAssertLessThanOrEqual(abs(Int(left.1) - Int(left.2)), 3)
        XCTAssertLessThanOrEqual(abs(Int(right.0) - Int(right.1)), 3)
        XCTAssertGreaterThan(Int(right.1), Int(left.1), "brighter linear input must render brighter")
        XCTAssertTrue((90...230).contains(Int(left.1)), "18% gray badly out of range: \(left)")
        XCTAssertGreaterThan(Int(right.1), 200, "70% linear should render bright, got \(right)")
    }

    /// The full planned capture pipeline, offline: Apple's own decoder takes
    /// a real iPhone Bayer DNG to scene-linear, we re-author it as a Linear
    /// DNG, and the result must render with the same colors as Apple's
    /// direct rendering — the guarantee the Bayer-native path couldn't give.
    func testLinearPipelineMatchesAppleRendering() throws {
        let realURL = URL(fileURLWithPath: "/Users/stevenwright/Downloads/frame-00001.DNG")
        guard FileManager.default.fileExists(atPath: realURL.path) else {
            throw XCTSkip("no local iPhone reference DNG")
        }

        // Apple's direct rendering (ground truth).
        let directSource = try XCTUnwrap(CGImageSourceCreateWithURL(realURL as CFURL, nil))
        let direct = try XCTUnwrap(CGImageSourceCreateImageAtIndex(directSource, 0, nil))

        // Planned pipeline: CIRAWFilter → linear working space → u16 → Linear DNG.
        let rawFilter = try XCTUnwrap(CIRAWFilter(imageData: try Data(contentsOf: realURL), identifierHint: nil))
        rawFilter.boostAmount = 0
        let linearImage = try XCTUnwrap(rawFilter.outputImage)
        let width = Int(linearImage.extent.width)
        let height = Int(linearImage.extent.height)

        let linearSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let context = CIContext(options: [
            .workingColorSpace: linearSpace,
            .workingFormat: CIFormat.RGBAh.rawValue,
        ])
        var half = [UInt16](repeating: 0, count: width * height * 4)
        half.withUnsafeMutableBytes { buffer in
            context.render(
                linearImage,
                toBitmap: buffer.baseAddress!,
                rowBytes: width * 8,
                bounds: linearImage.extent,
                format: .RGBAh,
                colorSpace: linearSpace)
        }
        var rgb = Data(capacity: width * height * 6)
        let headroomScale: Float = 0.25 // 2 stops
        for index in 0..<(width * height) {
            for channel in 0..<3 {
                let linear = max(0, Float(Float16(bitPattern: half[index * 4 + channel])))
                let stored = UInt16(min(65535, linear * headroomScale * 65535))
                rgb.append(UInt8(stored & 0xFF))
                rgb.append(UInt8(stored >> 8))
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("linear-pipeline-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: url) }
        try DNGAuthor.writeLinearDNG(
            rgb16: rgb, width: width, height: height,
            headroomStops: 2, preview: nil, to: url)

        let mineSource = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(mineSource) as String?, "com.adobe.raw-image")
        let mine = try XCTUnwrap(CGImageSourceCreateImageAtIndex(mineSource, 0, nil))

        // Compare channel means of central crops (orientation differs: Apple
        // bakes rotation; compare via sorted channel statistics instead).
        let directMeans = channelMeans(of: direct)
        let mineMeans = channelMeans(of: mine)
        print("LINEARDNG direct means \(directMeans) mine \(mineMeans)")
        for channel in 0..<3 {
            let ratio = mineMeans[channel] / max(0.001, directMeans[channel])
            XCTAssertGreaterThan(ratio, 0.75, "channel \(channel) far darker than Apple render")
            XCTAssertLessThan(ratio, 1.35, "channel \(channel) far brighter than Apple render")
        }
        // Cast check: my R/G and B/G must match Apple's within 12%.
        let directRG = directMeans[0] / directMeans[1]
        let mineRG = mineMeans[0] / mineMeans[1]
        let directBG = directMeans[2] / directMeans[1]
        let mineBG = mineMeans[2] / mineMeans[1]
        XCTAssertLessThanOrEqual(abs(mineRG - directRG) / directRG, 0.12, "red/green cast vs Apple render")
        XCTAssertLessThanOrEqual(abs(mineBG - directBG) / directBG, 0.12, "blue/green cast vs Apple render")
    }

    /// The production blend algorithm over a real untouched-DNG sequence
    /// captured on the iPhone ("1 · Untouched" mode): times each stage,
    /// writes viewable outputs, and asserts the blend renders with the same
    /// tone and cast as a single frame of the same scene.
    func testBlendsRealUntouchedSequence() throws {
        let folder = URL(fileURLWithPath: "/Users/stevenwright/Library/Application Support/LetsLapse/Projects/44A0A7C9-B3BF-4AA5-8F09-54E200E36C12/source")
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw XCTSkip("no local untouched sequence")
        }
        let frameURLs = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "dng" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard frameURLs.count >= 5 else { throw XCTSkip("need at least 5 frames") }

        let outputFolder = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-stevenwright-Documents-dev-letslapse/74c6aabd-e72c-4181-a8be-063a41337a65/scratchpad")
        let linearSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let context = CIContext(options: [
            .workingColorSpace: linearSpace,
            .workingFormat: CIFormat.RGBAh.rawValue,
            .cacheIntermediates: false,
        ])

        // Ground truth: single-frame render statistics.
        let singleSource = try XCTUnwrap(CGImageSourceCreateWithURL(frameURLs[0] as CFURL, nil))
        let single = try XCTUnwrap(CGImageSourceCreateImageAtIndex(singleSource, 0, nil))
        let singleMeans = channelMeans(of: single)

        for count in [3, 5] {
            let overallStart = Date()
            var stageStart = Date()
            var summed: CIImage?
            for url in frameURLs.prefix(count) {
                let filter = try XCTUnwrap(CIRAWFilter(imageData: try Data(contentsOf: url), identifierHint: nil))
                filter.boostAmount = 0
                let image = try XCTUnwrap(filter.outputImage)
                summed = summed.map { image.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? image
            }
            let graphMillis = Date().timeIntervalSince(stageStart) * 1000
            let scale = (1.0 / CGFloat(count)) / 4.0
            let averaged = try XCTUnwrap(summed).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            let width = Int(averaged.extent.width)
            let height = Int(averaged.extent.height)

            stageStart = Date()
            var rgba = [UInt16](repeating: 0, count: width * height * 4)
            rgba.withUnsafeMutableBytes { buffer in
                context.render(
                    averaged, toBitmap: buffer.baseAddress!, rowBytes: width * 8,
                    bounds: averaged.extent, format: .RGBA16, colorSpace: linearSpace)
            }
            let renderMillis = Date().timeIntervalSince(stageStart) * 1000

            stageStart = Date()
            var rgb = Data(count: width * height * 6)
            rgba.withUnsafeMutableBytes { source in
                rgb.withUnsafeMutableBytes { destination in
                    var sourceBuffer = vImage_Buffer(
                        data: source.baseAddress, height: vImagePixelCount(height),
                        width: vImagePixelCount(width), rowBytes: width * 8)
                    var destinationBuffer = vImage_Buffer(
                        data: destination.baseAddress, height: vImagePixelCount(height),
                        width: vImagePixelCount(width), rowBytes: width * 6)
                    vImageConvert_RGBA16UtoRGB16U(&sourceBuffer, &destinationBuffer, vImage_Flags(kvImageNoFlags))
                }
            }
            let packMillis = Date().timeIntervalSince(stageStart) * 1000

            stageStart = Date()
            let outputURL = outputFolder.appendingPathComponent("untouched-blend-\(count).dng")
            try DNGAuthor.writeLinearDNG(
                rgb16: rgb, width: width, height: height,
                headroomStops: 2, preview: nil, to: outputURL)
            let writeMillis = Date().timeIntervalSince(stageStart) * 1000
            let totalMillis = Date().timeIntervalSince(overallStart) * 1000
            let fileBytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
            print("HARNESS blend \(count): graph \(Int(graphMillis))ms render \(Int(renderMillis))ms pack \(Int(packMillis))ms write \(Int(writeMillis))ms total \(Int(totalMillis))ms → \(fileBytes / 1_048_576) MB")

            let blendSource = try XCTUnwrap(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(blendSource) as String?, "com.adobe.raw-image")
            let blended = try XCTUnwrap(CGImageSourceCreateImageAtIndex(blendSource, 0, nil))
            let blendMeans = channelMeans(of: blended)
            print("HARNESS blend \(count) means \(blendMeans) vs single \(singleMeans)")
            for channel in 0..<3 {
                let ratio = blendMeans[channel] / max(0.001, singleMeans[channel])
                XCTAssertGreaterThan(ratio, 0.72, "channel \(channel) far darker than single frame")
                XCTAssertLessThan(ratio, 1.4, "channel \(channel) far brighter than single frame")
            }
            let singleRG = singleMeans[0] / singleMeans[1]
            let blendRG = blendMeans[0] / blendMeans[1]
            XCTAssertLessThanOrEqual(abs(blendRG - singleRG) / singleRG, 0.12, "cast drift vs single frame")
        }
    }

    // MARK: - Helpers

    private func grayValuesRGB(of image: CGImage) -> [(UInt8, UInt8, UInt8)] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &bytes, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (0..<(width * height)).map {
            (bytes[$0 * 4 + 2], bytes[$0 * 4 + 1], bytes[$0 * 4])
        }
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

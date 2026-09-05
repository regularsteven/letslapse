import Accelerate
import CoreImage
import Foundation
import ImageIO
import LetsLapseKit
import Metal

/// A decoded picture in the engine's linear Display P3, RGB Float32.
struct LinearPicture {
    let width: Int
    let height: Int
    let rgb: [Float]
    let asShotK: Double
    let asShotTint: Double
    let decodePath: RawDecodePath

    func cropped(to w: Int, _ h: Int) -> LinearPicture {
        guard w != width || h != height else { return self }
        var out = [Float](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            let src = (y * width) * 3, dst = (y * w) * 3
            out.replaceSubrange(dst..<(dst + w * 3), with: rgb[src..<(src + w * 3)])
        }
        return LinearPicture(width: w, height: h, rgb: out, asShotK: asShotK, asShotTint: asShotTint, decodePath: decodePath)
    }
}

struct Means {
    let whole: SIMD3<Double>
    let blocks: [SIMD3<Double>]
    static let across = 8, down = 6
}

struct VerifyResult {
    var input: URL
    var output: URL
    var reference: URL
    var outputWidth = 0, outputHeight = 0
    var inputWidth = 0, inputHeight = 0
    var wholeRelative = 0.0, blockRelative = 0.0, blockAbsolute = 0.0
    var greenRatio = 0.0, blueRatio = 0.0
    var psnr = 0.0, ssim = 0.0, stopsRMS = 0.0
    var wbPushes: [(label: String, psnr: Double, stopsRMS: Double, balanced: Bool)] = []
    var repackApplies = false
    var appleDirectOpens = false
    /// Apple's decode by URL against the Kit's decode of the input, whole-frame.
    var appleDirectWhole = -1.0
    var appleDirectGreenRatio = 0.0
    var appleDirectBlueRatio = 0.0
    var imageIOType = ""
    var imageIODecodes = false
    var quickLook = ""
    var adobe = ""
    var adobeGap = -1.0
    var notes: [String] = []

    var text: String {
        var lines: [String] = []
        lines.append("verify \(output.lastPathComponent) against \(reference.lastPathComponent)")
        lines.append(String(format: "  size          %dx%d (reference %dx%d)", outputWidth, outputHeight, inputWidth, inputHeight))
        lines.append(String(format: "  means         whole %.2f%%  block %.2f%%  abs %.5f   green ×%.3f blue ×%.3f", wholeRelative * 100, blockRelative * 100, blockAbsolute, greenRatio, blueRatio))
        lines.append(String(format: "  fidelity      PSNR %.2f dB (peak 1.0 linear)  SSIM %.4f (γ2.2 luma, 8×8)  RMS %.3f stops (>0.5%% floor)", psnr, ssim, stopsRMS))
        for push in wbPushes {
            lines.append(String(format: "  wb %-10@ PSNR %.2f dB  RMS %.3f stops  %@", push.label as NSString, push.psnr, push.stopsRMS, push.balanced ? "balanced in converter" : "NOT balanced in converter"))
        }
        lines.append("  apple direct  \(appleDirectOpens ? "opens" : "declined")\(repackApplies ? " — LossyLinearDNG repack APPLIES in the Kit (Adobe-shaped lossy container)" : ", no repack needed")"
                     + (appleDirectWhole >= 0 ? String(format: "; direct decode vs input: whole %.2f%%  green ×%.3f blue ×%.3f", appleDirectWhole * 100, appleDirectGreenRatio, appleDirectBlueRatio) : ""))
        lines.append("  imageio       type \(imageIOType) decodes \(imageIODecodes)")
        if !quickLook.isEmpty { lines.append("  quicklook     \(quickLook)") }
        if !adobe.isEmpty { lines.append("  adobe         \(adobe)" + (adobeGap >= 0 ? String(format: " · re-decode gap %.2f%%", adobeGap * 100) : "")) }
        for note in notes { lines.append("  note          \(note)") }
        return lines.joined(separator: "\n")
    }

    var json: String {
        var object: [String: Any] = [
            "output": output.path, "reference": reference.path,
            "outputWidth": outputWidth, "outputHeight": outputHeight,
            "wholeRelative": wholeRelative, "blockRelative": blockRelative, "blockAbsolute": blockAbsolute,
            "greenRatio": greenRatio, "blueRatio": blueRatio,
            "psnr": psnr, "ssim": ssim, "stopsRMS": stopsRMS,
            "repackApplies": repackApplies, "appleDirectOpens": appleDirectOpens, "appleDirectWhole": appleDirectWhole,
            "imageIOType": imageIOType, "imageIODecodes": imageIODecodes,
            "quickLook": quickLook, "adobe": adobe, "adobeGap": adobeGap, "notes": notes,
        ]
        object["wb"] = wbPushes.map { ["label": $0.label, "psnr": $0.psnr, "stopsRMS": $0.stopsRMS, "balanced": $0.balanced] }
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

/// Quality and compatibility of one converted frame, measured the way
/// `LossyLinearDNGTests` measures: both files through the Kit's own decoder
/// (Apple's pipeline) into linear P3, compared as means, PSNR/SSIM and
/// under white-balance pushes.
final class Verifier {
    private let decoder: LinearFrameDecoder

    init() throws {
        decoder = try LinearFrameDecoder()
    }

    // MARK: - Decoding

    /// Pixel size of the main image from the file's own tags (DNG) or
    /// ImageIO's properties (other raws) — never by spinning up a raw
    /// converter just to read a number: RawCamera keeps asynchronous work
    /// behind a `CIRAWFilter`, and a filter created and dropped in a tight
    /// loop crashed the bench inside RawCamera (SIGSEGV on a released
    /// buffer, 2026-09-05).
    static func nativeSize(_ url: URL) -> CGSize? {
        if url.pathExtension.lowercased() == "dng",
           let data = try? Data(contentsOf: url, options: .mappedIfSafe),
           let directories = try? DNGDocument.parseDirectories(data) {
            let candidates = [directories.ifd0] + directories.subIFDs
            if let raw = candidates.first(where: { ($0.int(254) ?? 0) == 0 && [32803, 34892].contains($0.int(262) ?? -1) }),
               let width = raw.int(256), let height = raw.int(257) {
                // DefaultCropSize is what the converter reports as the native size.
                let crop = raw.doubles(50720)
                if crop.count == 2, crop[0] > 0, crop[1] > 0 { return CGSize(width: crop[0], height: crop[1]) }
                return CGSize(width: width, height: height)
            }
        }
        let frame = ImportedStills.frame(at: url)
        if let width = frame.pixelWidth, let height = frame.pixelHeight { return CGSize(width: width, height: height) }
        return nil
    }

    /// Apple's own decode by URL — no repack — rendered small through a
    /// context of our own and waited for, so nothing is dropped while
    /// RawCamera still works on it. Whole-frame means in linear P3.
    static func appleDirectMeans(_ url: URL) -> SIMD3<Double>? {
        guard let raw = CIRAWFilter(imageURL: url) else { return nil }
        raw.boostAmount = 0
        raw.extendedDynamicRangeAmount = 2
        raw.scaleFactor = 0.125
        guard let image = raw.outputImage, let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return nil }
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: extent, format: .RGBAf, colorSpace: space)
        }
        var mean = SIMD3<Double>.zero
        for i in stride(from: 0, to: pixels.count, by: 4) {
            mean += SIMD3<Double>(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
        }
        return mean / Double(width * height)
    }

    func decode(_ url: URL, scale: Float, path: RawDecodePath = .bradfordAdaptation, recipe: GradeRecipe = .neutral) throws -> LinearPicture {
        let frame = try decoder.decode(url: url, scale: scale, path: path, recipe: recipe)
        let texture = frame.texture
        let width = texture.width, height = texture.height
        var half = [UInt16](repeating: 0, count: width * height * 4)
        half.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        // Float16 → Float32, RGBA → RGB.
        var rgba = [Float](repeating: 0, count: width * height * 4)
        half.withUnsafeMutableBufferPointer { source in
            rgba.withUnsafeMutableBufferPointer { destination in
                var src = vImage_Buffer(data: source.baseAddress, height: 1, width: vImagePixelCount(width * height * 4), rowBytes: width * height * 8)
                var dst = vImage_Buffer(data: destination.baseAddress, height: 1, width: vImagePixelCount(width * height * 4), rowBytes: width * height * 16)
                vImageConvert_Planar16FtoPlanarF(&src, &dst, vImage_Flags(kvImageNoFlags))
            }
        }
        var rgb = [Float](repeating: 0, count: width * height * 3)
        rgba.withUnsafeMutableBufferPointer { source in
            rgb.withUnsafeMutableBufferPointer { destination in
                var src = vImage_Buffer(data: source.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 16)
                var dst = vImage_Buffer(data: destination.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 12)
                vImageConvert_RGBAFFFFtoRGBFFF(&src, &dst, vImage_Flags(kvImageNoFlags))
            }
        }
        return LinearPicture(width: width, height: height, rgb: rgb, asShotK: frame.asShotTemperatureK, asShotTint: frame.asShotTint, decodePath: frame.decodePath)
    }

    /// Decodes `candidate` at the scale that lands it on the same pixel grid
    /// as `reference` decoded at `referenceScale`, cropping any one-pixel
    /// rounding difference.
    func decodePair(reference: URL, candidate: URL, referenceScale: Float,
                    path: RawDecodePath = .bradfordAdaptation, recipe: GradeRecipe = .neutral) throws -> (LinearPicture, LinearPicture) {
        guard let referenceSize = Self.nativeSize(reference), let candidateSize = Self.nativeSize(candidate) else {
            throw SpikeError.decode("CIRAWFilter declined one of the pair")
        }
        let candidateScale = referenceScale * Float(referenceSize.width / candidateSize.width)
        let a = try decode(reference, scale: referenceScale, path: path, recipe: recipe)
        let b = try decode(candidate, scale: candidateScale, path: path, recipe: recipe)
        let w = min(a.width, b.width), h = min(a.height, b.height)
        return (a.cropped(to: w, h), b.cropped(to: w, h))
    }

    // MARK: - Metrics

    static func means(_ picture: LinearPicture) -> Means {
        let width = picture.width, height = picture.height
        var whole = SIMD3<Double>.zero
        var blocks = [SIMD3<Double>](repeating: .zero, count: Means.across * Means.down)
        var counts = [Int](repeating: 0, count: blocks.count)
        picture.rgb.withUnsafeBufferPointer { p in
            for y in 0..<height {
                let by = min(Means.down - 1, y * Means.down / height)
                for x in 0..<width {
                    let i = (y * width + x) * 3
                    let rgb = SIMD3<Double>(Double(p[i]), Double(p[i + 1]), Double(p[i + 2]))
                    whole += rgb
                    let bx = min(Means.across - 1, x * Means.across / width)
                    blocks[by * Means.across + bx] += rgb
                    counts[by * Means.across + bx] += 1
                }
            }
        }
        return Means(whole: whole / Double(width * height), blocks: zip(blocks, counts).map { $0 / Double(max(1, $1)) })
    }

    static func compare(_ candidate: Means, to reference: Means, blockFloor: Double = 0.02) -> (whole: Double, block: Double, absolute: Double) {
        func relative(_ a: SIMD3<Double>, _ b: SIMD3<Double>, floor: Double) -> Double {
            var worst = 0.0
            for c in 0..<3 where b[c] >= floor { worst = max(worst, abs(a[c] - b[c]) / b[c]) }
            return worst
        }
        let whole = relative(candidate.whole, reference.whole, floor: 0.002)
        var block = 0.0, absolute = 0.0
        for (a, b) in zip(candidate.blocks, reference.blocks) {
            block = max(block, relative(a, b, floor: blockFloor))
            for c in 0..<3 { absolute = max(absolute, abs(a[c] - b[c])) }
        }
        return (whole, block, absolute)
    }

    /// PSNR (peak 1.0, linear RGB), SSIM (γ2.2 luma, 8×8 blocks) and the RMS
    /// error in stops over pixels above a 0.5% floor.
    static func fidelity(_ candidate: LinearPicture, _ reference: LinearPicture) -> (psnr: Double, ssim: Double, stopsRMS: Double) {
        let n = candidate.width * candidate.height
        precondition(n == reference.width * reference.height)
        var mse = 0.0
        var stopsSum = 0.0
        var stopsCount = 0
        var lumaA = [Float](repeating: 0, count: n), lumaB = [Float](repeating: 0, count: n)
        candidate.rgb.withUnsafeBufferPointer { a in
            reference.rgb.withUnsafeBufferPointer { b in
                for i in 0..<n {
                    let j = i * 3
                    for c in 0..<3 {
                        let d = Double(a[j + c]) - Double(b[j + c])
                        mse += d * d
                        if b[j + c] > 0.005, a[j + c] > 0 {
                            let s = log2(Double(a[j + c]) / Double(b[j + c]))
                            stopsSum += s * s
                            stopsCount += 1
                        }
                    }
                    let la = 0.2627 * a[j] + 0.678 * a[j + 1] + 0.0593 * a[j + 2]
                    let lb = 0.2627 * b[j] + 0.678 * b[j + 1] + 0.0593 * b[j + 2]
                    lumaA[i] = pow(max(0, la), Float(1 / 2.2))
                    lumaB[i] = pow(max(0, lb), Float(1 / 2.2))
                }
            }
        }
        mse /= Double(n * 3)
        let psnr = mse > 0 ? 10 * log10(1 / mse) : 99
        let stopsRMS = stopsCount > 0 ? (stopsSum / Double(stopsCount)).squareRoot() : 0
        // SSIM over 8×8 blocks.
        let width = candidate.width, height = candidate.height
        let c1 = 0.01 * 0.01, c2 = 0.03 * 0.03
        var ssimSum = 0.0
        var blocks = 0
        var by = 0
        while by + 8 <= height {
            var bx = 0
            while bx + 8 <= width {
                var ma = 0.0, mb = 0.0
                for y in 0..<8 { for x in 0..<8 { let i = (by + y) * width + bx + x; ma += Double(lumaA[i]); mb += Double(lumaB[i]) } }
                ma /= 64; mb /= 64
                var va = 0.0, vb = 0.0, cov = 0.0
                for y in 0..<8 {
                    for x in 0..<8 {
                        let i = (by + y) * width + bx + x
                        let da = Double(lumaA[i]) - ma, db = Double(lumaB[i]) - mb
                        va += da * da; vb += db * db; cov += da * db
                    }
                }
                va /= 63; vb /= 63; cov /= 63
                ssimSum += ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
                blocks += 1
                bx += 8
            }
            by += 8
        }
        return (psnr, blocks > 0 ? ssimSum / Double(blocks) : 1, stopsRMS)
    }

    // MARK: - The whole verification

    func verify(input: URL, output: URL, reference: URL? = nil, whiteBalancePush: Bool, adobeRoundTrip: Bool, columnBands: Int = 0) throws -> VerifyResult {
        let reference = reference ?? input
        var result = VerifyResult(input: input, output: output, reference: reference)
        result.repackApplies = LossyLinearDNG.isApplicable(output)
        if let size = Self.nativeSize(output) { result.outputWidth = Int(size.width); result.outputHeight = Int(size.height) }
        if let size = Self.nativeSize(reference) { result.inputWidth = Int(size.width); result.inputHeight = Int(size.height) }

        // (a) Means against the input, exactly as the Kit test measures.
        let (inputPicture, outputPicture) = try decodePair(reference: input, candidate: output, referenceScale: 0.25)
        let inputMeans = Self.means(inputPicture), outputMeans = Self.means(outputPicture)
        let gap = Self.compare(outputMeans, to: inputMeans)
        result.wholeRelative = gap.whole
        result.blockRelative = gap.block
        result.blockAbsolute = gap.absolute
        result.greenRatio = outputMeans.whole.y / max(1e-9, inputMeans.whole.y)
        result.blueRatio = outputMeans.whole.z / max(1e-9, inputMeans.whole.z)
        // Per-channel means, whole frame + centre + corner blocks, so a cast
        // can be told from a shading (radial) error.
        func rgb(_ v: SIMD3<Double>) -> String { String(format: "%.4f %.4f %.4f", v.x, v.y, v.z) }
        func ratio(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> String { String(format: "×%.3f ×%.3f ×%.3f", a.x / max(1e-9, b.x), a.y / max(1e-9, b.y), a.z / max(1e-9, b.z)) }
        let centre = 2 * Means.across + 3, tl = 0, tr = Means.across - 1, bl = (Means.down - 1) * Means.across, br = Means.down * Means.across - 1
        result.notes.append("channels whole  out \(rgb(outputMeans.whole))  in \(rgb(inputMeans.whole))  \(ratio(outputMeans.whole, inputMeans.whole))")
        result.notes.append("channels centre out \(rgb(outputMeans.blocks[centre]))  in \(rgb(inputMeans.blocks[centre]))  \(ratio(outputMeans.blocks[centre], inputMeans.blocks[centre]))")
        for (label, i) in [("TL", tl), ("TR", tr), ("BL", bl), ("BR", br)] {
            result.notes.append("channels \(label)     out \(rgb(outputMeans.blocks[i]))  in \(rgb(inputMeans.blocks[i]))  \(ratio(outputMeans.blocks[i], inputMeans.blocks[i]))")
        }
        if columnBands > 0 {
            // Green means per vertical band, output over input, to see a
            // decoder's precision along a ramp.
            func bands(_ picture: LinearPicture) -> [Double] {
                var sums = [Double](repeating: 0, count: columnBands), counts = [Int](repeating: 0, count: columnBands)
                picture.rgb.withUnsafeBufferPointer { p in
                    for y in 0..<picture.height {
                        for x in 0..<picture.width {
                            let band = min(columnBands - 1, x * columnBands / picture.width)
                            sums[band] += Double(p[(y * picture.width + x) * 3 + 1]); counts[band] += 1
                        }
                    }
                }
                return zip(sums, counts).map { $0 / Double(max(1, $1)) }
            }
            let a = bands(outputPicture), b = bands(inputPicture)
            result.notes.append("bands out   " + a.map { String(format: "%.5f", $0) }.joined(separator: " "))
            result.notes.append("bands in    " + b.map { String(format: "%.5f", $0) }.joined(separator: " "))
            result.notes.append("bands ratio " + zip(a, b).map { String(format: "%.4f", $0 / max(1e-9, $1)) }.joined(separator: " "))
        }

        // (b) Fidelity against the reference (the lossless twin when given).
        let (referencePicture, candidatePicture) = reference == input && outputPicture.width == inputPicture.width
            ? (inputPicture, outputPicture)
            : try decodePair(reference: reference, candidate: output, referenceScale: 0.25)
        let fidelity = Self.fidelity(candidatePicture, referencePicture)
        result.psnr = fidelity.psnr
        result.ssim = fidelity.ssim
        result.stopsRMS = fidelity.stopsRMS

        // (c) White-balance pushes, balanced inside the converter.
        if whiteBalancePush {
            let asShotK = max(1667, min(25000, referencePicture.asShotK))
            let asShotMired = 1e6 / asShotK
            func mired(forDeltaK delta: Double) -> Float {
                let declared = max(1667, min(25000, asShotK + delta))
                return Float(asShotMired - 1e6 / declared)
            }
            let pushes: [(String, Float, Float)] = [
                ("+2000K", mired(forDeltaK: 2000), 0),
                ("-2000K", mired(forDeltaK: -2000), 0),
                ("tint+40", 0, -40 / LinearFrameDecoder.cirawTintPerRecipeUnit * -1),
                ("tint-40", 0, 40 / LinearFrameDecoder.cirawTintPerRecipeUnit * -1),
            ]
            for (label, temperature, tint) in pushes {
                var recipe = GradeRecipe.neutral
                recipe.temperatureMired = temperature
                recipe.tint = tint
                let (r, c) = try decodePair(reference: reference, candidate: output, referenceScale: 0.25, path: .cirawFilter, recipe: recipe)
                let f = Self.fidelity(c, r)
                result.wbPushes.append((label, f.psnr, f.stopsRMS, r.decodePath == .cirawFilter && c.decodePath == .cirawFilter))
            }
        }

        // Compatibility. Apple's decode by URL is measured on its own — the Kit
        // decode above goes through the repack whenever the container is
        // Adobe-shaped, which says nothing about Preview or Photos.
        if let direct = Self.appleDirectMeans(output) {
            result.appleDirectOpens = true
            let referenceMeans = inputMeans.whole
            var worst = 0.0
            for c in 0..<3 where referenceMeans[c] >= 0.002 { worst = max(worst, abs(direct[c] - referenceMeans[c]) / referenceMeans[c]) }
            result.appleDirectWhole = worst
            result.appleDirectGreenRatio = direct.y / max(1e-9, referenceMeans.y)
            result.appleDirectBlueRatio = direct.z / max(1e-9, referenceMeans.z)
        } else {
            result.appleDirectOpens = false
        }
        if let source = CGImageSourceCreateWithURL(output as CFURL, nil) {
            result.imageIOType = (CGImageSourceGetType(source) as String?) ?? "nil"
            result.imageIODecodes = CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        }
        result.quickLook = Self.quickLook(output)
        if adobeRoundTrip {
            let adobe = Self.adobeRoundTrip(output: output, input: input, verifier: self)
            result.adobe = adobe.0
            result.adobeGap = adobe.1
        }
        return result
    }

    /// `qlmanage -t` is QuickLook's thumbnailer — the same decoder Preview
    /// and Finder use — so "did it draw one" is the scriptable form of
    /// "does Preview open it".
    static func quickLook(_ url: URL) -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dngspike-ql-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-t", "-s", "256", "-o", directory.path, url.path]
        process.standardOutput = nil
        process.standardError = nil
        do { try process.run() } catch { return "qlmanage failed to launch" }
        process.waitUntilExit()
        let produced = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.first { $0.hasSuffix(".png") }
        return produced != nil ? "thumbnail drawn" : "NO thumbnail (exit \(process.terminationStatus))"
    }

    static let adobeConverter = URL(fileURLWithPath: "/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter")

    /// Adobe DNG Converter's verdict on one file: a `-c` round trip that
    /// produces a file means it parsed and decoded it.
    static func adobeAccepts(_ url: URL) -> String {
        guard FileManager.default.fileExists(atPath: adobeConverter.path) else { return "not installed" }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dngspike-accept-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process()
        process.executableURL = adobeConverter
        process.arguments = ["-c", "-p0", "-d", directory.path, "-o", "roundtrip.dng", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return "failed to launch" }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("roundtrip.dng").path) { return "accepts" }
        let reason = output.split(separator: "\n").first { $0.contains("Error") }.map(String.init) ?? "exit \(process.terminationStatus)"
        return "REFUSES (\(reason.trimmingCharacters(in: .whitespaces)))"
    }

    /// Adobe DNG Converter reads our file (`-c`), then its linear conversions
    /// of our file and of the input are decoded through Apple and compared.
    static func adobeRoundTrip(output: URL, input: URL, verifier: Verifier) -> (String, Double) {
        guard FileManager.default.fileExists(atPath: adobeConverter.path) else { return ("DNG Converter not installed", -1) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dngspike-adobe-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func run(_ arguments: [String]) -> Int32 {
            let process = Process()
            process.executableURL = adobeConverter
            process.arguments = arguments
            process.standardOutput = nil
            process.standardError = nil
            do { try process.run() } catch { return -1 }
            process.waitUntilExit()
            return process.terminationStatus
        }
        let roundTrip = directory.appendingPathComponent("roundtrip.dng")
        let status = run(["-c", "-p0", "-d", directory.path, "-o", "roundtrip.dng", output.path])
        guard FileManager.default.fileExists(atPath: roundTrip.path) else { return ("DNG Converter refused the file (-c exit \(status))", -1) }
        let ours = directory.appendingPathComponent("ours-linear.dng"), theirs = directory.appendingPathComponent("input-linear.dng")
        _ = run(["-l", "-c", "-p0", "-d", directory.path, "-o", "ours-linear.dng", output.path])
        _ = run(["-l", "-c", "-p0", "-d", directory.path, "-o", "input-linear.dng", input.path])
        guard FileManager.default.fileExists(atPath: ours.path), FileManager.default.fileExists(atPath: theirs.path) else {
            return ("round trip OK (\(mb((try? FileManager.default.attributesOfItem(atPath: roundTrip.path)[.size] as? Int) ?? 0))); linear conversion failed", -1)
        }
        do {
            let (a, b) = try verifier.decodePair(reference: theirs, candidate: ours, referenceScale: 0.25)
            let gap = compare(means(b), to: means(a))
            return ("round trip OK, Adobe re-decodes it within \(fmt(gap.whole * 100, 2))% whole / \(fmt(gap.block * 100, 2))% block of its decode of the input", gap.whole)
        } catch {
            return ("round trip OK; Apple could not decode Adobe's linear conversions: \(error)", -1)
        }
    }
}

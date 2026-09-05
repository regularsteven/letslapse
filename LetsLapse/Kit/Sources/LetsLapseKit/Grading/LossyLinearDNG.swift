import Accelerate
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Makes Adobe DNG Converter's *lossy* DNGs decode correctly through Apple's
/// raw pipeline — in memory, at decode time, without touching the file.
///
/// ## The files
///
/// A lossy DNG (DNG Converter with "Use lossy compression", with or without
/// a resize) is not a Bayer mosaic. Adobe demosaics first and stores a
/// three-sample `LinearRaw` image (PhotometricInterpretation 34892) as JPEG XL
/// tiles (Compression 52546, DNG 1.7) — or, with an older compatibility
/// setting, as 8-bit lossy JPEG tiles (Compression 34892, DNG 1.4). To spend
/// the codec's bits where the eye is, the samples are stored through a cubic
/// encoding: every plane carries a `MapPolynomial` opcode in OpcodeList2 that
/// a reader runs to get linear light back, and a per-plane `BlackLevel` that
/// Adobe picks per frame from the noise floor so the values under it survive
/// the codec. Lightroom reads all of that per the DNG specification and
/// renders the file exactly as it renders the original.
///
/// ## What Apple gets wrong
///
/// `CIRAWFilter` — and with it ImageIO, Preview, QuickLook and this app —
/// applies the polynomials correctly but mishandles `BlackLevel` whenever
/// those opcodes are present. Measured on macOS 15.6 and on the iOS 18.6 and
/// 26.1 simulators (2026-09-05, Sony ILCE-7M4 frames): with the black level
/// patched to zero the colour comes back; with the real values a dusk frame
/// renders as a yellow-green wash (green ×3, blue ÷3) and a night frame loses
/// blue almost entirely. Raising a *uniform* black level pushes green up and
/// red down, which no per-channel subtraction can do, and a polynomial that
/// goes negative wraps to bright rather than clamping. The uncompressed and
/// lossless-CFA outputs of the same converter, and Adobe's *linear lossless*
/// output (uniform black, no opcodes), all render correctly — so the failure
/// is specific to the black-level-plus-opcode combination, and nothing in the
/// converter's settings avoids it at a small file size.
///
/// ## What this does instead
///
/// Everything Apple gets wrong happens before the colour pipeline, and the
/// tiles themselves decode fine: ImageIO reads a bare JPEG XL codestream. So
/// the fix takes the container apart and puts it back together the way
/// Adobe's own linear-lossless output is shaped, which Apple demonstrably
/// handles:
///
/// 1. decode every tile through ImageIO (16-bit RGB for JXL, 8-bit for
///    legacy lossy JPEG);
/// 2. run the DNG stage-2 arithmetic ourselves, per plane — black
///    subtraction, white scaling, the plane's `MapPolynomial` — keeping
///    values below black negative rather than clipping them, so the noise
///    floor Adobe encoded under the pedestal reaches Apple's black handling
///    intact (measured: clipping at black instead changes nothing visible,
///    so this is fidelity to the file, not a tuning);
/// 3. re-quantise to 16-bit linear on a uniform pedestal (`pedestal`, the
///    same 2048 Adobe's linear-lossless files use) with no opcodes;
/// 4. write an uncompressed LinearRaw DNG *in memory* carrying the source's
///    colour tags verbatim (matrices, calibration, as-shot neutral, baseline
///    exposure, profile tables, noise profile, crop), and hand that to
///    `CIRAWFilter(imageData:)`.
///
/// The bytes on disk are never modified — the archive stays exactly the file
/// DNG Converter wrote, and Lightroom keeps reading it as before. Cost on an
/// M4 Max for a 10 MP frame: ~200 ms in a Debug build (the tile decode
/// dominates; the arithmetic is vDSP so an unoptimised build pays nothing
/// extra), ahead of a converter decode that takes ~1 s anyway.
///
/// `LossyLinearDNGTests` measures the result against the ARW the frames came
/// from and against Adobe's own *lossless* linear conversion of the same ARW.
/// The second is the sharper yardstick: a repacked lossy frame renders within
/// 1% of it on whole-frame means and within 3% on every block above the
/// noise floor — the 10 MP resize and the codec are all that separate them.
/// Against the ARW both sit where the lossless CFA DNG sits (a few percent:
/// Apple's own Sony profile versus the DNG's matrices), except in the deepest
/// shadows, where Adobe's demosaic and Apple's disagree with each other by
/// design and the lossless linear conversion shows exactly the same gap.
///
/// This is a container repair, not a colour pipeline: Apple's profile
/// handling, white balance and highlight recovery run on the repacked pixels
/// exactly as they do on any other DNG, so a lossy frame renders the way the
/// lossless conversion of the same frame does. Rendering the file the way
/// *Lightroom* does, embedded Adobe Standard look and all, is the separate
/// job of a genuine camera-space decode (`docs/TODO.md`).
public enum LossyLinearDNG {

    // MARK: - Inspection

    /// What a repack needs to know about a file, read from its directories.
    public struct Plan {
        public let width: Int
        public let height: Int
        public let tileWidth: Int
        public let tileHeight: Int
        public let tileOffsets: [Int]
        public let tileByteCounts: [Int]
        public let bitsPerSample: Int
        public let compression: Int
        /// Per plane, in stored sample units.
        public let blackLevels: [Double]
        public let whiteLevels: [Double]
        /// Per plane, `c0 … cN` of the `MapPolynomial` that linearises it —
        /// `[0, 1]` for a plane that carries none.
        public let polynomials: [[Double]]
        let ifd0: [DNGTagValue]
        let raw: [DNGTagValue]
        let exif: [DNGTagValue]

        public var tilesAcross: Int { (width + tileWidth - 1) / tileWidth }
        public var tilesDown: Int { (height + tileHeight - 1) / tileHeight }
    }

    public enum Inspection {
        case applicable(Plan)
        /// Why the file is left to `CIRAWFilter(imageURL:)` as it is. Most
        /// DNGs land here, and that is the right answer for them.
        case declined(String)
    }

    /// JPEG XL tiles (DNG 1.7) and legacy lossy JPEG tiles (DNG 1.4).
    public static let lossyCompressions: Set<Int> = [52546, 34892]

    /// Reads the directories and decides whether the file is one of Adobe's
    /// lossy LinearRaw DNGs this can repack. Conservative on purpose: any
    /// structure this has not measured (an opcode other than MapPolynomial
    /// in OpcodeList2, a linearization table, strips instead of tiles) is
    /// declined rather than guessed at, because the fallback — Apple's own
    /// decode — is wrong for these files but *right* for everything else.
    public static func inspect(_ data: Data) -> Inspection {
        let directories: DNGDocument.Directories
        do {
            directories = try DNGDocument.parseDirectories(data)
        } catch {
            return .declined("not a readable TIFF: \(error)")
        }
        let candidates = [directories.ifd0] + directories.subIFDs
        guard let raw = candidates.first(where: { entries in
            firstInt(entries, 262) == 34892
                && (firstInt(entries, 254) ?? 0) == 0
                && (firstInt(entries, 277) ?? 1) == 3
        }) else {
            return .declined("no LinearRaw image directory")
        }
        guard let compression = firstInt(raw, 259), lossyCompressions.contains(compression) else {
            return .declined("compression \(firstInt(raw, 259) ?? -1) is not a lossy container")
        }
        guard let width = firstInt(raw, 256), let height = firstInt(raw, 257), width > 0, height > 0 else {
            return .declined("no image size")
        }
        let bits = ints(raw, 258)
        guard let bitsPerSample = bits.first, bits.allSatisfy({ $0 == bitsPerSample }),
              bitsPerSample == 16 || bitsPerSample == 8 else {
            return .declined("unsupported BitsPerSample \(bits)")
        }
        guard (firstInt(raw, 284) ?? 1) == 1 else { return .declined("planar samples") }
        guard let tileWidth = firstInt(raw, 322), let tileHeight = firstInt(raw, 323),
              tileWidth > 0, tileHeight > 0 else {
            return .declined("not tiled")
        }
        let offsets = ints(raw, 324), counts = ints(raw, 325)
        let across = (width + tileWidth - 1) / tileWidth, down = (height + tileHeight - 1) / tileHeight
        guard offsets.count == across * down, counts.count == offsets.count else {
            return .declined("tile table has \(offsets.count) entries for \(across)×\(down) tiles")
        }
        for (offset, count) in zip(offsets, counts) where offset < 0 || count <= 0 || offset + count > data.count {
            return .declined("tile table points outside the file")
        }
        if raw.contains(where: { $0.tag == 50712 }) { return .declined("carries a LinearizationTable") }
        if raw.contains(where: { $0.tag == 50715 || $0.tag == 50716 }) { return .declined("carries BlackLevelDelta") }
        if raw.contains(where: { $0.tag == 51008 }) { return .declined("carries OpcodeList1") }
        let repeatDim = ints(raw, 50713)
        guard repeatDim.isEmpty || repeatDim == [1, 1] else { return .declined("BlackLevelRepeatDim \(repeatDim)") }

        let fullScale = Double((1 << bitsPerSample) - 1)
        let blackLevels = perPlane(doubles(raw, 50714), default: 0)
        let whiteLevels = perPlane(doubles(raw, 50717), default: fullScale)
        guard let blackLevels, let whiteLevels else {
            return .declined("BlackLevel/WhiteLevel are not per-plane values")
        }
        guard zip(blackLevels, whiteLevels).allSatisfy({ $0 < $1 }) else {
            return .declined("black level not below white level")
        }

        var polynomials: [[Double]] = Array(repeating: [0, 1], count: 3)
        if let opcodes = raw.first(where: { $0.tag == 51009 }) {
            do {
                polynomials = try mapPolynomials(in: opcodes.payload, width: width, height: height)
            } catch {
                return .declined("OpcodeList2: \(error)")
            }
        }

        return .applicable(Plan(
            width: width, height: height, tileWidth: tileWidth, tileHeight: tileHeight,
            tileOffsets: offsets, tileByteCounts: counts,
            bitsPerSample: bitsPerSample, compression: compression,
            blackLevels: blackLevels, whiteLevels: whiteLevels, polynomials: polynomials,
            ifd0: directories.ifd0, raw: raw, exif: directories.exif))
    }

    public static func inspect(url: URL) -> Inspection {
        guard url.pathExtension.lowercased() == "dng" else {
            return .declined("not a .dng")
        }
        do {
            return inspect(try Data(contentsOf: url, options: .mappedIfSafe))
        } catch {
            return .declined("unreadable: \(error)")
        }
    }

    /// Whether `url` needs the repack, memoised on path and modification
    /// date. Only the verdict is kept: a plan holds the file's profile tables
    /// (~120 KB), and a project has hundreds of frames.
    public static func isApplicable(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "dng" else { return false }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(modified)"
        verdictLock.lock()
        if let hit = verdicts[key] {
            verdictLock.unlock()
            return hit
        }
        verdictLock.unlock()
        let verdict: Bool
        if case .applicable = inspect(url: url) { verdict = true } else { verdict = false }
        verdictLock.lock()
        if verdicts.count > 8192 { verdicts.removeAll(keepingCapacity: true) }
        verdicts[key] = verdict
        verdictLock.unlock()
        return verdict
    }

    private static let verdictLock = NSLock()
    nonisolated(unsafe) private static var verdicts: [String: Bool] = [:]

    // MARK: - The entry point every raw decode goes through

    /// `CIRAWFilter` for a source file: the repacked bytes when the file is
    /// an Adobe lossy DNG, the file itself otherwise. Nil when the converter
    /// declines the file, exactly as `CIRAWFilter(imageURL:)` would be.
    ///
    /// Every raw decode in the Kit and the app opens its converter here so
    /// that no surface — editor, blend, thumbnail grid, framing measurement,
    /// CLI — can show these files through the broken path by accident.
    public static func rawFilter(for url: URL) -> CIRAWFilter? {
        if isApplicable(url) {
            do {
                let repacked = try repack(url: url)
                if let filter = CIRAWFilter(imageData: repacked, identifierHint: "com.adobe.raw-image") {
                    setFailure(nil)
                    return filter
                }
                setFailure("CIRAWFilter declined the repacked \(url.lastPathComponent)")
            } catch {
                setFailure("\(url.lastPathComponent): \(error)")
            }
        }
        return CIRAWFilter(imageURL: url)
    }

    /// Why the last applicable file fell through to Apple's own decode of the
    /// original bytes, if it did. Same posture as
    /// `LinearFrameDecoder.lastDCPFallbackReason`: degrade to *a* picture
    /// rather than none, but never silently.
    public static var lastRepackFailureReason: String? {
        failureLock.lock()
        defer { failureLock.unlock() }
        return failure
    }

    private static func setFailure(_ reason: String?) {
        failureLock.lock()
        failure = reason
        failureLock.unlock()
    }

    private static let failureLock = NSLock()
    nonisolated(unsafe) private static var failure: String?

    // MARK: - Repack

    /// The uniform black level the repacked samples sit on. Adobe's own
    /// linear-lossless output uses 2048 of 65535, and Apple decodes that
    /// file's noise floor to within 1% of the camera's ARW — so the value is
    /// measured, not chosen. Below it, ~3% of full scale is left for the
    /// negative noise the lossy encoding preserved.
    public static let pedestal: UInt16 = 2048

    public enum RepackError: Error, CustomStringConvertible {
        case notApplicable(String)
        case tileDecodeFailed(index: Int)
        case tileFormat(index: Int, String)

        public var description: String {
            switch self {
            case .notApplicable(let why): return "not an Adobe lossy DNG: \(why)"
            case .tileDecodeFailed(let index): return "tile \(index) did not decode"
            case .tileFormat(let index, let why): return "tile \(index): \(why)"
            }
        }
    }

    public static func repack(url: URL) throws -> Data {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        switch inspect(data) {
        case .declined(let why): throw RepackError.notApplicable(why)
        case .applicable(let plan): return try repack(data, plan: plan)
        }
    }

    /// The whole job: tiles in, uncompressed DNG bytes out.
    public static func repack(_ data: Data, plan: Plan) throws -> Data {
        let constants = (0..<3).map { plane in
            PlaneConstants(
                black: plan.blackLevels[plane], white: plan.whiteLevels[plane],
                coefficients: plan.polynomials[plane])
        }
        let width = plan.width, height = plan.height
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        let tileCount = plan.tileOffsets.count
        let across = plan.tilesAcross
        var failures = [Error?](repeating: nil, count: tileCount)

        samples.withUnsafeMutableBufferPointer { output in
            failures.withUnsafeMutableBufferPointer { errors in
                // Tiles cover disjoint rectangles, so writing them from
                // several threads is race-free by construction; ImageIO's
                // JXL decode is the dominant cost and scales a little.
                DispatchQueue.concurrentPerform(iterations: tileCount) { index in
                    do {
                        try decodeTile(
                            index, of: plan, in: data, constants: constants,
                            into: output, tileColumn: index % across, tileRow: index / across)
                    } catch {
                        errors[index] = error
                    }
                }
            }
        }
        if let error = failures.compactMap({ $0 }).first { throw error }

        let image = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        return try DNGAuthor.makeDNGData(
            image: image, width: width, height: height,
            samplesPerPixel: 3, photometric: 34892,
            reference: reference(for: plan), preview: nil)
    }

    /// Per-plane arithmetic of DNG stage 2, with the polynomial folded in:
    /// `linear = P((v / white − β) / (1 − β))`, β = black / white — and no
    /// clipping at zero (see the type comment).
    public struct PlaneConstants: Sendable {
        public let invWhite: Double
        public let beta: Double
        public let scale: Double
        public let coefficients: [Double]
        /// The same arithmetic in the form `vDSP` wants: `x = v·a + b`, then
        /// the polynomial with its coefficients highest degree first.
        let a: Float
        let b: Float
        let descending: [Float]

        public init(black: Double, white: Double, coefficients: [Double]) {
            invWhite = 1 / white
            beta = black / white
            scale = 1 / (1 - beta)
            self.coefficients = coefficients.isEmpty ? [0, 1] : coefficients
            a = Float(invWhite * scale)
            b = Float(-beta * scale)
            descending = self.coefficients.reversed().map(Float.init)
        }

        /// Reference form, one sample at a time — what the tests pin the
        /// vectorised path against.
        @inline(__always)
        public func linearise(_ sample: Double) -> Double {
            let x = (sample * invWhite - beta) * scale
            // Horner, highest degree first.
            var y = 0.0
            for c in coefficients.reversed() { y = y * x + c }
            return y
        }

        /// The 16-bit sample the repacked file stores for a linear value.
        @inline(__always)
        public static func encode(_ linear: Double) -> UInt16 {
            let ped = Double(pedestal)
            let v = (ped + linear * (65535 - ped)).rounded()
            return UInt16(max(0, min(65535, v)))
        }
    }

    private static func decodeTile(
        _ index: Int, of plan: Plan, in data: Data, constants: [PlaneConstants],
        into output: UnsafeMutableBufferPointer<UInt16>, tileColumn: Int, tileRow: Int
    ) throws {
        let range = plan.tileOffsets[index]..<(plan.tileOffsets[index] + plan.tileByteCounts[index])
        let tile = data.subdata(in: range)
        guard let source = CGImageSourceCreateWithData(tile as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(
                  source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw RepackError.tileDecodeFailed(index: index)
        }
        let pixels = try samples(of: image, bitsPerSample: plan.bitsPerSample, tileIndex: index)

        let x0 = tileColumn * plan.tileWidth, y0 = tileRow * plan.tileHeight
        // Edge tiles are padded to the full tile size in the file; only the
        // part inside the image is placed.
        let columns = min(image.width, plan.width - x0), rows = min(image.height, plan.height - y0)
        guard columns > 0, rows > 0 else { return }
        let spp = pixels.samplesPerPixel
        let rowStride = plan.width * 3

        // Row by row through vDSP, so the arithmetic costs the same in a
        // Debug build as in Release — a per-sample Swift loop over thirty
        // million samples took twenty seconds unoptimised.
        var interleaved = [Float](repeating: 0, count: columns * spp)   // the row as decoded, R G B (X)
        var staged = [Float](repeating: 0, count: columns * 3)          // the row on its way out, R G B
        var low: Float = 0, high: Float = 65535
        var gain = Float(65535 - Int(pedestal)), lift = Float(pedestal)
        pixels.bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            interleaved.withUnsafeMutableBufferPointer { inter in
                staged.withUnsafeMutableBufferPointer { out in
                    let n = vDSP_Length(columns)
                    for y in 0..<rows {
                        let sourceRow = raw.baseAddress!.advanced(by: y * pixels.bytesPerRow)
                        if plan.bitsPerSample == 16 {
                            vDSP_vfltu16(sourceRow.assumingMemoryBound(to: UInt16.self), 1,
                                         inter.baseAddress!, 1, vDSP_Length(columns * spp))
                        } else {
                            vDSP_vfltu8(sourceRow.assumingMemoryBound(to: UInt8.self), 1,
                                        inter.baseAddress!, 1, vDSP_Length(columns * spp))
                        }
                        for plane in 0..<3 {
                            var a = constants[plane].a, b = constants[plane].b
                            let source = inter.baseAddress! + plane
                            let target = out.baseAddress! + plane
                            // x = v·a + b  (black subtracted, white scaled)
                            vDSP_vsmsa(source, vDSP_Stride(spp), &a, &b, target, 3, n)
                            // linear = P(x), back into the interleaved slot
                            let coefficients = constants[plane].descending
                            coefficients.withUnsafeBufferPointer { c in
                                vDSP_vpoly(c.baseAddress!, 1, target, 3, source, vDSP_Stride(spp),
                                           n, vDSP_Length(coefficients.count - 1))
                            }
                            // stored = pedestal + linear·(65535 − pedestal)
                            vDSP_vsmsa(source, vDSP_Stride(spp), &gain, &lift, target, 3, n)
                        }
                        let destination = output.baseAddress!.advanced(by: (y0 + y) * rowStride + x0 * 3)
                        vDSP_vclip(out.baseAddress!, 1, &low, &high, out.baseAddress!, 1, vDSP_Length(columns * 3))
                        vDSP_vfixru16(out.baseAddress!, 1, destination, 1, vDSP_Length(columns * 3))
                    }
                }
            }
        }
    }

    private struct TileSamples {
        let bytes: Data
        let bytesPerRow: Int
        let samplesPerPixel: Int
    }

    /// The decoded tile's samples in R, G, B order at the file's bit depth.
    ///
    /// ImageIO hands a JXL codestream back as 16-bit RGBX with the samples
    /// untouched, and the data provider is read directly whenever the layout
    /// says so. Drawing the image into a `CGContext` is *not* an alternative:
    /// the tile is tagged with a Rec. 2020 profile the codestream declares,
    /// and a draw colour-manages the samples into a different picture. The
    /// fallback draw below therefore targets the image's own colour space,
    /// where Core Graphics does no conversion.
    private static func samples(of image: CGImage, bitsPerSample: Int, tileIndex: Int) throws -> TileSamples {
        let bpc = image.bitsPerComponent, bpp = image.bitsPerPixel
        let spp = bpc > 0 ? bpp / bpc : 0
        let alpha = image.alphaInfo
        let alphaFirst = alpha == .premultipliedFirst || alpha == .first || alpha == .noneSkipFirst
        let premultiplied = alpha == .premultipliedFirst || alpha == .premultipliedLast
        let byteOrder = image.bitmapInfo.intersection(.byteOrderMask)
        let hostOrder16 = byteOrder == .byteOrder16Little || byteOrder == CGBitmapInfo(rawValue: 0)
        let direct = bpc == bitsPerSample && spp >= 3 && !alphaFirst && !premultiplied
            && (bitsPerSample == 8 || hostOrder16)
            && !image.bitmapInfo.contains(.floatComponents)
        if direct, let provider = image.dataProvider, let bytes = provider.data as Data?,
           bytes.count >= image.bytesPerRow * image.height {
            return TileSamples(bytes: bytes, bytesPerRow: image.bytesPerRow, samplesPerPixel: spp)
        }
        guard bpc == bitsPerSample else {
            throw RepackError.tileFormat(index: tileIndex, "decoded at \(bpc) bits, file says \(bitsPerSample)")
        }
        let width = image.width, height = image.height
        let bytesPerRow = width * 4 * (bitsPerSample / 8)
        var buffer = Data(count: bytesPerRow * height)
        let space = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let info: UInt32 = bitsPerSample == 16
            ? CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
        let drawn = buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: bitsPerSample, bytesPerRow: bytesPerRow,
                space: space, bitmapInfo: info) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            throw RepackError.tileFormat(index: tileIndex, "no context for \(bpc)-bit \(spp)-sample tile")
        }
        return TileSamples(bytes: buffer, bytesPerRow: bytesPerRow, samplesPerPixel: 4)
    }

    // MARK: - The repacked file's tags

    /// IFD0 tags that describe the JPEG preview or the lossy container and
    /// have no business on the repacked image. Structural and pointer tags
    /// are dropped by `DNGAuthor.makeDNGData` itself.
    private static let droppedIFD0Tags: Set<UInt16> = [
        529, 530, 531, 532,       // YCbCr coefficients/subsampling/positioning, ReferenceBlackWhite
        50706, 50707,             // DNGVersion / DNGBackwardVersion — re-declared below
        50972, 51111,             // RawImageDigest / NewRawImageDigest — of bytes we no longer carry
    ]
    private static let droppedRawTags: Set<UInt16> = [
        50714, 50717,             // BlackLevel / WhiteLevel — replaced
        51008, 51009,             // OpcodeList1 / OpcodeList2 — consumed
        52553, 52554, 52555,      // JXLDistance / JXLEffort / JXLDecodeSpeed
    ]

    static func reference(for plan: Plan) -> DNGReference {
        var ifd0 = plan.ifd0.filter { !droppedIFD0Tags.contains($0.tag) }
        ifd0.append(DNGTagValue(tag: 50706, type: 1, count: 4, payload: Data([1, 4, 0, 0])))
        ifd0.append(DNGTagValue(tag: 50707, type: 1, count: 4, payload: Data([1, 1, 0, 0])))
        var raw = plan.raw.filter { !droppedRawTags.contains($0.tag) }
        var black = Data(), white = Data()
        for _ in 0..<3 {
            black.appendU16(pedestal)
            white.appendU16(65535)
        }
        raw.append(DNGTagValue(tag: 50714, type: 3, count: 3, payload: black))
        raw.append(DNGTagValue(tag: 50717, type: 3, count: 3, payload: white))
        return DNGReference(ifd0: ifd0, raw: raw, exif: plan.exif)
    }

    // MARK: - OpcodeList2

    enum OpcodeError: Error, CustomStringConvertible {
        case truncated
        case unsupportedOpcode(UInt32)
        case partialArea(plane: Int)
        case duplicatePlane(Int)
        case planeOutOfRange(Int)

        var description: String {
            switch self {
            case .truncated: return "truncated opcode list"
            case .unsupportedOpcode(let id): return "opcode \(id) is not MapPolynomial"
            case .partialArea(let plane): return "plane \(plane) polynomial covers part of the image"
            case .duplicatePlane(let plane): return "plane \(plane) has two polynomials"
            case .planeOutOfRange(let plane): return "polynomial for plane \(plane)"
            }
        }
    }

    /// The per-plane `MapPolynomial` coefficients of an OpcodeList2 blob.
    /// Opcode lists are big-endian regardless of the file's byte order.
    ///
    /// Only lists made of MapPolynomials are accepted: any other opcode
    /// ahead of a plane's polynomial would see values this repack no longer
    /// produces, and after it would need re-emitting on the output. Adobe's
    /// lossy files carry exactly three, one per plane, full-frame.
    static func mapPolynomials(in blob: Data, width: Int, height: Int) throws -> [[Double]] {
        func u32(_ at: Int) throws -> UInt32 {
            guard at + 4 <= blob.count else { throw OpcodeError.truncated }
            return blob.readU32(at: at).byteSwapped
        }
        func f64(_ at: Int) throws -> Double {
            guard at + 8 <= blob.count else { throw OpcodeError.truncated }
            let high = UInt64(try u32(at)), low = UInt64(try u32(at + 4))
            return Double(bitPattern: high << 32 | low)
        }
        var polynomials: [[Double]?] = [nil, nil, nil]
        let count = Int(try u32(0))
        var cursor = 4
        for _ in 0..<count {
            let id = try u32(cursor)
            let size = Int(try u32(cursor + 12))
            let body = cursor + 16
            guard id == 8 else { throw OpcodeError.unsupportedOpcode(id) }
            let top = Int(try u32(body)), left = Int(try u32(body + 4))
            let bottom = Int(try u32(body + 8)), right = Int(try u32(body + 12))
            let plane = Int(try u32(body + 16)), planes = Int(try u32(body + 20))
            let rowPitch = Int(try u32(body + 24)), colPitch = Int(try u32(body + 28))
            let degree = Int(try u32(body + 32))
            guard degree >= 0, degree <= 8 else { throw OpcodeError.truncated }
            var coefficients: [Double] = []
            for k in 0...degree { coefficients.append(try f64(body + 36 + 8 * k)) }
            guard plane >= 0, planes >= 1, plane + planes <= 3 else {
                throw OpcodeError.planeOutOfRange(plane)
            }
            guard top == 0, left == 0, bottom >= height, right >= width, rowPitch == 1, colPitch == 1 else {
                throw OpcodeError.partialArea(plane: plane)
            }
            for p in plane..<(plane + planes) {
                guard polynomials[p] == nil else { throw OpcodeError.duplicatePlane(p) }
                polynomials[p] = coefficients
            }
            cursor = body + size
        }
        return polynomials.map { $0 ?? [0, 1] }
    }

    // MARK: - Tag value helpers (payloads are little-endian, per `DNGDocument`)

    private static func ints(_ entries: [DNGTagValue], _ tag: UInt16) -> [Int] {
        guard let entry = entries.first(where: { $0.tag == tag }) else { return [] }
        return DNGDocument.longValues(of: entry).map(Int.init)
    }

    private static func firstInt(_ entries: [DNGTagValue], _ tag: UInt16) -> Int? {
        ints(entries, tag).first
    }

    static func doubles(_ entries: [DNGTagValue], _ tag: UInt16) -> [Double] {
        guard let entry = entries.first(where: { $0.tag == tag }) else { return [] }
        return doubles(of: entry)
    }

    static func doubles(of entry: DNGTagValue) -> [Double] {
        let payload = entry.payload
        var values: [Double] = []
        switch entry.type {
        case 3:
            for i in stride(from: 0, to: payload.count - 1, by: 2) { values.append(Double(payload.readU16(at: i))) }
        case 4:
            for i in stride(from: 0, to: payload.count - 3, by: 4) { values.append(Double(payload.readU32(at: i))) }
        case 8:
            for i in stride(from: 0, to: payload.count - 1, by: 2) {
                values.append(Double(Int16(bitPattern: payload.readU16(at: i))))
            }
        case 9:
            for i in stride(from: 0, to: payload.count - 3, by: 4) {
                values.append(Double(Int32(bitPattern: payload.readU32(at: i))))
            }
        case 5:
            for i in stride(from: 0, to: payload.count - 7, by: 8) {
                let d = Double(payload.readU32(at: i + 4))
                values.append(d == 0 ? 0 : Double(payload.readU32(at: i)) / d)
            }
        case 10:
            for i in stride(from: 0, to: payload.count - 7, by: 8) {
                let d = Double(Int32(bitPattern: payload.readU32(at: i + 4)))
                values.append(d == 0 ? 0 : Double(Int32(bitPattern: payload.readU32(at: i))) / d)
            }
        case 11:
            for i in stride(from: 0, to: payload.count - 3, by: 4) {
                values.append(Double(Float(bitPattern: payload.readU32(at: i))))
            }
        case 12:
            for i in stride(from: 0, to: payload.count - 7, by: 8) {
                let low = UInt64(payload.readU32(at: i)), high = UInt64(payload.readU32(at: i + 4))
                values.append(Double(bitPattern: high << 32 | low))
            }
        default:
            break
        }
        return values
    }

    /// One value per plane from a tag that may carry one for all or one each.
    private static func perPlane(_ values: [Double], default fallback: Double) -> [Double]? {
        switch values.count {
        case 0: return [fallback, fallback, fallback]
        case 1: return [values[0], values[0], values[0]]
        case 3: return values
        default: return nil
        }
    }
}

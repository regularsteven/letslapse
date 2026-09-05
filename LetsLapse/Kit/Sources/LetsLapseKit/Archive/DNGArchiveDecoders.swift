import Accelerate
import CoreImage
import CLibRaw
import Foundation

extension DNGArchive {

    // MARK: - Apple's converter

    /// Apple's raw converter as a decoder: demosaiced, white-balanced,
    /// camera-profiled linear pixels — rendered into extended linear sRGB so
    /// the output DNG can declare sRGB primaries honestly. Not camera-native,
    /// and measured 6–33% dark against Apple's own render of the source
    /// (report §4); kept for inputs the other decoders cannot open.
    public enum AppleDecoder {
        static let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        static let context = CIContext(options: [
            .workingColorSpace: linearSRGB,
            .workingFormat: CIFormat.RGBAf,
            .cacheIntermediates: false,
        ])

        public struct Result {
            public let frame: RGBFrame
            public let nativeSize: CGSize
            public let neutralTemperatureK: Double
            public let neutralTint: Double
            public let renderMilliseconds: Double
            public let setupMilliseconds: Double
            public let scale: Float
        }

        /// Pays the context's one-time cost.
        public static func warmUp() { _ = context }

        /// `targetPixels` resamples inside the converter; the frame reports
        /// `headroomStops` of headroom (samples pre-divided, BaselineExposure
        /// raised by the writer).
        public static func decode(url: URL, targetPixels: Int?, headroomStops: Int = 2) throws -> Result {
            let clock = ProcessInfo.processInfo.systemUptime
            guard let raw = LossyLinearDNG.rawFilter(for: url) else {
                throw ConversionError.decode("CIRAWFilter declined \(url.lastPathComponent)")
            }
            raw.boostAmount = 0
            raw.extendedDynamicRangeAmount = 2
            var scale: Float = 1
            let nativePixels = Double(raw.nativeSize.width * raw.nativeSize.height)
            if let targetPixels, Double(targetPixels) < nativePixels {
                scale = Float((Double(targetPixels) / nativePixels).squareRoot())
            }
            raw.scaleFactor = scale
            let neutralK = Double(raw.neutralTemperature)
            let tint = Double(raw.neutralTint)
            let nativeSize = raw.nativeSize
            guard let image = raw.outputImage else {
                throw ConversionError.decode("CIRAWFilter produced no image for \(url.lastPathComponent)")
            }
            let setup = (ProcessInfo.processInfo.systemUptime - clock) * 1000
            let renderStart = ProcessInfo.processInfo.systemUptime
            let extent = image.extent.integral
            let width = Int(extent.width), height = Int(extent.height)
            var rgba = [Float](repeating: 0, count: width * height * 4)
            rgba.withUnsafeMutableBytes { buffer in
                context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                               bounds: extent, format: .RGBAf, colorSpace: linearSRGB)
            }
            var rgb = [Float](repeating: 0, count: width * height * 3)
            rgba.withUnsafeMutableBufferPointer { source in
                rgb.withUnsafeMutableBufferPointer { destination in
                    var src = vImage_Buffer(data: source.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 16)
                    var dst = vImage_Buffer(data: destination.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 12)
                    vImageConvert_RGBAFFFFtoRGBFFF(&src, &dst, vImage_Flags(kvImageNoFlags))
                    var divisor = Float(1 / pow(2, Double(headroomStops)))
                    vDSP_vsmul(destination.baseAddress!, 1, &divisor, destination.baseAddress!, 1, vDSP_Length(width * height * 3))
                }
            }
            let render = (ProcessInfo.processInfo.systemUptime - renderStart) * 1000
            var metadata = FrameMetadata()
            metadata.colorTags = DNGArchive.sRGBColorTags()
            metadata.isCameraNative = false
            metadata.headroomStops = headroomStops
            metadata.decodePath = "apple-ciraw"
            metadata.originalFileName = url.lastPathComponent
            metadata.exif = InputMetadata.exifTags(for: url)
            metadata.cameraName = InputMetadata.cameraName(for: url)
            let frame = RGBFrame(width: width, height: height, samples: rgb, metadata: metadata)
            return Result(frame: frame, nativeSize: nativeSize, neutralTemperatureK: neutralK, neutralTint: tint,
                          renderMilliseconds: render, setupMilliseconds: setup, scale: scale)
        }
    }

    // MARK: - The app's own Bayer DNGs

    /// The Kit's own parse of a lossless-JPEG Bayer DNG plus
    /// `LosslessJPEGDecoder` — no colour work, the mosaic is camera-native
    /// already. ~40 ms for a 12 MP frame on the M4 Max.
    public enum NativeDecoder {
        public struct Result {
            public let frame: MosaicFrame
            public let parseMilliseconds: Double
            public let tileMilliseconds: Double
            public let tileCount: Int
        }

        public static func canDecode(_ url: URL) -> Bool {
            guard url.pathExtension.lowercased() == "dng",
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let directories = try? DNGDocument.parseDirectories(data) else { return false }
            let candidates = [directories.ifd0] + directories.subIFDs
            guard let raw = candidates.first(where: { $0.int(262) == 32803 }) else { return false }
            guard raw.int(258) == 16 else { return false }
            switch raw.int(259) {
            case 7: return raw.tag(322) != nil
            case 1: return raw.tag(322) != nil || raw.tag(273) != nil
            default: return false
            }
        }

        public static func decode(url: URL) throws -> Result {
            let clock = ProcessInfo.processInfo.systemUptime
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let directories = try DNGDocument.parseDirectories(data)
            let candidates = [directories.ifd0] + directories.subIFDs
            guard let raw = candidates.first(where: { $0.int(262) == 32803 }) else {
                throw ConversionError.decode("\(url.lastPathComponent) has no CFA image directory")
            }
            let compression = raw.int(259) ?? 1
            guard compression == 7 || compression == 1 else {
                throw ConversionError.unsupported("compression \(compression); the native path reads lossless JPEG (7) and uncompressed (1)")
            }
            guard raw.int(258) == 16 else { throw ConversionError.unsupported("\(raw.int(258) ?? 0)-bit CFA") }
            guard let width = raw.int(256), let height = raw.int(257) else { throw ConversionError.decode("no image size") }
            // Tiles, or strips read as full-width tiles.
            let tiled = raw.tag(322) != nil
            let tileWidth = tiled ? (raw.int(322) ?? width) : width
            let tileHeight = tiled ? (raw.int(323) ?? height) : (raw.int(278) ?? height)
            let offsets = raw.tag(tiled ? 324 : 273)?.ints ?? [], counts = raw.tag(tiled ? 325 : 279)?.ints ?? []
            let across = (width + tileWidth - 1) / tileWidth, down = (height + tileHeight - 1) / tileHeight
            guard offsets.count == across * down, counts.count == offsets.count else {
                throw ConversionError.decode("\(tiled ? "tile" : "strip") table has \(offsets.count) entries for \(across)×\(down)")
            }
            let bigEndian = data.count >= 2 && data[data.startIndex] == 0x4D
            let dims = raw.tag(33421)?.ints ?? [2, 2]
            let pattern = raw.tag(33422)?.ints.map(UInt8.init) ?? []
            guard dims == [2, 2], pattern.count == 4 else { throw ConversionError.unsupported("CFA pattern \(pattern) with dims \(dims)") }
            let blacks = raw.doubles(50714)
            let black = blacks.first ?? 0
            guard blacks.allSatisfy({ $0 == black }) else { throw ConversionError.unsupported("per-channel black levels \(blacks)") }
            guard (raw.tag(50713)?.ints ?? [1, 1]) == [1, 1] else { throw ConversionError.unsupported("BlackLevelRepeatDim \(raw.tag(50713)!.ints)") }
            guard raw.tag(50712) == nil else { throw ConversionError.unsupported("LinearizationTable on the input") }
            let white = raw.doubles(50717).first ?? 65535
            let parse = (ProcessInfo.processInfo.systemUptime - clock) * 1000

            let tileStart = ProcessInfo.processInfo.systemUptime
            var samples = [UInt16](repeating: 0, count: width * height)
            var failures = [String?](repeating: nil, count: offsets.count)
            samples.withUnsafeMutableBufferPointer { output in
                failures.withUnsafeMutableBufferPointer { errors in
                    DispatchQueue.concurrentPerform(iterations: offsets.count) { index in
                        let range = offsets[index]..<(offsets[index] + counts[index])
                        guard range.upperBound <= data.count else { errors[index] = "tile \(index) past end"; return }
                        if compression == 1 {
                            // Uncompressed: 16-bit samples in the file's byte order.
                            let x0 = (index % across) * tileWidth, y0 = (index / across) * tileHeight
                            let columns = min(tileWidth, width - x0), rows = min(tileHeight, height - y0)
                            guard counts[index] >= rows * tileWidth * 2 else { errors[index] = "strip/tile \(index) is short"; return }
                            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                                let base = bytes.baseAddress!.advanced(by: offsets[index] - data.startIndex)
                                for y in 0..<rows {
                                    let destinationRow = output.baseAddress! + (y0 + y) * width + x0
                                    let sourceRow = base.advanced(by: y * tileWidth * 2)
                                    for x in 0..<columns {
                                        let value = sourceRow.loadUnaligned(fromByteOffset: x * 2, as: UInt16.self)
                                        destinationRow[x] = bigEndian ? value.byteSwapped : value
                                    }
                                }
                            }
                            return
                        }
                        do {
                            let tile = try LosslessJPEGDecoder.decode(data.subdata(in: range))
                            // A CFA tile is commonly coded as an N-component
                            // JPEG of 1/N the width (Apple's and Canon's DNGs
                            // use two: one CFA column pair per JPEG pixel).
                            // Interleaved, the samples are the mosaic row in
                            // order, so the layout is the same either way.
                            let tileColumns = tile.width * tile.components
                            guard tileColumns == tileWidth else {
                                errors[index] = "tile \(index) is \(tile.width)×\(tile.components) components for a \(tileWidth)-wide tile"
                                return
                            }
                            let x0 = (index % across) * tileWidth, y0 = (index / across) * tileHeight
                            let columns = min(tileColumns, width - x0), rows = min(tile.height, height - y0)
                            tile.samples.withUnsafeBufferPointer { source in
                                for y in 0..<rows {
                                    let sourceRow = source.baseAddress! + y * tileColumns
                                    let destinationRow = output.baseAddress! + (y0 + y) * width + x0
                                    destinationRow.update(from: sourceRow, count: columns)
                                }
                            }
                        } catch {
                            errors[index] = "tile \(index): \(error)"
                        }
                    }
                }
            }
            if let failure = failures.compactMap({ $0 }).first { throw ConversionError.decode(failure) }
            let tiles = (ProcessInfo.processInfo.systemUptime - tileStart) * 1000

            // ActiveArea (top, left, bottom, right): the sensor's masked border
            // is not picture. Cropped here on even offsets so the CFA phase
            // holds, and never carried — an ActiveArea describes the old image.
            var outWidth = width, outHeight = height
            var note: String?
            let active = raw.tag(50829)?.ints ?? []
            if active.count == 4 {
                let top = active[0] & ~1, left = active[1] & ~1
                let bottom = min(height, active[2]), right = min(width, active[3])
                if top >= 0, left >= 0, right - left >= 2, bottom - top >= 2, (top, left, bottom, right) != (0, 0, height, width) {
                    outWidth = right - left
                    outHeight = bottom - top
                    var cropped = [UInt16](repeating: 0, count: outWidth * outHeight)
                    samples.withUnsafeBufferPointer { source in
                        cropped.withUnsafeMutableBufferPointer { destination in
                            for y in 0..<outHeight {
                                (destination.baseAddress! + y * outWidth).update(from: source.baseAddress! + (top + y) * width + left, count: outWidth)
                            }
                        }
                    }
                    samples = cropped
                    note = "ActiveArea \(active) applied: \(width)×\(height) → \(outWidth)×\(outHeight)"
                }
            }

            var metadata = FrameMetadata()
            metadata.colorTags = DNGArchive.carriedIFD0Tags(from: directories.ifd0)
            metadata.rawTags = DNGArchive.carriedRawTags(from: raw)
            metadata.exif = directories.exif.isEmpty ? InputMetadata.exifTags(for: url) : directories.exif
            metadata.gps = directories.gps
            metadata.isCameraNative = true
            metadata.headroomStops = 0
            metadata.decodePath = compression == 7 ? "native-lj92" : "native-uncompressed"
            metadata.originalFileName = url.lastPathComponent
            metadata.cameraName = directories.ifd0.tag(50708)?.text ?? InputMetadata.cameraName(for: url)
            if let note { metadata.notes.append(note) }
            for tag: UInt16 in [51008, 51009, 51022] {
                if let list = raw.tag(tag) { metadata.opcodeLists[tag] = list.payload }
            }
            let frame = MosaicFrame(width: outWidth, height: outHeight, samples: samples, cfaPattern: pattern,
                                    black: black, white: white, metadata: metadata)
            return Result(frame: frame, parseMilliseconds: parse, tileMilliseconds: tiles, tileCount: offsets.count)
        }
    }

    // MARK: - LibRaw

    /// LibRaw for third-party camera raws: the camera-native mosaic with the
    /// camera's black and white levels, Adobe's colour matrix for the body,
    /// the as-shot multipliers and the sensor's CFA layout.
    public enum LibRawDecoder {
        public struct Result {
            public let frame: MosaicFrame
            public let openMilliseconds: Double
            public let unpackMilliseconds: Double
            public let copyMilliseconds: Double
            public let cameraMake: String
            public let cameraModel: String
        }

        public struct DemosaicResult {
            public let frame: RGBFrame
            public let openUnpackMilliseconds: Double
            public let processMilliseconds: Double
            public let copyMilliseconds: Double
        }

        public static var version: String { String(cString: libraw_version()) }

        /// Whether LibRaw recognises the file (by opening it, header only).
        public static func canDecode(_ url: URL) -> Bool {
            guard ImportedStills.isRaw(url), let lr = libraw_init(0) else { return false }
            defer { libraw_close(lr) }
            return libraw_open_file(lr, url.path) == 0 && lr.pointee.idata.colors >= 3
        }

        private static func check(_ code: Int32, _ what: String) throws {
            guard code == 0 else {
                throw ConversionError.decode("LibRaw \(what): \(String(cString: libraw_strerror(code)))")
            }
        }

        /// The DNG colour tags LibRaw's metadata supports: ColorMatrix1 from
        /// Adobe's coefficient table (XYZ D65 → camera), AsShotNeutral from the
        /// camera's multipliers, identity, and the illuminant.
        private static func colorTags(_ lr: UnsafeMutablePointer<libraw_data_t>, make: String, model: String) -> [DNGTagValue] {
            var matrix: [Double] = []
            withUnsafeBytes(of: &lr.pointee.color.cam_xyz) { raw in
                let floats = raw.bindMemory(to: Float.self)
                for i in 0..<9 { matrix.append(Double(floats[i])) }
            }
            var multipliers: [Double] = []
            withUnsafeBytes(of: &lr.pointee.color.cam_mul) { raw in
                let floats = raw.bindMemory(to: Float.self)
                for i in 0..<4 { multipliers.append(Double(floats[i])) }
            }
            var tags: [DNGTagValue] = []
            tags.append(DNGArchive.asciiTag(271, make))
            tags.append(DNGArchive.asciiTag(272, model))
            tags.append(DNGArchive.asciiTag(50708, "\(make) \(model)"))
            if matrix.contains(where: { $0 != 0 }) {
                tags.append(DNGArchive.srationalTag(50721, matrix))
                tags.append(DNGArchive.shortTag(50778, [21])) // D65: LibRaw's cam_xyz is Adobe's D65 matrix
            }
            if multipliers[1] > 0, multipliers[0] > 0, multipliers[2] > 0 {
                // Camera multipliers scale channels to neutral; AsShotNeutral is the
                // neutral's camera-space value, i.e. the reciprocal, green = 1.
                let neutral = [multipliers[1] / multipliers[0], 1.0, multipliers[1] / multipliers[2]]
                tags.append(DNGArchive.rationalTag(50728, neutral))
            }
            return tags
        }

        private static func cfaPattern(_ lr: UnsafeMutablePointer<libraw_data_t>, rowOffset: Int, columnOffset: Int) throws -> [UInt8] {
            var pattern: [UInt8] = []
            var cdesc = lr.pointee.idata.cdesc
            let description = withUnsafeBytes(of: &cdesc) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            for row in 0..<2 {
                for column in 0..<2 {
                    let index = Int(libraw_COLOR(lr, Int32(row + rowOffset), Int32(column + columnOffset)))
                    guard index >= 0, index < description.count else { throw ConversionError.unsupported("CFA colour index \(index)") }
                    let letter = description[description.index(description.startIndex, offsetBy: index)]
                    switch letter {
                    case "R": pattern.append(0)
                    case "G": pattern.append(1)
                    case "B": pattern.append(2)
                    default: throw ConversionError.unsupported("CFA colour \(letter) (\(description)) — Bayer RGB only")
                    }
                }
            }
            return pattern
        }

        private static func cString(_ tuple: inout (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)) -> String {
            withUnsafeBytes(of: &tuple) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        }

        private static func open(_ url: URL) throws -> (UnsafeMutablePointer<libraw_data_t>, Double) {
            let clock = ProcessInfo.processInfo.systemUptime
            guard let lr = libraw_init(0) else { throw ConversionError.decode("libraw_init failed") }
            try check(libraw_open_file(lr, url.path), "open")
            return (lr, (ProcessInfo.processInfo.systemUptime - clock) * 1000)
        }

        public static func decode(url: URL) throws -> Result {
            let (lr, openMs) = try open(url)
            defer { libraw_close(lr) }
            let unpackStart = ProcessInfo.processInfo.systemUptime
            try check(libraw_unpack(lr), "unpack")
            let unpackMs = (ProcessInfo.processInfo.systemUptime - unpackStart) * 1000

            let copyStart = ProcessInfo.processInfo.systemUptime
            guard let rawImage = lr.pointee.rawdata.raw_image else {
                throw ConversionError.unsupported("\(url.lastPathComponent) is not a 16-bit Bayer raw (no raw_image plane)")
            }
            let sizes = lr.pointee.sizes
            let pitch = Int(sizes.raw_pitch) / 2
            var top = Int(sizes.top_margin), left = Int(sizes.left_margin)
            var width = Int(sizes.width), height = Int(sizes.height)
            // The camera's own crop when LibRaw reports one (Sony writes it);
            // kept on even offsets so the CFA phase is unchanged.
            var crops = lr.pointee.sizes.raw_inset_crops
            let crop = withUnsafeBytes(of: &crops) { raw -> (Int, Int, Int, Int) in
                let shorts = raw.bindMemory(to: UInt16.self)
                return (Int(shorts[0]), Int(shorts[1]), Int(shorts[2]), Int(shorts[3])) // cleft, ctop, cwidth, cheight
            }
            var note = "LibRaw visible area \(width)×\(height) at (\(left),\(top))"
            if crop.2 > 0, crop.3 > 0, crop.2 <= width, crop.3 <= height, crop.0 % 2 == 0, crop.1 % 2 == 0 {
                left += crop.0
                top += crop.1
                width = crop.2
                height = crop.3
                note += "; camera crop \(width)×\(height) at +(\(crop.0),\(crop.1))"
            }
            var samples = [UInt16](repeating: 0, count: width * height)
            samples.withUnsafeMutableBufferPointer { destination in
                for y in 0..<height {
                    let source = rawImage + (top + y) * pitch + left
                    (destination.baseAddress! + y * width).update(from: source, count: width)
                }
            }
            let black = Double(lr.pointee.color.black)
            let cblack: [UInt32] = (0..<6).map { letslapse_libraw_cblack(lr, Int32($0)) }
            let perChannel = Array(cblack[0..<4])
            var blackNote = "black \(black)"
            if perChannel.contains(where: { $0 != 0 }) || cblack[4] != 0 || cblack[5] != 0 {
                blackNote += " + per-channel \(perChannel) pattern \(cblack[4])×\(cblack[5]) (uniform value used; delta ignored)"
            }
            let white = Double(lr.pointee.color.maximum)
            let pattern = try cfaPattern(lr, rowOffset: top - Int(sizes.top_margin), columnOffset: left - Int(sizes.left_margin))
            var makeTuple = lr.pointee.idata.make, modelTuple = lr.pointee.idata.model
            let make = cString(&makeTuple), model = cString(&modelTuple)
            let copyMs = (ProcessInfo.processInfo.systemUptime - copyStart) * 1000

            var metadata = FrameMetadata()
            metadata.colorTags = colorTags(lr, make: make, model: model)
            metadata.exif = InputMetadata.exifTags(for: url)
            metadata.isCameraNative = true
            metadata.decodePath = "libraw-\(version)"
            metadata.originalFileName = url.lastPathComponent
            metadata.cameraName = "\(make) \(model)"
            metadata.notes = [note, blackNote, "maximum \(Int(white))"]
            let frame = MosaicFrame(width: width, height: height, samples: samples, cfaPattern: pattern,
                                    black: black, white: white, metadata: metadata)
            return Result(frame: frame, openMilliseconds: openMs, unpackMilliseconds: unpackMs, copyMilliseconds: copyMs,
                          cameraMake: make, cameraModel: model)
        }

        /// LibRaw's own demosaic (`quality` 0 linear, 1 VNG, 2 PPG, 3 AHD, 11 DHT,
        /// 12 AAHD), camera-native colour, no white balance, linear 16-bit.
        public static func demosaic(url: URL, quality: Int) throws -> DemosaicResult {
            let (lr, openMs) = try open(url)
            defer { libraw_close(lr) }
            try check(libraw_unpack(lr), "unpack")
            let unpackDone = ProcessInfo.processInfo.systemUptime
            lr.pointee.params.output_bps = 16
            lr.pointee.params.gamm.0 = 1
            lr.pointee.params.gamm.1 = 1
            lr.pointee.params.no_auto_bright = 1
            lr.pointee.params.output_color = 0
            lr.pointee.params.use_camera_wb = 0
            lr.pointee.params.use_auto_wb = 0
            lr.pointee.params.user_mul = (1, 1, 1, 1)
            lr.pointee.params.user_qual = Int32(quality)
            lr.pointee.params.user_flip = 0
            lr.pointee.params.half_size = 0
            try check(libraw_dcraw_process(lr), "process")
            var errorCode: Int32 = 0
            guard let processed = libraw_dcraw_make_mem_image(lr, &errorCode) else {
                throw ConversionError.decode("LibRaw make_mem_image: \(String(cString: libraw_strerror(errorCode)))")
            }
            defer { libraw_dcraw_clear_mem(processed) }
            let processMs = (ProcessInfo.processInfo.systemUptime - unpackDone) * 1000
            let copyStart = ProcessInfo.processInfo.systemUptime
            let width = Int(processed.pointee.width), height = Int(processed.pointee.height)
            guard processed.pointee.colors == 3, processed.pointee.bits == 16 else {
                throw ConversionError.decode("LibRaw produced \(processed.pointee.colors) colours at \(processed.pointee.bits) bits")
            }
            var samples = [Float](repeating: 0, count: width * height * 3)
            withUnsafeMutablePointer(to: &processed.pointee.data) { data in
                let source = UnsafeRawPointer(data).assumingMemoryBound(to: UInt16.self)
                samples.withUnsafeMutableBufferPointer { destination in
                    vDSP_vfltu16(source, 1, destination.baseAddress!, 1, vDSP_Length(width * height * 3))
                    var scale: Float = 1 / 65535
                    vDSP_vsmul(destination.baseAddress!, 1, &scale, destination.baseAddress!, 1, vDSP_Length(width * height * 3))
                }
            }
            var makeTuple = lr.pointee.idata.make, modelTuple = lr.pointee.idata.model
            let make = cString(&makeTuple), model = cString(&modelTuple)
            let copyMs = (ProcessInfo.processInfo.systemUptime - copyStart) * 1000
            var metadata = FrameMetadata()
            metadata.colorTags = colorTags(lr, make: make, model: model)
            metadata.exif = InputMetadata.exifTags(for: url)
            metadata.isCameraNative = true
            metadata.decodePath = "libraw-demosaic-q\(quality)"
            metadata.originalFileName = url.lastPathComponent
            metadata.cameraName = "\(make) \(model)"
            let frame = RGBFrame(width: width, height: height, samples: samples, metadata: metadata)
            return DemosaicResult(frame: frame, openUnpackMilliseconds: openMs, processMilliseconds: processMs, copyMilliseconds: copyMs)
        }
    }
}

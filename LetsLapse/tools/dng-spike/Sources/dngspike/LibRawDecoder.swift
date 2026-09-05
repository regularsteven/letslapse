import Foundation
import LetsLapseKit
#if LibRaw
import CLibRaw
#endif

/// Strategy A2: LibRaw. Camera-native mosaic with the camera's black and
/// white levels, Adobe's colour matrix for the body, the as-shot multipliers
/// and the sensor's CFA layout — for every raw family the app imports.
/// Built only with the `LibRaw` trait; the stub below explains itself.
enum LibRawDecoder {
    struct Result {
        let frame: MosaicFrame
        let openMilliseconds: Double
        let unpackMilliseconds: Double
        let copyMilliseconds: Double
        let cameraMake: String
        let cameraModel: String
    }

    struct DemosaicResult {
        let frame: RGBFrame
        let openUnpackMilliseconds: Double
        let processMilliseconds: Double
        let copyMilliseconds: Double
    }

    static var isAvailable: Bool {
        #if LibRaw
        return true
        #else
        return false
        #endif
    }

    static var version: String {
        #if LibRaw
        return String(cString: libraw_version())
        #else
        return "not built (swift build --traits LibRaw)"
        #endif
    }

    #if LibRaw
    private static func check(_ code: Int32, _ what: String) throws {
        guard code == 0 else {
            throw SpikeError.decode("LibRaw \(what): \(String(cString: libraw_strerror(code)))")
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
                guard index >= 0, index < description.count else { throw SpikeError.unsupported("CFA colour index \(index)") }
                let letter = description[description.index(description.startIndex, offsetBy: index)]
                switch letter {
                case "R": pattern.append(0)
                case "G": pattern.append(1)
                case "B": pattern.append(2)
                default: throw SpikeError.unsupported("CFA colour \(letter) (\(description)) — Bayer RGB only")
                }
            }
        }
        return pattern
    }

    private static func open(_ url: URL) throws -> (UnsafeMutablePointer<libraw_data_t>, Double) {
        let clock = ProcessInfo.processInfo.systemUptime
        guard let lr = libraw_init(0) else { throw SpikeError.decode("libraw_init failed") }
        try check(libraw_open_file(lr, url.path), "open")
        return (lr, (ProcessInfo.processInfo.systemUptime - clock) * 1000)
    }

    static func decode(url: URL) throws -> Result {
        let (lr, openMs) = try open(url)
        defer { libraw_close(lr) }
        let unpackStart = ProcessInfo.processInfo.systemUptime
        try check(libraw_unpack(lr), "unpack")
        let unpackMs = (ProcessInfo.processInfo.systemUptime - unpackStart) * 1000

        let copyStart = ProcessInfo.processInfo.systemUptime
        guard let rawImage = lr.pointee.rawdata.raw_image else {
            throw SpikeError.unsupported("\(url.lastPathComponent) is not a 16-bit Bayer raw (no raw_image plane)")
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
        let cblack: [UInt32] = (0..<6).map { dngspike_cblack(lr, Int32($0)) }
        let perChannel = Array(cblack[0..<4])
        var blackNote = "black \(black)"
        if perChannel.contains(where: { $0 != 0 }) || cblack[4] != 0 || cblack[5] != 0 {
            blackNote += " + per-channel \(perChannel) pattern \(cblack[4])×\(cblack[5]) (uniform value used; delta ignored)"
        }
        let white = Double(lr.pointee.color.maximum)
        let pattern = try cfaPattern(lr, rowOffset: top - Int(sizes.top_margin), columnOffset: left - Int(sizes.left_margin))
        var makeTuple = lr.pointee.idata.make, modelTuple = lr.pointee.idata.model
        let make = withUnsafeBytes(of: &makeTuple) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let model = withUnsafeBytes(of: &modelTuple) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
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
    static func demosaic(url: URL, quality: Int) throws -> DemosaicResult {
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
            throw SpikeError.decode("LibRaw make_mem_image: \(String(cString: libraw_strerror(errorCode)))")
        }
        defer { libraw_dcraw_clear_mem(processed) }
        let processMs = (ProcessInfo.processInfo.systemUptime - unpackDone) * 1000
        let copyStart = ProcessInfo.processInfo.systemUptime
        let width = Int(processed.pointee.width), height = Int(processed.pointee.height)
        guard processed.pointee.colors == 3, processed.pointee.bits == 16 else {
            throw SpikeError.decode("LibRaw produced \(processed.pointee.colors) colours at \(processed.pointee.bits) bits")
        }
        var samples = [Float](repeating: 0, count: width * height * 3)
        withUnsafeMutablePointer(to: &processed.pointee.data) { data in
            let bytes = UnsafeRawPointer(data)
            let source = bytes.assumingMemoryBound(to: UInt16.self)
            samples.withUnsafeMutableBufferPointer { destination in
                for i in 0..<(width * height * 3) {
                    destination[i] = Float(source[i]) / 65535
                }
            }
        }
        var makeTuple = lr.pointee.idata.make, modelTuple = lr.pointee.idata.model
        let make = withUnsafeBytes(of: &makeTuple) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let model = withUnsafeBytes(of: &modelTuple) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let copyMs = (ProcessInfo.processInfo.systemUptime - copyStart) * 1000
        var metadata = FrameMetadata()
        metadata.colorTags = colorTags(lr, make: make, model: model)
        metadata.exif = InputMetadata.exifTags(for: url)
        metadata.isCameraNative = true
        metadata.decodePath = "libraw-demosaic-q\(quality)"
        metadata.originalFileName = url.lastPathComponent
        metadata.cameraName = "\(make) \(model)"
        let frame = RGBFrame(width: width, height: height, samples: samples, metadata: metadata)
        return DemosaicResult(frame: frame, openUnpackMilliseconds: openMs + (unpackDone - ProcessInfo.processInfo.systemUptime) * 0 + 0,
                              processMilliseconds: processMs, copyMilliseconds: copyMs)
    }
    #else
    static func decode(url: URL) throws -> Result {
        throw SpikeError.unsupported("LibRaw is not built in — swift build --traits LibRaw")
    }

    static func demosaic(url: URL, quality: Int) throws -> DemosaicResult {
        throw SpikeError.unsupported("LibRaw is not built in — swift build --traits LibRaw")
    }
    #endif
}

import Foundation
import Compression

// MARK: - Tag model

/// One TIFF/DNG directory entry, carried verbatim (type, count and raw
/// payload bytes) so authored files reproduce the camera's own values —
/// color matrices, as-shot neutral, black levels — without reinterpretation.
public struct DNGTagValue: Equatable {
    public let tag: UInt16
    public let type: UInt16
    public let count: UInt32
    public let payload: Data

    public init(tag: UInt16, type: UInt16, count: UInt32, payload: Data) {
        self.tag = tag
        self.type = type
        self.count = count
        self.payload = payload
    }
}

/// The tag sets harvested from a real capture's DNG (one per session or per
/// window): IFD0 carries the DNG camera profile (matrices, neutral), the raw
/// IFD carries sensor geometry (CFA pattern, black/white levels), EXIF is
/// optional exposure metadata.
public struct DNGReference {
    public var ifd0: [DNGTagValue]
    public var raw: [DNGTagValue]
    public var exif: [DNGTagValue]

    public init(ifd0: [DNGTagValue], raw: [DNGTagValue], exif: [DNGTagValue] = []) {
        self.ifd0 = ifd0
        self.raw = raw
        self.exif = exif
    }
}

// MARK: - Parsing

public enum DNGDocument {
    /// Reads a TIFF/DNG in either byte order — iPhone DNGs are big-endian
    /// ("MM"), most camera DNGs little-endian ("II") — and returns its tags
    /// grouped by role, with every payload normalised to little-endian so
    /// authored output stays byte-order-correct. The raw IFD is found by
    /// PhotometricInterpretation == 32803 (CFA) in IFD0 or any SubIFD.
    public static func parseReference(_ data: Data) throws -> DNGReference {
        let reader = TIFFReader(data: data)
        guard try reader.readHeader() else {
            throw DNGError.malformedDNG("not a TIFF")
        }
        let ifd0Offset = try reader.u32(at: 4)
        let ifd0 = try reader.readIFD(at: Int(ifd0Offset))

        var candidates: [[DNGTagValue]] = [ifd0]
        if let subIFDs = ifd0.first(where: { $0.tag == 330 }) {
            for offset in Self.longValues(of: subIFDs) {
                candidates.append(try reader.readIFD(at: Int(offset)))
            }
        }
        guard let raw = candidates.first(where: { entries in
            entries.first { $0.tag == 262 }.map { Self.firstShortOrLong(of: $0) == 32803 } ?? false
        }) else {
            throw DNGError.malformedDNG("no CFA image directory")
        }

        var exif: [DNGTagValue] = []
        if let exifPointer = ifd0.first(where: { $0.tag == 34665 }),
           let offset = Self.longValues(of: exifPointer).first {
            exif = (try? reader.readIFD(at: Int(offset))) ?? []
        }
        return DNGReference(ifd0: ifd0, raw: raw, exif: exif)
    }

    public static func longValues(of entry: DNGTagValue) -> [UInt32] {
        var values: [UInt32] = []
        let stride = entry.type == 3 ? 2 : 4
        var index = 0
        while index + stride <= entry.payload.count {
            if stride == 2 {
                values.append(UInt32(entry.payload.readU16(at: index)))
            } else {
                values.append(entry.payload.readU32(at: index))
            }
            index += stride
        }
        return values
    }

    public static func firstShortOrLong(of entry: DNGTagValue) -> UInt32? {
        longValues(of: entry).first
    }
}

private final class TIFFReader {
    let data: Data
    private(set) var isBigEndian = false
    init(data: Data) { self.data = data }

    func readHeader() throws -> Bool {
        guard data.count >= 8 else { throw DNGError.malformedDNG("truncated header") }
        let first = data[data.startIndex]
        let second = data[data.startIndex + 1]
        if first == 0x49, second == 0x49 {
            isBigEndian = false
        } else if first == 0x4D, second == 0x4D {
            isBigEndian = true
        } else {
            return false
        }
        return readU16(at: 2) == 42
    }

    private func readU16(at offset: Int) -> UInt16 {
        let value = data.readU16(at: offset)
        return isBigEndian ? value.byteSwapped : value
    }

    private func readU32(at offset: Int) -> UInt32 {
        let value = data.readU32(at: offset)
        return isBigEndian ? value.byteSwapped : value
    }

    func u32(at offset: Int) throws -> UInt32 {
        guard offset + 4 <= data.count else { throw DNGError.malformedDNG("read past end") }
        return readU32(at: offset)
    }

    func readIFD(at offset: Int) throws -> [DNGTagValue] {
        guard offset + 2 <= data.count else { throw DNGError.malformedDNG("IFD offset past end") }
        let entryCount = Int(readU16(at: offset))
        var entries: [DNGTagValue] = []
        entries.reserveCapacity(entryCount)
        for index in 0..<entryCount {
            let entryOffset = offset + 2 + index * 12
            guard entryOffset + 12 <= data.count else {
                throw DNGError.malformedDNG("IFD entry past end")
            }
            let tag = readU16(at: entryOffset)
            let type = readU16(at: entryOffset + 2)
            let count = readU32(at: entryOffset + 4)
            let size = Int(count) * Self.typeSize(type)
            let raw: Data
            if size <= 4 {
                raw = data.subdata(in: (data.startIndex + entryOffset + 8)..<(data.startIndex + entryOffset + 8 + max(0, size)))
            } else {
                let valueOffset = Int(readU32(at: entryOffset + 8))
                guard valueOffset + size <= data.count else {
                    throw DNGError.malformedDNG("tag \(tag) value past end")
                }
                raw = data.subdata(in: (data.startIndex + valueOffset)..<(data.startIndex + valueOffset + size))
            }
            entries.append(DNGTagValue(tag: tag, type: type, count: count, payload: normalized(raw, type: type)))
        }
        return entries
    }

    /// Payloads are carried little-endian everywhere downstream; big-endian
    /// sources get each numeric unit swapped (rationals are two 32-bit
    /// halves). Byte-ish types — ASCII, BYTE, UNDEFINED (opcode lists and
    /// maker notes define their own internal order) — pass through verbatim.
    private func normalized(_ raw: Data, type: UInt16) -> Data {
        guard isBigEndian else { return raw }
        let unit: Int
        switch type {
        case 3, 8: unit = 2
        case 4, 9, 11: unit = 4
        case 5, 10: unit = 4
        case 12: unit = 8
        default: return raw
        }
        var output = Data(capacity: raw.count)
        var index = raw.startIndex
        while index + unit <= raw.endIndex {
            for step in stride(from: unit - 1, through: 0, by: -1) {
                output.append(raw[index + step])
            }
            index += unit
        }
        if index < raw.endIndex {
            output.append(raw[index...])
        }
        return output
    }

    static func typeSize(_ type: UInt16) -> Int {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8: return 2
        case 4, 9, 11: return 4
        case 5, 10, 12: return 8
        default: return 1
        }
    }
}

// MARK: - Authoring

/// Writes a blended Bayer mosaic as an uncompressed CFA DNG, carrying the
/// reference capture's tags verbatim so post tools see the same camera
/// profile they would in a straight-from-camera file. Optionally embeds an
/// uncompressed RGB preview as IFD0 (raw image moves to a SubIFD) so system
/// thumbnailing stays fast.
public enum DNGAuthor {
    public struct Preview {
        public let width: Int
        public let height: Int
        /// Tightly packed RGB, 8 bits per sample.
        public let rgb: Data

        public init(width: Int, height: Int, rgb: Data) {
            self.width = width
            self.height = height
            self.rgb = rgb
        }
    }

    /// Tags the author owns because they describe the strips it writes.
    private static let structuralTags: Set<UInt16> = [
        254, 256, 257, 258, 259, 262, 273, 277, 278, 279, 284,
        322, 323, 324, 325, 513, 514,
    ]
    /// Pointers into the reference file; never carried over.
    private static let pointerTags: Set<UInt16> = [330, 34665, 34853, 40965, 700]

    public static func writeBayerDNG(
        mosaic: Data,
        width: Int,
        height: Int,
        reference: DNGReference,
        preview: Preview?,
        to url: URL
    ) throws {
        let data = try makeBayerDNGData(
            mosaic: mosaic, width: width, height: height,
            reference: reference, preview: preview)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw DNGError.writeFailed(error.localizedDescription)
        }
    }

    /// Writes 16-bit scene-linear RGB as a LinearRaw DNG. The samples are
    /// linear light in Rec.709/sRGB primaries (D65), declared via a fixed
    /// ColorMatrix1, with `AsShotNeutral = 1,1,1`. Values above `1.0 /
    /// headroom` of full scale carry highlight headroom for recovery. This is
    /// the "practical first implementation" path: not sensor-native Bayer,
    /// but linear + 16-bit + headroom is real post latitude — unlike JPEG.
    /// `cameraColor`: identity/matrix/neutral tags from
    /// `CameraColorTransform.model(from:)` for samples already transformed
    /// into camera-native space; nil keeps the fixed-sRGB tag set for
    /// working-space samples.
    public static func writeLinearDNG(
        rgb16: Data,
        width: Int,
        height: Int,
        headroomStops: Int = 0,
        compress: Bool = false,
        cameraColor: [DNGTagValue]? = nil,
        preview: Preview?,
        to url: URL
    ) throws {
        guard rgb16.count == width * height * 6 else {
            throw DNGError.sizeMismatch(
                expected: "\(width * height * 6) rgb bytes",
                actual: "\(rgb16.count)")
        }
        // XYZ(D65) -> linear Rec.709, rows scaled by 10000 as SRATIONALs —
        // the DNG "camera to XYZ" convention is the inverse direction, and
        // for LinearRaw with sRGB primaries the standard matrix is the
        // XYZ->RGB one.
        let matrix: [(Int32, Int32)] = [
            (32406, 10000), (-15372, 10000), (-4986, 10000),
            (-9689, 10000), (18758, 10000), (415, 10000),
            (557, 10000), (-2040, 10000), (10570, 10000),
        ]
        var matrixPayload = Data()
        for (numerator, denominator) in matrix {
            matrixPayload.appendU32(UInt32(bitPattern: numerator))
            matrixPayload.appendU32(UInt32(bitPattern: denominator))
        }
        var neutralPayload = Data()
        for _ in 0..<3 {
            neutralPayload.appendU32(1)
            neutralPayload.appendU32(1)
        }
        var whitePayload = Data()
        for _ in 0..<3 { whitePayload.appendU16(65535) }
        var illuminantPayload = Data()
        illuminantPayload.appendU16(21) // D65

        var ifd0Tags: [DNGTagValue] = [
            DNGTagValue(tag: 50706, type: 1, count: 4, payload: Data([1, 4, 0, 0])),
            DNGTagValue(tag: 50707, type: 1, count: 4, payload: Data([1, 1, 0, 0])),
        ]
        if let cameraColor {
            ifd0Tags.append(contentsOf: cameraColor)
        } else {
            ifd0Tags.append(contentsOf: [
                DNGTagValue(tag: 50721, type: 10, count: 9, payload: matrixPayload),
                DNGTagValue(tag: 50728, type: 5, count: 3, payload: neutralPayload),
                DNGTagValue(tag: 50778, type: 3, count: 1, payload: illuminantPayload),
            ])
        }
        if headroomStops > 0 {
            // Values were pre-divided by 2^stops to keep highlight headroom;
            // BaselineExposure tells the decoder to push it back.
            var exposurePayload = Data()
            exposurePayload.appendU32(UInt32(bitPattern: Int32(headroomStops)))
            exposurePayload.appendU32(1)
            ifd0Tags.append(DNGTagValue(tag: 50730, type: 10, count: 1, payload: exposurePayload))
        }
        let reference = DNGReference(
            ifd0: ifd0Tags,
            raw: [
                DNGTagValue(tag: 50717, type: 3, count: 3, payload: whitePayload),
            ])
        // Deflate+predictor lands ~27 MB (measured on real data) and the
        // stream round-trips byte-perfectly — but Apple's ImageIO refuses
        // Deflate on integer LinearRaw (probe: DeflateProbeTests), which
        // would break in-app rendering and Photos. Default stays
        // uncompressed until the Bayer+lossless-JPEG path (Indigo's shape)
        // lands in Phase 2; the flag remains for Adobe-only exports.
        var payloadOverride: DNGAuthor.CompressedStrip?
        if compress {
            payloadOverride = DNGAuthor.CompressedStrip(
                payload: try deflateWithPredictor(rgb16, width: width, height: height, samplesPerPixel: 3),
                predictor: 2)
        }
        let data = try makeDNGData(
            image: rgb16, width: width, height: height,
            samplesPerPixel: 3, photometric: 34892,
            reference: reference, preview: preview,
            compressedStrip: payloadOverride)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw DNGError.writeFailed(error.localizedDescription)
        }
    }

    struct CompressedStrip {
        let payload: Data
        let predictor: UInt16
    }

    /// Samples camera-native linear RGB back into a Bayer mosaic — one real
    /// measured channel per site, the layout every raw decoder demosaics
    /// natively and the reason the file shrinks 3× before compression.
    public static func mosaic(
        fromRGBA16 rgba: [UInt16],
        width: Int,
        height: Int,
        pattern: [UInt8]
    ) -> [UInt16] {
        precondition(pattern.count == 4)
        var output = [UInt16](repeating: 0, count: width * height)
        rgba.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                let src = source.baseAddress!
                let dst = destination.baseAddress!
                for row in 0..<height {
                    let rowBase = row * width
                    let patternRow = (row & 1) << 1
                    for column in 0..<width {
                        let channel = Int(pattern[patternRow + (column & 1)])
                        dst[rowBase + column] = src[(rowBase + column) * 4 + channel]
                    }
                }
            }
        }
        return output
    }

    /// Writes a camera-native Bayer mosaic as a lossless-JPEG-compressed,
    /// 256px-tiled CFA DNG — the same shape camera vendors ship, at roughly
    /// a fifth the size of uncompressed LinearRaw with identical post
    /// latitude (bit-exact codec; white balance lives in metadata).
    public static func writeCompressedBayerDNG(
        mosaic: [UInt16],
        width: Int,
        height: Int,
        cfaPattern: [UInt8],
        cameraColor: [DNGTagValue],
        headroomStops: Int = 0,
        preview: Preview?,
        to url: URL
    ) throws {
        guard mosaic.count == width * height else {
            throw DNGError.sizeMismatch(expected: "\(width * height) samples", actual: "\(mosaic.count)")
        }
        let tileSize = 256
        let tilesAcross = (width + tileSize - 1) / tileSize
        let tilesDown = (height + tileSize - 1) / tileSize

        // Cut edge-replicated full tiles, then encode them concurrently.
        var tileInputs: [[UInt16]] = []
        tileInputs.reserveCapacity(tilesAcross * tilesDown)
        for tileRow in 0..<tilesDown {
            for tileColumn in 0..<tilesAcross {
                var tile = [UInt16](repeating: 0, count: tileSize * tileSize)
                for y in 0..<tileSize {
                    let sourceY = min(tileRow * tileSize + y, height - 1)
                    for x in 0..<tileSize {
                        let sourceX = min(tileColumn * tileSize + x, width - 1)
                        tile[y * tileSize + x] = mosaic[sourceY * width + sourceX]
                    }
                }
                tileInputs.append(tile)
            }
        }
        var encoded = [Data?](repeating: nil, count: tileInputs.count)
        var encodeFailure = false
        encoded.withUnsafeMutableBufferPointer { buffer in
            let pointer = UnsafeMutableBufferPointer(rebasing: buffer[...])
            DispatchQueue.concurrentPerform(iterations: tileInputs.count) { index in
                pointer[index] = try? LosslessJPEG.encode(
                    samples: tileInputs[index], width: tileSize, height: tileSize)
            }
        }
        let tiles: [Data] = try encoded.map {
            guard let tile = $0 else {
                encodeFailure = true
                throw DNGError.writeFailed("tile encode failed")
            }
            return tile
        }
        _ = encodeFailure

        var ifd0Tags: [DNGTagValue] = [
            DNGTagValue(tag: 50706, type: 1, count: 4, payload: Data([1, 4, 0, 0])),
            DNGTagValue(tag: 50707, type: 1, count: 4, payload: Data([1, 1, 0, 0])),
        ]
        ifd0Tags.append(contentsOf: cameraColor)
        if headroomStops > 0 {
            var exposurePayload = Data()
            exposurePayload.appendU32(UInt32(bitPattern: Int32(headroomStops)))
            exposurePayload.appendU32(1)
            ifd0Tags.append(DNGTagValue(tag: 50730, type: 10, count: 1, payload: exposurePayload))
        }

        var cfaDims = Data()
        cfaDims.appendU16(2)
        cfaDims.appendU16(2)
        var blackPayload = Data()
        blackPayload.appendU16(0)
        var whitePayload = Data()
        whitePayload.appendU32(65535)
        let rawTags: [DNGTagValue] = [
            DNGTagValue(tag: 33421, type: 3, count: 2, payload: cfaDims),
            DNGTagValue(tag: 33422, type: 1, count: 4, payload: Data(cfaPattern)),
            DNGTagValue(tag: 50710, type: 1, count: 3, payload: Data([0, 1, 2])),
            DNGTagValue(tag: 50711, type: 3, count: 1, payload: { var d = Data(); d.appendU16(1); return d }()),
            DNGTagValue(tag: 50714, type: 3, count: 1, payload: blackPayload),
            DNGTagValue(tag: 50717, type: 4, count: 1, payload: whitePayload),
        ]

        let data = try makeTiledDNGData(
            width: width, height: height,
            tileSize: tileSize, tilesAcross: tilesAcross, tilesDown: tilesDown,
            tiles: tiles,
            ifd0Tags: ifd0Tags, rawTags: rawTags,
            preview: preview)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw DNGError.writeFailed(error.localizedDescription)
        }
    }

    /// Assembles a two-IFD DNG whose raw image is lossless-JPEG tiles.
    private static func makeTiledDNGData(
        width: Int,
        height: Int,
        tileSize: Int,
        tilesAcross: Int,
        tilesDown: Int,
        tiles: [Data],
        ifd0Tags: [DNGTagValue],
        rawTags: [DNGTagValue],
        preview: Preview?
    ) throws -> Data {
        let rawIFD = IFDBuilder()
        rawIFD.addLong(254, 0)
        rawIFD.addLong(256, UInt32(width))
        rawIFD.addLong(257, UInt32(height))
        rawIFD.addShorts(258, [16])
        rawIFD.addShorts(259, [7]) // lossless JPEG
        rawIFD.addShorts(262, [32803])
        rawIFD.addShorts(277, [1])
        rawIFD.addShorts(284, [1])
        rawIFD.addLong(322, UInt32(tileSize))
        rawIFD.addLong(323, UInt32(tileSize))
        rawIFD.addLongs(324, [UInt32](repeating: 0, count: tiles.count)) // patched
        rawIFD.addLongs(325, tiles.map { UInt32($0.count) })
        for tag in rawTags {
            rawIFD.add(tag)
        }

        let ifd0 = IFDBuilder()
        let hasPreview = preview != nil
        if let preview {
            ifd0.addLong(254, 1)
            ifd0.addLong(256, UInt32(preview.width))
            ifd0.addLong(257, UInt32(preview.height))
            ifd0.addShorts(258, [8, 8, 8])
            ifd0.addShorts(259, [1])
            ifd0.addShorts(262, [2])
            ifd0.addLong(273, 0) // patched
            ifd0.addShorts(277, [3])
            ifd0.addLong(278, UInt32(preview.height))
            ifd0.addLong(279, UInt32(preview.rgb.count))
            ifd0.addShorts(284, [1])
            ifd0.addLong(330, 0) // patched
        }
        if !hasPreview {
            for tag in rawIFD.sorted {
                ifd0.add(tag)
            }
        }
        for tag in ifd0Tags {
            ifd0.add(tag)
        }
        if !ifd0.contains(50708) {
            let name = Data("LetsLapse Live Blend\0".utf8)
            ifd0.add(DNGTagValue(tag: 50708, type: 2, count: UInt32(name.count), payload: name))
        }

        let header = 8
        let ifd0Table = header
        let ifd0End = ifd0Table + ifd0.tableSize + ifd0.valueSize
        let rawTable = ifd0End
        let rawEnd = hasPreview ? rawTable + rawIFD.tableSize + rawIFD.valueSize : rawTable
        let previewStrip = (rawEnd + 1) & ~1
        var cursor = ((previewStrip + (preview?.rgb.count ?? 0)) + 1) & ~1
        var tileOffsets: [UInt32] = []
        for tile in tiles {
            tileOffsets.append(UInt32(cursor))
            cursor += tile.count
            cursor = (cursor + 1) & ~1
        }

        let target = hasPreview ? rawIFD : ifd0
        target.addLongs(324, tileOffsets)
        if hasPreview {
            ifd0.patchLong(273, UInt32(previewStrip))
            ifd0.patchLong(330, UInt32(rawTable))
        }

        var output = Data(capacity: cursor)
        output.append(contentsOf: [0x49, 0x49, 42, 0])
        output.appendU32(UInt32(ifd0Table))
        output.append(ifd0.serialize(tableOffset: ifd0Table))
        if hasPreview {
            output.append(rawIFD.serialize(tableOffset: rawTable))
        }
        while output.count < previewStrip { output.append(0) }
        if let preview {
            output.append(preview.rgb)
        }
        for (index, tile) in tiles.enumerated() {
            while output.count < Int(tileOffsets[index]) { output.append(0) }
            output.append(tile)
        }
        return output
    }

    /// TIFF Deflate (Compression 8) with horizontal-difference Predictor 2
    /// over 16-bit samples, quantised to 12 significant bits first. The
    /// Compression framework emits raw deflate, so the zlib header/adler32
    /// wrapper TIFF expects is added by hand.
    static func deflateWithPredictor(_ image: Data, width: Int, height: Int, samplesPerPixel: Int, predict: Bool = true) throws -> Data {
        let perRow = width * samplesPerPixel
        var working = [UInt16](repeating: 0, count: perRow * height)
        image.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let source = raw.bindMemory(to: UInt16.self)
            working.withUnsafeMutableBufferPointer { destination in
                let dst = destination.baseAddress!
                for row in 0..<height {
                    let base = row * perRow
                    // Quantise, then difference against the previous sample
                    // of the same channel (stride = samplesPerPixel).
                    var previous = [UInt16](repeating: 0, count: samplesPerPixel)
                    for column in 0..<perRow {
                        let value = source[base + column] & 0xFFF0
                        let channel = column % samplesPerPixel
                        if !predict || column < samplesPerPixel {
                            dst[base + column] = value
                        } else {
                            dst[base + column] = value &- previous[channel]
                        }
                        previous[channel] = value
                    }
                }
            }
        }

        let sourceData = working.withUnsafeBufferPointer { Data(buffer: $0) }
        var compressed = Data(count: sourceData.count + 65536)
        let compressedCount = compressed.withUnsafeMutableBytes { destination in
            sourceData.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!,
                    destination.count,
                    source.bindMemory(to: UInt8.self).baseAddress!,
                    source.count,
                    nil,
                    COMPRESSION_ZLIB)
            }
        }
        guard compressedCount > 0 else {
            throw DNGError.writeFailed("deflate failed")
        }
        compressed.removeSubrange(compressedCount..<compressed.count)

        // RFC1950 wrapper: header + raw deflate + Adler-32 (big-endian).
        var wrapped = Data([0x78, 0x9C])
        wrapped.append(compressed)
        var s1: UInt32 = 1
        var s2: UInt32 = 0
        sourceData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var index = 0
            let count = raw.count
            let bytes = raw.bindMemory(to: UInt8.self).baseAddress!
            while index < count {
                let block = min(5552, count - index)
                for offset in 0..<block {
                    s1 &+= UInt32(bytes[index + offset])
                    s2 &+= s1
                }
                s1 %= 65521
                s2 %= 65521
                index += block
            }
        }
        let adler = (s2 << 16) | s1
        wrapped.append(UInt8((adler >> 24) & 0xFF))
        wrapped.append(UInt8((adler >> 16) & 0xFF))
        wrapped.append(UInt8((adler >> 8) & 0xFF))
        wrapped.append(UInt8(adler & 0xFF))
        return wrapped
    }

    /// Builds the DNG in memory — callers that want to demosaic the blended
    /// result for an embedded preview author twice without touching disk.
    public static func makeBayerDNGData(
        mosaic: Data,
        width: Int,
        height: Int,
        reference: DNGReference,
        preview: Preview?
    ) throws -> Data {
        guard mosaic.count == width * height * 2 else {
            throw DNGError.sizeMismatch(
                expected: "\(width * height * 2) mosaic bytes",
                actual: "\(mosaic.count)")
        }
        return try makeDNGData(
            image: mosaic, width: width, height: height,
            samplesPerPixel: 1, photometric: 32803,
            reference: reference, preview: preview)
    }

    /// Shared builder for 16-bit-per-sample raw DNGs (Bayer CFA or
    /// LinearRaw RGB), carrying the reference's tags verbatim.
    static func makeDNGData(
        image: Data,
        width: Int,
        height: Int,
        samplesPerPixel: Int,
        photometric: UInt16,
        reference: DNGReference,
        preview: Preview?,
        compressedStrip: CompressedStrip? = nil
    ) throws -> Data {
        guard image.count == width * height * 2 * samplesPerPixel else {
            throw DNGError.sizeMismatch(
                expected: "\(width * height * 2 * samplesPerPixel) image bytes",
                actual: "\(image.count)")
        }

        let carriedIFD0 = reference.ifd0.filter { !structuralTags.contains($0.tag) && !pointerTags.contains($0.tag) }
        let carriedRaw = reference.raw.filter { !structuralTags.contains($0.tag) && !pointerTags.contains($0.tag) }
        let carriedExif = reference.exif.filter { !pointerTags.contains($0.tag) }

        if photometric == 32803 {
            guard carriedRaw.contains(where: { $0.tag == 33422 }) else {
                throw DNGError.malformedDNG("reference is missing CFAPattern")
            }
        }

        let strip = compressedStrip?.payload ?? image
        let rawIFD = IFDBuilder()
        rawIFD.addLong(254, 0)
        rawIFD.addLong(256, UInt32(width))
        rawIFD.addLong(257, UInt32(height))
        rawIFD.addShorts(258, Array(repeating: 16, count: samplesPerPixel))
        rawIFD.addShorts(259, [compressedStrip == nil ? 1 : 8])
        rawIFD.addShorts(262, [photometric])
        rawIFD.addLong(273, 0) // patched to the strip offset
        rawIFD.addShorts(277, [UInt16(samplesPerPixel)])
        rawIFD.addLong(278, UInt32(height))
        rawIFD.addLong(279, UInt32(strip.count))
        rawIFD.addShorts(284, [1])
        if let compressedStrip {
            rawIFD.addShorts(317, [compressedStrip.predictor])
        }
        for entry in carriedRaw {
            rawIFD.add(entry)
        }

        let hasExif = !carriedExif.isEmpty
        let exifIFD = IFDBuilder()
        for entry in carriedExif {
            exifIFD.add(entry)
        }

        let ifd0 = IFDBuilder()
        if let preview {
            ifd0.addLong(254, 1)
            ifd0.addLong(256, UInt32(preview.width))
            ifd0.addLong(257, UInt32(preview.height))
            ifd0.addShorts(258, [8, 8, 8])
            ifd0.addShorts(259, [1])
            ifd0.addShorts(262, [2])
            ifd0.addLong(273, 0) // patched
            ifd0.addShorts(277, [3])
            ifd0.addLong(278, UInt32(preview.height))
            ifd0.addLong(279, UInt32(preview.rgb.count))
            ifd0.addShorts(284, [1])
            ifd0.addLong(330, 0) // patched to the raw IFD offset
        }
        if preview == nil {
            // Single-IFD DNG: IFD0 is the raw image, so it takes the raw
            // structural and carried tags first; profile tags fill in after.
            for entry in rawIFD.sorted {
                ifd0.add(entry)
            }
        }
        for entry in carriedIFD0 {
            ifd0.add(entry)
        }
        if hasExif {
            ifd0.addLong(34665, 0) // patched
        }
        // Spec-required identity tags, injected only when the reference
        // lacks them (a synthetic test reference might).
        if !ifd0.contains(50706) {
            ifd0.add(DNGTagValue(tag: 50706, type: 1, count: 4, payload: Data([1, 4, 0, 0])))
        }
        if !ifd0.contains(50708) {
            let name = Data("LetsLapse Live Blend\0".utf8)
            ifd0.add(DNGTagValue(tag: 50708, type: 2, count: UInt32(name.count), payload: name))
        }

        // Layout: header, IFD0, [EXIF], [raw IFD], preview strip, raw strip.
        let singleIFD = preview == nil
        let header = 8
        let ifd0Table = header
        let ifd0Values = ifd0Table + ifd0.tableSize
        let exifTable = ifd0Values + ifd0.valueSize
        let exifEnd = hasExif ? exifTable + exifIFD.tableSize + exifIFD.valueSize : exifTable
        let rawTable = exifEnd
        let rawEnd = singleIFD ? rawTable : rawTable + rawIFD.tableSize + rawIFD.valueSize
        let previewStrip = (rawEnd + 1) & ~1
        let rawStrip = ((previewStrip + (preview?.rgb.count ?? 0)) + 1) & ~1
        _ = image // geometry validated by callers; strip may be compressed

        if singleIFD {
            ifd0.patchLong(273, UInt32(rawStrip))
        } else {
            ifd0.patchLong(273, UInt32(previewStrip))
            ifd0.patchLong(330, UInt32(rawTable))
            rawIFD.patchLong(273, UInt32(rawStrip))
        }
        if hasExif {
            ifd0.patchLong(34665, UInt32(exifTable))
        }

        var output = Data(capacity: rawStrip + strip.count)
        output.append(contentsOf: [0x49, 0x49, 42, 0])
        output.appendU32(UInt32(ifd0Table))
        output.append(ifd0.serialize(tableOffset: ifd0Table))
        if hasExif {
            output.append(exifIFD.serialize(tableOffset: exifTable))
        }
        if !singleIFD {
            output.append(rawIFD.serialize(tableOffset: rawTable))
        }
        while output.count < previewStrip { output.append(0) }
        if let preview {
            output.append(preview.rgb)
        }
        while output.count < rawStrip { output.append(0) }
        output.append(strip)
        return output
    }

}

// MARK: - IFD serialization

private final class IFDBuilder {
    private var entries: [UInt16: DNGTagValue] = [:]

    func add(_ entry: DNGTagValue) {
        // First writer wins: structural tags are added before carried tags,
        // so a reference can never override the strip layout.
        guard entries[entry.tag] == nil else { return }
        entries[entry.tag] = entry
    }

    func addLong(_ tag: UInt16, _ value: UInt32) {
        var payload = Data()
        payload.appendU32(value)
        entries[tag] = DNGTagValue(tag: tag, type: 4, count: 1, payload: payload)
    }

    func addShorts(_ tag: UInt16, _ values: [UInt16]) {
        var payload = Data()
        for value in values { payload.appendU16(value) }
        entries[tag] = DNGTagValue(tag: tag, type: 3, count: UInt32(values.count), payload: payload)
    }

    /// LONG array; replaces any existing entry (used to patch offset tables
    /// once the layout is known — counts must match the placeholder's).
    func addLongs(_ tag: UInt16, _ values: [UInt32]) {
        var payload = Data()
        for value in values { payload.appendU32(value) }
        entries[tag] = DNGTagValue(tag: tag, type: 4, count: UInt32(values.count), payload: payload)
    }

    func patchLong(_ tag: UInt16, _ value: UInt32) {
        guard entries[tag] != nil else { return }
        addLong(tag, value)
    }

    func contains(_ tag: UInt16) -> Bool {
        entries[tag] != nil
    }

    var sorted: [DNGTagValue] {
        entries.values.sorted { $0.tag < $1.tag }
    }

    var tableSize: Int {
        2 + entries.count * 12 + 4
    }

    var valueSize: Int {
        sorted.reduce(0) { total, entry in
            entry.payload.count > 4 ? total + ((entry.payload.count + 1) & ~1) : total
        }
    }

    /// Emits the entry table followed by the spilled value area. Values that
    /// fit in 4 bytes are inline; larger ones live right after the table.
    func serialize(tableOffset: Int) -> Data {
        let ordered = sorted
        var table = Data()
        var values = Data()
        let valueBase = tableOffset + tableSize

        table.appendU16(UInt16(ordered.count))
        for entry in ordered {
            table.appendU16(entry.tag)
            table.appendU16(entry.type)
            table.appendU32(entry.count)
            if entry.payload.count <= 4 {
                var inline = entry.payload
                while inline.count < 4 { inline.append(0) }
                table.append(inline)
            } else {
                table.appendU32(UInt32(valueBase + values.count))
                values.append(entry.payload)
                if values.count % 2 == 1 { values.append(0) }
            }
        }
        table.appendU32(0) // no next IFD
        return table + values
    }
}

// MARK: - Little-endian helpers

extension Data {
    func readU16(at offset: Int) -> UInt16 {
        let base = startIndex + offset
        return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
    }

    func readU32(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        return UInt32(self[base])
            | (UInt32(self[base + 1]) << 8)
            | (UInt32(self[base + 2]) << 16)
            | (UInt32(self[base + 3]) << 24)
    }

    mutating func appendU16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendU32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}

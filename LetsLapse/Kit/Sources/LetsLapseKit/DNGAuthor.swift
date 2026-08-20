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
        gps: [DNGTagValue]? = nil,
        exif: [DNGTagValue]? = nil,
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
            // Orientation (274) = 1: authored pixels are display-oriented (the
            // CIRAWFilter decode already applied the reference DNG's tag), so
            // declare "up" explicitly instead of leaving readers to default it.
            DNGTagValue(tag: 274, type: 3, count: 1, payload: { var d = Data(); d.appendU16(1); return d }()),
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
            ],
            exif: exif ?? [])
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
            gps: gps,
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
        gps: [DNGTagValue]? = nil,
        exif: [DNGTagValue]? = nil,
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
            // Orientation (274) = 1: the re-mosaiced Bayer plane comes from the
            // display-oriented working image, not sensor-native geometry, so
            // "up" is the truthful tag (see CameraColorTransform.carriedTags).
            DNGTagValue(tag: 274, type: 3, count: 1, payload: { var d = Data(); d.appendU16(1); return d }()),
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
            gps: gps,
            exif: exif,
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
        gps: [DNGTagValue]? = nil,
        exif: [DNGTagValue]? = nil,
        preview: Preview?
    ) throws -> Data {
        let hasGPS = !(gps?.isEmpty ?? true)
        let gpsIFD = IFDBuilder()
        if let gps { for entry in gps { gpsIFD.add(entry) } }
        let hasExif = !(exif?.isEmpty ?? true)
        let exifIFD = IFDBuilder()
        if let exif { for entry in exif { exifIFD.add(entry) } }
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
        if hasExif {
            ifd0.addLong(34665, 0) // ExifIFDPointer, patched to the EXIF IFD
        }
        if hasGPS {
            ifd0.addLong(34853, 0) // GPSInfoIFDPointer, patched to the GPS IFD
        }
        if !ifd0.contains(50708) {
            let name = Data("LetsLapse Live Blend\0".utf8)
            ifd0.add(DNGTagValue(tag: 50708, type: 2, count: UInt32(name.count), payload: name))
        }

        // Layout: header, IFD0, [EXIF], [GPS], [raw IFD], preview strip, tiles.
        let header = 8
        let ifd0Table = header
        let ifd0End = ifd0Table + ifd0.tableSize + ifd0.valueSize
        let exifTable = ifd0End
        let exifEnd = hasExif ? exifTable + exifIFD.tableSize + exifIFD.valueSize : exifTable
        let gpsTable = exifEnd
        let gpsEnd = hasGPS ? gpsTable + gpsIFD.tableSize + gpsIFD.valueSize : gpsTable
        let rawTable = gpsEnd
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
        if hasExif {
            ifd0.patchLong(34665, UInt32(exifTable))
        }
        if hasGPS {
            ifd0.patchLong(34853, UInt32(gpsTable))
        }

        var output = Data(capacity: cursor)
        output.append(contentsOf: [0x49, 0x49, 42, 0])
        output.appendU32(UInt32(ifd0Table))
        output.append(ifd0.serialize(tableOffset: ifd0Table))
        if hasExif {
            output.append(exifIFD.serialize(tableOffset: exifTable))
        }
        if hasGPS {
            output.append(gpsIFD.serialize(tableOffset: gpsTable))
        }
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
        gps: [DNGTagValue]? = nil,
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

        let hasGPS = !(gps?.isEmpty ?? true)
        let gpsIFD = IFDBuilder()
        if let gps { for entry in gps { gpsIFD.add(entry) } }

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
        if hasGPS {
            ifd0.addLong(34853, 0) // GPSInfoIFDPointer, patched
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

        // Layout: header, IFD0, [EXIF], [GPS], [raw IFD], preview strip, raw strip.
        let singleIFD = preview == nil
        let header = 8
        let ifd0Table = header
        let ifd0Values = ifd0Table + ifd0.tableSize
        let exifTable = ifd0Values + ifd0.valueSize
        let exifEnd = hasExif ? exifTable + exifIFD.tableSize + exifIFD.valueSize : exifTable
        let gpsTable = exifEnd
        let gpsEnd = hasGPS ? gpsTable + gpsIFD.tableSize + gpsIFD.valueSize : gpsTable
        let rawTable = gpsEnd
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
        if hasGPS {
            ifd0.patchLong(34853, UInt32(gpsTable))
        }

        var output = Data(capacity: rawStrip + strip.count)
        output.append(contentsOf: [0x49, 0x49, 42, 0])
        output.appendU32(UInt32(ifd0Table))
        output.append(ifd0.serialize(tableOffset: ifd0Table))
        if hasExif {
            output.append(exifIFD.serialize(tableOffset: exifTable))
        }
        if hasGPS {
            output.append(gpsIFD.serialize(tableOffset: gpsTable))
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

    // MARK: - GPS

    /// One GPS sub-IFD field before byte-order serialization, kept neutral so
    /// the same values feed both the little-endian authored writer and the
    /// endian-matched injector for pass-through Apple originals.
    private struct GPSField {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        enum Value {
            /// ASCII / BYTE payloads, stored verbatim (never byte-swapped).
            case bytes(Data)
            /// RATIONAL values as (numerator, denominator) pairs.
            case rationals([(UInt32, UInt32)])
        }
        let value: Value
    }

    /// The GPS sub-IFD fields (EXIF GPS spec) for one location fix. Latitude
    /// and longitude are degrees/minutes/seconds; time and date stamps are
    /// UTC — matching `CLLocation.exifGPSDictionary()` on the JPEG path.
    private static func gpsFields(
        latitude: Double, longitude: Double, altitude: Double, timestamp: Date
    ) -> [GPSField] {
        func dms(_ value: Double) -> [(UInt32, UInt32)] {
            let magnitude = abs(value)
            let degrees = UInt32(magnitude.rounded(.down))
            let minutesTotal = (magnitude - Double(degrees)) * 60
            let minutes = UInt32(minutesTotal.rounded(.down))
            let seconds = (minutesTotal - Double(minutes)) * 60
            return [(degrees, 1), (minutes, 1), (UInt32((seconds * 10000).rounded()), 10000)]
        }
        func ref(_ string: String) -> Data {
            var data = Data(string.utf8)
            data.append(0)
            return data
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: timestamp)
        var dateStamp = Data(String(format: "%04d:%02d:%02d",
                                     parts.year ?? 0, parts.month ?? 0, parts.day ?? 0).utf8)
        dateStamp.append(0)
        return [
            GPSField(tag: 0, type: 1, count: 4, value: .bytes(Data([2, 3, 0, 0]))),
            GPSField(tag: 1, type: 2, count: 2, value: .bytes(ref(latitude >= 0 ? "N" : "S"))),
            GPSField(tag: 2, type: 5, count: 3, value: .rationals(dms(latitude))),
            GPSField(tag: 3, type: 2, count: 2, value: .bytes(ref(longitude >= 0 ? "E" : "W"))),
            GPSField(tag: 4, type: 5, count: 3, value: .rationals(dms(longitude))),
            GPSField(tag: 5, type: 1, count: 1, value: .bytes(Data([altitude >= 0 ? 0 : 1]))),
            GPSField(tag: 6, type: 5, count: 1, value: .rationals([(UInt32((abs(altitude) * 100).rounded()), 100)])),
            GPSField(tag: 7, type: 5, count: 3, value: .rationals([
                (UInt32(parts.hour ?? 0), 1), (UInt32(parts.minute ?? 0), 1), (UInt32(parts.second ?? 0), 1),
            ])),
            GPSField(tag: 29, type: 2, count: UInt32(dateStamp.count), value: .bytes(dateStamp)),
        ]
    }

    /// The GPS sub-IFD as little-endian TIFF tags, for embedding in an
    /// authored DNG via IFD0's GPSInfoIFDPointer (34853). Emits raw tags
    /// because the DNG writer is hand-rolled rather than routed through
    /// ImageIO's `kCGImagePropertyGPSDictionary`.
    public static func gpsTags(
        latitude: Double, longitude: Double, altitude: Double, timestamp: Date
    ) -> [DNGTagValue] {
        gpsFields(latitude: latitude, longitude: longitude, altitude: altitude, timestamp: timestamp)
            .map { field in
                var payload = Data()
                switch field.value {
                case .bytes(let bytes):
                    payload = bytes
                case .rationals(let rationals):
                    for (numerator, denominator) in rationals {
                        payload.appendU32(numerator)
                        payload.appendU32(denominator)
                    }
                }
                return DNGTagValue(tag: field.tag, type: field.type, count: field.count, payload: payload)
            }
    }

    /// One capture's exposure, as the camera reported it. The values come
    /// straight off `AVCapturePhoto.metadata`'s EXIF dictionary, which is the
    /// only place they exist for an authored blend: the file the blend writes
    /// is built from decoded samples, so nothing carries the shot's ISO,
    /// shutter, aperture or metered brightness unless it is put there
    /// deliberately.
    ///
    /// `brightness` is APEX `BrightnessValue` — scene-referred, describing the
    /// light rather than the exposure chosen for it. `ev` derives the exposure
    /// value the camera actually used, which is the number a grader wants when
    /// comparing frames of a ramping shoot.
    public struct DNGExposure: Equatable, Sendable {
        /// ISO speed rating (EXIF 34855).
        public var iso: Double?
        /// Exposure time in seconds (EXIF 33434).
        public var exposureDuration: Double?
        /// f-number (EXIF 33437).
        public var aperture: Double?
        /// APEX scene brightness (EXIF 37379).
        public var brightness: Double?
        /// When the shutter fired (EXIF 36867 DateTimeOriginal).
        public var capturedAt: Date?

        public init(
            iso: Double? = nil,
            exposureDuration: Double? = nil,
            aperture: Double? = nil,
            brightness: Double? = nil,
            capturedAt: Date? = nil
        ) {
            self.iso = iso
            self.exposureDuration = exposureDuration
            self.aperture = aperture
            self.brightness = brightness
            self.capturedAt = capturedAt
        }

        /// Nothing worth writing an EXIF IFD for.
        public var isEmpty: Bool {
            iso == nil && exposureDuration == nil && aperture == nil
                && brightness == nil && capturedAt == nil
        }

        /// Exposure value at ISO 100 for the settings this frame was taken
        /// with: `log2(N² / t)` corrected for the sensitivity actually used.
        /// Nil unless aperture, shutter and ISO are all known — a partial EV is
        /// a wrong EV, not an approximate one.
        public var exposureValue: Double? {
            guard let aperture, aperture > 0,
                  let exposureDuration, exposureDuration > 0,
                  let iso, iso > 0 else { return nil }
            return log2((aperture * aperture) / exposureDuration) - log2(iso / 100)
        }
    }

    /// The EXIF sub-IFD for one capture's exposure, as little-endian TIFF tags
    /// ready for IFD0's ExifIFDPointer (34665). Emitted by hand for the same
    /// reason `gpsTags` is: the DNG writer assembles IFDs itself rather than
    /// going through ImageIO's property dictionaries.
    ///
    /// Only the fields that are actually known get a tag — an absent reading is
    /// left out rather than written as a zero, so a reader can tell "the camera
    /// didn't say" from "the camera said 0".
    public static func exifTags(_ exposure: DNGExposure) -> [DNGTagValue] {
        func rational(_ numerator: UInt32, _ denominator: UInt32) -> Data {
            var payload = Data()
            payload.appendU32(numerator)
            payload.appendU32(denominator)
            return payload
        }
        func signedRational(_ numerator: Int32, _ denominator: Int32) -> Data {
            var payload = Data()
            payload.appendU32(UInt32(bitPattern: numerator))
            payload.appendU32(UInt32(bitPattern: denominator))
            return payload
        }

        let iso = exposure.iso
        let exposureDuration = exposure.exposureDuration
        let aperture = exposure.aperture
        let brightness = exposure.brightness
        let capturedAt = exposure.capturedAt

        var tags: [DNGTagValue] = []
        // ExifVersion (2.31) — an EXIF IFD without it is technically malformed,
        // and some readers skip the whole block rather than guess.
        tags.append(DNGTagValue(tag: 36864, type: 7, count: 4, payload: Data("0231".utf8)))

        if let exposureDuration, exposureDuration > 0 {
            // Sub-second shutters keep the 1/N shape photographers read; longer
            // ones get millisecond precision.
            let payload = exposureDuration < 1
                ? rational(1, UInt32(max(1, (1 / exposureDuration).rounded())))
                : rational(UInt32((exposureDuration * 1000).rounded()), 1000)
            tags.append(DNGTagValue(tag: 33434, type: 5, count: 1, payload: payload))
        }
        if let aperture, aperture > 0 {
            tags.append(DNGTagValue(
                tag: 33437, type: 5, count: 1,
                payload: rational(UInt32((aperture * 100).rounded()), 100)))
        }
        if let capturedAt {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone.current
            let parts = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: capturedAt)
            var stamp = Data(String(
                format: "%04d:%02d:%02d %02d:%02d:%02d",
                parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0).utf8)
            stamp.append(0)
            tags.append(DNGTagValue(
                tag: 36867, type: 2, count: UInt32(stamp.count), payload: stamp))
        }
        if let brightness {
            tags.append(DNGTagValue(
                tag: 37379, type: 10, count: 1,
                payload: signedRational(Int32((brightness * 10000).rounded()), 10000)))
        }
        if let iso, iso > 0 {
            var payload = Data()
            payload.appendU16(UInt16(min(65535, max(1, iso.rounded()))))
            tags.append(DNGTagValue(tag: 34855, type: 3, count: 1, payload: payload))
        }
        return tags
    }

    /// Adds a GPS sub-IFD to an already-encoded DNG without touching its
    /// pixel data — for the pass-through paths that write a captured Apple
    /// original byte-for-byte. A rebuilt IFD0 (the original entries plus the
    /// GPS pointer) and the GPS IFD are appended, and the TIFF header is
    /// repointed at the rebuilt IFD0, so every existing offset stays valid and
    /// the raw image is left exactly as captured. Honours the source byte
    /// order (iPhone originals are big-endian "MM"). Returns the input
    /// unchanged if it can't be parsed or already carries a GPS IFD.
    public static func dngByInsertingGPS(
        into data: Data,
        latitude: Double, longitude: Double, altitude: Double, timestamp: Date
    ) -> Data {
        guard data.count >= 8 else { return data }
        let bigEndian: Bool
        switch (data[data.startIndex], data[data.startIndex + 1]) {
        case (0x49, 0x49): bigEndian = false
        case (0x4D, 0x4D): bigEndian = true
        default: return data
        }
        func readU16(_ offset: Int) -> UInt16 {
            let base = data.startIndex + offset
            let first = UInt16(data[base]); let second = UInt16(data[base + 1])
            return bigEndian ? (first << 8) | second : (second << 8) | first
        }
        func readU32(_ offset: Int) -> UInt32 {
            let base = data.startIndex + offset
            let bytes = (0..<4).map { UInt32(data[base + $0]) }
            return bigEndian
                ? (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]
                : (bytes[3] << 24) | (bytes[2] << 16) | (bytes[1] << 8) | bytes[0]
        }
        func u16(_ value: UInt16) -> [UInt8] {
            let bytes: [UInt8] = [UInt8(value >> 8), UInt8(value & 0xFF)]
            return bigEndian ? bytes : bytes.reversed()
        }
        func u32(_ value: UInt32) -> [UInt8] {
            let bytes: [UInt8] = [
                UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
            ]
            return bigEndian ? bytes : bytes.reversed()
        }

        guard readU16(2) == 42 else { return data }
        let ifd0Offset = Int(readU32(4))
        guard ifd0Offset >= 8, ifd0Offset + 2 <= data.count else { return data }
        let entryCount = Int(readU16(ifd0Offset))
        let tableStart = ifd0Offset + 2
        guard tableStart + entryCount * 12 + 4 <= data.count else { return data }
        // Copy each 12-byte entry record verbatim (already in file byte order);
        // their spilled-value offsets point into the untouched original.
        var entries: [(tag: UInt16, record: Data)] = []
        entries.reserveCapacity(entryCount + 1)
        for index in 0..<entryCount {
            let recordStart = data.startIndex + tableStart + index * 12
            let tag = readU16(tableStart + index * 12)
            if tag == 34853 { return data } // already geotagged
            entries.append((tag, data.subdata(in: recordStart..<recordStart + 12)))
        }
        let nextIFDOffset = readU32(tableStart + entryCount * 12)

        // GPS IFD is appended first, then the rebuilt IFD0. Word-align both.
        let fields = gpsFields(latitude: latitude, longitude: longitude, altitude: altitude, timestamp: timestamp)
        let gpsOffset = (data.count + 1) & ~1
        let gpsTableSize = 2 + fields.count * 12 + 4
        let gpsValueBase = gpsOffset + gpsTableSize
        var gpsTable = Data()
        var gpsSpill = Data()
        gpsTable.append(contentsOf: u16(UInt16(fields.count)))
        for field in fields {
            gpsTable.append(contentsOf: u16(field.tag))
            gpsTable.append(contentsOf: u16(field.type))
            gpsTable.append(contentsOf: u32(field.count))
            switch field.value {
            case .bytes(let bytes) where bytes.count <= 4:
                var inline = Array(bytes)
                while inline.count < 4 { inline.append(0) }
                gpsTable.append(contentsOf: inline)
            case .bytes(let bytes):
                gpsTable.append(contentsOf: u32(UInt32(gpsValueBase + gpsSpill.count)))
                gpsSpill.append(bytes)
                if gpsSpill.count % 2 == 1 { gpsSpill.append(0) }
            case .rationals(let rationals):
                gpsTable.append(contentsOf: u32(UInt32(gpsValueBase + gpsSpill.count)))
                for (numerator, denominator) in rationals {
                    gpsSpill.append(contentsOf: u32(numerator))
                    gpsSpill.append(contentsOf: u32(denominator))
                }
            }
        }
        gpsTable.append(contentsOf: u32(0)) // no next IFD

        let ifd0PrimeOffset = (gpsOffset + gpsTable.count + gpsSpill.count + 1) & ~1
        var pointerRecord = Data()
        pointerRecord.append(contentsOf: u16(34853))
        pointerRecord.append(contentsOf: u16(4))              // LONG
        pointerRecord.append(contentsOf: u32(1))              // count
        pointerRecord.append(contentsOf: u32(UInt32(gpsOffset))) // inline value
        var merged = entries
        merged.append((34853, pointerRecord))
        merged.sort { $0.tag < $1.tag } // TIFF requires ascending tag order
        var ifd0Prime = Data()
        ifd0Prime.append(contentsOf: u16(UInt16(merged.count)))
        for entry in merged { ifd0Prime.append(entry.record) }
        ifd0Prime.append(contentsOf: u32(nextIFDOffset))

        var output = Data(data)
        let headerPatch = u32(UInt32(ifd0PrimeOffset))
        for offset in 0..<4 { output[output.startIndex + 4 + offset] = headerPatch[offset] }
        while output.count < gpsOffset { output.append(0) }
        output.append(gpsTable)
        output.append(gpsSpill)
        while output.count < ifd0PrimeOffset { output.append(0) }
        output.append(ifd0Prime)
        return output
    }

    // MARK: Orientation (tag 274) byte-level editing

    /// Geometry of IFD0 and its Orientation entry (if any), shared by the
    /// orientation getter/setter. nil when the container can't be parsed.
    private struct IFD0Scan {
        let bigEndian: Bool
        let tableStart: Int
        let entryCount: Int
        /// Byte offset of the existing tag-274 entry record, with its type
        /// and count; nil when IFD0 carries no Orientation tag.
        let orientationEntry: (offset: Int, type: UInt16, count: UInt32)?
        let nextIFDOffset: UInt32
    }

    private static func tiffReadU16(_ data: Data, _ offset: Int, bigEndian: Bool) -> UInt16 {
        let base = data.startIndex + offset
        let first = UInt16(data[base]); let second = UInt16(data[base + 1])
        return bigEndian ? (first << 8) | second : (second << 8) | first
    }

    private static func tiffReadU32(_ data: Data, _ offset: Int, bigEndian: Bool) -> UInt32 {
        let base = data.startIndex + offset
        let bytes = (0..<4).map { UInt32(data[base + $0]) }
        return bigEndian
            ? (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]
            : (bytes[3] << 24) | (bytes[2] << 16) | (bytes[1] << 8) | bytes[0]
    }

    private static func tiffBytes(_ value: UInt16, bigEndian: Bool) -> [UInt8] {
        let bytes: [UInt8] = [UInt8(value >> 8), UInt8(value & 0xFF)]
        return bigEndian ? bytes : bytes.reversed()
    }

    private static func tiffBytes(_ value: UInt32, bigEndian: Bool) -> [UInt8] {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ]
        return bigEndian ? bytes : bytes.reversed()
    }

    private static func scanIFD0(_ data: Data) -> IFD0Scan? {
        guard data.count >= 8 else { return nil }
        let bigEndian: Bool
        switch (data[data.startIndex], data[data.startIndex + 1]) {
        case (0x49, 0x49): bigEndian = false
        case (0x4D, 0x4D): bigEndian = true
        default: return nil
        }
        guard tiffReadU16(data, 2, bigEndian: bigEndian) == 42 else { return nil }
        let ifd0Offset = Int(tiffReadU32(data, 4, bigEndian: bigEndian))
        guard ifd0Offset >= 8, ifd0Offset + 2 <= data.count else { return nil }
        let entryCount = Int(tiffReadU16(data, ifd0Offset, bigEndian: bigEndian))
        let tableStart = ifd0Offset + 2
        guard tableStart + entryCount * 12 + 4 <= data.count else { return nil }
        var orientationEntry: (offset: Int, type: UInt16, count: UInt32)?
        for index in 0..<entryCount {
            let entryOffset = tableStart + index * 12
            guard tiffReadU16(data, entryOffset, bigEndian: bigEndian) == 274 else { continue }
            orientationEntry = (
                offset: entryOffset,
                type: tiffReadU16(data, entryOffset + 2, bigEndian: bigEndian),
                count: tiffReadU32(data, entryOffset + 4, bigEndian: bigEndian))
            break
        }
        return IFD0Scan(
            bigEndian: bigEndian,
            tableStart: tableStart,
            entryCount: entryCount,
            orientationEntry: orientationEntry,
            nextIFDOffset: tiffReadU32(data, tableStart + entryCount * 12, bigEndian: bigEndian))
    }

    /// The IFD0 Orientation (EXIF/TIFF tag 274) of an encoded DNG/TIFF —
    /// 1 ("up") when the tag is absent or the container can't be parsed,
    /// matching the TIFF default.
    public static func dngOrientation(in data: Data) -> UInt16 {
        guard let scan = scanIFD0(data),
              let entry = scan.orientationEntry,
              entry.count == 1
        else { return 1 }
        switch entry.type {
        case 3: return tiffReadU16(data, entry.offset + 8, bigEndian: scan.bigEndian)
        case 4: return UInt16(clamping: tiffReadU32(data, entry.offset + 8, bigEndian: scan.bigEndian))
        default: return 1
        }
    }

    /// Returns a copy of `data` with IFD0 Orientation (tag 274) set, without
    /// touching pixel data — the metadata-only rotate for both Apple
    /// pass-through originals and app-authored DNGs.
    ///
    /// When the tag already exists as an inline SHORT/LONG, its value bytes
    /// are overwritten in place (file size unchanged; TIFF 6 stores sub-4-byte
    /// values left-justified in the entry's value field, in file byte order).
    /// Otherwise IFD0 is rebuilt append-only the same way `dngByInsertingGPS`
    /// works: entry records copied verbatim, the new record merged in
    /// ascending tag order, the rebuilt table appended at word-aligned EOF and
    /// the TIFF header repointed — every existing offset stays valid. Unlike
    /// the GPS injector this throws on unparseable input: a user-initiated
    /// rotate must surface failure rather than silently no-op.
    public static func dngBySettingOrientation(_ data: Data, to orientation: UInt16) throws -> Data {
        guard let scan = scanIFD0(data) else {
            throw DNGError.malformedDNG("unparseable TIFF header or IFD0")
        }

        if let entry = scan.orientationEntry, entry.count == 1, entry.type == 3 || entry.type == 4 {
            var output = Data(data)
            let valueBytes = entry.type == 3
                ? tiffBytes(orientation, bigEndian: scan.bigEndian)
                : tiffBytes(UInt32(orientation), bigEndian: scan.bigEndian)
            for (index, byte) in valueBytes.enumerated() {
                output[output.startIndex + entry.offset + 8 + index] = byte
            }
            return output
        }

        // Absent (app-authored files before orientation support) or an exotic
        // shape: rebuild IFD0 without any old 274 record and append.
        var entries: [(tag: UInt16, record: Data)] = []
        entries.reserveCapacity(scan.entryCount + 1)
        for index in 0..<scan.entryCount {
            let recordStart = data.startIndex + scan.tableStart + index * 12
            let tag = tiffReadU16(data, scan.tableStart + index * 12, bigEndian: scan.bigEndian)
            if tag == 274 { continue }
            entries.append((tag, data.subdata(in: recordStart..<recordStart + 12)))
        }
        var orientationRecord = Data()
        orientationRecord.append(contentsOf: tiffBytes(UInt16(274), bigEndian: scan.bigEndian))
        orientationRecord.append(contentsOf: tiffBytes(UInt16(3), bigEndian: scan.bigEndian)) // SHORT
        orientationRecord.append(contentsOf: tiffBytes(UInt32(1), bigEndian: scan.bigEndian)) // count
        orientationRecord.append(contentsOf: tiffBytes(orientation, bigEndian: scan.bigEndian))
        orientationRecord.append(contentsOf: [0, 0]) // inline value padding
        entries.append((274, orientationRecord))
        entries.sort { $0.tag < $1.tag } // TIFF requires ascending tag order

        let ifd0PrimeOffset = (data.count + 1) & ~1
        var ifd0Prime = Data()
        ifd0Prime.append(contentsOf: tiffBytes(UInt16(entries.count), bigEndian: scan.bigEndian))
        for entry in entries { ifd0Prime.append(entry.record) }
        ifd0Prime.append(contentsOf: tiffBytes(scan.nextIFDOffset, bigEndian: scan.bigEndian))

        var output = Data(data)
        let headerPatch = tiffBytes(UInt32(ifd0PrimeOffset), bigEndian: scan.bigEndian)
        for offset in 0..<4 { output[output.startIndex + 4 + offset] = headerPatch[offset] }
        while output.count < ifd0PrimeOffset { output.append(0) }
        output.append(ifd0Prime)
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

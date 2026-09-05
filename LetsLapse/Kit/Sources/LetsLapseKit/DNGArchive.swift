import Foundation

/// A DNG 1.4 / 1.7 container writer for **tiled payloads from any codec** —
/// lossless JPEG, JPEG XL, 8-bit lossy JPEG or none — over either a Bayer
/// mosaic (CFA) or demosaiced LinearRaw samples.
///
/// `DNGAuthor` writes the two shapes the capture pipeline needs and owns
/// their tag sets. This is the general form the archive-conversion spike
/// (`docs/dng-archive-spike-brief.md`) needs: the caller decides geometry,
/// codec, bit depth, levels and the curve the samples were stored through,
/// and this assembles a container that Apple's decoder, Adobe's and the
/// Kit's own readers agree on.
///
/// Two rules come from measurement, not taste:
///
/// - **No `MapPolynomial` with a non-zero black level.** Apple's decoder
///   mishandles `BlackLevel` whenever OpcodeList2 carries polynomials and
///   wraps negative polynomial output to bright (`LossyLinearDNG`). A curve
///   is therefore carried as a `LinearizationTable` (stage 1 of the DNG
///   pipeline, DNG 1.0, handled by every reader), or as a polynomial over a
///   zero black level and non-negative coefficients — never both a
///   polynomial and a pedestal.
/// - **Uniform black level.** One value for every plane keeps the file in the
///   shape Adobe's own linear-lossless output has, which Apple demonstrably
///   renders right.
public enum DNGArchive {

    // MARK: - Vocabulary

    public enum Photometric: Equatable {
        /// A Bayer mosaic. `pattern` is row-major over `rows × columns`
        /// with DNG's plane indices (0 = red, 1 = green, 2 = blue).
        case cfa(pattern: [UInt8], rows: Int, columns: Int)
        /// Demosaiced three-sample data in the declared camera space.
        case linearRaw

        var tag: UInt16 {
            switch self {
            case .cfa: return 32803
            case .linearRaw: return 34892
            }
        }
    }

    public enum Compression: Equatable {
        /// Uncompressed tiles (little-endian samples).
        case none
        /// ITU-T T.81 process 14, Compression 7 — `LosslessJPEG`.
        case losslessJPEG
        /// 8-bit baseline DCT JPEG tiles, Compression 34892 (DNG 1.4).
        case lossyJPEG
        /// Bare JPEG XL codestreams, Compression 52546 (DNG 1.7). The three
        /// values are recorded in the raw IFD as JXLDistance / JXLEffort /
        /// JXLDecodeSpeed, as Adobe does.
        case jpegXL(distance: Float, effort: Int, decodeSpeed: Int)

        var tag: UInt16 {
            switch self {
            case .none: return 1
            case .losslessJPEG: return 7
            case .lossyJPEG: return 34892
            case .jpegXL: return 52546
            }
        }

        /// DNGVersion / DNGBackwardVersion the container must declare: a
        /// JPEG XL payload needs a 1.7 reader, everything else reads back to
        /// 1.1 (lossy JPEG tiles were introduced in 1.4, and a pre-1.4
        /// reader that meets them fails on the compression value anyway).
        var version: [UInt8] {
            switch self {
            case .jpegXL: return [1, 7, 0, 0]
            default: return [1, 4, 0, 0]
            }
        }

        var backwardVersion: [UInt8] {
            switch self {
            case .jpegXL: return [1, 7, 0, 0]
            case .lossyJPEG: return [1, 4, 0, 0]
            default: return [1, 1, 0, 0]
            }
        }
    }

    /// Stage-1 and stage-2 constants of the DNG pipeline for the stored
    /// samples.
    public struct Levels: Equatable {
        /// Black level in *linearized* sample units — after the
        /// `linearizationTable`, before any polynomial. One value (uniform)
        /// or one per sample.
        public var black: [Double]
        /// White level in the same units. One value or one per sample.
        public var white: [UInt32]
        /// Stored value → linearized value (tag 50712). Indexed by stored
        /// sample; values past the end clamp to the last entry.
        public var linearizationTable: [UInt16]?
        /// Per-plane `MapPolynomial` coefficients `c0…cN` written as
        /// OpcodeList2, applied to `(linearized − black) / (white − black)`.
        /// Only sensible with `black == 0` — see the type comment.
        public var mapPolynomials: [[Double]]?

        public init(black: [Double], white: [UInt32], linearizationTable: [UInt16]? = nil, mapPolynomials: [[Double]]? = nil) {
            self.black = black
            self.white = white
            self.linearizationTable = linearizationTable
            self.mapPolynomials = mapPolynomials
        }

        public static func uniform(black: Double, white: UInt32) -> Levels {
            Levels(black: [black], white: [white])
        }
    }

    public struct Image {
        public var width: Int
        public var height: Int
        public var samplesPerPixel: Int
        public var bitsPerSample: Int
        public var photometric: Photometric
        public var compression: Compression
        public var tileWidth: Int
        public var tileHeight: Int
        /// Row-major, `tilesAcross × tilesDown` complete codestreams (or raw
        /// little-endian samples for `.none`). Edge tiles are stored at the
        /// full tile size, as the DNG specification requires.
        public var tiles: [Data]
        public var levels: Levels

        public init(
            width: Int, height: Int, samplesPerPixel: Int, bitsPerSample: Int,
            photometric: Photometric, compression: Compression,
            tileWidth: Int, tileHeight: Int, tiles: [Data], levels: Levels
        ) {
            self.width = width
            self.height = height
            self.samplesPerPixel = samplesPerPixel
            self.bitsPerSample = bitsPerSample
            self.photometric = photometric
            self.compression = compression
            self.tileWidth = tileWidth
            self.tileHeight = tileHeight
            self.tiles = tiles
            self.levels = levels
        }

        public var tilesAcross: Int { (width + tileWidth - 1) / tileWidth }
        public var tilesDown: Int { (height + tileHeight - 1) / tileHeight }
    }

    public struct Metadata {
        /// IFD0 tags carried verbatim: colour matrices, calibration, as-shot
        /// neutral, camera identity, profile tables, baseline exposure, lens
        /// info. Structural, pointer, version and digest tags are filtered
        /// out here; the writer owns those.
        public var ifd0: [DNGTagValue] = []
        /// Raw-IFD tags carried verbatim (NoiseProfile, BestQualityScale,
        /// AntiAliasStrength…). Levels, CFA geometry, opcode lists and codec
        /// tags are filtered out; `Image` and `Levels` own those.
        public var raw: [DNGTagValue] = []
        public var exif: [DNGTagValue] = []
        public var gps: [DNGTagValue] = []
        public var preview: DNGAuthor.Preview?
        public var software = "LetsLapse"
        public var orientation: UInt16? = 1
        /// `DefaultCropOrigin` / `DefaultCropSize`, in pixels.
        public var defaultCropOrigin: [Double]?
        public var defaultCropSize: [Double]?
        public var originalRawFileName: String?
        /// Used when `ifd0` carries no UniqueCameraModel (the tag is mandatory).
        public var fallbackUniqueCameraModel = "LetsLapse"
        /// OpcodeList1/2/3 (51008/51009/51022) to write on the raw IFD, when the
        /// caller knows they still describe this image (same geometry, same
        /// stored values). `Levels.mapPolynomials` writes list 2 itself and wins.
        public var opcodeLists: [UInt16: Data] = [:]

        public init() {}
    }

    public enum WriteError: Error, CustomStringConvertible {
        case geometry(String)
        case levels(String)
        case tags(String)

        public var description: String {
            switch self {
            case .geometry(let why): return "DNG geometry: \(why)"
            case .levels(let why): return "DNG levels: \(why)"
            case .tags(let why): return "DNG tags: \(why)"
            }
        }
    }

    // MARK: - Validation

    /// Structural checks a DNG reader (Adobe's above all) applies before it
    /// will open a file. Returns the problems, empty when the container is
    /// sound. Run on every write, and usable on any file.
    public static func validate(_ data: Data) -> [String] {
        var issues: [String] = []
        let directories: DNGDocument.Directories
        do {
            directories = try DNGDocument.parseDirectories(data)
        } catch {
            return ["not a readable TIFF: \(error)"]
        }
        let candidates = [directories.ifd0] + directories.subIFDs
        guard let raw = candidates.first(where: { ($0.int(254) ?? 0) == 0 && [32803, 34892].contains($0.int(262) ?? -1) }) else {
            return ["no raw image directory (NewSubfileType 0 with CFA or LinearRaw photometric)"]
        }
        let photometric = raw.int(262) ?? 0
        let width = raw.int(256) ?? 0, height = raw.int(257) ?? 0
        let spp = raw.int(277) ?? 1
        let bits = raw.tag(258)?.ints ?? []
        if width <= 0 || height <= 0 { issues.append("image size \(width)×\(height)") }
        if bits.count != spp { issues.append("BitsPerSample has \(bits.count) entries for \(spp) samples") }
        if photometric == 32803 {
            if spp != 1 { issues.append("CFA image with \(spp) samples per pixel") }
            if raw.tag(33422) == nil || raw.tag(33421) == nil { issues.append("CFA image without CFAPattern/CFARepeatPatternDim") }
        } else {
            for tag: UInt16 in [33421, 33422, 50710, 50711] where raw.tag(tag) != nil {
                issues.append("CFA tag \(tag) on a LinearRaw image")
            }
            if spp != 3 { issues.append("LinearRaw with \(spp) samples per pixel") }
        }
        let blacks = raw.doubles(50714), whites = raw.doubles(50717)
        if !blacks.isEmpty, blacks.count != 1, blacks.count != spp {
            let repeatDim = raw.tag(50713)?.ints ?? [1, 1]
            if blacks.count != repeatDim.reduce(1, *) * spp { issues.append("BlackLevel has \(blacks.count) values for \(spp) samples") }
        }
        if !whites.isEmpty, whites.count != 1, whites.count != spp { issues.append("WhiteLevel has \(whites.count) values for \(spp) samples") }
        if let table = raw.tag(50712), table.count > (1 << (bits.first ?? 16)) {
            issues.append("LinearizationTable has \(table.count) entries for \(bits.first ?? 16)-bit samples")
        }
        var activeTop = 0, activeLeft = 0, activeBottom = height, activeRight = width
        let active = raw.tag(50829)?.ints ?? []
        if active.count == 4 {
            activeTop = active[0]; activeLeft = active[1]; activeBottom = active[2]; activeRight = active[3]
            if activeTop < 0 || activeLeft < 0 || activeBottom > height || activeRight > width || activeBottom <= activeTop || activeRight <= activeLeft {
                issues.append("ActiveArea \(active) outside the \(width)×\(height) image")
            }
        } else if !active.isEmpty {
            issues.append("ActiveArea has \(active.count) values")
        }
        let cropOrigin = raw.doubles(50719), cropSize = raw.doubles(50720)
        if cropOrigin.count == 2, cropSize.count == 2 {
            if cropOrigin[0] + cropSize[0] > Double(activeRight - activeLeft) + 0.5 || cropOrigin[1] + cropSize[1] > Double(activeBottom - activeTop) + 0.5 {
                issues.append("DefaultCrop \(cropOrigin)+\(cropSize) exceeds the active area \(activeRight - activeLeft)×\(activeBottom - activeTop)")
            }
        }
        let compression = raw.int(259) ?? 1
        let jxlTags: [UInt16] = [52553, 52554, 52555]
        if compression != 52546, jxlTags.contains(where: { raw.tag($0) != nil }) { issues.append("JXL tags on a non-JPEG-XL image") }
        if compression == 52546 || compression == 7 || compression == 34892 {
            if let tileWidth = raw.int(322), let tileHeight = raw.int(323) {
                let across = (width + tileWidth - 1) / tileWidth, down = (height + tileHeight - 1) / tileHeight
                let offsets = raw.tag(324)?.ints ?? [], counts = raw.tag(325)?.ints ?? []
                if offsets.count != across * down || counts.count != offsets.count {
                    issues.append("tile table has \(offsets.count)/\(counts.count) entries for \(across)×\(down) tiles")
                }
                for (offset, count) in zip(offsets, counts) where offset < 8 || count <= 0 || offset + count > data.count {
                    issues.append("tile at \(offset)+\(count) lies outside the \(data.count)-byte file")
                    break
                }
            } else if raw.tag(273) == nil {
                issues.append("compressed image with neither tiles nor strips")
            }
        }
        for tag: UInt16 in [50706, 50708, 50721] where directories.ifd0.tag(tag) == nil {
            issues.append("IFD0 lacks required tag \(tag)")
        }
        let version = directories.ifd0.tag(50706)?.ints ?? []
        if compression == 52546, version.count == 4, (version[0], version[1]) < (1, 7) { issues.append("JPEG XL payload with DNGVersion \(version)") }
        return issues
    }

    // MARK: - Writing

    public static func write(image: Image, metadata: Metadata, to url: URL) throws {
        let data = try makeDNG(image: image, metadata: metadata)
        let issues = validate(data)
        guard issues.isEmpty else { throw WriteError.tags("invalid DNG: " + issues.joined(separator: "; ")) }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw DNGError.writeFailed(error.localizedDescription)
        }
    }

    /// The whole container in memory.
    public static func makeDNG(image: Image, metadata: Metadata) throws -> Data {
        try validate(image)

        let rawIFD = IFDBuilder()
        rawIFD.addLong(254, 0)
        rawIFD.addLong(256, UInt32(image.width))
        rawIFD.addLong(257, UInt32(image.height))
        rawIFD.addShorts(258, Array(repeating: UInt16(image.bitsPerSample), count: image.samplesPerPixel))
        rawIFD.addShorts(259, [image.compression.tag])
        rawIFD.addShorts(262, [image.photometric.tag])
        rawIFD.addShorts(277, [UInt16(image.samplesPerPixel)])
        rawIFD.addShorts(284, [1])
        rawIFD.addLong(322, UInt32(image.tileWidth))
        rawIFD.addLong(323, UInt32(image.tileHeight))
        rawIFD.addLongs(324, [UInt32](repeating: 0, count: image.tiles.count)) // patched
        rawIFD.addLongs(325, image.tiles.map { UInt32($0.count) })

        if case .cfa(let pattern, let rows, let columns) = image.photometric {
            var dims = Data()
            dims.appendU16(UInt16(rows))
            dims.appendU16(UInt16(columns))
            rawIFD.add(DNGTagValue(tag: 33421, type: 3, count: 2, payload: dims))
            rawIFD.add(DNGTagValue(tag: 33422, type: 1, count: UInt32(pattern.count), payload: Data(pattern)))
            rawIFD.add(DNGTagValue(tag: 50710, type: 1, count: 3, payload: Data([0, 1, 2])))
            rawIFD.addShorts(50711, [1])
        }

        // Levels.
        if let table = image.levels.linearizationTable {
            var payload = Data(capacity: table.count * 2)
            for value in table { payload.appendU16(value) }
            rawIFD.add(DNGTagValue(tag: 50712, type: 3, count: UInt32(table.count), payload: payload))
        }
        rawIFD.addShorts(50713, [1, 1])
        // One level per sample, always. Apple's decoder misapplies a
        // single-value BlackLevel on a three-sample LinearRaw image (measured
        // 2026-09-05: a 2048 pedestal written once rendered a dusk frame with
        // green ×1.6, blue ×2.2, red ×3.8; written three times it rendered
        // within 0.5% of the source), so the tag is expanded here rather than
        // left to the caller.
        var blacks = image.levels.black, whites = image.levels.white
        if blacks.count == 1, image.samplesPerPixel > 1 { blacks = Array(repeating: blacks[0], count: image.samplesPerPixel) }
        if whites.count == 1, image.samplesPerPixel > 1 { whites = Array(repeating: whites[0], count: image.samplesPerPixel) }
        var black = Data()
        for value in blacks {
            let (numerator, denominator) = rational(value)
            black.appendU32(numerator)
            black.appendU32(denominator)
        }
        rawIFD.add(DNGTagValue(tag: 50714, type: 5, count: UInt32(blacks.count), payload: black))
        rawIFD.addLongs(50717, whites)
        if let polynomials = image.levels.mapPolynomials {
            let list = opcodeList2(mapPolynomials: polynomials, width: image.width, height: image.height)
            rawIFD.add(DNGTagValue(tag: 51009, type: 7, count: UInt32(list.count), payload: list))
        }
        for (tag, list) in metadata.opcodeLists where [51008, 51009, 51022].contains(tag) && !list.isEmpty {
            rawIFD.add(DNGTagValue(tag: tag, type: 7, count: UInt32(list.count), payload: list))
        }

        // Crop and scale.
        var defaultScale = Data()
        for _ in 0..<2 { defaultScale.appendU32(1); defaultScale.appendU32(1) }
        rawIFD.add(DNGTagValue(tag: 50718, type: 5, count: 2, payload: defaultScale))
        if let origin = metadata.defaultCropOrigin, origin.count == 2 {
            rawIFD.add(DNGTagValue(tag: 50719, type: 5, count: 2, payload: rationals(origin)))
        }
        if let size = metadata.defaultCropSize, size.count == 2 {
            rawIFD.add(DNGTagValue(tag: 50720, type: 5, count: 2, payload: rationals(size)))
        }

        // Codec tags.
        if case .jpegXL(let distance, let effort, let decodeSpeed) = image.compression {
            var distancePayload = Data()
            distancePayload.appendU32(distance.bitPattern)
            rawIFD.add(DNGTagValue(tag: 52553, type: 11, count: 1, payload: distancePayload))
            rawIFD.addLong(52554, UInt32(max(1, min(10, effort))))
            rawIFD.addLong(52555, UInt32(max(0, min(4, decodeSpeed))))
        }

        for entry in metadata.raw where !ownedRawTags.contains(entry.tag) && !pointerTags.contains(entry.tag) {
            rawIFD.add(entry)
        }

        // IFD0 — the preview when there is one, else the raw image itself.
        let ifd0 = IFDBuilder()
        let hasPreview = metadata.preview != nil
        if let preview = metadata.preview {
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
        } else {
            for entry in rawIFD.sorted { ifd0.add(entry) }
        }

        ifd0.add(DNGTagValue(tag: 50706, type: 1, count: 4, payload: Data(image.compression.version)))
        ifd0.add(DNGTagValue(tag: 50707, type: 1, count: 4, payload: Data(image.compression.backwardVersion)))
        if let orientation = metadata.orientation {
            ifd0.addShorts(274, [orientation])
        }
        ifd0.add(ascii(305, metadata.software))
        if let name = metadata.originalRawFileName {
            ifd0.add(ascii(50827, name))
        }
        for entry in metadata.ifd0 where !ownedIFD0Tags.contains(entry.tag) && !ownedRawTags.contains(entry.tag) && !pointerTags.contains(entry.tag) {
            ifd0.add(entry)
        }
        if !ifd0.contains(50708) {
            ifd0.add(ascii(50708, metadata.fallbackUniqueCameraModel))
        }
        let hasExif = !metadata.exif.isEmpty
        let exifIFD = IFDBuilder()
        for entry in metadata.exif where !pointerTags.contains(entry.tag) { exifIFD.add(entry) }
        if hasExif { ifd0.addLong(34665, 0) }
        let hasGPS = !metadata.gps.isEmpty
        let gpsIFD = IFDBuilder()
        for entry in metadata.gps { gpsIFD.add(entry) }
        if hasGPS { ifd0.addLong(34853, 0) }

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
        var cursor = ((previewStrip + (metadata.preview?.rgb.count ?? 0)) + 1) & ~1
        var tileOffsets: [UInt32] = []
        tileOffsets.reserveCapacity(image.tiles.count)
        for tile in image.tiles {
            tileOffsets.append(UInt32(cursor))
            cursor += tile.count
            cursor = (cursor + 1) & ~1
        }
        (hasPreview ? rawIFD : ifd0).addLongs(324, tileOffsets)
        if hasPreview {
            ifd0.patchLong(273, UInt32(previewStrip))
            ifd0.patchLong(330, UInt32(rawTable))
        }
        if hasExif { ifd0.patchLong(34665, UInt32(exifTable)) }
        if hasGPS { ifd0.patchLong(34853, UInt32(gpsTable)) }

        var output = Data(capacity: cursor)
        output.append(contentsOf: [0x49, 0x49, 42, 0])
        output.appendU32(UInt32(ifd0Table))
        output.append(ifd0.serialize(tableOffset: ifd0Table))
        if hasExif { output.append(exifIFD.serialize(tableOffset: exifTable)) }
        if hasGPS { output.append(gpsIFD.serialize(tableOffset: gpsTable)) }
        if hasPreview { output.append(rawIFD.serialize(tableOffset: rawTable)) }
        while output.count < previewStrip { output.append(0) }
        if let preview = metadata.preview { output.append(preview.rgb) }
        for (index, tile) in image.tiles.enumerated() {
            while output.count < Int(tileOffsets[index]) { output.append(0) }
            output.append(tile)
        }
        return output
    }

    // MARK: - Helpers for callers

    /// The colour tag set for LinearRaw samples in **linear sRGB / Rec. 709
    /// primaries (D65)** — what a converter that has already rendered the
    /// raw through its own profile can honestly declare. Same matrix
    /// `DNGAuthor.writeLinearDNG` uses.
    public static func sRGBColorTags() -> [DNGTagValue] {
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
        var neutral = Data()
        for _ in 0..<3 { neutral.appendU32(1); neutral.appendU32(1) }
        var illuminant = Data()
        illuminant.appendU16(21)
        return [
            DNGTagValue(tag: 50721, type: 10, count: 9, payload: matrixPayload),
            DNGTagValue(tag: 50728, type: 5, count: 3, payload: neutral),
            DNGTagValue(tag: 50778, type: 3, count: 1, payload: illuminant),
        ]
    }

    /// Camera colour and identity tags worth carrying from a source DNG's
    /// IFD0 into an archive of it: everything a raw developer reads to
    /// render the file, minus the structural, preview and digest tags that
    /// describe the *old* container.
    public static func carriedIFD0Tags(from ifd0: [DNGTagValue]) -> [DNGTagValue] {
        // A single-IFD source (Apple's camera DNGs) keeps its raw geometry —
        // CFA pattern, ActiveArea, levels, opcode lists, crop — in IFD0 too;
        // none of it may follow the colour tags onto a new image. That leak
        // put CFAPattern and an oversize ActiveArea on a LinearRaw archive and
        // Adobe refused every frame (2026-09-05).
        ifd0.filter {
            !ownedIFD0Tags.contains($0.tag) && !ownedRawTags.contains($0.tag)
                && !pointerTags.contains($0.tag) && !previewOnlyTags.contains($0.tag)
        }
    }

    /// Raw-IFD tags worth carrying (NoiseProfile and the quality hints).
    public static func carriedRawTags(from raw: [DNGTagValue]) -> [DNGTagValue] {
        raw.filter { carriedRawWhitelist.contains($0.tag) }
    }

    /// A signed-rational tag (SRATIONAL, type 10) from doubles at 1/10000.
    public static func srationalTag(_ tag: UInt16, _ values: [Double]) -> DNGTagValue {
        var payload = Data()
        for value in values {
            payload.appendU32(UInt32(bitPattern: Int32((value * 10000).rounded())))
            payload.appendU32(10000)
        }
        return DNGTagValue(tag: tag, type: 10, count: UInt32(values.count), payload: payload)
    }

    /// An unsigned-rational tag (RATIONAL, type 5) from doubles.
    public static func rationalTag(_ tag: UInt16, _ values: [Double]) -> DNGTagValue {
        DNGTagValue(tag: tag, type: 5, count: UInt32(values.count), payload: rationals(values))
    }

    public static func shortTag(_ tag: UInt16, _ values: [UInt16]) -> DNGTagValue {
        var payload = Data()
        for value in values { payload.appendU16(value) }
        return DNGTagValue(tag: tag, type: 3, count: UInt32(values.count), payload: payload)
    }

    public static func doubleTag(_ tag: UInt16, _ values: [Double]) -> DNGTagValue {
        var payload = Data()
        for value in values {
            let bits = value.bitPattern
            payload.appendU32(UInt32(truncatingIfNeeded: bits))
            payload.appendU32(UInt32(truncatingIfNeeded: bits >> 32))
        }
        return DNGTagValue(tag: tag, type: 12, count: UInt32(values.count), payload: payload)
    }

    public static func asciiTag(_ tag: UInt16, _ text: String) -> DNGTagValue { ascii(tag, text) }

    /// Big-endian OpcodeList2 made of one full-frame `MapPolynomial` per plane.
    public static func opcodeList2(mapPolynomials: [[Double]], width: Int, height: Int) -> Data {
        var blob = Data()
        func u32(_ v: UInt32) { blob.append(contentsOf: withUnsafeBytes(of: v.bigEndian, Array.init)) }
        func f64(_ v: Double) { blob.append(contentsOf: withUnsafeBytes(of: v.bitPattern.bigEndian, Array.init)) }
        u32(UInt32(mapPolynomials.count))
        for (plane, coefficients) in mapPolynomials.enumerated() {
            let degree = max(0, coefficients.count - 1)
            u32(8)                 // MapPolynomial
            u32(0x0103_0000)       // DNG 1.3
            u32(0)                 // flags: mandatory
            u32(UInt32(36 + 8 * (degree + 1)))
            u32(0); u32(0); u32(UInt32(height)); u32(UInt32(width))
            u32(UInt32(plane)); u32(1); u32(1); u32(1)
            u32(UInt32(degree))
            for c in coefficients { f64(c) }
        }
        return blob
    }

    // MARK: - Internals

    private static func validate(_ image: Image) throws {
        guard image.width > 0, image.height > 0 else { throw WriteError.geometry("empty image") }
        guard image.tileWidth > 0, image.tileHeight > 0 else { throw WriteError.geometry("empty tile") }
        guard image.tiles.count == image.tilesAcross * image.tilesDown else {
            throw WriteError.geometry("\(image.tiles.count) tiles for \(image.tilesAcross)×\(image.tilesDown)")
        }
        switch image.photometric {
        case .cfa(let pattern, let rows, let columns):
            guard image.samplesPerPixel == 1 else { throw WriteError.geometry("CFA needs one sample per pixel") }
            guard pattern.count == rows * columns, rows > 0, columns > 0 else { throw WriteError.geometry("CFA pattern \(pattern) is not \(rows)×\(columns)") }
        case .linearRaw:
            guard image.samplesPerPixel == 3 else { throw WriteError.geometry("LinearRaw here means three samples per pixel") }
        }
        guard [8, 16].contains(image.bitsPerSample) else { throw WriteError.geometry("\(image.bitsPerSample) bits per sample") }
        if case .lossyJPEG = image.compression, image.bitsPerSample != 8 {
            throw WriteError.geometry("lossy JPEG tiles are 8-bit")
        }
        let black = image.levels.black, white = image.levels.white
        guard black.count == 1 || black.count == image.samplesPerPixel else { throw WriteError.levels("\(black.count) black levels") }
        guard white.count == 1 || white.count == image.samplesPerPixel else { throw WriteError.levels("\(white.count) white levels") }
        let whiteMax = Double(white.max() ?? 0)
        guard black.allSatisfy({ $0 >= 0 && $0 < whiteMax }) else { throw WriteError.levels("black \(black) not below white \(white)") }
        if let polynomials = image.levels.mapPolynomials {
            guard polynomials.count == image.samplesPerPixel else { throw WriteError.levels("\(polynomials.count) polynomials for \(image.samplesPerPixel) planes") }
            guard black.allSatisfy({ $0 == 0 }) else {
                throw WriteError.levels("MapPolynomial over a non-zero black level is the combination Apple's decoder renders wrong")
            }
        }
        if let table = image.levels.linearizationTable {
            guard !table.isEmpty, table.count <= (1 << image.bitsPerSample) else { throw WriteError.levels("linearization table of \(table.count) entries") }
        }
    }

    private static func rational(_ value: Double) -> (UInt32, UInt32) {
        if value == value.rounded(), value >= 0, value < 4_000_000_000 { return (UInt32(value), 1) }
        let scaled = (value * 65536).rounded()
        return (UInt32(max(0, min(4_294_967_295, scaled))), 65536)
    }

    private static func rationals(_ values: [Double]) -> Data {
        var payload = Data()
        for value in values {
            let (numerator, denominator) = rational(value)
            payload.appendU32(numerator)
            payload.appendU32(denominator)
        }
        return payload
    }

    private static func ascii(_ tag: UInt16, _ text: String) -> DNGTagValue {
        var payload = Data(text.utf8)
        payload.append(0)
        return DNGTagValue(tag: tag, type: 2, count: UInt32(payload.count), payload: payload)
    }

    /// Tags this writer emits itself for IFD0 (or drops as describing a
    /// previous container).
    private static let ownedIFD0Tags: Set<UInt16> = [
        254, 256, 257, 258, 259, 262, 273, 274, 277, 278, 279, 284, 305, 317,
        322, 323, 324, 325, 513, 514,
        50706, 50707,             // versions
        50972, 51111,             // RawImageDigest / NewRawImageDigest
    ]
    /// Tags this writer emits itself for the raw IFD.
    private static let ownedRawTags: Set<UInt16> = [
        254, 256, 257, 258, 259, 262, 273, 277, 278, 279, 284, 317, 322, 323, 324, 325,
        33421, 33422, 50710, 50711,       // CFA geometry
        50712, 50713, 50714, 50715, 50716, 50717,   // levels
        50718, 50719, 50720, 51125,       // scale, crop, user crop
        50829, 50830,                     // ActiveArea, MaskedAreas — geometry of the old image
        50733, 50734,                     // ChromaBlurRadius, AntiAliasStrength (raw-only)
        50738,                            // AntiAliasStrength
        51008, 51009, 51022,              // opcode lists
        51110,                            // NoiseReductionApplied — describes the old pixels
        52553, 52554, 52555,              // JXL
    ]
    private static let pointerTags: Set<UInt16> = [330, 34665, 34853, 40965, 700]
    /// IFD0 tags that only describe the embedded preview of the source file.
    private static let previewOnlyTags: Set<UInt16> = [
        529, 530, 531, 532,               // YCbCr / ReferenceBlackWhite
        50966, 50967, 50968, 50969, 50970, 50971, // Preview* (application, version, digest, colour space, date)
        306,                              // DateTime of the old container
    ]
    private static let carriedRawWhitelist: Set<UInt16> = [
        51041,                            // NoiseProfile
        50780,                            // BestQualityScale
        50738,                            // AntiAliasStrength
        50829,                            // ActiveArea (when geometry is unchanged, callers decide)
    ]
}

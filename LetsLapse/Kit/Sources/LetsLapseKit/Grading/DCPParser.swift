import Foundation
import simd

/// Reader for Adobe Device Color Profile (`.dcp`) files.
///
/// A DCP is a TIFF-shaped container — byte-order mark, a version word, an IFD
/// offset, then one flat IFD of Adobe's DNG-spec profile tags. Two details
/// about that shape are worth stating up front, because both will reject every
/// real file if you assume the textbook version:
///
/// 1. **The magic is not TIFF's.** Real profiles start `II` + `0x4352`
///    (`"RC"`, for RawCamera) rather than `II` + `42`. Measured across the
///    Lightroom-shipped set on this machine; a strict version-42 check matches
///    none of them. `MM`-ordered profiles are accepted for symmetry, though
///    Adobe ships little-endian.
/// 2. **ImageIO will not open it.** `CGImageSource` sniffs for an image and a
///    DCP carries none, so the tag walk here is hand-rolled `Data` reads
///    rather than the `CGImageSourceCopyPropertiesAtIndex` route
///    `ForwardMatrixDecoder` uses for DNGs.
///
/// Everything the colour path needs lives in IFD0; there is no chain to
/// follow and no sub-IFD, so the reader stops after one directory.
public enum DCPParser {
    public enum Error: Swift.Error, LocalizedError, Equatable {
        case unreadable(String)
        case notADCP
        case truncated
        case missingTag(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let why): return "The DCP could not be read: \(why)"
            case .notADCP: return "That file is not an Adobe DCP profile."
            case .truncated: return "The DCP ended in the middle of a value."
            case .missingTag(let tag): return "The DCP is missing its \(tag) tag."
            }
        }
    }

    // MARK: - Tag numbers

    /// DNG-spec tag numbers for the profile tags, as they actually appear in
    /// shipped profiles.
    ///
    /// Worth pinning down explicitly because the look-table pair and the tone
    /// curve are easy to transpose: the `0xC6Fx` block ends at
    /// `ProfileCopyright`, and the look table lives two rows further out at
    /// `0xC725`/`0xC726`. Reading `ProfileLookTableDims` from `0xC6FC` gets
    /// you the tone curve, which is a different rank of tensor and fails in a
    /// confusing place.
    enum Tag {
        static let uniqueCameraModel: UInt16 = 0xC614
        static let colorMatrix1: UInt16 = 0xC621
        static let colorMatrix2: UInt16 = 0xC622
        static let calibrationIlluminant1: UInt16 = 0xC65A
        static let calibrationIlluminant2: UInt16 = 0xC65B
        static let profileName: UInt16 = 0xC6F8
        static let hueSatMapDims: UInt16 = 0xC6F9
        static let hueSatMapData1: UInt16 = 0xC6FA
        static let hueSatMapData2: UInt16 = 0xC6FB
        static let toneCurve: UInt16 = 0xC6FC
        static let forwardMatrix1: UInt16 = 0xC714
        static let forwardMatrix2: UInt16 = 0xC715
        static let lookTableDims: UInt16 = 0xC725
        static let lookTableData: UInt16 = 0xC726
    }

    // MARK: - Parse

    public static func parse(url: URL) throws -> DCPFile {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw Error.unreadable(error.localizedDescription)
        }
        return try parse(data: data, name: url.deletingPathExtension().lastPathComponent)
    }

    /// Parses profile bytes already in memory. Separated from the URL entry
    /// point so tests can author a minimal profile without touching the disk.
    public static func parse(data: Data, name: String = "") throws -> DCPFile {
        let reader = try DCPTIFFReader(data: data)
        let entries = try reader.readIFD(at: reader.firstIFDOffset)

        func entry(_ tag: UInt16) -> DCPTIFFReader.Entry? { entries[tag] }

        // MARK: identity
        let profileName = entry(Tag.profileName).flatMap { try? reader.string($0) } ?? name
        let uniqueCameraModel = entry(Tag.uniqueCameraModel).flatMap { try? reader.string($0) } ?? ""

        // MARK: illuminants
        //
        // EXIF LightSource codes, matching `ForwardMatrixDecoder`'s table
        // exactly — the two readers describe the same tag and must not drift.
        let illuminant1 = entry(Tag.calibrationIlluminant1).flatMap { try? reader.unsignedShort($0) }
        let illuminant2 = entry(Tag.calibrationIlluminant2).flatMap { try? reader.unsignedShort($0) }
        let illuminant1K = illuminantKelvin(illuminant1) ?? 2856
        let illuminant2K = illuminantKelvin(illuminant2) ?? 6504

        // MARK: matrices
        //
        // A single-illuminant profile is legal; both slots then carry the one
        // matrix so downstream interpolation is a no-op rather than a branch.
        let fm1 = entry(Tag.forwardMatrix1).flatMap { try? reader.matrix3x3($0) }
        let fm2 = entry(Tag.forwardMatrix2).flatMap { try? reader.matrix3x3($0) }
        let cm1 = entry(Tag.colorMatrix1).flatMap { try? reader.matrix3x3($0) }
        let cm2 = entry(Tag.colorMatrix2).flatMap { try? reader.matrix3x3($0) }

        // MARK: tables
        let hueSatMapDims = try entry(Tag.hueSatMapDims).flatMap { try reader.dims($0) }
        let hueSatMapData1 = try entry(Tag.hueSatMapData1).map { try reader.floatTriples($0) } ?? []
        let hueSatMapData2 = try entry(Tag.hueSatMapData2).map { try reader.floatTriples($0) } ?? []
        let lookTableDims = try entry(Tag.lookTableDims).flatMap { try reader.dims($0) }
        let lookTableData = try entry(Tag.lookTableData).map { try reader.floatTriples($0) } ?? []

        // MARK: tone curve
        //
        // Stored as a flat run of (input, output) pairs. Apple's profiles ship
        // without one — every iPhone DCP in the Lightroom set omits 0xC6FC —
        // so an empty curve is the normal case, not a parse failure.
        let toneCurve = try entry(Tag.toneCurve).map { try reader.floatPairs($0) } ?? []

        return DCPFile(
            profileName: profileName,
            uniqueCameraModel: uniqueCameraModel,
            forwardMatrix1: fm1 ?? fm2 ?? matrix_identity_float3x3,
            forwardMatrix2: fm2 ?? fm1 ?? matrix_identity_float3x3,
            hasForwardMatrices: fm1 != nil || fm2 != nil,
            colorMatrix1: cm1 ?? cm2 ?? matrix_identity_float3x3,
            colorMatrix2: cm2 ?? cm1 ?? matrix_identity_float3x3,
            illuminant1K: illuminant1K,
            illuminant2K: illuminant2K,
            hueSatMapDims: hueSatMapDims ?? SIMD3<Int>(0, 0, 0),
            hueSatMapData1: hueSatMapData1,
            hueSatMapData2: hueSatMapData2,
            lookTableDims: lookTableDims ?? SIMD3<Int>(0, 0, 0),
            lookTableData: lookTableData,
            toneCurve: toneCurve)
    }

    /// EXIF `LightSource` code → correlated colour temperature.
    ///
    /// The codes are easy to misremember by one — 20 is D55 and 21 is D65, not
    /// the other way around. Apple's DCPs calibrate at 17/21 (Standard A and
    /// D65), which is the pairing this table has to get right.
    static func illuminantKelvin(_ code: UInt16?) -> Float? {
        guard let code else { return nil }
        switch code {
        case 17: return 2856   // Standard light A
        case 18: return 4874   // Standard light B
        case 19: return 6774   // Standard light C
        case 20: return 5503   // D55
        case 21: return 6504   // D65
        case 22: return 7504   // D75
        case 23: return 5003   // D50
        default: return nil
        }
    }
}

// MARK: - The parsed profile

/// One Adobe camera profile, parsed.
///
/// The two table pairs do different jobs and it matters which is which:
///
/// - **`hueSatMap`** is the *calibration* table. It ships once per calibration
///   illuminant (hence `Data1`/`Data2`, interpolated by shot temperature the
///   same reciprocal way the forward matrices are) and it is applied before
///   any tone rendering.
/// - **`lookTable`** is the *look*. One table, no illuminant pair, applied
///   after the tone curve — which is precisely what makes it tone-dependent,
///   and precisely the thing no 3×3 in the existing paths can imitate.
///
/// Both are indexed the same way; see `DCPTableIndex` for the axis order,
/// which is not the order the tag name suggests.
public struct DCPFile: Sendable {
    public let profileName: String
    /// The camera this profile calibrates, e.g. `iPhone17,1 back camera` —
    /// the same string the matching DNG carries in its own `UniqueCameraModel`.
    public let uniqueCameraModel: String

    /// Camera → XYZ_D50 at `illuminant1K` / `illuminant2K`.
    public let forwardMatrix1: simd_float3x3
    public let forwardMatrix2: simd_float3x3
    /// Whether the forward matrices were read from the file or defaulted to
    /// identity. A caller that means to transform by them needs to know.
    public let hasForwardMatrices: Bool

    /// XYZ → camera at each illuminant (the spec's `ColorMatrix1/2`).
    public let colorMatrix1: simd_float3x3
    public let colorMatrix2: simd_float3x3

    public let illuminant1K: Float
    public let illuminant2K: Float

    /// `[hueDivisions, satDivisions, valueDivisions]`.
    public let hueSatMapDims: SIMD3<Int>
    /// `[ΔH°, ×S, ×V]` per cell, for calibration illuminant 1.
    public let hueSatMapData1: [SIMD3<Float>]
    /// The same for illuminant 2. Empty on a single-illuminant profile.
    public let hueSatMapData2: [SIMD3<Float>]

    /// `[hueDivisions, satDivisions, valueDivisions]`.
    public let lookTableDims: SIMD3<Int>
    /// `[ΔH°, ×S, ×V]` per cell.
    public let lookTableData: [SIMD3<Float>]

    /// `(input, output)` pairs. Empty on profiles that ship no curve — which
    /// is every Apple profile in the Lightroom set.
    public let toneCurve: [(input: Float, output: Float)]

    public var hasHueSatMap: Bool {
        hueSatMapData1.count == expectedCount(hueSatMapDims) && expectedCount(hueSatMapDims) > 0
    }

    public var hasLookTable: Bool {
        lookTableData.count == expectedCount(lookTableDims) && expectedCount(lookTableDims) > 0
    }

    private func expectedCount(_ dims: SIMD3<Int>) -> Int {
        guard dims.x > 0, dims.y > 0, dims.z > 0 else { return 0 }
        return dims.x * dims.y * dims.z
    }

    /// The hue/sat map for a shot illuminant, interpolated between the two
    /// calibration tables in reciprocal temperature.
    ///
    /// Same weighting rule as `ForwardMatrixDecoder.interpolate`, and for the
    /// same reason: illuminants are perceptually spaced in mired, and matching
    /// Adobe is the entire object of the exercise. Interpolating the *tables*
    /// rather than picking the nearer one is what the DNG spec calls for.
    public func hueSatMap(at kelvin: Float) -> [SIMD3<Float>] {
        guard hasHueSatMap else { return [] }
        guard hueSatMapData2.count == hueSatMapData1.count else { return hueSatMapData1 }
        guard illuminant1K > 0, illuminant2K > 0, illuminant1K != illuminant2K else {
            return hueSatMapData1
        }
        let lo = min(illuminant1K, illuminant2K), hi = max(illuminant1K, illuminant2K)
        let clamped = min(max(kelvin, lo), hi)
        let weight = (1 / clamped - 1 / illuminant2K) / (1 / illuminant1K - 1 / illuminant2K)
        let t = min(max(weight, 0), 1)
        guard t > 0 else { return hueSatMapData2 }
        guard t < 1 else { return hueSatMapData1 }
        return zip(hueSatMapData1, hueSatMapData2).map { $0 * t + $1 * (1 - t) }
    }

    /// Camera → XYZ_D50 at a shot illuminant, interpolated the same way.
    public func forwardMatrix(at kelvin: Float) -> simd_float3x3 {
        ForwardMatrixDecoder.interpolate(
            fm1: forwardMatrix1, fm2: forwardMatrix2,
            ill1K: illuminant1K, ill2K: illuminant2K, declaredK: kelvin)
    }
}

// MARK: - Table indexing

/// Where a cell lives in a DNG hue/sat table.
///
/// The axis order is the one thing here most likely to be got wrong, because
/// the tag names list the dimensions as `[hue, sat, value]` and the obvious
/// reading is that hue is the major axis. It is not. The DNG spec stores these
/// tables "with the value divisions in the outer loop, the hue divisions in
/// the middle loop, and the saturation divisions in the inner loop", so the
/// stride order is the *reverse* of the dimension order.
///
/// Verified against the shipped Apple profiles rather than taken on trust: on
/// the V-outer reading the tables are 3.4× smoother along the hue axis and
/// every zero-saturation cell carries an exactly-1.0 value scale (the
/// invariant the spec requires); on the hue-major reading the invariant breaks
/// outright. Getting this backwards does not fail loudly — it silently
/// scrambles hue against brightness, which looks like a bad profile rather
/// than a bad index.
public enum DCPTableIndex {
    /// Flat offset of cell `(hue, sat, value)` in a table of `dims`.
    @inline(__always)
    public static func offset(hue: Int, sat: Int, value: Int, dims: SIMD3<Int>) -> Int {
        ((value * dims.x) + hue) * dims.y + sat
    }
}

// MARK: - Minimal TIFF reader

/// Just enough TIFF to walk one IFD of a DCP.
///
/// Deliberately not general: no IFD chain, no sub-IFDs, no strip/tile
/// geometry. Every offset is bounds-checked against the mapped `Data` before
/// use, because these files come from outside the app's control and a
/// malformed one must throw rather than read past the end.
///
/// Named for the DCP rather than for TIFF because `DNGAuthor` already owns a
/// `TIFFReader` — that one writes and reads the files this app *authors*,
/// where the tag set is known because we wrote it. This one reads files Adobe
/// authored. Keeping them apart is deliberate: merging them would couple the
/// capture path's DNG writer to a profile format it has no interest in.
struct DCPTIFFReader {
    struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: Int
        /// Offset of the value bytes — either the inline 4-byte field or the
        /// out-of-line location the field pointed at.
        let valueOffset: Int
    }

    let data: Data
    let bigEndian: Bool
    let firstIFDOffset: Int

    init(data: Data) throws {
        guard data.count >= 8 else { throw DCPParser.Error.truncated }
        let b0 = data[data.startIndex]
        let b1 = data[data.startIndex + 1]
        switch (b0, b1) {
        case (0x49, 0x49): bigEndian = false   // "II"
        case (0x4D, 0x4D): bigEndian = true    // "MM"
        default: throw DCPParser.Error.notADCP
        }
        self.data = data
        // The version word is 0x4352 ("RC") in a DCP where a TIFF carries 42.
        // Both are accepted: the byte-order mark plus a plausible IFD offset
        // is identification enough, and rejecting 42 here would refuse a
        // profile that happened to be written as a plain TIFF.
        let version = Self.read16(data, at: 2, bigEndian: bigEndian)
        guard version == 0x4352 || version == 42 else { throw DCPParser.Error.notADCP }
        let offset = Int(Self.read32(data, at: 4, bigEndian: bigEndian))
        guard offset >= 8, offset + 2 <= data.count else { throw DCPParser.Error.truncated }
        self.firstIFDOffset = offset
    }

    /// Reads one IFD into a tag-keyed table. Entries whose values fall outside
    /// the file are dropped rather than throwing, so one bad tag cannot deny
    /// the caller the rest of a usable profile.
    func readIFD(at offset: Int) throws -> [UInt16: Entry] {
        guard offset + 2 <= data.count else { throw DCPParser.Error.truncated }
        let count = Int(Self.read16(data, at: offset, bigEndian: bigEndian))
        guard offset + 2 + count * 12 <= data.count else { throw DCPParser.Error.truncated }
        var entries: [UInt16: Entry] = [:]
        entries.reserveCapacity(count)
        for i in 0..<count {
            let base = offset + 2 + i * 12
            let tag = Self.read16(data, at: base, bigEndian: bigEndian)
            let type = Self.read16(data, at: base + 2, bigEndian: bigEndian)
            let n = Int(Self.read32(data, at: base + 4, bigEndian: bigEndian))
            let unit = Self.typeSize(type)
            guard unit > 0, n >= 0 else { continue }
            let total = unit * n
            let value: Int = total > 4
                ? Int(Self.read32(data, at: base + 8, bigEndian: bigEndian))
                : base + 8
            guard value >= 0, value + total <= data.count else { continue }
            entries[tag] = Entry(tag: tag, type: type, count: n, valueOffset: value)
        }
        return entries
    }

    // MARK: value accessors

    func string(_ e: Entry) throws -> String {
        let bytes = data.subdata(in: index(e.valueOffset)..<index(e.valueOffset + e.count))
        let trimmed = bytes.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    func unsignedShort(_ e: Entry) throws -> UInt16 {
        guard e.count >= 1 else { throw DCPParser.Error.truncated }
        return Self.read16(data, at: e.valueOffset, bigEndian: bigEndian)
    }

    func dims(_ e: Entry) throws -> SIMD3<Int> {
        guard e.count >= 3 else { throw DCPParser.Error.truncated }
        return SIMD3<Int>(
            Int(Self.read32(data, at: e.valueOffset, bigEndian: bigEndian)),
            Int(Self.read32(data, at: e.valueOffset + 4, bigEndian: bigEndian)),
            Int(Self.read32(data, at: e.valueOffset + 8, bigEndian: bigEndian)))
    }

    /// A 3×3 stored as nine SRATIONALs, row-major on disk.
    func matrix3x3(_ e: Entry) throws -> simd_float3x3 {
        guard e.count >= 9, e.type == 10 || e.type == 5 else { throw DCPParser.Error.truncated }
        var v = [Float](repeating: 0, count: 9)
        for i in 0..<9 {
            let at = e.valueOffset + i * 8
            let numerator = Int32(bitPattern: Self.read32(data, at: at, bigEndian: bigEndian))
            let denominator = Int32(bitPattern: Self.read32(data, at: at + 4, bigEndian: bigEndian))
            v[i] = denominator == 0 ? 0 : Float(numerator) / Float(denominator)
        }
        return simd_float3x3(rows: [
            SIMD3<Float>(v[0], v[1], v[2]),
            SIMD3<Float>(v[3], v[4], v[5]),
            SIMD3<Float>(v[6], v[7], v[8]),
        ])
    }

    /// A run of IEEE floats read as `[ΔH, ×S, ×V]` triples.
    func floatTriples(_ e: Entry) throws -> [SIMD3<Float>] {
        guard e.type == 11 else { throw DCPParser.Error.truncated }
        let cells = e.count / 3
        var out = [SIMD3<Float>]()
        out.reserveCapacity(cells)
        for i in 0..<cells {
            let at = e.valueOffset + i * 12
            out.append(SIMD3<Float>(
                Self.readFloat(data, at: at, bigEndian: bigEndian),
                Self.readFloat(data, at: at + 4, bigEndian: bigEndian),
                Self.readFloat(data, at: at + 8, bigEndian: bigEndian)))
        }
        return out
    }

    /// A run of IEEE floats read as `(input, output)` pairs.
    func floatPairs(_ e: Entry) throws -> [(input: Float, output: Float)] {
        guard e.type == 11 else { throw DCPParser.Error.truncated }
        let pairs = e.count / 2
        var out = [(input: Float, output: Float)]()
        out.reserveCapacity(pairs)
        for i in 0..<pairs {
            let at = e.valueOffset + i * 8
            out.append((
                input: Self.readFloat(data, at: at, bigEndian: bigEndian),
                output: Self.readFloat(data, at: at + 4, bigEndian: bigEndian)))
        }
        return out
    }

    // MARK: primitives

    private func index(_ offset: Int) -> Data.Index {
        data.startIndex + offset
    }

    static func typeSize(_ type: UInt16) -> Int {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8: return 2
        case 4, 9, 11: return 4
        case 5, 10, 12: return 8
        default: return 0
        }
    }

    static func read16(_ d: Data, at offset: Int, bigEndian: Bool) -> UInt16 {
        let i = d.startIndex + offset
        guard i + 1 < d.endIndex else { return 0 }
        let a = UInt16(d[i]), b = UInt16(d[i + 1])
        return bigEndian ? (a << 8 | b) : (b << 8 | a)
    }

    static func read32(_ d: Data, at offset: Int, bigEndian: Bool) -> UInt32 {
        let i = d.startIndex + offset
        guard i + 3 < d.endIndex else { return 0 }
        let a = UInt32(d[i]), b = UInt32(d[i + 1]), c = UInt32(d[i + 2]), e = UInt32(d[i + 3])
        return bigEndian ? (a << 24 | b << 16 | c << 8 | e) : (e << 24 | c << 16 | b << 8 | a)
    }

    static func readFloat(_ d: Data, at offset: Int, bigEndian: Bool) -> Float {
        Float(bitPattern: read32(d, at: offset, bigEndian: bigEndian))
    }
}

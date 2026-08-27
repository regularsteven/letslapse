import CoreGraphics
import Foundation
import ImageIO
import simd

/// The DNG colour model, read from a file's own calibration tags, expressed as
/// the pieces the grade engine needs: camera → XYZ_D50 at a chosen illuminant,
/// and the camera-space neutral that illuminant produces.
///
/// This is the openly documented model from chapter 6 of the DNG spec —
/// `ForwardMatrix1/2`, `ColorMatrix1/2`, `CalibrationIlluminant1/2`,
/// `AsShotNeutral`, interpolated between the two calibration illuminants by
/// reciprocal colour temperature. Nothing here is proprietary, and nothing
/// here is a look: it is the geometry of the camera's response, which is
/// exactly the part a generic Bradford adaptation in Display P3 throws away.
///
/// ## The missing-tag case, which is the normal one on iPhone
///
/// Apple's camera DNGs are DNG 1.3 and carry **no** `ForwardMatrix` tags —
/// only `ColorMatrix1/2`. Measured on `iPhone17,1 back camera`: the DNG
/// dictionary holds `ColorMatrix1/2`, `CalibrationIlluminant1/2` (17 = StdA,
/// 21 = D65), `AsShotNeutral`, and no forward matrices at all. So a decoder
/// that only read tag 0xC714/0xC715 would fail on every file this app
/// produces.
///
/// The spec's own answer, and Adobe's, is to synthesise the forward matrix
/// from the colour matrix: camera → XYZ is the inverse of the interpolated
/// `ColorMatrix`, chromatically adapted so the shot's white lands on D50.
/// `matrices(for:)` does that transparently and reports which it used through
/// `Calibration.forwardMatrixWasPresent`, so a caller (or a test) can tell a
/// measured forward matrix from a derived one.
public struct ForwardMatrixDecoder {

    // MARK: - Errors

    public enum Error: Swift.Error, LocalizedError {
        case notAnImage(URL)
        case missingTag(String)
        case singularMatrix

        public var errorDescription: String? {
            switch self {
            case .notAnImage(let url):
                return "Could not open \(url.lastPathComponent) as an image."
            case .missingTag(let name):
                return "DNG is missing \(name)."
            case .singularMatrix:
                return "DNG colour matrix is not invertible."
            }
        }
    }

    // MARK: - What a file tells us

    /// One DNG's colour calibration, ready to evaluate at any illuminant.
    public struct Calibration: Sendable {
        /// Camera → XYZ_D50 for `CalibrationIlluminant1`, before the neutral
        /// normalisation (the spec's `ForwardMatrix1`).
        public let fm1: simd_float3x3
        /// The same for `CalibrationIlluminant2`.
        public let fm2: simd_float3x3
        /// XYZ(illuminant 1) → camera (the spec's `ColorMatrix1`).
        public let cm1: simd_float3x3
        /// XYZ(illuminant 2) → camera (the spec's `ColorMatrix2`).
        public let cm2: simd_float3x3
        /// Correlated colour temperature of `CalibrationIlluminant1`, in K.
        public let ill1K: Float
        /// The same for `CalibrationIlluminant2`.
        public let ill2K: Float
        /// The camera-space neutral the shot's illuminant produced, green
        /// normalised to 1 — the `AsShotNeutral` tag.
        public let asShotNeutral: SIMD3<Float>
        /// `true` when the file actually carried `ForwardMatrix1/2`; `false`
        /// when `fm1`/`fm2` were derived from the colour matrices. Every
        /// iPhone DNG measured so far reports `false`.
        public let forwardMatrixWasPresent: Bool
    }

    /// Reads `ForwardMatrix1/2` and `CalibrationIlluminant1/2` from DNG
    /// metadata using ImageIO, synthesising the forward matrices from
    /// `ColorMatrix1/2` when the file does not carry them (which is the case
    /// for every Apple DNG — see the type's notes).
    public static func matrices(
        for url: URL
    ) throws -> (fm1: simd_float3x3, fm2: simd_float3x3, ill1K: Float, ill2K: Float) {
        let calibration = try self.calibration(for: url)
        return (calibration.fm1, calibration.fm2, calibration.ill1K, calibration.ill2K)
    }

    /// `calibration(for:)` memoised on path and modification date.
    ///
    /// A renderer is rebuilt on every slider tick, and each rebuild asks for
    /// the white-balance matrix — so an uncached read would open and parse the
    /// DNG's metadata at the frame rate of a drag. The parse is the only file
    /// I/O on this path; the matrices themselves never change for a given file.
    public static func cachedCalibration(for url: URL) throws -> Calibration {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(modified)"
        cacheLock.lock()
        if let hit = cache[key] {
            cacheLock.unlock()
            return try hit.get()
        }
        cacheLock.unlock()

        let result: Result<Calibration, Swift.Error>
        do {
            result = .success(try calibration(for: url))
        } catch {
            // Failures are cached too: a JPEG or a DNG with no colour matrix
            // will fail identically every tick, and re-reading it to find that
            // out again is the cost this cache exists to avoid.
            result = .failure(error)
        }
        cacheLock.lock()
        if cache.count > 64 { cache.removeAll(keepingCapacity: true) }
        cache[key] = result
        cacheLock.unlock()
        return try result.get()
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Result<Calibration, Swift.Error>] = [:]

    /// The full calibration, including the colour matrices and the as-shot
    /// neutral that `matrices(for:)` drops.
    public static func calibration(for url: URL) throws -> Calibration {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            throw Error.notAnImage(url)
        }
        guard let dng = properties[kCGImagePropertyDNGDictionary] as? [CFString: Any] else {
            throw Error.missingTag("a DNG metadata dictionary")
        }

        guard let cm1 = matrix(dng[kCGImagePropertyDNGColorMatrix1]) else {
            throw Error.missingTag("ColorMatrix1")
        }
        // A single-illuminant DNG is legal; both slots then hold the one matrix
        // and the interpolation below is a no-op at every temperature.
        let cm2 = matrix(dng[kCGImagePropertyDNGColorMatrix2]) ?? cm1

        let ill1K = illuminantTemperature(dng[kCGImagePropertyDNGCalibrationIlluminant1]) ?? 2856
        let ill2K = illuminantTemperature(dng[kCGImagePropertyDNGCalibrationIlluminant2]) ?? 6504

        guard var neutral = vector(dng[kCGImagePropertyDNGAsShotNeutral]) else {
            throw Error.missingTag("AsShotNeutral")
        }
        guard neutral.y > 0 else { throw Error.missingTag("a positive AsShotNeutral green") }
        neutral /= neutral.y

        // Forward matrices if the file has them; otherwise derive each one from
        // its own colour matrix, which is what the spec prescribes and what
        // Adobe's SDK does.
        let present = matrix(dng[kCGImagePropertyDNGForwardMatrix1])
        let fm1: simd_float3x3
        let fm2: simd_float3x3
        if let present {
            fm1 = present
            fm2 = matrix(dng[kCGImagePropertyDNGForwardMatrix2]) ?? present
        } else {
            fm1 = try derivedForwardMatrix(colorMatrix: cm1, illuminantK: ill1K)
            fm2 = try derivedForwardMatrix(colorMatrix: cm2, illuminantK: ill2K)
        }

        return Calibration(
            fm1: fm1, fm2: fm2, cm1: cm1, cm2: cm2,
            ill1K: ill1K, ill2K: ill2K,
            asShotNeutral: neutral,
            forwardMatrixWasPresent: present != nil)
    }

    /// Camera → XYZ_D50 built from a colour matrix alone, for files with no
    /// `ForwardMatrix` tag.
    ///
    /// `ColorMatrix(K)` maps XYZ under illuminant K to camera space, so its
    /// inverse maps camera to XYZ under that same illuminant. The forward
    /// matrix is defined against D50, so the result is chromatically adapted
    /// from the illuminant's white to D50 — the "map white" step in the spec's
    /// camera-to-XYZ chain. Returned un-normalised: the per-illuminant neutral
    /// division happens in `cameraToXYZ_D50(at:)`, exactly as it would for a
    /// real forward matrix.
    private static func derivedForwardMatrix(
        colorMatrix: simd_float3x3, illuminantK: Float
    ) throws -> simd_float3x3 {
        guard let inverse = invert(colorMatrix) else { throw Error.singularMatrix }
        let white = whitePointXYZ(kelvin: Double(illuminantK), tint: 0)
        let adapt = bradfordAdaptation(from: white, to: d50)
        // `inverse` already carries the illuminant's own neutral scaling, and
        // `cameraToXYZ_D50` divides by that neutral again. Multiplying the
        // neutral back in here keeps the two conventions consistent, so a
        // derived matrix and a tagged one are interchangeable downstream.
        let neutral = colorMatrix * SIMD3<Float>(white)
        return adapt * inverse * simd_float3x3(diagonal: neutral)
    }

    // MARK: - Interpolation

    /// Interpolate between `fm1` and `fm2` by correlated colour temperature.
    ///
    /// The DNG spec interpolates linearly in *reciprocal* temperature (mired),
    /// not in kelvin — the perceptual spacing of illuminants is a mired
    /// spacing, and matching Adobe here is the whole point of the exercise.
    /// The weight is clamped to the calibration range, so a declared
    /// illuminant outside it pins to the nearer matrix rather than
    /// extrapolating the camera's response into temperatures nobody measured.
    public static func interpolate(
        fm1: simd_float3x3, fm2: simd_float3x3,
        ill1K: Float, ill2K: Float, declaredK: Float
    ) -> simd_float3x3 {
        guard ill1K > 0, ill2K > 0, declaredK > 0, ill1K != ill2K else { return fm2 }
        let lo = min(ill1K, ill2K), hi = max(ill1K, ill2K)
        let clamped = min(max(declaredK, lo), hi)
        // weight = 1 → fm1, weight = 0 → fm2.
        let weight = (1 / clamped - 1 / ill2K) / (1 / ill1K - 1 / ill2K)
        let t = min(max(weight, 0), 1)
        return simd_float3x3(
            fm1.columns.0 * t + fm2.columns.0 * (1 - t),
            fm1.columns.1 * t + fm2.columns.1 * (1 - t),
            fm1.columns.2 * t + fm2.columns.2 * (1 - t))
    }

    // MARK: - Standard primaries

    /// XYZ_D50 → linear sRGB (IEC 61966-2-1 primaries, Bradford-adapted from
    /// the D50 connection space to the sRGB D65 white).
    ///
    /// Provided because it is the textbook constant and the obvious thing to
    /// reach for — but note that this engine's working space is *extended
    /// linear Display P3*, not sRGB. Composing a decode through sRGB primaries
    /// and handing the result to `LinearFrameDecoder`'s P3 textures would shift
    /// every colour in the frame. `xyzD50ToLinearP3` below is the one the
    /// grade path actually uses.
    public static let xyzToSRGB = simd_float3x3(rows: [
        SIMD3<Float>(3.1338561, -1.6168667, -0.4906146),
        SIMD3<Float>(-0.9787684, 1.9161415, 0.0334540),
        SIMD3<Float>(0.0719453, -0.2289914, 1.4052427),
    ])

    /// XYZ_D50 → extended linear Display P3, Bradford-adapted D50 → D65. The
    /// engine's actual working space.
    public static let xyzD50ToLinearP3: simd_float3x3 = {
        let adapt = bradfordAdaptation(from: d50, to: d65)
        return p3FromXYZ_D65 * adapt
    }()

    /// Extended linear Display P3 → XYZ_D65.
    public static let linearP3ToXYZ_D65 = simd_float3x3(rows: [
        SIMD3<Float>(0.4865709, 0.2656677, 0.1982173),
        SIMD3<Float>(0.2289746, 0.6917385, 0.0792869),
        SIMD3<Float>(0.0000000, 0.0451134, 1.0439444),
    ])

    private static let p3FromXYZ_D65 = linearP3ToXYZ_D65.inverse

    private static let d50 = SIMD3<Double>(0.9642, 1.0, 0.8249)
    private static let d65 = SIMD3<Double>(0.95047, 1.0, 1.08883)

    // MARK: - The grade-engine entry point

    /// Camera → XYZ_D50 at a given illuminant, with the spec's neutral
    /// normalisation applied: the illuminant's own camera neutral is divided
    /// out first, so camera white under that illuminant lands on D50 white.
    public static func cameraToXYZ_D50(
        _ calibration: Calibration, at kelvin: Float, tint: Float = 0
    ) -> simd_float3x3 {
        let forward = interpolate(
            fm1: calibration.fm1, fm2: calibration.fm2,
            ill1K: calibration.ill1K, ill2K: calibration.ill2K, declaredK: kelvin)
        let neutral = cameraNeutral(calibration, at: kelvin, tint: tint)
        let inverseNeutral = SIMD3<Float>(
            1 / max(neutral.x, 1e-6), 1 / max(neutral.y, 1e-6), 1 / max(neutral.z, 1e-6))
        return forward * simd_float3x3(diagonal: inverseNeutral)
    }

    /// The camera RGB a perfectly neutral surface produces under an illuminant
    /// — `ColorMatrix(K) · whiteXYZ(K)`, green normalised to 1. This is the
    /// raw converter's white-balance gain vector, and the quantity the two
    /// declared/as-shot illuminants differ by.
    public static func cameraNeutral(
        _ calibration: Calibration, at kelvin: Float, tint: Float = 0
    ) -> SIMD3<Float> {
        let colorMatrix = interpolate(
            fm1: calibration.cm1, fm2: calibration.cm2,
            ill1K: calibration.ill1K, ill2K: calibration.ill2K, declaredK: kelvin)
        let white = SIMD3<Float>(whitePointXYZ(kelvin: Double(kelvin), tint: Double(tint)))
        var neutral = colorMatrix * white
        guard neutral.y > 1e-6 else { return SIMD3<Float>(repeating: 1) }
        neutral /= neutral.y
        return neutral
    }

    /// The white-balance 3×3 the grade kernel applies in linear Display P3,
    /// built from this DNG's own calibration instead of a generic Bradford
    /// adaptation.
    ///
    /// Semantics match `ToneMath.whiteBalanceMatrix` exactly — the sliders
    /// *declare* the scene's illuminant and the matrix adapts from that
    /// declared white to the as-shot white, so a positive mired offset renders
    /// warmer. What differs is the space the adaptation happens in: Bradford
    /// scales in a generic cone space fitted to human vision, whereas this
    /// scales in the camera's own channels — a `diag(n_asShot / n_declared)`
    /// von Kries gain, which is literally what a raw converter's temperature
    /// slider does — and conjugates that gain into P3 through the file's
    /// forward matrix.
    ///
    /// Identity when the sliders are neutral, bit-for-bit, so switching to
    /// this path cannot disturb an untouched render.
    public static func whiteBalanceMatrix(
        _ calibration: Calibration,
        declaredK: Float, declaredTint: Float, asShotK: Float
    ) -> simd_float3x3 {
        guard declaredK != asShotK || declaredTint != 0 else { return matrix_identity_float3x3 }

        // BOTH ends of the gain come from the model, never one from the model
        // and one from the `AsShotNeutral` tag.
        //
        // That mixture is continuity-breaking, and measurably so: on the
        // calibration frame the tag reads (0.6493, 1, 0.3125) while the model
        // at the same illuminant reads (0.6605, 1, 0.3377) — 8% apart in blue,
        // because the tag sits off the Planckian locus (it carries the shot's
        // real tint) and `cameraNeutral` sits on it. Dividing one by the other
        // makes the gain ≠ 1 at zero offset, so nudging the temperature slider
        // a thousandth of a mired off centre snapped blue by 7.6%. Anchoring
        // both ends on `cameraNeutral` makes the gain exactly 1 at zero offset
        // and continuous either side of it — the same property Bradford gets
        // by evaluating `whitePointXYZ` at both temperatures.
        //
        // `asShotNeutral` stays on `Calibration` because it is the file's own
        // ground truth and worth reporting; it is just not this gain's
        // denominator.
        let declared = cameraNeutral(calibration, at: declaredK, tint: declaredTint)
        let asShot = cameraNeutral(calibration, at: asShotK, tint: 0)
        let gain = SIMD3<Float>(
            asShot.x / max(declared.x, 1e-6),
            asShot.y / max(declared.y, 1e-6),
            asShot.z / max(declared.z, 1e-6))

        // Conjugate the camera-space gain into the working space. The bridge is
        // evaluated at the as-shot illuminant on both sides, because that is
        // the state the decoded pixels are actually in.
        let cameraToP3 = xyzD50ToLinearP3 * cameraToXYZ_D50(calibration, at: asShotK)
        guard abs(cameraToP3.determinant) > 1e-9 else { return matrix_identity_float3x3 }
        return cameraToP3 * simd_float3x3(diagonal: gain) * cameraToP3.inverse
    }

    // MARK: - Tag decoding

    /// ImageIO hands DNG matrices back as a flat 9-element array of numbers,
    /// row-major.
    private static func matrix(_ value: Any?) -> simd_float3x3? {
        guard let numbers = value as? [NSNumber], numbers.count >= 9 else { return nil }
        let v = numbers.map { Float(truncating: $0) }
        return simd_float3x3(rows: [
            SIMD3<Float>(v[0], v[1], v[2]),
            SIMD3<Float>(v[3], v[4], v[5]),
            SIMD3<Float>(v[6], v[7], v[8]),
        ])
    }

    private static func vector(_ value: Any?) -> SIMD3<Float>? {
        guard let numbers = value as? [NSNumber], numbers.count >= 3 else { return nil }
        return SIMD3<Float>(
            Float(truncating: numbers[0]),
            Float(truncating: numbers[1]),
            Float(truncating: numbers[2]))
    }

    /// EXIF `LightSource` codes → correlated colour temperature, for the values
    /// cameras actually write. Matches `CameraColorTransform`'s table, which is
    /// the same spec table read from raw TIFF bytes rather than through
    /// ImageIO.
    private static func illuminantTemperature(_ value: Any?) -> Float? {
        guard let code = (value as? NSNumber)?.intValue else { return nil }
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

    // MARK: - Colour science shared with ToneMath

    /// The Planckian white point for a temperature, with tint as a
    /// green–magenta offset off the locus. Delegates to `ToneMath` so the two
    /// paths cannot drift apart on what "5500 K, tint +10" means.
    private static func whitePointXYZ(kelvin: Double, tint: Double) -> SIMD3<Double> {
        ToneMath.whitePointXYZ(kelvin: kelvin, tint: tint)
    }

    private static let bradford = simd_float3x3(rows: [
        SIMD3<Float>(0.8951, 0.2664, -0.1614),
        SIMD3<Float>(-0.7502, 1.7135, 0.0367),
        SIMD3<Float>(0.0389, -0.0685, 1.0296),
    ])

    private static func bradfordAdaptation(
        from source: SIMD3<Double>, to destination: SIMD3<Double>
    ) -> simd_float3x3 {
        let sourceCone = bradford * SIMD3<Float>(source)
        let destinationCone = bradford * SIMD3<Float>(destination)
        let gain = simd_float3x3(diagonal: SIMD3<Float>(
            destinationCone.x / sourceCone.x,
            destinationCone.y / sourceCone.y,
            destinationCone.z / sourceCone.z))
        return bradford.inverse * gain * bradford
    }

    private static func invert(_ m: simd_float3x3) -> simd_float3x3? {
        guard abs(m.determinant) > 1e-9 else { return nil }
        return m.inverse
    }
}

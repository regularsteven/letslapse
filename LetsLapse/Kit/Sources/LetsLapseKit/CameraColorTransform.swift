import Foundation

/// Derives the working-sRGB → camera-native transform from a reference DNG's
/// own calibration tags, so blended linear output can be stored in the
/// camera's color space with the camera's real identity — giving raw
/// developers their native dual-illuminant white-balance model instead of a
/// single synthetic sRGB matrix.
///
/// Everything here is the openly documented DNG color model (chapter 6 of
/// the spec): ColorMatrix interpolation by correlated color temperature,
/// Bradford chromatic adaptation, nothing proprietary.
public struct CameraColorModel {
    /// Rows of the 3×3 matrix taking linear-sRGB(D65) pixels to
    /// camera-native values, normalised so sRGB white maps to the
    /// AsShotNeutral vector with green = 1.
    public let transformRows: [[Double]]
    /// The reference's color/identity tags to embed in the authored DNG
    /// (matrices, illuminants, neutral, camera identity, noise profile).
    public let tags: [DNGTagValue]
}

public enum CameraColorTransformError: LocalizedError {
    case missingTag(String)
    case singularMatrix

    public var errorDescription: String? {
        switch self {
        case .missingTag(let name): return "Reference DNG is missing \(name)."
        case .singularMatrix: return "Reference color matrix is not invertible."
        }
    }
}

public enum CameraColorTransform {
    /// IFD0 tags carried into camera-native output. Orientation is
    /// deliberately absent: the decoded working image is already
    /// display-oriented, so carrying the tag would double-rotate.
    private static let carriedTags: [UInt16] = [
        271, 272,          // Make, Model
        50708,             // UniqueCameraModel
        50721, 50722,      // ColorMatrix1/2
        50723, 50724,      // CameraCalibration1/2
        50778, 50779,      // CalibrationIlluminant1/2
        50728,             // AsShotNeutral
        51041,             // NoiseProfile
    ]

    public static func model(from reference: DNGReference) throws -> CameraColorModel {
        guard let matrix1Tag = reference.ifd0.first(where: { $0.tag == 50721 }) else {
            throw CameraColorTransformError.missingTag("ColorMatrix1")
        }
        guard let neutralTag = reference.ifd0.first(where: { $0.tag == 50728 }) else {
            throw CameraColorTransformError.missingTag("AsShotNeutral")
        }
        let matrix1 = try matrix3x3(fromSRationals: matrix1Tag)
        let matrix2 = reference.ifd0.first(where: { $0.tag == 50722 }).flatMap { try? matrix3x3(fromSRationals: $0) }
        var neutral = try vector3(fromRationals: neutralTag)
        guard neutral[1] > 0 else { throw CameraColorTransformError.missingTag("AsShotNeutral green") }
        neutral = neutral.map { $0 / neutral[1] }

        let illuminant1 = temperature(ofIlluminant: reference.ifd0.first { $0.tag == 50778 }) ?? 2856
        let illuminant2 = temperature(ofIlluminant: reference.ifd0.first { $0.tag == 50779 }) ?? 6504

        // DNG spec: the camera matrix for the shot is interpolated between
        // the calibration illuminants by inverse CCT of the shot's white —
        // which itself depends on the interpolated matrix, so iterate.
        var interpolated = matrix2 ?? matrix1
        var sceneWhite = [0.9505, 1.0, 1.0888]
        for _ in 0..<4 {
            guard let inverse = invert3x3(interpolated) else {
                throw CameraColorTransformError.singularMatrix
            }
            sceneWhite = multiply(inverse, neutral)
            guard sceneWhite[1] > 0 else { throw CameraColorTransformError.singularMatrix }
            sceneWhite = sceneWhite.map { $0 / sceneWhite[1] }
            guard let matrix2 else { break }
            let cct = correlatedColorTemperature(of: sceneWhite)
            let clamped = min(max(cct, min(illuminant1, illuminant2)), max(illuminant1, illuminant2))
            let weight = (1 / clamped - 1 / illuminant2) / (1 / illuminant1 - 1 / illuminant2)
            interpolated = blend(matrix1, matrix2, weight: min(max(weight, 0), 1))
        }
        // Recompute the white from the FINAL matrix so white and matrix are
        // consistent — one loop iteration apart leaves a small neutral error.
        if let inverse = invert3x3(interpolated) {
            sceneWhite = multiply(inverse, neutral)
            guard sceneWhite[1] > 0 else { throw CameraColorTransformError.singularMatrix }
            sceneWhite = sceneWhite.map { $0 / sceneWhite[1] }
        }

        // sRGB(D65) pixel → XYZ(D65) → chromatically re-adapt to the scene
        // white → camera space via the interpolated matrix.
        let d65 = [0.95047, 1.0, 1.08883]
        let adaptation = bradfordAdaptation(from: d65, to: sceneWhite)
        var transform = multiply(interpolated, multiply(adaptation, srgbToXYZ))

        // Normalise: sRGB white must land exactly on the neutral vector with
        // green = 1 (it does up to scale, by construction — this fixes the
        // scale so callers can apply headroom uniformly).
        let white = multiply(transform, [1, 1, 1])
        guard white[1] > 0 else { throw CameraColorTransformError.singularMatrix }
        let scale = 1 / white[1]
        transform = transform.map { row in row.map { $0 * scale } }

        let tags = reference.ifd0.filter { carriedTags.contains($0.tag) }
        return CameraColorModel(transformRows: transform, tags: tags)
    }

    // MARK: - Tag decoding

    private static func matrix3x3(fromSRationals entry: DNGTagValue) throws -> [[Double]] {
        guard entry.type == 10, entry.count >= 9, entry.payload.count >= 72 else {
            throw CameraColorTransformError.missingTag("9 SRATIONALs in tag \(entry.tag)")
        }
        var values: [Double] = []
        for index in 0..<9 {
            let numerator = Int32(bitPattern: entry.payload.readU32(at: index * 8))
            let denominator = Int32(bitPattern: entry.payload.readU32(at: index * 8 + 4))
            guard denominator != 0 else { throw CameraColorTransformError.missingTag("tag \(entry.tag) denominator") }
            values.append(Double(numerator) / Double(denominator))
        }
        return [Array(values[0...2]), Array(values[3...5]), Array(values[6...8])]
    }

    private static func vector3(fromRationals entry: DNGTagValue) throws -> [Double] {
        guard entry.count >= 3, entry.payload.count >= 24 else {
            throw CameraColorTransformError.missingTag("3 RATIONALs in tag \(entry.tag)")
        }
        var values: [Double] = []
        for index in 0..<3 {
            let numerator = entry.payload.readU32(at: index * 8)
            let denominator = entry.payload.readU32(at: index * 8 + 4)
            guard denominator != 0 else { throw CameraColorTransformError.missingTag("tag \(entry.tag) denominator") }
            values.append(Double(numerator) / Double(denominator))
        }
        return values
    }

    /// EXIF LightSource values → correlated color temperature for the ones
    /// cameras actually use.
    private static func temperature(ofIlluminant entry: DNGTagValue?) -> Double? {
        guard let entry, entry.payload.count >= 2 else { return nil }
        switch entry.payload.readU16(at: 0) {
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

    // MARK: - Color science

    static let srgbToXYZ: [[Double]] = [
        [0.4124564, 0.3575761, 0.1804375],
        [0.2126729, 0.7151522, 0.0721750],
        [0.0193339, 0.1191920, 0.9503041],
    ]

    private static let bradford: [[Double]] = [
        [0.8951, 0.2664, -0.1614],
        [-0.7502, 1.7135, 0.0367],
        [0.0389, -0.0685, 1.0296],
    ]

    static func bradfordAdaptation(from source: [Double], to destination: [Double]) -> [[Double]] {
        let sourceCone = multiply(bradford, source)
        let destinationCone = multiply(bradford, destination)
        let gain = [
            [destinationCone[0] / sourceCone[0], 0, 0],
            [0, destinationCone[1] / sourceCone[1], 0],
            [0, 0, destinationCone[2] / sourceCone[2]],
        ]
        let inverse = invert3x3(bradford)!
        return multiply(inverse, multiply(gain, bradford))
    }

    /// McCamy's approximation from chromaticity.
    static func correlatedColorTemperature(of white: [Double]) -> Double {
        let sum = white[0] + white[1] + white[2]
        guard sum > 0 else { return 6504 }
        let x = white[0] / sum
        let y = white[1] / sum
        let n = (x - 0.3320) / (0.1858 - y)
        return 449 * n * n * n + 3525 * n * n + 6823.3 * n + 5520.33
    }

    // MARK: - 3×3 helpers

    static func multiply(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        var result = [[Double]](repeating: [0, 0, 0], count: 3)
        for row in 0..<3 {
            for column in 0..<3 {
                result[row][column] = a[row][0] * b[0][column]
                    + a[row][1] * b[1][column]
                    + a[row][2] * b[2][column]
            }
        }
        return result
    }

    static func multiply(_ a: [[Double]], _ v: [Double]) -> [Double] {
        (0..<3).map { a[$0][0] * v[0] + a[$0][1] * v[1] + a[$0][2] * v[2] }
    }

    static func invert3x3(_ m: [[Double]]) -> [[Double]]? {
        let a = m[0][0], b = m[0][1], c = m[0][2]
        let d = m[1][0], e = m[1][1], f = m[1][2]
        let g = m[2][0], h = m[2][1], i = m[2][2]
        let determinant = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        guard abs(determinant) > 1e-12 else { return nil }
        let inverse = [
            [(e * i - f * h), (c * h - b * i), (b * f - c * e)],
            [(f * g - d * i), (a * i - c * g), (c * d - a * f)],
            [(d * h - e * g), (b * g - a * h), (a * e - b * d)],
        ]
        return inverse.map { row in row.map { $0 / determinant } }
    }

    private static func blend(_ a: [[Double]], _ b: [[Double]], weight: Double) -> [[Double]] {
        (0..<3).map { row in
            (0..<3).map { column in
                a[row][column] * weight + b[row][column] * (1 - weight)
            }
        }
    }
}

import CoreGraphics
import Foundation
import simd

/// The White Balance panel's Auto button: a grey-world estimate of the white
/// a frame should be declared at so its average colour renders neutral.
///
/// Grey-world is the oldest and bluntest of the auto-balance heuristics —
/// "the world is grey on average, so whatever colour the average has is the
/// light's" — and it is here because it is the one that can be explained in a
/// sentence, runs on a thumbnail, and is right often enough to be a useful
/// first move. It is wrong on purpose whenever the scene is not grey on
/// average: a sunset is orange because the light is, a forest is green
/// because the leaves are, and Auto will drain both. That is why this is a
/// button the photographer presses and then judges, not a default, and why
/// the result is written through the same keyframed owned-white path a menu
/// pick uses: one more edit, undoable like any other.
///
/// The estimate is made on the frame AS CURRENTLY RENDERED — the picture the
/// photographer is looking at, declared at `currentKelvin` / `currentTint`.
/// What comes back is the white to declare INSTEAD, so a second press on the
/// corrected picture measures a neutral mean and moves nothing.
public enum AutoWhiteBalance {

    /// The white to declare: Kelvin and the converter's ±150 tint.
    public struct Estimate: Equatable, Sendable {
        public var kelvin: Double
        public var tint: Double

        public init(kelvin: Double, tint: Double) {
            self.kelvin = kelvin
            self.tint = tint
        }
    }

    /// The long edge the picture is reduced to before it is averaged. A mean
    /// over 128 × 96 samples is the same mean as over the full frame to well
    /// inside a mired; the draw is what makes Auto instant on a 4K frame.
    static let sampleLongEdge = 128

    /// The reference white the mean is judged against — D65, sRGB's own, and
    /// the white every rendered picture is encoded to. The estimator's own
    /// reading of it (through the same McCamy fit and the same locus
    /// distance) is subtracted rather than the textbook 6504 K, so a neutral
    /// grey lands on exactly the current white and the fit's small biases
    /// cancel instead of leaking into the answer as a phantom cast.
    static let referenceXY = SIMD2<Double>(0.3127, 0.3290)

    /// Adobe's tint axis, which the converter's ±150 travel follows, is an
    /// offset perpendicular to the Planckian locus in CIE 1960 uv scaled by
    /// 3000 — 150 units is 0.05 in uv (`LinearFrameDecoder.cirawTintPerRecipeUnit`
    /// carries the measurement). The same constant turns a measured Duv into
    /// tint units here.
    static let tintUnitsPerDuv: Double = 3000

    /// Pixels whose brightest channel is below this (encoded, 0…1) carry no
    /// usable colour — sensor noise dominates a near-black — and pixels above
    /// the upper bound have clipped at least one channel, which is a colour
    /// the light did not have. Both are left out of the mean.
    static let darkFloor = 0.02
    static let clipCeiling = 0.98

    /// Below this share of usable pixels the picture is nearly all black or
    /// all clipped; the gates are dropped and every pixel counts, which is a
    /// worse estimate than a gated one but a far better one than none.
    static let minimumUsableShare = 0.05

    // MARK: - From a picture

    /// Grey-world estimate over `image`, the frame as currently rendered
    /// (declared at `currentKelvin` / `currentTint`, converter tint units
    /// ±150). Returns the white to declare so the mean of the picture goes
    /// neutral, or nil when the picture has no usable mean (near-black, or
    /// one that could not be read).
    ///
    /// The picture is drawn into an sRGB bitmap at ≤ 128 px on its long edge
    /// — Core Graphics converts a Display P3 render on the way, which for a
    /// mean is more than accurate enough — read back as RGBA8, decoded to
    /// linear light and averaged with the near-black and clipped pixels left
    /// out. The maths from the mean onward is `estimate(meanLinearRGB:…)`.
    public static func estimate(
        image: CGImage, currentKelvin: Double, currentTint: Double
    ) -> Estimate? {
        guard let mean = meanLinearRGB(of: image) else { return nil }
        return estimate(meanLinearRGB: mean, currentKelvin: currentKelvin, currentTint: currentTint)
    }

    /// The mean of `image` in linear sRGB, gated as described on `estimate`.
    /// Nil when the picture cannot be drawn or has no pixels.
    static func meanLinearRGB(of image: CGImage) -> SIMD3<Double>? {
        let longEdge = max(image.width, image.height)
        guard longEdge > 0 else { return nil }
        let scale = min(1, Double(sampleLongEdge) / Double(longEdge))
        let width = max(Int((Double(image.width) * scale).rounded()), 1)
        let height = max(Int((Double(image.height) * scale).rounded()), 1)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: raw.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // Two passes over the same samples: gated first, then — if the gate
        // left too little — everything.
        func accumulate(gated: Bool) -> (sum: SIMD3<Double>, count: Int) {
            var sum = SIMD3<Double>(repeating: 0)
            var count = 0
            for pixel in 0..<(width * height) {
                let r = Double(bytes[pixel * 4]) / 255
                let g = Double(bytes[pixel * 4 + 1]) / 255
                let b = Double(bytes[pixel * 4 + 2]) / 255
                if gated {
                    let brightest = max(r, g, b)
                    if brightest < darkFloor || brightest > clipCeiling { continue }
                }
                sum += SIMD3<Double>(srgbToLinear(r), srgbToLinear(g), srgbToLinear(b))
                count += 1
            }
            return (sum, count)
        }
        var (sum, count) = accumulate(gated: true)
        if Double(count) < Double(width * height) * minimumUsableShare {
            (sum, count) = accumulate(gated: false)
        }
        guard count > 0 else { return nil }
        return sum / Double(count)
    }

    // MARK: - The maths

    /// The pure estimate, for tests and for callers that already hold a mean:
    /// mean linear sRGB → XYZ (D65 matrix) → xy → correlated colour
    /// temperature (McCamy) and Duv → the corrected declared white.
    ///
    /// The correction is made in mired, the space the white-balance controls
    /// are linear in: `declaredMired = currentMired + (mired(mean) −
    /// mired(reference))`, clamped to the converter's 40…600 travel. A mean
    /// that reads 4000 K — an orange cast — is a scene lit warmer than the
    /// picture was declared, so the declared white moves warmer (a lower
    /// Kelvin) and the render, adapting away from it, goes cooler.
    ///
    /// Tint is the signed distance of the mean from the Planckian locus at
    /// its own temperature, in CIE 1960 uv — positive ABOVE the locus, the
    /// green side — scaled by `tintUnitsPerDuv` and added to the current
    /// tint, clamped to ±150. A green cast needs magenta, and the converter's
    /// positive tint is magenta, so the sign carries straight through. This
    /// is the locus-distance Duv (`ToneMath.planckianXY` at the McCamy
    /// temperature), not Ohno's polynomial fit; the two agree to well under a
    /// tint unit in the range a photograph's mean can reach.
    ///
    /// Nil for a mean with no colour to read: near-black, or not a number.
    public static func estimate(
        meanLinearRGB: SIMD3<Double>, currentKelvin: Double, currentTint: Double
    ) -> Estimate? {
        let mean = meanLinearRGB
        guard mean.x.isFinite, mean.y.isFinite, mean.z.isFinite,
              max(mean.x, mean.y, mean.z) > 1e-4
        else { return nil }
        guard let sample = chromaticity(linearSRGB: mean) else { return nil }

        // The reference white, read the same way, so the estimator's own
        // biases cancel and a neutral mean corrects by exactly nothing.
        let sampleKelvin = correlatedColorTemperature(x: sample.x, y: sample.y)
        let referenceKelvin = correlatedColorTemperature(x: referenceXY.x, y: referenceXY.y)
        let sampleDuv = planckianDuv(xy: sample, kelvin: sampleKelvin)
        let referenceDuv = planckianDuv(xy: referenceXY, kelvin: referenceKelvin)

        let currentMired = 1_000_000 / min(max(currentKelvin, 1667), 25000)
        let miredShift = 1_000_000 / sampleKelvin - 1_000_000 / referenceKelvin
        let declaredMired = min(max(currentMired + miredShift, 40), 600)
        let tint = min(max(currentTint + (sampleDuv - referenceDuv) * tintUnitsPerDuv, -150), 150)
        return Estimate(kelvin: 1_000_000 / declaredMired, tint: tint)
    }

    /// McCamy's cubic approximation of correlated colour temperature from a
    /// CIE xy chromaticity — accurate to a few Kelvin between 2000 K and
    /// 12500 K, which is more than a white-balance slider needs. The result
    /// is clamped to the converter's 1667…25000 K, the range every other
    /// Kelvin in the Kit lives in.
    public static func correlatedColorTemperature(x: Double, y: Double) -> Double {
        let n = (x - 0.3320) / (0.1858 - y)
        let kelvin = 449 * n * n * n + 3525 * n * n + 6823.3 * n + 5520.33
        guard kelvin.isFinite else { return 6504 }
        return min(max(kelvin, 1667), 25000)
    }

    /// Signed distance of `xy` from the Planckian locus at `kelvin`, in CIE
    /// 1960 uv: positive above the locus (toward green), negative below
    /// (toward magenta). The locus point is `ToneMath.planckianXY`.
    static func planckianDuv(xy: SIMD2<Double>, kelvin: Double) -> Double {
        let sample = uv(xy: xy)
        let locus = uv(xy: ToneMath.planckianXY(kelvin: kelvin))
        let distance = simd_length(sample - locus)
        return sample.y >= locus.y ? distance : -distance
    }

    /// CIE 1960 (u, v) from CIE 1931 (x, y).
    static func uv(xy: SIMD2<Double>) -> SIMD2<Double> {
        let denominator = -2 * xy.x + 12 * xy.y + 3
        guard abs(denominator) > 1e-9 else { return SIMD2<Double>(0.2, 0.3) }
        return SIMD2<Double>(4 * xy.x / denominator, 6 * xy.y / denominator)
    }

    /// CIE xy of a linear sRGB colour through the D65 sRGB → XYZ matrix.
    /// Nil for black, which has no chromaticity.
    static func chromaticity(linearSRGB c: SIMD3<Double>) -> SIMD2<Double>? {
        let x = 0.4124564 * c.x + 0.3575761 * c.y + 0.1804375 * c.z
        let y = 0.2126729 * c.x + 0.7151522 * c.y + 0.0721750 * c.z
        let z = 0.0193339 * c.x + 0.1191920 * c.y + 0.9503041 * c.z
        let sum = x + y + z
        guard sum > 1e-9 else { return nil }
        return SIMD2<Double>(x / sum, y / sum)
    }

    /// The sRGB transfer function, decode direction.
    static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
}

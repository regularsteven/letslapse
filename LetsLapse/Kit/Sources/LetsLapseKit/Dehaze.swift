import CoreImage
import Foundation

/// Haze removal by the dark-channel prior (He, Sun & Tang 2009).
///
/// WHY THIS ONE. The corpus said it plainly: on `_DSC6372` — the file carrying
/// Lightroom's Dehaze 45 — our render's mean chroma is 5.25 against
/// Lightroom's 13.34, and it is the worst-scoring file. A single global
/// saturation boost recovers 0.41 of its 10.69, which is the tell: the deficit
/// is LOCALISED. Haze is a spatially varying veil, so only a spatially varying
/// operation can lift it, and the dark-channel prior is the standard one.
///
/// THE PRIOR, in a sentence: in a haze-free outdoor picture, almost every
/// small patch has at least one colour channel that is nearly black. Where a
/// patch has no dark channel, the light between camera and subject has been
/// scattered into it — that is haze, and how much brighter the darkest channel
/// is says how much.
///
///     dark(x) = min over a patch of min over RGB of I
///     t(x)    = 1 − ω · dark(x) / A        the transmission
///     J(x)    = (I(x) − A) / max(t, t₀) + A    the recovered radiance
///
/// `A` is the airlight — the colour of the haze itself. It is estimated from
/// the brightest part of the dark channel, which needs one small readback; see
/// `airlight`. Everything else stays on the GPU.
///
/// Removing the veil restores contrast AND saturation together, which is what
/// the measurement says is missing. It is not a saturation slider with extra
/// steps: it acts only where the prior says there is haze.
public enum Dehaze {

    /// Patch radius for the dark channel, as a fraction of the long edge.
    /// Big enough to contain a genuinely dark pixel in a haze-free patch;
    /// small enough not to smear across a horizon. 1.5% is the literature's
    /// 15px-on-1000 by another name.
    public static let patchFraction: Double = 0.015

    /// How much of the haze to remove at full strength. Never 1: leaving a
    /// little keeps distance readable, and the original paper's 0.95 exists
    /// for exactly that reason.
    public static let omega: Double = 0.95

    /// The transmission floor. Where the prior says almost nothing survives,
    /// dividing by `t` explodes the noise; this is the clamp that stops it.
    public static let minimumTransmission: Double = 0.1

    /// `image` with haze removed (or, for a negative amount, added).
    ///
    /// `amount` is −1…1 — Lightroom's Dehaze ÷ 100. 0 returns the input
    /// untouched and costs nothing.
    public static func apply(
        _ image: CIImage, amount: Double, context: CIContext? = nil
    ) -> CIImage? {
        guard abs(amount) > 1e-6 else { return image }
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return image }

        guard let dark = darkChannel(image, extent: extent) else { return nil }
        let air = airlight(image, dark: dark, extent: extent, context: context)
        // A negative amount re-hazes, which is the same arithmetic with the
        // sign of ω flipped — the transmission goes above 1 and the recovery
        // pulls toward the airlight instead of away from it.
        let strength = Self.omega * amount
        guard let recovered = recover(
            image, dark: dark, airlight: air, strength: strength) else { return nil }
        return recovered.cropped(to: extent)
    }

    // MARK: - The three stages

    /// min over RGB, then a local minimum over the patch.
    private static func darkChannel(_ image: CIImage, extent: CGRect) -> CIImage? {
        guard let minRGB = CIColorKernel(source: """
            kernel vec4 darkMin(__sample s) {
                float m = min(s.r, min(s.g, s.b));
                return vec4(m, m, m, 1.0);
            }
            """)?.apply(extent: extent, arguments: [image]) else { return nil }
        let radius = max(Double(max(extent.width, extent.height)) * patchFraction, 1)
        guard let erode = CIFilter(name: "CIMorphologyMinimum") else { return minRGB }
        // Clamped: a minimum filter sampling transparent black past the edge
        // would find a false dark channel all round the border and dehaze the
        // frame's rim into a halo.
        erode.setValue(minRGB.clampedToExtent(), forKey: kCIInputImageKey)
        erode.setValue(radius, forKey: kCIInputRadiusKey)
        return erode.outputImage?.cropped(to: extent)
    }

    /// The haze's own colour, as a single scalar brightness.
    ///
    /// The paper takes the brightest 0.1% of the dark channel and reads the
    /// input there. This takes the maximum of a heavily downsampled dark
    /// channel, which lands in the same place for far less work and is
    /// robust to a single blown pixel — the failure the 0.1% rule is itself
    /// guarding against.
    ///
    /// The one readback in the operation. Worth it: guessing A wrong scales
    /// the whole recovery, and a constant would be wrong on every scene that
    /// is not a grey afternoon.
    private static func airlight(
        _ image: CIImage, dark: CIImage, extent: CGRect, context: CIContext?
    ) -> Double {
        let shared = context ?? CIContext(options: [.useSoftwareRenderer: false])
        guard let filter = CIFilter(name: "CIAreaMaximum") else { return 0.95 }
        filter.setValue(dark, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return 0.95 }
        var pixel = [UInt8](repeating: 0, count: 4)
        shared.render(
            output, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: nil)
        let value = Double(pixel[0]) / 255
        // A hazeless picture has a near-black dark channel, and dividing by it
        // would send the transmission to nonsense. Floor it well above zero.
        return min(max(value, 0.35), 1.0)
    }

    /// J = (I − A)/max(t, t₀) + A, with t = 1 − strength·dark/A.
    private static func recover(
        _ image: CIImage, dark: CIImage, airlight: Double, strength: Double
    ) -> CIImage? {
        let kernel = CIColorKernel(source: """
            kernel vec4 dehazeRecover(__sample src, __sample dark, float a, float w, float tmin) {
                float t = 1.0 - w * (dark.r / a);
                t = max(t, tmin);
                vec3 j = (src.rgb - a) / t + a;
                return vec4(clamp(j, 0.0, 1.0), src.a);
            }
            """)
        return kernel?.apply(
            extent: image.extent,
            arguments: [image, dark, airlight, strength, minimumTransmission])
    }
}

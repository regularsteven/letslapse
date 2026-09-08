import CoreGraphics
import CoreImage
import Foundation

// The display-referred grade: a parametric Core Image chain over a FINISHED
// picture, as distinct from the tone engine's linear-light Metal pass.
//
// It exists for the one stage every renderer shares. The whole-picture grade
// is the engine's — linear decode, Metal kernel, display-referred out. A
// MASKED grade then runs this chain over that finished picture, because a
// stills export blends many source frames into one output frame and hands it
// over already rendered: there is no seam earlier than this where a mask
// drawn on the OUTPUT frame could be applied at all. The video composition
// grades through it too, until video moves onto the engine.
//
// It is the coarser of the two paths — it cannot recover a highlight the
// engine has already clipped — and it is used anyway because preview, export
// and the render bench all have to agree, and this is the only chain all
// three can run. That is the whole reason it lives in the Kit rather than in
// the app: the bench scores WHOLE renders, masks included, only because this
// file is reachable from the command line.
//
// The chain is the app's original `PhotoGrader.adjust`, moved here verbatim
// (2026-09-07): same filters, same constants, same order.

/// A grade for display-referred pixels. Same units as the engine's
/// `GradeRecipe` wherever the two share a control: EV for exposure, ±1 for
/// the hundred-scale sliders, mired for the white.
public struct DisplayGrade: Equatable, Sendable {
    /// Exposure in EV.
    public var exposure: Float = 0
    /// Pivoted contrast, ±1.
    public var contrast: Float = 0
    /// ±1. Only the recovering (negative) half acts on this path — the
    /// filter behind it has no highlight LIFT.
    public var highlights: Float = 0
    /// ±1, positive lifts.
    public var shadows: Float = 0
    /// Moves the white point, ±1.
    public var whites: Float = 0
    /// Moves the black point, ±1.
    public var blacks: Float = 0
    /// An owned white in mired; 0 means the picture's own as-shot.
    public var whiteMired: Float = 0
    /// The owned white's tint, in the converter's ±150 units.
    public var whiteTint: Float = 0
    /// A mired OFFSET from the anchor; positive warms.
    public var temperatureMired: Float = 0
    /// Green (−) to magenta (+), ±1.
    public var tint: Float = 0
    /// ±1.
    public var vibrance: Float = 0
    /// ±1.
    public var saturation: Float = 0
    /// ±1. Only the positive half acts here: an unsharp mask cannot smooth.
    public var clarity: Float = 0
    /// 0…1.
    public var vignette: Float = 0
    /// Haze removal, −1…1 — the same dark-channel prior the whole-picture
    /// `GradeRecipe.dehaze` runs, here so a masked grade can carry it
    /// (Lightroom's LocalDehaze; three of the corpus's sky masks use it).
    public var dehaze: Float = 0
    /// The HSL panel, nil when untouched. Here for the video path, whose
    /// whole-picture grade runs this chain; a masked grade never sets it.
    public var hsl: HSLAdjustments?
    /// The LUT, nil when none — the video path's copy of `GradeRecipe.lut`,
    /// applied last as the still path applies it. A masked grade never sets it.
    public var lut: LUTLayer?

    public init() {}

    public static let neutral = DisplayGrade()

    /// True when nothing here would move a pixel, so `apply` is skipped.
    public var isNeutral: Bool { self == .neutral }

    public var ownsWhite: Bool { whiteMired > 0 }

    /// The white point to grade against when a picture declares none: D65,
    /// which is what sRGB JPEGs and every video frame are written to. Only
    /// the white-balance controls care, and only relative to this anchor.
    public static let neutralKelvin: CGFloat = 6500

    // MARK: - The chain's constants

    /// The clarity filter's radius at this reference edge length. The radius
    /// is scaled by the actual image size so a 1400 px preview and a 4032 px
    /// export get the same *look* rather than the same pixel radius —
    /// without it the preview understates the effect the export applies.
    static let clarityReferenceEdge: CGFloat = 1400
    /// A large radius is what separates "clarity" (broad local contrast)
    /// from "sharpening" (a bright outline on every edge). At 10 px the
    /// rock/sky horizon in the calibration frame gained a visible halo;
    /// 40 px reads as local contrast.
    static let clarityRadius: CGFloat = 40
    /// Clarity 1.0 maps to this unsharp-mask intensity. Calibrated to stop
    /// short of haloing on a high-contrast edge.
    static let clarityMaxIntensity: CGFloat = 0.5
    /// Vignette 1.0 maps to this `CIVignette` intensity.
    static let vignetteMaxIntensity: CGFloat = 2.0
    static let vignetteRadius: CGFloat = 1.5

    // MARK: - Applying it

    /// `image` with `grade` applied.
    ///
    /// Order matters: white balance first (it is a property of the light, so
    /// everything after it grades an already-neutral image), then tone, then
    /// colour, then the two spatial effects. The vignette goes last so it
    /// darkens the finished picture rather than being clarity's input.
    public static func apply(
        _ image: CIImage, _ grade: DisplayGrade,
        asShotKelvin: CGFloat = DisplayGrade.neutralKelvin
    ) -> CIImage {
        guard !grade.isNeutral else { return image }
        // Filters like the unsharp mask grow the extent; everything
        // downstream (and the vignette's centre in particular) has to stay
        // keyed to the picture's own bounds.
        let baseExtent = image.extent
        var out = image

        if grade.ownsWhite || grade.temperatureMired != 0 || grade.tint != 0,
           let filter = CIFilter(name: "CITemperatureAndTint") {
            // Same semantics as the engine: the picture is declared to have
            // been lit by some white, and is adapted from that white to the
            // one it was encoded against. An owned white IS that
            // declaration; otherwise it is as-shot moved by the offset, and
            // a positive mired offset warms.
            let asShotMired = 1_000_000 / max(Double(asShotKelvin), 1667)
            let anchorMired = grade.ownsWhite ? Double(grade.whiteMired) : asShotMired
            let declaredMired = min(max(anchorMired - Double(grade.temperatureMired), 40), 600)
            let declaredTint = (grade.ownsWhite ? CGFloat(grade.whiteTint) : 0)
                + CGFloat(grade.tint) * 50
            filter.setValue(out, forKey: kCIInputImageKey)
            filter.setValue(
                CIVector(x: 1_000_000 / declaredMired, y: declaredTint),
                forKey: "inputNeutral")
            filter.setValue(CIVector(x: asShotKelvin, y: 0), forKey: "inputTargetNeutral")
            out = filter.outputImage ?? out
        }

        if grade.exposure != 0, let filter = CIFilter(name: "CIExposureAdjust") {
            filter.setValue(out, forKey: kCIInputImageKey)
            filter.setValue(grade.exposure, forKey: kCIInputEVKey)
            out = filter.outputImage ?? out
        }

        if grade.highlights < 0 || grade.shadows != 0,
           let filter = CIFilter(name: "CIHighlightShadowAdjust") {
            // `inputHighlightAmount` is 0…1 (lower darkens highlights),
            // `inputShadowAmount` −1…1 (positive lifts shadows).
            filter.setValue(out, forKey: kCIInputImageKey)
            filter.setValue(1.0 + min(grade.highlights, 0), forKey: "inputHighlightAmount")
            filter.setValue(grade.shadows, forKey: "inputShadowAmount")
            out = filter.outputImage ?? out
        }

        if grade.whites != 0 || grade.blacks != 0,
           let filter = CIFilter(name: "CIColorMatrix") {
            let gain = CGFloat(1 + 0.15 * grade.whites)
            let lift = CGFloat(0.06 * grade.blacks)
            filter.setValue(out, forKey: kCIInputImageKey)
            filter.setValue(CIVector(x: gain, y: 0, z: 0, w: 0), forKey: "inputRVector")
            filter.setValue(CIVector(x: 0, y: gain, z: 0, w: 0), forKey: "inputGVector")
            filter.setValue(CIVector(x: 0, y: 0, z: gain, w: 0), forKey: "inputBVector")
            filter.setValue(CIVector(x: lift, y: lift, z: lift, w: 0), forKey: "inputBiasVector")
            out = filter.outputImage ?? out
        }

        if grade.contrast != 0 || grade.saturation != 0,
           let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(out, forKey: kCIInputImageKey)
            filter.setValue(1 + 0.8 * grade.saturation, forKey: kCIInputSaturationKey)
            filter.setValue(1 + 0.2 * grade.contrast, forKey: kCIInputContrastKey)
            out = filter.outputImage ?? out
        }

        if grade.vibrance != 0, let filter = CIFilter(name: "CIVibrance") {
            filter.setValue(out, forKey: kCIInputImageKey)
            filter.setValue(grade.vibrance, forKey: "inputAmount")
            out = filter.outputImage ?? out
        }

        if abs(grade.dehaze) > 1e-6,
           let hazed = Dehaze.apply(out.cropped(to: baseExtent), amount: Double(grade.dehaze)) {
            out = hazed
        }

        if let hsl = grade.hsl, !hsl.isNeutral,
           let shifted = HSLAdjustments.apply(hsl, to: out.cropped(to: baseExtent)) {
            out = shifted
        }

        if let layer = grade.lut, layer.isActive, let cube = LUTRegistry.shared.cube(for: layer.id) {
            out = cube.apply(to: out.cropped(to: baseExtent), strength: layer.strength)
        }

        // Positive only on this path: the engine's clarity is ±detail gain
        // over its guided-filter base, which an unsharp mask cannot mimic
        // for the smoothing direction.
        if grade.clarity > 0, let filter = CIFilter(name: "CIUnsharpMask") {
            let longest = max(baseExtent.width, baseExtent.height)
            filter.setValue(out, forKey: kCIInputImageKey)
            filter.setValue(clarityRadius * max(longest, 1) / clarityReferenceEdge,
                            forKey: kCIInputRadiusKey)
            filter.setValue(CGFloat(grade.clarity) * clarityMaxIntensity,
                            forKey: kCIInputIntensityKey)
            out = (filter.outputImage ?? out).cropped(to: baseExtent)
        }

        if grade.vignette != 0, let filter = CIFilter(name: "CIVignette") {
            filter.setValue(out, forKey: kCIInputImageKey)
            filter.setValue(CGFloat(grade.vignette) * vignetteMaxIntensity,
                            forKey: kCIInputIntensityKey)
            filter.setValue(vignetteRadius, forKey: kCIInputRadiusKey)
            out = filter.outputImage ?? out
        }

        return out.cropped(to: baseExtent)
    }
}

/// A grade applied INSIDE a mask: the display-referred chain over the picture,
/// composited back through a selection. One function, so the editor's
/// preview, the export and the render bench cannot disagree about what a
/// masked grade does to a pixel.
public enum MaskedGradeStage {

    /// Exposure inside a mask travels ±2 EV rather than the whole picture's
    /// ±5: a local lift beyond a couple of stops is a different photograph,
    /// not a correction, and the extra travel only makes the slider coarse.
    public static let exposureRange: ClosedRange<Float> = -2...2

    /// Temp inside a mask is a RELATIVE warmth — a mired offset from
    /// whatever white the whole-picture grade landed on, not a white of its
    /// own. ±25 mired rather than the full ±150: at daylight that is about
    /// +1270 K / −920 K, and the full travel reads +2687 K a third of the
    /// way along, unusable for the nudge this control is.
    public static let temperatureRange: ClosedRange<Float> = -25...25

    /// The unit sliders' travel.
    public static let unitRange: ClosedRange<Float> = -1...1

    /// `grade` held to the travel a masked grade's own sliders have — what
    /// an import lands on, so a value read from a file cannot reach further
    /// than a hand could.
    public static func clampedToMaskTravel(_ grade: DisplayGrade) -> DisplayGrade {
        func clamp(_ value: Float, _ range: ClosedRange<Float>) -> Float {
            min(max(value, range.lowerBound), range.upperBound)
        }
        var out = grade
        out.exposure = clamp(grade.exposure, exposureRange)
        out.temperatureMired = clamp(grade.temperatureMired, temperatureRange)
        out.tint = clamp(grade.tint, unitRange)
        out.contrast = clamp(grade.contrast, unitRange)
        out.highlights = clamp(grade.highlights, unitRange)
        out.shadows = clamp(grade.shadows, unitRange)
        out.saturation = clamp(grade.saturation, unitRange)
        out.clarity = clamp(grade.clarity, unitRange)
        out.vibrance = clamp(grade.vibrance, unitRange)
        out.whites = clamp(grade.whites, unitRange)
        out.blacks = clamp(grade.blacks, unitRange)
        out.vignette = clamp(grade.vignette, 0...1)
        out.dehaze = clamp(grade.dehaze, unitRange)
        out.hsl = grade.hsl?.clamped
        out.lut = grade.lut
        return out
    }

    /// `base` with `grade` applied where `selection` is white, untouched
    /// where it is black, and mixed in between. `selection` must cover
    /// `base.extent`; a shape from `MaskShapeRenderer.maskImage` does.
    ///
    /// Returns `base` itself for a neutral grade — no re-encode, no cost.
    public static func apply(
        _ grade: DisplayGrade, to base: CIImage, through selection: CIImage,
        asShotKelvin: CGFloat = DisplayGrade.neutralKelvin
    ) -> CIImage {
        guard !grade.isNeutral else { return base }
        let adjusted = DisplayGrade.apply(base, grade, asShotKelvin: asShotKelvin)
            .cropped(to: base.extent)
        guard let filter = CIFilter(name: "CIBlendWithMask") else { return base }
        filter.setValue(adjusted, forKey: kCIInputImageKey)
        filter.setValue(base, forKey: kCIInputBackgroundImageKey)
        filter.setValue(selection, forKey: kCIInputMaskImageKey)
        return filter.outputImage?.cropped(to: base.extent) ?? base
    }
}

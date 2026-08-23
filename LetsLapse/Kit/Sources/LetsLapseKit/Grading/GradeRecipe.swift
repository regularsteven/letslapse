import Foundation

/// One grade, engine-ready: the Lightroom-basic-panel parameter set the tone
/// engine renders. This is the *engine's* model — the app's `PhotoAdjustments`
/// (UI ranges, persistence, legacy migration) converts into it.
///
/// Every field's neutral value is 0, so `neutral` is a constant and a caller
/// can skip the whole render when nothing would change a pixel.
public struct GradeRecipe: Codable, Equatable, Sendable {
    /// Exposure in EV stops. −5…+5.
    public var exposure: Float = 0
    /// Pivoted contrast. −1…+1.
    public var contrast: Float = 0
    /// Negative recovers/compresses highlights, positive lifts them. −1…+1.
    public var highlights: Float = 0
    /// Negative deepens shadows, positive lifts them. −1…+1.
    public var shadows: Float = 0
    /// Moves the white point. −1…+1.
    public var whites: Float = 0
    /// Moves the black point: negative crushes, positive lifts to matte. −1…+1.
    public var blacks: Float = 0
    /// White balance as a mired offset from the as-shot illuminant; positive
    /// renders warmer. Stored as an offset so a saved preset carries "warm it
    /// a little" rather than one photo's absolute Kelvin. Roughly −150…+150.
    public var temperatureMired: Float = 0
    /// Green (−) to magenta (+). −1…+1.
    public var tint: Float = 0
    /// Raises muted colours more than saturated ones. −1…+1.
    public var vibrance: Float = 0
    /// Uniform chroma gain. −1…+1.
    public var saturation: Float = 0
    /// Local contrast as detail-layer gain over the guided-filter base:
    /// positive adds punch, negative smooths. Halo-limited. −1…+1.
    public var clarity: Float = 0
    /// Mid-frequency detail (the band between clarity's regions and
    /// sharpen's pixels): positive makes surfaces tactile, negative smooths
    /// them. −1…+1.
    public var texture: Float = 0
    /// Capture sharpening — small-radius luma acutance, the counterpart of
    /// Lightroom's always-on Detail-panel sharpen. 0…1.
    public var sharpen: Float = 0
    /// Luminance noise reduction — edge-preserving (bilateral) smoothing of
    /// fine luma grain. 0…1.
    public var noiseReduction: Float = 0
    /// Colour noise reduction — steers chroma toward the tonally-similar
    /// neighbourhood, which is where the mottling in pushed dark scenes
    /// lives. 0…1.
    public var colorNoiseReduction: Float = 0
    /// Darkens the corners. 0…1.
    public var vignette: Float = 0

    public init() {}

    public static let neutral = GradeRecipe()

    public var isNeutral: Bool { self == .neutral }

    /// Bumped whenever the engine's math changes so render caches keyed on
    /// recipes self-invalidate across engine revisions.
    ///
    /// 2: local tone — shadows/highlights keyed on the guided-filter base,
    ///    clarity as ±detail gain, chroma-protected deep-shadow lifts,
    ///    clip-targeted highlight desaturation.
    public static let engineVersion = 2

    /// A short, stable string identifying this grade for cache keys.
    public var cacheToken: String {
        guard !isNeutral else { return "e\(Self.engineVersion)|n" }
        let values: [Float] = [
            exposure, contrast, highlights, shadows, whites, blacks,
            temperatureMired, tint, vibrance, saturation, clarity, vignette,
            texture, sharpen, noiseReduction, colorNoiseReduction,
        ]
        let joined = values.map { String(format: "%.4f", $0) }.joined(separator: ",")
        return "e\(Self.engineVersion)|\(joined)"
    }
}

/// Per-project anchors the engine needs beside the recipe: what "as shot"
/// means for this file, and the pixel scale the spatial effects key to.
public struct GradeReference: Sendable {
    /// The as-shot illuminant, from the DNG's own metadata when available.
    public var asShotTemperatureK: Double
    /// The as-shot tint, in the decoder's green–magenta units. Carried for
    /// completeness; the white-balance matrix is anchored on Kelvin.
    public var asShotTint: Double
    /// The rendered image's longest edge in pixels — clarity and vignette
    /// scale from it so a preview and an export get the same look.
    public var longEdge: Double

    public init(asShotTemperatureK: Double = 6500, asShotTint: Double = 0, longEdge: Double = 0) {
        self.asShotTemperatureK = asShotTemperatureK
        self.asShotTint = asShotTint
        self.longEdge = longEdge
    }
}

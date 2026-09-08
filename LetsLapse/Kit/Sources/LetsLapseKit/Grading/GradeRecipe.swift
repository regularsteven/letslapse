import Foundation

/// One grade, engine-ready: the Lightroom-basic-panel parameter set the tone
/// engine renders. This is the *engine's* model — the app's `PhotoAdjustments`
/// (UI ranges, persistence, legacy migration) converts into it.
///
/// Every field's neutral value is 0 bar `noiseDetail`, which is a two-sided
/// control centred at 0.5 (and means nothing at all while its parent slider
/// sits at 0). `neutral` is still a constant, so a caller can skip the whole
/// render when nothing would change a pixel.
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
    /// An absolute declared illuminant in Kelvin, replacing "as shot" as the
    /// anchor `temperatureMired` is measured from. Nil — the default — keeps
    /// the historic behaviour exactly: every frame is anchored on its own
    /// as-shot reading, so the offset is a relative nudge.
    ///
    /// Set, it *pins* the anchor, which is the whole point: a shoot whose
    /// camera moved its own white balance mid-run (an auto-WB step, or the
    /// coarse plateaus a body walks through at dusk) renders every frame at
    /// the same declared white, and the camera's decisions stop reaching the
    /// picture. The offset still applies on top, so a preset's "warm it a
    /// little" survives.
    ///
    /// This is a *project* choice, never a preset's — see
    /// `PhotoAdjustments.withoutRotation` for the same treatment of the other
    /// field that must not travel between shoots.
    public var declaredKelvin: Float?
    /// The declared illuminant's tint, in the raw converter's own
    /// green–magenta units (±150, the axis `CIRAWFilter.neutralTint` and
    /// Adobe's Tint slider share) rather than the recipe's ±1. It is stored
    /// in converter units because that is the space the reading came from and
    /// the space it is written back into; only the Bradford fallback has to
    /// convert, through `LinearFrameDecoder.cirawTintPerRecipeUnit`.
    public var declaredTint: Float?
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
    /// How far the sharpen amount is gated by local edge energy — Lightroom's
    /// Masking. 0 sharpens every pixel equally (what the engine always did);
    /// 1 leaves flat areas alone and spends the whole amount on edges. 0…1.
    public var sharpenMasking: Float = 0
    /// Luminance noise reduction — a frequency split on encoded luma: the
    /// Gaussian base layer is never touched, only the fine residual riding on
    /// it is shrunk, so coarse structure survives any setting. 0…1.
    public var noiseReduction: Float = 0
    /// How much of the fine layer survives the shrink, independent of the
    /// amount: 0 takes the whole residual down to the base, 1 leaves all but
    /// the smallest fluctuations standing. A *preservation* control, the
    /// direction Lightroom's Detail slider runs. Two-sided, neutral 0.5.
    public var noiseDetail: Float = 0.5
    /// Colour noise reduction — steers chroma toward the tonally-similar
    /// neighbourhood, which is where the mottling in pushed dark scenes
    /// lives. 0…1.
    public var colorNoiseReduction: Float = 0
    /// Chroma noise reduction — a spatial Gaussian on Cb/Cr with luma left
    /// alone, which is what dissolves purple shadow haze and colour speckle
    /// without costing any detail. 0…1.
    public var colorNoise: Float = 0
    /// Darkens the corners. 0…1.
    public var vignette: Float = 0
    /// Haze removal (positive) or haze (negative), −1…+1 — Lightroom's
    /// Dehaze ÷ 100. The one control the Metal kernel does NOT render: it is
    /// a dark-channel prior over the finished picture (`Dehaze`), run by
    /// `EnginePostPasses` after the engine, because its airlight estimate
    /// needs the whole frame and its natural place is on rendered pixels.
    public var dehaze: Float = 0
    /// The HSL panel, when the grade moves any of its sliders. Nil is
    /// neutral. Rendered after the engine by `EnginePostPasses`, like dehaze.
    public var hsl: HSLAdjustments?

    public init() {}

    /// True when the HSL panel would change a pixel.
    public var hasHSL: Bool { hsl.map { !$0.isNeutral } ?? false }

    public static let neutral = GradeRecipe()

    public var isNeutral: Bool { self == .neutral }

    /// True when the recipe pins its own white-balance anchor instead of
    /// taking each frame's as-shot reading. Callers key decode caches on this
    /// (a declared balance is applied inside the converter, so it changes
    /// pixels at decode time) and the matrix path branches on it.
    public var hasDeclaredWhiteBalance: Bool { declaredKelvin != nil || declaredTint != nil }

    /// Bumped whenever the engine's math changes so render caches keyed on
    /// recipes self-invalidate across engine revisions.
    ///
    /// 2: local tone — shadows/highlights keyed on the guided-filter base,
    ///    clarity as ±detail gain, chroma-protected deep-shadow lifts,
    ///    clip-targeted highlight desaturation.
    /// 3: detail stage — luma NR's spatial footprint scales with the render
    ///    instead of being fixed in pixels, its range gate splits off into
    ///    `noiseDetail`, and sharpening gains an edge mask.
    /// 4: chroma NR — a YCbCr pass that smooths Cb/Cr on spatial distance
    ///    alone and carries Y through untouched.
    /// 5: luma NR — the bilateral becomes a frequency split (Gaussian base
    ///    kept whole, soft-thresholded detail residual), and `noiseDetail`
    ///    inverts from a range gate into a preservation control.
    /// 6: neutral is identity for display-referred sources — the hidden base
    ///    look, the neutral highlight roll-off and the desaturation floor are
    ///    gated on `GradeReference.displayReferred`, so a JPEG/HEIF/PNG renders
    ///    as its own pixels at Original instead of through a second rendering.
    public static let engineVersion = 6

    /// The declared-anchor half of the cache token. Empty — and so free of
    /// any effect on existing keys — while the anchor is as-shot.
    public var declaredToken: String {
        guard hasDeclaredWhiteBalance else { return "" }
        return String(format: "|d%.1f,%.2f", declaredKelvin ?? 0, declaredTint ?? 0)
    }

    /// A short, stable string identifying this grade for cache keys.
    public var cacheToken: String {
        guard !isNeutral else { return "e\(Self.engineVersion)|n" }
        let values: [Float] = [
            exposure, contrast, highlights, shadows, whites, blacks,
            temperatureMired, tint, vibrance, saturation, clarity, vignette,
            texture, sharpen, sharpenMasking, noiseReduction, noiseDetail,
            colorNoiseReduction, colorNoise,
        ]
        let joined = values.map { String(format: "%.4f", $0) }.joined(separator: ",")
        // Appended only when set, so every key minted before the control
        // existed reads exactly as it did.
        let post = (dehaze != 0 ? String(format: "|dh%.4f", dehaze) : "")
            + (hasHSL ? "|hsl" + (hsl?.cacheToken ?? "") : "")
        return "e\(Self.engineVersion)|\(joined)\(declaredToken)\(post)"
    }
}

/// Per-project anchors the engine needs beside the recipe: what "as shot"
/// means for this file, and the pixel scale the spatial effects key to.
public struct GradeReference: Sendable, Equatable {
    /// The as-shot illuminant, from the DNG's own metadata when available.
    public var asShotTemperatureK: Double
    /// The as-shot tint, in the decoder's green–magenta units. Carried for
    /// completeness; the white-balance matrix is anchored on Kelvin.
    public var asShotTint: Double
    /// The rendered image's longest edge in pixels — clarity and vignette
    /// scale from it so a preview and an export get the same look.
    public var longEdge: Double
    /// The file the texture was decoded from, when there is one. Only the
    /// `.forwardMatrix` decode path reads it — that path builds its
    /// white-balance matrix out of the DNG's own calibration tags, so it needs
    /// to get back to the bytes. Nil for textures with no file behind them
    /// (the blend path grades an accumulated buffer), which is why the whole
    /// thing degrades to Bradford rather than failing.
    public var sourceURL: URL?
    /// Which decode path produced the texture and should shape the
    /// white-balance matrix. Defaults to `.bradfordAdaptation` so every
    /// existing call site keeps exactly the behaviour it had.
    public var decodePath: RawDecodePath
    /// True when the texture is already a rendered picture — a JPEG, HEIF,
    /// PNG or TIFF that ImageIO decoded, carrying the camera's or Lightroom's
    /// own tone rendering. The engine's hidden base look, its neutral
    /// highlight roll-off and its neutral desaturation floor exist to make a
    /// scene-linear raw decode look the way DNG consumers render it by
    /// default; on a picture that has already been rendered they are a second
    /// rendering (measured on a Lightroom JPEG: median gray 198 → 228, blue
    /// clipped). With this set, `.neutral` is a true identity: output pixels
    /// are input pixels. Defaults to false (scene-referred) so every
    /// hand-built reference — and every raw decode — keeps the look it had.
    public var displayReferred: Bool

    public init(
        asShotTemperatureK: Double = 6500,
        asShotTint: Double = 0,
        longEdge: Double = 0,
        sourceURL: URL? = nil,
        decodePath: RawDecodePath = .bradfordAdaptation,
        displayReferred: Bool = false
    ) {
        self.asShotTemperatureK = asShotTemperatureK
        self.asShotTint = asShotTint
        self.longEdge = longEdge
        self.sourceURL = sourceURL
        self.decodePath = decodePath
        self.displayReferred = displayReferred
    }
}

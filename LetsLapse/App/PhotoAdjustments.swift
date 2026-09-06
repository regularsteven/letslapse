import CoreGraphics
import Foundation
import LetsLapseKit

/// The manual grade that sits *on top* of a `PhotoPreset` — the slider panel
/// in the photo viewer. Non-destructive: the values are stored on the project
/// and re-applied on demand, so the original file on disk is never rewritten.
///
/// v2 (the grading-engine rebuild): Lightroom-basic-panel parity. Fields are
/// stored in the engine's normalized units — ±1 for the ±100 sliders, EV for
/// exposure, a mired offset from as-shot for temperature — and map 1:1 onto
/// `GradeRecipe`. Every field's neutral value is 0, so `.neutral` renders
/// exactly the preset on its own.
struct PhotoAdjustments: Codable, Equatable {
    /// Exposure in EV stops. −5…+5.
    var exposure: Float
    /// Pivoted contrast. −1…+1.
    var contrast: Float
    /// Negative recovers highlights, positive lifts them. −1…+1
    /// (v1 stored only −1…0; those values load unchanged).
    var highlights: Float
    /// Negative deepens shadows, positive lifts them. −1…+1.
    var shadows: Float
    /// Moves the white point. −1…+1.
    var whites: Float
    /// Moves the black point: negative crushes, positive lifts to matte. −1…+1.
    var blacks: Float
    /// The white this moment is declared at, in mired (reciprocal megakelvin)
    /// — **the white itself, not a nudge.** 0 means the frame's own as-shot;
    /// anything else is owned, and owned means the camera's decision no longer
    /// reaches the picture: two frames a camera balanced 116 mired apart
    /// render at the same white when both own the same value.
    ///
    /// Stored in mired rather than Kelvin because keyframes interpolate this
    /// field like any other, and mired is the axis on which equal steps look
    /// equal — a ramp lerped in Kelvin is front-loaded to the eye. The
    /// readout converts. Range 40…600 (25000 K … 1667 K, the converter's
    /// travel); 0 is a sentinel outside it, never a value.
    var whiteMired: Float
    /// The owned white's tint, on the raw converter's ±150 green–magenta
    /// axis (the axis Adobe's Tint also uses). Meaningful only while
    /// `whiteMired` is owned.
    var whiteTint: Float
    /// A mired *offset* layered under the owned white; positive renders
    /// warmer. This is a preset's "warm it a little" — the one legitimately
    /// relative thing, because a look has to travel across shoots with
    /// different whites. No control writes it any more; it survives for
    /// presets and for decoding grades saved before the white was owned.
    var temperature: Float
    /// The preset's tint offset, −1…+1. Same standing as `temperature`.
    var tint: Float
    /// Raises muted colours more than already-saturated ones. −1…1.
    var vibrance: Float
    /// Uniform chroma gain. −1…+1.
    var saturation: Float
    /// Local contrast as detail gain: positive adds punch, negative smooths.
    /// −1…+1.
    var clarity: Float
    /// Mid-frequency detail — the band between clarity's regions and
    /// sharpen's pixels. −1…+1.
    var texture: Float
    /// Capture sharpening: small-radius luma acutance. 0…1.
    var sharpen: Float
    /// How far sharpening is held back where there is no edge to sharpen —
    /// Lightroom's Masking. 0…1, neutral 0 (sharpen everything equally).
    var sharpenMasking: Float
    /// Luminance noise reduction: a frequency split that shrinks fine grain
    /// and leaves the coarse structure under it alone. 0…1.
    var noiseReduction: Float
    /// How much of that fine layer survives the shrink, separate from the
    /// amount — up keeps more. 0…1, neutral 0.5, and inert while
    /// `noiseReduction` is 0.
    var noiseDetail: Float
    /// Colour noise reduction: dissolves chroma mottling in pushed dark
    /// scenes; the smoothing reach grows with the slider. 0…1.
    var colorNoiseReduction: Float
    /// Chroma noise reduction: a spatial Gaussian on Cb/Cr with luma left
    /// alone — purple shadow haze and colour speckle go, detail stays. 0…1.
    var colorNoise: Float
    /// Darkens the corners. 0…1.
    var vignetteIntensity: Float
    /// The Edit screen's fine rotation in degrees, positive clockwise —
    /// `FrameRotation` owns the geometry. The one field here that is not a
    /// colour: it lives in this struct so the grade timeline carries it per
    /// keyframe and eases it between moments exactly like every other
    /// control, but it is kept OUT of presets (`withoutRotation` at save and
    /// compare time) and out of the Original/Edited verdict, and the colour
    /// engine never sees it (`recipe(over:)` ignores it). −10…+10.
    var rotationDegrees: Float

    /// Every slider at its no-op value — the preset alone, ungarnished. Every
    /// field is 0 except `noiseDetail`, whose no-op is the middle of its
    /// travel — so anything resetting one control asks
    /// `PhotoAdjustmentField.neutralValue` rather than writing a zero.
    static var neutral: PhotoAdjustments {
        .init(exposure: 0, contrast: 0, highlights: 0, shadows: 0, whites: 0,
              blacks: 0, whiteMired: 0, whiteTint: 0,
              temperature: 0, tint: 0, vibrance: 0, saturation: 0,
              clarity: 0, texture: 0, sharpen: 0, sharpenMasking: 0,
              noiseReduction: 0, noiseDetail: neutralNoiseDetail,
              colorNoiseReduction: 0, colorNoise: 0, vignetteIntensity: 0,
              rotationDegrees: 0)
    }

    /// True when the rotation would change a pixel.
    var hasRotation: Bool { FrameRotation.isActive(Double(rotationDegrees)) }

    /// These values with the rotation taken out — what a preset stores, what
    /// the Original/Edited verdict looks at, and what a path that levels
    /// separately hands the colour engine.
    var withoutRotation: PhotoAdjustments {
        var copy = self
        copy.rotationDegrees = 0
        return copy
    }

    /// True when no COLOUR control has moved, whatever the rotation says. An
    /// owned white counts: it moves pixels, so a render cannot be skipped.
    var isColorNeutral: Bool { withoutRotation == .neutral }

    /// True when no LOOK has been applied — rotation and the owned white set
    /// aside, both being corrections of the capture rather than treatments of
    /// it. The Original/Edited verdict asks this.
    var isLookNeutral: Bool { withoutRotation.withoutWhite == .neutral }

    /// True when this moment owns its white rather than taking the camera's.
    var ownsWhite: Bool { whiteMired > 0 }

    /// The owned white as the converter wants it, or nil for as-shot.
    var ownedWhite: (kelvin: Float, tint: Float)? {
        guard ownsWhite else { return nil }
        return (1e6 / min(max(whiteMired, Self.whiteMiredRange.lowerBound),
                          Self.whiteMiredRange.upperBound), whiteTint)
    }

    /// These values with the owned white released — what a preset stores. A
    /// look is a way of treating light, not a claim about which light it was:
    /// a preset that pinned one shoot's 5200 K would wreck the next shoot it
    /// was applied to.
    var withoutWhite: PhotoAdjustments {
        var copy = self
        copy.whiteMired = 0
        copy.whiteTint = 0
        return copy
    }

    /// The middle of the Detail sub-slider's travel — the gate width the
    /// engine used before the control existed.
    static let neutralNoiseDetail: Float = 0.5

    /// True when nothing here would change a pixel, so the grader can skip the
    /// whole chain (and the export can save the original bytes untouched).
    var isNeutral: Bool { self == .neutral }

    // MARK: - Slider ranges
    //
    // Kept next to the values they bound so the viewer's sliders and the
    // grader's mappings can never drift apart.

    static let exposureRange: ClosedRange<Float> = -5...5
    static let contrastRange: ClosedRange<Float> = -1...1
    static let highlightsRange: ClosedRange<Float> = -1...1
    static let shadowsRange: ClosedRange<Float> = -1...1
    static let whitesRange: ClosedRange<Float> = -1...1
    static let blacksRange: ClosedRange<Float> = -1...1
    /// The converter's own travel, 25000 K down to 1667 K.
    static let whiteMiredRange: ClosedRange<Float> = 40...600
    static let whiteTintRange: ClosedRange<Float> = -150...150
    static let temperatureRange: ClosedRange<Float> = -150...150
    static let tintRange: ClosedRange<Float> = -1...1
    static let vibranceRange: ClosedRange<Float> = -1...1
    static let saturationRange: ClosedRange<Float> = -1...1
    static let clarityRange: ClosedRange<Float> = -1...1
    static let textureRange: ClosedRange<Float> = -1...1
    static let sharpenRange: ClosedRange<Float> = 0...1
    static let sharpenMaskingRange: ClosedRange<Float> = 0...1
    static let noiseReductionRange: ClosedRange<Float> = 0...1
    static let noiseDetailRange: ClosedRange<Float> = 0...1
    static let colorNoiseReductionRange: ClosedRange<Float> = 0...1
    static let colorNoiseRange: ClosedRange<Float> = 0...1
    static let vignetteRange: ClosedRange<Float> = 0...1
    static let rotationRange: ClosedRange<Float> =
        Float(FrameRotation.range.lowerBound)...Float(FrameRotation.range.upperBound)

    /// The engine-side recipe these adjustments describe, optionally layered
    /// on a preset's base recipe (component-wise, clamped to the UI ranges).
    func recipe(over base: GradeRecipe = GradeRecipe()) -> GradeRecipe {
        var recipe = base
        recipe.exposure = min(max(base.exposure + exposure, -5), 5)
        recipe.contrast = min(max(base.contrast + contrast, -1), 1)
        recipe.highlights = min(max(base.highlights + highlights, -1), 1)
        recipe.shadows = min(max(base.shadows + shadows, -1), 1)
        recipe.whites = min(max(base.whites + whites, -1), 1)
        recipe.blacks = min(max(base.blacks + blacks, -1), 1)
        recipe.temperatureMired = min(max(base.temperatureMired + temperature, -150), 150)
        recipe.tint = min(max(base.tint + tint, -1), 1)
        // The owned white is absolute, so it is not layered — it replaces the
        // anchor the offsets above are measured from. A preset's own offset
        // still rides on it, which is what lets a look stay a look.
        if let white = ownedWhite {
            recipe.declaredKelvin = white.kelvin
            recipe.declaredTint = white.tint
        }
        recipe.vibrance = min(max(base.vibrance + vibrance, -1), 1)
        recipe.saturation = min(max(base.saturation + saturation, -1), 1)
        recipe.clarity = min(max(base.clarity + clarity, -1), 1)
        recipe.texture = min(max(base.texture + texture, -1), 1)
        recipe.sharpen = min(max(base.sharpen + sharpen, 0), 1)
        recipe.sharpenMasking = min(max(base.sharpenMasking + sharpenMasking, 0), 1)
        recipe.noiseReduction = min(max(base.noiseReduction + noiseReduction, 0), 1)
        // Centred at 0.5, so what layers onto the preset is the offset from
        // neutral — adding the value itself would double a preset's gate.
        recipe.noiseDetail = min(
            max(base.noiseDetail + (noiseDetail - Self.neutralNoiseDetail), 0), 1)
        recipe.colorNoiseReduction = min(max(base.colorNoiseReduction + colorNoiseReduction, 0), 1)
        recipe.colorNoise = min(max(base.colorNoise + colorNoise, 0), 1)
        recipe.vignette = min(max(base.vignette + vignetteIntensity, 0), 1)
        return recipe
    }

    /// A short, stable string identifying this grade, for the render cache key.
    var cacheToken: String {
        guard !isNeutral else { return "n" }
        return String(
            format: "%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.1f,%.3f,%.3f,%.3f,%.3f,%.3f,"
                + "%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f",
            exposure, contrast, highlights, shadows, whites, blacks,
            temperature, tint, vibrance, saturation, clarity, vignetteIntensity,
            texture, sharpen, sharpenMasking, noiseReduction, noiseDetail,
            colorNoiseReduction, colorNoise)
            + (hasRotation ? String(format: ",r%.2f", rotationDegrees) : "")
            + (ownsWhite ? String(format: ",w%.2f,%.1f", whiteMired, whiteTint) : "")
    }

    // MARK: - Codable
    //
    // A versioned envelope, per-field tolerant inside a version: v2 decodes
    // each field with a neutral default so a future field costs nothing, and
    // anything without a version marker is a v1 payload routed through the
    // one migration function below.

    init(exposure: Float, contrast: Float, highlights: Float, shadows: Float,
         whites: Float, blacks: Float, whiteMired: Float = 0, whiteTint: Float = 0,
         temperature: Float, tint: Float,
         vibrance: Float, saturation: Float, clarity: Float, texture: Float = 0,
         sharpen: Float = 0, sharpenMasking: Float = 0,
         noiseReduction: Float = 0,
         noiseDetail: Float = PhotoAdjustments.neutralNoiseDetail,
         colorNoiseReduction: Float = 0, colorNoise: Float = 0,
         vignetteIntensity: Float, rotationDegrees: Float = 0) {
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.whiteMired = whiteMired
        self.whiteTint = whiteTint
        self.temperature = temperature
        self.tint = tint
        self.vibrance = vibrance
        self.saturation = saturation
        self.clarity = clarity
        self.texture = texture
        self.sharpen = sharpen
        self.sharpenMasking = sharpenMasking
        self.noiseReduction = noiseReduction
        self.noiseDetail = noiseDetail
        self.colorNoiseReduction = colorNoiseReduction
        self.colorNoise = colorNoise
        self.vignetteIntensity = vignetteIntensity
        self.rotationDegrees = rotationDegrees
    }

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case exposure, contrast, highlights, shadows, whites, blacks
        case temperature, tint, vibrance, saturation, clarity, vignetteIntensity
        case texture, sharpen, noiseReduction, colorNoiseReduction, colorNoise
        case sharpenMasking, noiseDetail
        case whiteMired, whiteTint
        case rotationDegrees = "rotation"
        case whiteBalance  // v1 only; never written by v2
    }

    /// The white-balance picker of the v1 model, kept only to decode old
    /// payloads. The presets became slider-setters; see `migratingV1`.
    private enum LegacyWhiteBalance: String, Decodable {
        case asShot = "As Shot"
        case auto = "Auto"
        case sunny = "Sunny"
        case cloudy = "Cloudy"
        case fluorescent = "Fluorescent"
        case tungsten = "Tungsten"

        /// The v2 mired offset that declares this preset's illuminant against
        /// the v1 renderer's 6500 K anchor. `asShot` and `auto` migrate to 0 —
        /// auto was a damped near-no-op and is now a one-shot action, not a
        /// stored state.
        var temperatureOffset: Float {
            switch self {
            case .asShot, .auto: return 0
            case .sunny: return -28       // 5500 K declared
            case .cloudy: return 0        // 6500 K = the anchor itself
            case .fluorescent: return -96 // 4000 K
            case .tungsten: return -150   // 3200 K, clamped to the slider
            }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        func field(_ key: CodingKeys, default fallback: Float = 0) -> Float {
            (try? container.decodeIfPresent(Float.self, forKey: key)) ?? fallback
        }
        if version >= 2 {
            self.init(
                exposure: field(.exposure), contrast: field(.contrast),
                highlights: field(.highlights), shadows: field(.shadows),
                whites: field(.whites), blacks: field(.blacks),
                whiteMired: field(.whiteMired), whiteTint: field(.whiteTint),
                temperature: field(.temperature), tint: field(.tint),
                vibrance: field(.vibrance), saturation: field(.saturation),
                clarity: field(.clarity), texture: field(.texture),
                sharpen: field(.sharpen), sharpenMasking: field(.sharpenMasking),
                noiseReduction: field(.noiseReduction),
                // A payload written before the sub-slider existed carries the
                // gate the engine had then, which is the middle of its travel.
                noiseDetail: field(.noiseDetail, default: Self.neutralNoiseDetail),
                colorNoiseReduction: field(.colorNoiseReduction),
                colorNoise: field(.colorNoise),
                vignetteIntensity: field(.vignetteIntensity),
                rotationDegrees: field(.rotationDegrees))
            return
        }
        let legacyWB = (try? container.decodeIfPresent(LegacyWhiteBalance.self, forKey: .whiteBalance)) ?? .asShot
        self = PhotoAdjustments.migratingV1(
            highlights: field(.highlights), shadows: field(.shadows),
            vibrance: field(.vibrance), clarity: field(.clarity),
            vignetteIntensity: field(.vignetteIntensity), whiteBalance: legacyWB)
    }

    /// The single v1 → v2 mapping. v1's ranges are subsets of v2's, so the
    /// tonal fields pass through unchanged; only the white-balance enum needs
    /// re-expression.
    private static func migratingV1(
        highlights: Float, shadows: Float, vibrance: Float, clarity: Float,
        vignetteIntensity: Float, whiteBalance: LegacyWhiteBalance
    ) -> PhotoAdjustments {
        var adjustments = PhotoAdjustments.neutral
        adjustments.highlights = highlights
        adjustments.shadows = shadows
        adjustments.vibrance = vibrance
        adjustments.clarity = clarity
        adjustments.vignetteIntensity = vignetteIntensity
        adjustments.temperature = whiteBalance.temperatureOffset
        return adjustments
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(2, forKey: .version)
        try container.encode(exposure, forKey: .exposure)
        try container.encode(contrast, forKey: .contrast)
        try container.encode(highlights, forKey: .highlights)
        try container.encode(shadows, forKey: .shadows)
        try container.encode(whites, forKey: .whites)
        try container.encode(blacks, forKey: .blacks)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(tint, forKey: .tint)
        try container.encode(vibrance, forKey: .vibrance)
        try container.encode(saturation, forKey: .saturation)
        try container.encode(clarity, forKey: .clarity)
        try container.encode(texture, forKey: .texture)
        try container.encode(sharpen, forKey: .sharpen)
        try container.encode(sharpenMasking, forKey: .sharpenMasking)
        try container.encode(noiseReduction, forKey: .noiseReduction)
        try container.encode(noiseDetail, forKey: .noiseDetail)
        try container.encode(colorNoiseReduction, forKey: .colorNoiseReduction)
        try container.encode(colorNoise, forKey: .colorNoise)
        try container.encode(vignetteIntensity, forKey: .vignetteIntensity)
        // Only when set: an unlevelled project reads and writes exactly the
        // payload it always did.
        if hasRotation {
            try container.encode(rotationDegrees, forKey: .rotationDegrees)
        }
        // Same rule for the white: a project that never owned one keeps its
        // payload byte for byte.
        if ownsWhite {
            try container.encode(whiteMired, forKey: .whiteMired)
            try container.encode(whiteTint, forKey: .whiteTint)
        }
    }
}

/// A project's whole grade in one value: the preset, the manual adjustments
/// layered on it, and — for a shoot with length — how those adjustments travel
/// over the capture. Photo, Interval and Video captures all carry one — a still
/// is graded frame by frame, a movie through a video composition — so the paths
/// that render or export take this rather than the halves separately.
struct PhotoGrade: Equatable, Sendable {
    var preset: PhotoPreset
    var adjustments: PhotoAdjustments
    /// The keyframes, when the grade changes across the shoot. Empty for a
    /// still, and for every clip graded with one look end to end — which is
    /// every clip until somebody edits at a second moment.
    var timeline: GradeTimeline = .empty
    /// What the temperature and tint offsets are measured *from*.
    ///
    /// `.asShot` — the default, and every project's behaviour before this
    /// existed — anchors each frame on its own as-shot reading, which is right
    /// for a still and for a run shot on a locked white balance. Over a
    /// sequence whose camera re-decided mid-run it is the reason the same
    /// slider value renders a different white either side of the decision:
    /// the anchor moves under the offset. Pinning it here makes the offsets
    /// absolute. See `WhiteBalanceSource`.
    var whiteBalance: WhiteBalanceTrack = .asShot

    /// The grade that changes nothing: the file exactly as captured.
    static let identity = PhotoGrade(preset: .original, adjustments: .neutral)

    /// True when the white balance is anchored on something other than each
    /// frame's own as-shot reading — which makes it a pixel-moving choice even
    /// with every slider at zero.
    var hasDeclaredWhiteBalance: Bool { !whiteBalance.source.isAsShot }

    /// True when nothing here would move a pixel — no filter in the chain and
    /// no rotation at any moment — so every render can be skipped and every
    /// export can hand over the original bytes.
    var isIdentity: Bool { isColorIdentity && !hasRotation }

    /// True when the colour chain alone is a no-op, whatever the geometry.
    var isColorIdentity: Bool {
        preset == .original && adjustments.isColorNeutral && timeline.isLookEmpty
            && !ownsWhite && !hasDeclaredWhiteBalance
    }

    /// True when any moment of the grade owns its white.
    var ownsWhite: Bool {
        adjustments.ownsWhite || timeline.keyframes.contains { $0.adjustments.ownsWhite }
    }

    // MARK: Rotation
    //
    // The Edit screen's fine rotation rides inside `PhotoAdjustments` so the
    // timeline can keyframe it (`FrameRotation` owns the geometry); these are
    // the views of it the render paths want.

    /// The rotation at the OPENING moment, degrees, positive clockwise — the
    /// one every single-image surface shows, and the space text layers are
    /// stored in. `rotationDegrees(at:)` is the moment-aware read.
    var rotationDegrees: Double { Double(adjustments.rotationDegrees) }

    /// The rotation at one moment of the source, eased between keyframes
    /// exactly like the colour controls.
    func rotationDegrees(at position: Double) -> Double {
        Double(adjustments(at: position).rotationDegrees)
    }

    /// True when the rotation would change a pixel at ANY moment.
    var hasRotation: Bool {
        adjustments.hasRotation || timeline.keyframes.contains { $0.adjustments.hasRotation }
    }

    /// True when the rotation changes across the clip.
    var hasKeyframedRotation: Bool { timeline.keyframedFields.contains(.rotation) }

    /// This grade with its rotation taken out everywhere — for the paths that
    /// level frames themselves, once per OUTPUT frame, and must not have the
    /// colour renderer level them a second time on the way in.
    var withoutRotation: PhotoGrade {
        PhotoGrade(
            preset: preset, adjustments: adjustments.withoutRotation,
            timeline: timeline.withoutRotation, whiteBalance: whiteBalance)
    }

    /// Only the corrections of this grade — the level and the owned white —
    /// with Original colour, kept at every moment. What an Original project
    /// renders through: neither is a filter, and a shoot whose camera would
    /// not hold its white is still Original once somebody has told it which
    /// white it was.
    var rotationOnly: PhotoGrade {
        var neutral = PhotoAdjustments.neutral
        neutral.rotationDegrees = adjustments.rotationDegrees
        neutral.whiteMired = adjustments.whiteMired
        neutral.whiteTint = adjustments.whiteTint
        return PhotoGrade(preset: .original, adjustments: neutral, timeline: timeline.rotationOnly)
    }

    /// True when the grade is a function of time, so a caller that can only
    /// apply one set of values has to say *when*.
    var isKeyframed: Bool { !timeline.isEmpty }

    /// The manual grade at one moment of the source, 0…1. Without keyframes
    /// this is the stored grade at every moment, which is what keeps every
    /// caller that never asks the question right by default.
    func adjustments(at position: Double) -> PhotoAdjustments {
        timeline.adjustments(at: position, baseline: adjustments)
    }

    /// This grade frozen at one moment — a plain, timeless `PhotoGrade` for the
    /// paths that render a single frame.
    func frozen(at position: Double) -> PhotoGrade {
        // A declared anchor is a function of position too — a smoothed track
        // walks a different white every frame — so freezing has to pin the
        // white as well as the sliders, and a non-keyframed grade with a
        // moving anchor is no longer a constant.
        guard isKeyframed || whiteBalance.variesOverTime else { return self }
        var frozen = PhotoGrade(preset: preset, adjustments: adjustments(at: position))
        if let declared = whiteBalance.declared(atPosition: position) {
            frozen.whiteBalance = WhiteBalanceTrack(
                source: .fixed(kelvin: declared.kelvin, tint: declared.tint))
        }
        return frozen
    }

    /// The engine recipe at one moment: the preset's base recipe with that
    /// moment's manual adjustments layered on top.
    func recipe(at position: Double) -> GradeRecipe {
        var recipe = adjustments(at: position).recipe(over: preset.recipe)
        // Resolved here, at the one place a moment becomes a recipe, so every
        // render path — preview, blend, export, thumbnail — gets the white for
        // the frame it is actually drawing. An owned white (already on the
        // recipe, from the keyframes) outranks the smoothed track: the track
        // is what a frame renders at until somebody says otherwise.
        if !recipe.hasDeclaredWhiteBalance,
           let declared = whiteBalance.declared(atPosition: position) {
            recipe.declaredKelvin = declared.kelvin
            recipe.declaredTint = declared.tint
        }
        return recipe
    }

    /// The white one moment of the source is declared at — owned, or the
    /// smoothed track's, or nil for the frame's own as-shot. What the blend
    /// path asks per SOURCE frame, since the balance is applied at decode.
    func declaredWhite(at position: Double) -> (kelvin: Float, tint: Float)? {
        adjustments(at: position).ownedWhite ?? whiteBalance.declared(atPosition: position)
    }

    /// The engine recipe for this grade. A keyframed grade answers for its
    /// opening moment, which is the frame every single-image surface — card,
    /// thumbnail, hero — is showing.
    var recipe: GradeRecipe { recipe(at: 0) }

    /// A short, stable string identifying this grade — for render cache keys and
    /// for the `task(id:)` that re-renders a preview when the grade changes.
    /// Prefixed with the engine version so caches self-invalidate when the
    /// engine's math changes.
    var cacheToken: String {
        "e\(GradeRecipe.engineVersion)|\(preset.rawValue)|\(adjustments.cacheToken)"
            + (timeline.isEmpty ? "" : "|kf\(timeline.cacheToken)")
            + whiteBalance.cacheToken
    }
}

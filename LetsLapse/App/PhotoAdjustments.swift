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
    /// White balance as a mired offset from the as-shot illuminant; positive
    /// renders warmer. An offset, not an absolute Kelvin, so a saved preset
    /// carries "warm it a little" across photos with different as-shot values.
    var temperature: Float
    /// Green (−) to magenta (+). −1…+1.
    var tint: Float
    /// Raises muted colours more than already-saturated ones. −1…1.
    var vibrance: Float
    /// Uniform chroma gain. −1…+1.
    var saturation: Float
    /// Large-radius local contrast. 0…1.
    var clarity: Float
    /// Darkens the corners. 0…1.
    var vignetteIntensity: Float

    /// Every slider at its no-op value — the preset alone, ungarnished.
    static var neutral: PhotoAdjustments {
        .init(exposure: 0, contrast: 0, highlights: 0, shadows: 0, whites: 0,
              blacks: 0, temperature: 0, tint: 0, vibrance: 0, saturation: 0,
              clarity: 0, vignetteIntensity: 0)
    }

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
    static let temperatureRange: ClosedRange<Float> = -150...150
    static let tintRange: ClosedRange<Float> = -1...1
    static let vibranceRange: ClosedRange<Float> = -1...1
    static let saturationRange: ClosedRange<Float> = -1...1
    static let clarityRange: ClosedRange<Float> = 0...1
    static let vignetteRange: ClosedRange<Float> = 0...1

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
        recipe.vibrance = min(max(base.vibrance + vibrance, -1), 1)
        recipe.saturation = min(max(base.saturation + saturation, -1), 1)
        recipe.clarity = min(max(base.clarity + clarity, 0), 1)
        recipe.vignette = min(max(base.vignette + vignetteIntensity, 0), 1)
        return recipe
    }

    /// A short, stable string identifying this grade, for the render cache key.
    var cacheToken: String {
        guard !isNeutral else { return "n" }
        return String(
            format: "%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.1f,%.3f,%.3f,%.3f,%.3f,%.3f",
            exposure, contrast, highlights, shadows, whites, blacks,
            temperature, tint, vibrance, saturation, clarity, vignetteIntensity)
    }

    // MARK: - Codable
    //
    // A versioned envelope, per-field tolerant inside a version: v2 decodes
    // each field with a neutral default so a future field costs nothing, and
    // anything without a version marker is a v1 payload routed through the
    // one migration function below.

    init(exposure: Float, contrast: Float, highlights: Float, shadows: Float,
         whites: Float, blacks: Float, temperature: Float, tint: Float,
         vibrance: Float, saturation: Float, clarity: Float, vignetteIntensity: Float) {
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.temperature = temperature
        self.tint = tint
        self.vibrance = vibrance
        self.saturation = saturation
        self.clarity = clarity
        self.vignetteIntensity = vignetteIntensity
    }

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case exposure, contrast, highlights, shadows, whites, blacks
        case temperature, tint, vibrance, saturation, clarity, vignetteIntensity
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
        func field(_ key: CodingKeys) -> Float {
            (try? container.decodeIfPresent(Float.self, forKey: key)) ?? 0
        }
        if version >= 2 {
            self.init(
                exposure: field(.exposure), contrast: field(.contrast),
                highlights: field(.highlights), shadows: field(.shadows),
                whites: field(.whites), blacks: field(.blacks),
                temperature: field(.temperature), tint: field(.tint),
                vibrance: field(.vibrance), saturation: field(.saturation),
                clarity: field(.clarity), vignetteIntensity: field(.vignetteIntensity))
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
        try container.encode(vignetteIntensity, forKey: .vignetteIntensity)
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

    /// The grade that changes nothing: the file exactly as captured.
    static let identity = PhotoGrade(preset: .original, adjustments: .neutral)

    /// True when no filter in the chain would move a pixel, so every render can
    /// be skipped and every export can hand over the original bytes.
    var isIdentity: Bool { preset == .original && adjustments.isNeutral && timeline.isEmpty }

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
        guard isKeyframed else { return self }
        return PhotoGrade(preset: preset, adjustments: adjustments(at: position))
    }

    /// The engine recipe at one moment: the preset's base recipe with that
    /// moment's manual adjustments layered on top.
    func recipe(at position: Double) -> GradeRecipe {
        adjustments(at: position).recipe(over: preset.recipe)
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
    }
}

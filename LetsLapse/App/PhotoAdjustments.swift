import CoreGraphics
import Foundation

/// The manual grade that sits *on top* of a `PhotoPreset` — the five sliders
/// and the white-balance picker in the photo viewer. Like the presets, this is
/// non-destructive: the values are stored on the project and re-applied on
/// demand, so the original file on disk is never rewritten.
///
/// Every field's neutral value is the one that makes its filter a no-op, so
/// `.neutral` renders exactly the preset on its own.
///
/// The ranges were calibrated against a 12 MP iPhone DNG (`frame-00001.dng`)
/// with a Lightroom edit of the same frame as the target. See
/// `PhotoGrader.adjust(_:_:asShotKelvin:)` for the filter mappings and
/// `docs/design/iOS/project-photos.viewer.portrait.svg` for the UI.
struct PhotoAdjustments: Codable, Equatable {
    /// Pulls highlights down. -1 is the strongest reduction, 0 leaves them.
    var highlights: Float
    /// Lifts shadows. 0 leaves them, 1 is the strongest lift.
    var shadows: Float
    /// Raises muted colours more than already-saturated ones. -1…1.
    var vibrance: Float
    /// Large-radius local contrast. 0…1.
    var clarity: Float
    /// Darkens the corners. 0…1.
    var vignetteIntensity: Float
    /// Which illuminant the scene is treated as having been lit by.
    var whiteBalance: WhiteBalance

    enum WhiteBalance: String, Codable, CaseIterable, Identifiable {
        case asShot      = "As Shot"
        case auto        = "Auto"
        case sunny       = "Sunny"
        case cloudy      = "Cloudy"
        case fluorescent = "Fluorescent"
        case tungsten    = "Tungsten"

        var id: String { rawValue }
        var displayName: String { rawValue }

        /// The illuminant temperature this option declares the scene to have
        /// been shot under. `nil` means "don't impose one": `asShot` keeps the
        /// camera's own white balance and `auto` estimates it from the pixels.
        var kelvin: Float? {
            switch self {
            case .asShot, .auto: return nil
            case .sunny: return 5500
            case .cloudy: return 6500
            case .fluorescent: return 4000
            case .tungsten: return 3200
            }
        }
    }

    /// Every filter at its no-op value — the preset alone, ungarnished.
    static var neutral: PhotoAdjustments {
        .init(highlights: 0, shadows: 0, vibrance: 0, clarity: 0,
              vignetteIntensity: 0, whiteBalance: .asShot)
    }

    /// True when nothing here would change a pixel, so the grader can skip the
    /// whole chain (and the export can save the original bytes untouched).
    var isNeutral: Bool { self == .neutral }

    // MARK: - Slider ranges
    //
    // Kept next to the values they bound so the viewer's sliders and the
    // grader's filter mappings can never drift apart.

    static let highlightsRange: ClosedRange<Float> = -1...0
    static let shadowsRange: ClosedRange<Float> = 0...1
    static let vibranceRange: ClosedRange<Float> = -1...1
    static let clarityRange: ClosedRange<Float> = 0...1
    static let vignetteRange: ClosedRange<Float> = 0...1

    /// A short, stable string identifying this grade, for the render cache key.
    var cacheToken: String {
        guard !isNeutral else { return "n" }
        return String(
            format: "%.3f,%.3f,%.3f,%.3f,%.3f,%@",
            highlights, shadows, vibrance, clarity, vignetteIntensity,
            whiteBalance.rawValue)
    }

    // MARK: - Codable
    //
    // Decoded field by field so a grade written by an older build — or one
    // written before a field existed — still loads, taking the neutral value
    // for anything missing rather than failing the whole project manifest.

    init(highlights: Float, shadows: Float, vibrance: Float, clarity: Float,
         vignetteIntensity: Float, whiteBalance: WhiteBalance) {
        self.highlights = highlights
        self.shadows = shadows
        self.vibrance = vibrance
        self.clarity = clarity
        self.vignetteIntensity = vignetteIntensity
        self.whiteBalance = whiteBalance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        highlights = try container.decodeIfPresent(Float.self, forKey: .highlights) ?? 0
        shadows = try container.decodeIfPresent(Float.self, forKey: .shadows) ?? 0
        vibrance = try container.decodeIfPresent(Float.self, forKey: .vibrance) ?? 0
        clarity = try container.decodeIfPresent(Float.self, forKey: .clarity) ?? 0
        vignetteIntensity = try container.decodeIfPresent(Float.self, forKey: .vignetteIntensity) ?? 0
        whiteBalance = try container.decodeIfPresent(WhiteBalance.self, forKey: .whiteBalance) ?? .asShot
    }
}

/// A project's whole grade in one value: the preset and the manual adjustments
/// layered on it. Photo, Interval and Video captures all carry one — a still is
/// graded frame by frame, a movie through a video composition — so the paths
/// that render or export take this rather than the two halves separately.
struct PhotoGrade: Equatable, Sendable {
    var preset: PhotoPreset
    var adjustments: PhotoAdjustments

    /// The grade that changes nothing: the file exactly as captured.
    static let identity = PhotoGrade(preset: .original, adjustments: .neutral)

    /// True when no filter in the chain would move a pixel, so every render can
    /// be skipped and every export can hand over the original bytes.
    var isIdentity: Bool { preset == .original && adjustments.isNeutral }

    /// A short, stable string identifying this grade — for render cache keys and
    /// for the `task(id:)` that re-renders a preview when the grade changes.
    var cacheToken: String { "\(preset.rawValue)|\(adjustments.cacheToken)" }
}

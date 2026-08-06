import CoreGraphics
import Foundation

// MARK: - Keyframe

/// One keyframe on the reframe timeline.
///
/// Speed, crop and blend all ride the *same* key on purpose: the three ramp
/// together between neighbours on one eased curve, so there is no second
/// timeline to keep in sync and no way for the punch to land off the lock.
struct PunchKeyframe: Identifiable, Codable, Equatable {
    var id = UUID()
    /// Source time, in seconds.
    var t: Double
    /// Punch factor. 1 = the whole frame at the chosen ratio; 6 = the tightest
    /// crop the engine allows.
    var z: Double
    /// Crop centre in *source pixels*, display-oriented — the same space as
    /// `AppModel.sourceDisplaySize()`, so a metadata rotation needs no fixups.
    var cx: Double
    var cy: Double
    /// Playback speed, × real time (0.25…100).
    var v: Double
    /// Blend depth, 0 (crisp) … 1 (heavy streaks).
    var bl: Double
    /// The user pinned `bl` by hand on this key; auto-blend leaves it alone.
    var ovr: Bool

    init(
        id: UUID = UUID(),
        t: Double,
        z: Double = 1,
        cx: Double,
        cy: Double,
        v: Double = 1,
        bl: Double = 0,
        ovr: Bool = false
    ) {
        self.id = id
        self.t = t
        self.z = z
        self.cx = cx
        self.cy = cy
        self.v = v
        self.bl = bl
        self.ovr = ovr
    }
}

// MARK: - Ratio

/// The output shape of the reframe crop. Mirrors `CanvasRatio` (the collection
/// and Adjust canvases) so a reframed clip can hand straight over to them —
/// the raw values are identical, and `canvas` bridges the two.
enum ReframeRatio: String, CaseIterable, Identifiable, Codable {
    case wide = "16:9"
    case tall = "9:16"
    case square = "1:1"
    case classic = "4:3"
    case portrait = "3:4"

    var id: String { rawValue }

    /// The chip's text — the ratio itself.
    var label: String { rawValue }

    /// Width ÷ height.
    var ratio: Double {
        switch self {
        case .wide: return 16.0 / 9.0
        case .tall: return 9.0 / 16.0
        case .square: return 1
        case .classic: return 4.0 / 3.0
        case .portrait: return 3.0 / 4.0
        }
    }

    /// What picking this shape costs you, for the menu rows.
    var cropNote: String {
        switch self {
        case .wide: return "wide — cinema and desktop"
        case .tall: return "tall — the full phone screen"
        case .square: return "square — even on every side"
        case .classic: return "classic — a little taller than wide"
        case .portrait: return "portrait — a little taller than square"
        }
    }

    var canvas: CanvasRatio {
        switch self {
        case .wide: return .wide
        case .tall: return .tall
        case .square: return .square
        case .classic: return .classic
        case .portrait: return .portrait
        }
    }

    init(canvas: CanvasRatio) {
        switch canvas {
        case .wide: self = .wide
        case .tall: self = .tall
        case .square: self = .square
        case .classic: self = .classic
        case .portrait: self = .portrait
        }
    }

    /// The shape nearest an aspect — the default for "as shot".
    static func nearest(to aspect: Double) -> ReframeRatio {
        guard aspect.isFinite, aspect > 0 else { return .wide }
        return allCases.min { abs($0.ratio - aspect) < abs($1.ratio - aspect) } ?? .wide
    }

    /// The rendered pixel size for this shape, capped at 1080 on the short
    /// side and kept even so every encoder accepts it.
    var renderSize: CGSize {
        let short = 1080.0
        let size = ratio >= 1
            ? CGSize(width: short * ratio, height: short)
            : CGSize(width: short, height: short / ratio)
        return CGSize(width: Self.even(size.width), height: Self.even(size.height))
    }

    private static func even(_ value: Double) -> Double {
        let rounded = (value / 2).rounded() * 2
        return max(2, rounded)
    }
}

// MARK: - Crop

/// A crop window in source pixels — what the engine hands the renderer and
/// the player, so neither has to know how it was arrived at.
struct ScaledCrop: Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    init(rect: CGRect) {
        self.init(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            w: Double(rect.width),
            h: Double(rect.height)
        )
    }

    var rect: CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    var size: CGSize {
        CGSize(width: w, height: h)
    }

    var center: CGPoint {
        CGPoint(x: x + w / 2, y: y + h / 2)
    }
}

import Foundation

/// Interval mode's blend-depth dial: how many source frames each interval
/// blends into one output image. Lives in Shared/ so the Watch remote speaks
/// the same vocabulary. Engineering names stay boring and precise
/// (`unthrottled`/`throttled`); the capture UI dresses them as Psycho/Safe —
/// pure presentation, swappable without touching behaviour.
enum BlendDepth: Hashable {
    /// Deterministic count; 1 = no blending (classic interval timelapse).
    case fixed(Int)
    /// As many frames as the device can physically manage each interval,
    /// ignoring thermal limits. Every interval teaches the Safe profiles.
    case unthrottled
    /// A known-safe count looked up from what unthrottled runs have taught,
    /// re-evaluated each interval. Unavailable without a matching profile.
    case throttled

    /// The counts the fixed picker offers, shared by phone and Watch.
    static let fixedOptions: [(frames: Int, label: String)] = [
        (1, "No blending"), (3, "Light"), (5, "Standard"), (10, "High"), (20, "Experimental"),
    ]

    /// Wire/defaults token: bare frame counts stay numeric, so persisted
    /// pre-adaptive values and stale Watch builds keep working.
    var token: String {
        switch self {
        case .fixed(let frames): return String(frames)
        case .unthrottled: return "unthrottled"
        case .throttled: return "throttled"
        }
    }

    init?(token: String) {
        switch token {
        case "unthrottled": self = .unthrottled
        case "throttled": self = .throttled
        default:
            guard let frames = Int(token), (1...60).contains(frames) else { return nil }
            self = .fixed(frames)
        }
    }

    /// Log-header name for the depth family (the fixed count is recorded
    /// separately).
    var familyName: String {
        switch self {
        case .fixed: return "fixed"
        case .unthrottled: return "unthrottled"
        case .throttled: return "throttled"
        }
    }

    var fixedFrames: Int? {
        if case .fixed(let frames) = self { return frames }
        return nil
    }

    /// Whether outputs are blends of several frames (drives "blends" vs
    /// "photos" counters and the blend captions).
    var blends: Bool {
        self != .fixed(1)
    }
}

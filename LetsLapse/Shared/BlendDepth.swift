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
    /// A count chosen from the light: the scene's EV picks a depth from
    /// `DynamicBlendPolicy`'s table, capped by what the device measured itself
    /// capable of at the start of the run. The other two adaptive depths ask
    /// "what can this device take?"; this one asks "what does this scene need?"
    case auto

    /// The counts the fixed picker offers, shared by phone and Watch, in the
    /// order they are meant to be **read**: deepest first, ending at Off. Every
    /// blend dial in the app descends this way — the unbounded option at the
    /// top (Photo's Bulb, Interval's Psycho and Safe), the counts under it, and
    /// "no blending at all" at the bottom.
    ///
    /// **Reading order is not always declaration order**, so a menu drawing
    /// this list must go through `BlendMenuOrder` rather than iterating it
    /// directly — see the note there. Plain lists (the Watch's picker) can use
    /// it as it stands.
    ///
    /// **The labels are bare counts.** They used to carry a verdict as well —
    /// "3 frames · Light", "20 frames · Experimental" — which Photo's dial
    /// never had, so the app's two blend menus disagreed about their own
    /// vocabulary while offering the identical five values. The count is the
    /// whole fact. Whether it is "light" or "experimental" depends on the
    /// scene, the interval and the device, none of which a static label knows.
    static let fixedOptions: [(frames: Int, label: String)] = [
        (20, "20 Frames"), (10, "10 Frames"), (5, "5 Frames"), (3, "3 Frames"), (1, "Off"),
    ]

    /// What a chip reads when this depth is the selection — the count alone,
    /// so the dial stays narrow enough for MODE, EVERY and BLEND to share one
    /// line on a portrait iPhone. The caption ahead of it already says BLEND,
    /// so "5 frames" on the chip was saying "frames" twice.
    var chipLabel: String {
        switch self {
        case .fixed(1): return "Off"
        case .fixed(let frames): return "\(frames)"
        case .unthrottled: return "Psycho"
        case .throttled: return "Safe"
        case .auto: return "Auto"
        }
    }

    /// Wire/defaults token: bare frame counts stay numeric, so persisted
    /// pre-adaptive values and stale Watch builds keep working.
    var token: String {
        switch self {
        case .fixed(let frames): return String(frames)
        case .unthrottled: return "unthrottled"
        case .throttled: return "throttled"
        case .auto: return "auto"
        }
    }

    init?(token: String) {
        switch token {
        case "unthrottled": self = .unthrottled
        case "throttled": self = .throttled
        case "auto": self = .auto
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
        case .auto: return "auto"
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

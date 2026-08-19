import Foundation

/// The capture modes offered on the phone's capture screen. Lives in Shared/
/// so the Watch remote speaks the same vocabulary (mode selection and state
/// mirroring use the raw values on the wire).
enum CaptureMode: String, CaseIterable, Identifiable {
    /// The simple mode — one tap, one photo (or a short steadied burst that
    /// stacks into a single long exposure). Listed first: it's the least
    /// involved way to capture.
    case photo = "Photo"
    case interval = "Interval"
    case video = "Video"
    var id: String { rawValue }

    /// Decodes a mode token from the wire or from persisted defaults. The
    /// retired "Live Blend" mode maps onto Interval — blending became an
    /// Interval dial when the two modes merged — so stale Watch builds and
    /// old remembered-settings snapshots keep working.
    init?(token: String) {
        if token == "Live Blend" {
            self = .interval
            return
        }
        self.init(rawValue: token)
    }
}

/// Units for a scheduled stop ("stop at…") set from the Watch remote.
/// Frames mean captured photos/blends in Interval, and fps-derived recorded
/// frames in Video.
enum ScheduledStopUnit: String, CaseIterable {
    case minutes
    case frames
}

/// What drives an Interval shoot beyond its spacing — the **MODE** dial.
///
/// Named MODE rather than the RAMP it started as: only one of these values is
/// a ramp. Holy Grail ramps exposure through a lighting transition; Scanner
/// doesn't ramp anything, it decides *when* to fire from what the scene is
/// doing. What they share is that each takes a decision away from the timer,
/// which is what the dial actually selects.
///
/// Both non-`basic` values need manual exposure, a numeric ISO/shutter envelope
/// and (for Scanner) a preview tap — iOS/iPadOS only. The dial isn't drawn on
/// macOS and a remembered value is ignored there rather than silently shooting
/// something else.
///
/// Lives in Shared/ beside `CaptureMode` for the same reason: it is capture
/// vocabulary, and the persisted token is the thing that has to stay stable.
enum IntervalCaptureMode: String, CaseIterable, Identifiable {
    /// The plain timer shoot — spacing and blend depth are the whole story.
    ///
    /// **Called "Basic", not "Off".** The name is the fix for a dial that
    /// described itself by what it wasn't: this value is a locked interval —
    /// a frame every N seconds, exactly as asked — which is the mode most
    /// shoots use and the one the app is named after. "Off" read as a feature
    /// switched off, and a first-time user reasonably wondered what they were
    /// missing.
    ///
    /// The raw value stays `off`: it is the persisted `@AppStorage` token and
    /// the Watch wire format, and neither cares what the dial calls it.
    case basic = "off"
    /// Shutter and ISO follow the light, so one shoot runs daylight → night.
    case holyGrail
    /// The camera fires when the scene stops moving: reposition, let go, click.
    case scanner

    var id: String { rawValue }

    /// Decodes from persisted defaults. The dial was a Bool
    /// (`letslapse.capture.holyGrail`) before Scanner existed, so the two
    /// values `Bool`'s `@AppStorage` writes decode onto the modes they meant.
    init(token: String) {
        switch token {
        case "true", "1": self = .holyGrail
        case "false", "0": self = .basic
        default: self = IntervalCaptureMode(rawValue: token) ?? .basic
        }
    }

    /// What the dial's chip reads — the shortest true name for each mode, so
    /// MODE, EVERY and BLEND share one line on a portrait iPhone. "Scanner"
    /// and "Holy Grail" are the names in the open menu, where there is room to
    /// say them in full and room to say what they do; on the chip they are
    /// "Scan" and "Dynamic", which is what the shoot is rather than what the
    /// feature is called.
    var chipLabel: String {
        switch self {
        case .basic: return "Basic"
        case .holyGrail: return "Dynamic"
        case .scanner: return "Scan"
        }
    }

    /// The menu row — the label plus what the mode is for.
    ///
    /// Holy Grail leads with **Dynamic Light** because that is the plain
    /// description and "Holy Grail" is the craft's nickname for it: a reader
    /// who has never shot a day-to-night sequence learns nothing from the
    /// nickname, and one who has would miss it if it went. The row carries
    /// both, in that order, and the chip carries the half that explains itself.
    var menuLabel: String {
        switch self {
        case .basic: return "Basic · a frame on the timer"
        case .holyGrail: return "Dynamic Light · Holy Grail"
        case .scanner: return "Scanner · fires when the scene stills"
        }
    }

    /// Whether this mode can pace itself, i.e. whether EVERY may be Auto.
    /// Basic cannot: with nothing deciding the spacing, "Auto" would name no
    /// behaviour at all, so the dial simply doesn't offer it.
    var supportsAutoInterval: Bool { self != .basic }

    /// Whether this mode takes the spacing over entirely — Scanner's shutter is
    /// the scene's, so there is no interval to set and EVERY isn't drawn at all.
    var ownsInterval: Bool { self == .scanner }

    /// Whether this mode *requires* Auto — the same fact as `ownsInterval`,
    /// named for the reconciliation that reads it (`reconcileIntervalAuto`).
    var requiresAutoInterval: Bool { ownsInterval }
}

/// Output format for Interval shooting. DNG blends Bayer RAW captures into
/// a real raw file — white balance and tone stay adjustable in post — and
/// needs a RAW-capable camera source; JPEG is the path every source
/// supports.
enum IntervalOutputFormat: String, CaseIterable {
    /// Raw value stays "standard" — the pre-merge name this preference was
    /// persisted under.
    case jpeg = "standard"
    case dng
}

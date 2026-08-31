import Foundation
import CoreGraphics

/// One element composited over a project's frames — text today, SVG/image
/// later. The scene-integration and animation machinery deliberately never
/// looks inside `content`: scene understanding must not know the overlay
/// happens to contain text (text-overlay spike, 2026-08-31).
struct SceneOverlay: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var content: OverlayContent
    /// Anchor centre, normalized 0…1 over the displayed frame, top-left
    /// origin — the same space `PhotoGrader.DetailPatch.region` lives in.
    var centerX: Double = 0.5
    var centerY: Double = 0.3
    /// Glyph size as a fraction of the frame's LONG edge, so the overlay
    /// resolves identically at the 2000 px settled preview, the 1100 px scrub
    /// render, and a full-resolution export.
    var size: Double = 0.08
    /// Which semantic region of the scene is allowed to occlude this overlay.
    var placement: OverlayPlacement = .none
    /// nil = shown at full strength throughout.
    var animation: OverlayAnimation?

    private enum CodingKeys: String, CodingKey {
        case id, content = "c", centerX = "x", centerY = "y", size = "s",
             placement = "p", animation = "an"
    }

    /// The text, when this overlay is text. The editing panel goes through
    /// this; the compositor never does.
    var text: String {
        get {
            switch content { case .text(let value): return value.string }
        }
        set {
            switch content {
            case .text(var value):
                value.string = newValue
                content = .text(value)
            }
        }
    }
}

/// What the overlay holds. One case today; the tag-based Codable leaves room
/// for `.svg`/`.image` cases old builds simply fail to decode (and drop)
/// rather than corrupt.
enum OverlayContent: Codable, Equatable, Sendable {
    case text(TextOverlayContent)

    private enum CodingKeys: String, CodingKey { case type = "t", value = "v" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(TextOverlayContent.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "unknown overlay content type \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

/// The spike's text: one string, one font, one color. Typography is an
/// explicit non-goal; fields arrive here only when they earn their place.
struct TextOverlayContent: Codable, Equatable, Sendable {
    var string: String

    private enum CodingKeys: String, CodingKey { case string = "s" }
}

/// Which scene region composites back over the overlay. "Placement" in the
/// product sense — the element reads as placed *into* the scene — though the
/// overlay's position never changes.
enum OverlayPlacement: String, Codable, Equatable, Sendable, CaseIterable {
    /// Plain overlay, foreground-most. No segmentation involved.
    case none
    /// The overlay sits in the sky: everything that is not sky occludes it.
    case sky
    /// The overlay sits in the land: the sky occludes it.
    case land

    var displayName: String {
        switch self {
        case .none: return "None"
        case .sky: return "Sky"
        case .land: return "Land"
        }
    }
}

/// How an overlay arrives at its resolved final state. The animation answers
/// "how does it get there", never "where is it" — the final layout is the
/// user's, set by dragging, and every animation ends exactly on it.
struct OverlayAnimation: Codable, Equatable, Sendable {
    enum Style: String, Codable, Sendable, CaseIterable {
        /// Characters fade 0→1 with staggered timing.
        case characterFade
        /// Characters slide in from `direction` while fading.
        case characterSlide

        var displayName: String {
            switch self {
            case .characterFade: return "Character fade"
            case .characterSlide: return "Character slide"
            }
        }
    }

    /// Where a sliding character arrives FROM.
    enum Direction: String, Codable, Sendable, CaseIterable {
        case top, bottom, left, right
        var displayName: String { rawValue.capitalized }
    }

    var style: Style = .characterFade
    var direction: Direction = .bottom
    /// Reveal span, SOURCE position 0…1 — the grade strip's own axis, immune
    /// to the speed layer for exactly the reason `GradeKeyframe.position` is.
    /// A future still-photo output timeline feeds output progress here
    /// instead (source ≡ output for a still), so nothing downstream assumes
    /// one tick is one captured frame.
    var start: Double = 0
    var end: Double = 0.25
    /// 0 = strict typewriter (each character waits for the last), 1 = every
    /// character together.
    var overlap: Double = 0.6

    private enum CodingKeys: String, CodingKey {
        case style = "st", direction = "d", start = "a", end = "b", overlap = "o"
    }

    /// Raw per-character progress at `position`, one value per grapheme
    /// cluster. Easing is applied at raster time, not here.
    ///
    /// Character *i* owns the sub-interval `[stride·i, stride·i + width]` of
    /// the band, sized so character 0 starts at the band's start and the last
    /// character completes exactly at its end — which is what makes the
    /// raster at `position ≥ end` byte-identical to a no-animation raster:
    /// the "final layout is always the end state" guarantee, structurally.
    func phases(at position: Double, characterCount: Int) -> [Double] {
        guard characterCount > 0 else { return [] }
        let band = max(end - start, 0.0001)
        let t = (position - start) / band
        let n = Double(characterCount)
        let width = 1.0 / (1.0 + (n - 1) * (1.0 - overlap))
        let stride = characterCount > 1 ? (1.0 - width) / (n - 1) : 0
        return (0..<characterCount).map { i in
            min(max((t - stride * Double(i)) / width, 0), 1)
        }
    }
}

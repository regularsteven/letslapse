import Foundation
import CoreGraphics

/// One element composited over a project's frames — text today, SVG/image
/// later. The scene-integration and animation machinery deliberately never
/// looks inside `content`: scene understanding must not know the overlay
/// happens to contain text (text-overlay spike, 2026-08-31).
///
/// Layers are ordered FRONT-TO-BACK: index 0 is the frontmost layer, which
/// is the order the Text tab lists them in. The compositor walks the array
/// in reverse so the first row paints last.
struct SceneOverlay: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var content: OverlayContent
    /// Anchor centre, normalized 0…1 over the displayed frame, top-left
    /// origin — the same space `PhotoGrader.DetailPatch.region` lives in.
    var centerX: Double = 0.5
    var centerY: Double = 0.3
    /// Glyph size as a fraction of the frame's LONG edge, so the overlay
    /// resolves identically at the 2000 px settled preview, the 1100 px scrub
    /// render, and a full-resolution export. Ignored while `autoSize` is on
    /// in `.box` mode — `resolvedSize(aspect:)` is the value that renders.
    var size: Double = 0.08
    /// Which semantic region of the scene is allowed to occlude this overlay.
    var placement: OverlayPlacement = .none
    /// nil = shown at full strength throughout.
    var animation: OverlayAnimation?

    // MARK: Layer chrome

    /// Hidden layers are skipped by the compositor everywhere — preview and
    /// export both. The Text tab can still ghost one via `onionSkin`.
    var isVisible: Bool = true
    /// Editor-only scaffolding: draw this layer at full strength ignoring its
    /// animation, so its resting layout can be judged without scrubbing to
    /// the end of the reveal. Never baked into an export — it describes how
    /// the editor should draw, not what the piece is.
    var onionSkin: Bool = false

    // MARK: Layout

    /// Free text flows from the anchor; boxed text wraps inside a bounding
    /// box and can be auto-fitted to it.
    var mode: OverlayLayoutMode = .free
    /// The bounding box, as fractions of frame width/height, centred on the
    /// anchor. Only meaningful in `.box` mode.
    var boxWidth: Double = 0.4
    var boxHeight: Double = 0.16
    /// Fit the type to the box instead of using `size`. Box mode only: free
    /// text has no boundary to solve against.
    var autoSize: Bool = false
    /// The bracket auto-size searches, in the same long-edge fraction units
    /// as `size`.
    var minSize: Double = 0.04
    var maxSize: Double = 0.18

    private enum CodingKeys: String, CodingKey {
        case id, content = "c", centerX = "x", centerY = "y", size = "s",
             placement = "p", animation = "an",
             isVisible = "v", onionSkin = "on", mode = "md",
             boxWidth = "bw", boxHeight = "bh",
             autoSize = "as", minSize = "mn", maxSize = "mx"
    }

    init(content: OverlayContent) {
        self.content = content
    }

    /// Every field past the spike's original five is `decodeIfPresent`: a
    /// sidecar written before this schema grew must keep its text, not throw
    /// its way to an empty document. `OverlayStore` treats a decode failure
    /// as "no overlays", so a strict decoder here would silently delete a
    /// user's layers on first launch after an update.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        content = try c.decode(OverlayContent.self, forKey: .content)
        centerX = try c.decodeIfPresent(Double.self, forKey: .centerX) ?? 0.5
        centerY = try c.decodeIfPresent(Double.self, forKey: .centerY) ?? 0.3
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 0.08
        placement = try c.decodeIfPresent(OverlayPlacement.self, forKey: .placement) ?? .none
        animation = try c.decodeIfPresent(OverlayAnimation.self, forKey: .animation)
        isVisible = try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        onionSkin = try c.decodeIfPresent(Bool.self, forKey: .onionSkin) ?? false
        mode = try c.decodeIfPresent(OverlayLayoutMode.self, forKey: .mode) ?? .free
        boxWidth = try c.decodeIfPresent(Double.self, forKey: .boxWidth) ?? 0.4
        boxHeight = try c.decodeIfPresent(Double.self, forKey: .boxHeight) ?? 0.16
        autoSize = try c.decodeIfPresent(Bool.self, forKey: .autoSize) ?? false
        minSize = try c.decodeIfPresent(Double.self, forKey: .minSize) ?? 0.04
        maxSize = try c.decodeIfPresent(Double.self, forKey: .maxSize) ?? 0.18
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

    /// The typography, when this overlay is text.
    var textStyle: TextOverlayContent? {
        get {
            switch content { case .text(let value): return value }
        }
        set {
            guard let newValue else { return }
            content = .text(newValue)
        }
    }

    /// The layer's row title: the text itself, with newlines shown as pilcrow
    /// arrows so a multi-line layer still reads as one line in the list.
    var listTitle: String {
        let title = text.replacingOccurrences(of: "\n", with: "  ↵  ")
            .trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? "Empty layer" : title
    }
}

/// How the overlay's type is laid out.
enum OverlayLayoutMode: String, Codable, Equatable, Sendable, CaseIterable {
    /// The line flows from the anchor, as wide as it needs to be.
    case free
    /// The text wraps inside a bounding box, and can be fitted to it.
    case box

    var displayName: String {
        switch self {
        case .free: return "Free"
        case .box: return "Box"
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

/// The overlay's text and how it is set. Typography arrived with the Text
/// Features design; the spike's single bold-white-system-font rule is now
/// this struct's default values, so a spike-era sidecar decodes to exactly
/// what it used to render.
struct TextOverlayContent: Codable, Equatable, Sendable {
    var string: String
    /// PostScript-ish family name, or nil for the system face. Resolved at
    /// raster time so a project that names a font the device lacks falls
    /// back rather than failing.
    var fontFamily: String?
    var isBold: Bool = true
    var isItalic: Bool = false
    var isUnderlined: Bool = false
    /// `#RRGGBB`. A string because it has to survive a JSON round trip on
    /// three platforms without a color space sneaking in.
    var colorHex: String = "#FFFFFF"
    var alignment: OverlayTextAlignment = .center
    /// Extra letter spacing, in points at the resolved font size ÷ 100 —
    /// i.e. a fraction of the em, so it scales with the type.
    var kerning: Double = 0
    /// Multiple of the font size.
    var lineHeight: Double = 1.05
    /// Extra space between paragraphs, as a multiple of the font size.
    var paragraphSpacing: Double = 0

    private enum CodingKeys: String, CodingKey {
        case string = "s", fontFamily = "f", isBold = "b", isItalic = "i",
             isUnderlined = "u", colorHex = "cl", alignment = "al",
             kerning = "k", lineHeight = "lh", paragraphSpacing = "ps"
    }

    init(string: String) {
        self.string = string
    }

    /// Same contract as `SceneOverlay.init(from:)`: a spike-era sidecar holds
    /// only `s`, and must decode to the spike's own look.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        string = try c.decode(String.self, forKey: .string)
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily)
        isBold = try c.decodeIfPresent(Bool.self, forKey: .isBold) ?? true
        isItalic = try c.decodeIfPresent(Bool.self, forKey: .isItalic) ?? false
        isUnderlined = try c.decodeIfPresent(Bool.self, forKey: .isUnderlined) ?? false
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#FFFFFF"
        alignment = try c.decodeIfPresent(
            OverlayTextAlignment.self, forKey: .alignment) ?? .center
        kerning = try c.decodeIfPresent(Double.self, forKey: .kerning) ?? 0
        lineHeight = try c.decodeIfPresent(Double.self, forKey: .lineHeight) ?? 1.05
        paragraphSpacing = try c.decodeIfPresent(
            Double.self, forKey: .paragraphSpacing) ?? 0
    }
}

/// Horizontal alignment inside the layer's own layout box.
enum OverlayTextAlignment: String, Codable, Equatable, Sendable, CaseIterable {
    case left, center, right
}

/// Which scene region composites back over the overlay. "Placement" in the
/// product sense — the element reads as placed *into* the scene — though the
/// overlay's position never changes.
///
/// Sky and Land are the segmentation model's two halves. A project can also
/// carry hand-supplied `CustomMask`s, and a layer can name one of those (or
/// its complement) instead.
enum OverlayPlacement: Codable, Equatable, Sendable, Hashable {
    /// Plain overlay, foreground-most. No segmentation involved.
    case none
    /// The overlay sits in the sky: everything that is not sky occludes it.
    case sky
    /// The overlay sits in the land: the sky occludes it.
    case land
    /// The overlay sits inside a custom mask's white region.
    case custom(UUID)
    /// The overlay sits inside a custom mask's complement.
    case customInverted(UUID)

    /// The wire form. `none`/`sky`/`land` are spelled exactly as the spike's
    /// `String` raw values were, so old sidecars decode unchanged.
    var storageKey: String {
        switch self {
        case .none: return "none"
        case .sky: return "sky"
        case .land: return "land"
        case .custom(let id): return "m:\(id.uuidString)"
        case .customInverted(let id): return "mi:\(id.uuidString)"
        }
    }

    init?(storageKey: String) {
        switch storageKey {
        case "none": self = .none
        case "sky": self = .sky
        case "land": self = .land
        default:
            let parts = storageKey.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let id = UUID(uuidString: String(parts[1]))
            else { return nil }
            switch parts[0] {
            case "m": self = .custom(id)
            case "mi": self = .customInverted(id)
            default: return nil
            }
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // An unknown key means the mask it named is gone. Reading that as
        // "no placement" keeps the layer and its text; throwing would lose
        // the whole document.
        self = OverlayPlacement(storageKey: raw) ?? .none
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageKey)
    }

    /// The mask this placement refers to, if it is a custom one.
    var customMaskID: UUID? {
        switch self {
        case .custom(let id), .customInverted(let id): return id
        case .none, .sky, .land: return nil
        }
    }
}

/// A hand-supplied black-and-white mask that belongs to the PROJECT, not to
/// any one layer: every text layer can pick any of them. White is the
/// region the mask names; black is its complement.
struct CustomMask: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    /// The white region's name — the pill a layer picks.
    var name: String = ""
    /// The black region's name. Empty means the complement gets no pill.
    var invertedName: String = ""
    /// When true this mask's names stand in for Sky and Land across the
    /// project, and those two pills drop out. At most one mask per project
    /// may claim it.
    var replacesSkyAndLand: Bool = false
    /// File name inside the project's `masks/` folder.
    var fileName: String

    private enum CodingKeys: String, CodingKey {
        case id, name = "n", invertedName = "in",
             replacesSkyAndLand = "r", fileName = "f"
    }

    var displayName: String { name.isEmpty ? "Untitled" : name }
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
            case .characterFade: return "Fade"
            case .characterSlide: return "Slide"
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

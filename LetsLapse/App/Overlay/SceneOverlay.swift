import Foundation
import CoreGraphics
import LetsLapseKit

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
    /// How and when the layer arrives, leaves, and what it waits for. nil =
    /// shown at full strength throughout — the same thing as a hard cut at
    /// 0:00 with no exit, which is what `effectiveAnimation` reads it as.
    var animation: OverlayAnimation?
    /// The user's own name for the layer ("Intro top", "Byline", "Main
    /// message") — blank when unset. It names the layer in the list, the
    /// After-layer picker, the lane gutter and toasts, and it is what
    /// programmatic copy will address a layer by later, so it must stay
    /// stable across rewrites of the text itself.
    var label: String = ""

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

    // MARK: Rotation

    /// This layer's own angle in degrees, positive clockwise, about its
    /// anchor — set with the same `RotationSlider` the Edit screen levels
    /// the project with. It lives in the OUTPUT frame's space, after the
    /// project's rotation: a layer added to a levelled project starts at 0
    /// and reads level, and a layer that was already there when the project
    /// was levelled carries the project's turn (see `remapped`). 0 for every
    /// layer written before the field existed.
    var rotationDegrees: Double = 0

    private enum CodingKeys: String, CodingKey {
        case id, content = "c", centerX = "x", centerY = "y", size = "s",
             placement = "p", animation = "an",
             isVisible = "v", onionSkin = "on", mode = "md",
             boxWidth = "bw", boxHeight = "bh",
             autoSize = "as", minSize = "mn", maxSize = "mx",
             rotationDegrees = "r", label = "l"
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
        rotationDegrees = try c.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
    }

    /// This layer re-expressed after the project's rotation changes from
    /// `old` to `new` degrees, so it stays pinned to the scene it was placed
    /// on: the anchor rides the same point of the picture, the layer turns
    /// with it, and it grows with the crop-in the way the rock under it
    /// does. Layers are stored in the output frame's space (what the editor
    /// shows and the export bakes), which is why this has to be applied at
    /// the moment the rotation moves rather than derived at render time.
    /// `width`/`height` only need the frame's aspect.
    func remapped(fromRotation old: Double, to new: Double, width: Double, height: Double) -> SceneOverlay {
        guard old != new, width > 0, height > 0 else { return self }
        var copy = self
        let centre = FrameRotation.remap(
            CGPoint(x: centerX, y: centerY), width: width, height: height, from: old, to: new)
        copy.centerX = centre.x
        copy.centerY = centre.y
        copy.rotationDegrees += new - old
        let grow = FrameRotation.lengthScale(width: width, height: height, from: old, to: new)
        copy.size *= grow
        copy.minSize *= grow
        copy.maxSize *= grow
        copy.boxWidth *= grow
        copy.boxHeight *= grow
        return copy
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

    /// The ID when the user gave one, else the copy itself.
    var displayName: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? listTitle : trimmed
    }

    /// The animation as the render reads it: an absent one is a hard cut at
    /// 0:00 that holds to the end of the shoot.
    var effectiveAnimation: OverlayAnimation { animation ?? .alwaysOn }

    /// True when something actually animates — a reveal style, or an exit.
    /// A cut-in with no exit is "no animation" as far as the wand and the
    /// onion skin are concerned.
    var hasReveal: Bool {
        guard let animation else { return false }
        return animation.reveal.style != nil || animation.exit != nil
    }

    /// True when the layer is on screen at all at `position` — inside its
    /// span, whether mid-reveal, settled or mid-exit.
    func isOnScreen(at position: Double) -> Bool {
        effectiveAnimation.isOnScreen(at: position)
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

extension OverlayDocument {
    /// The layers `id` may NOT follow: itself and everything already
    /// following it, directly or down a chain — a parent cannot follow one of
    /// its descendants.
    func descendants(of id: UUID) -> Set<UUID> {
        OverlaySequencing.descendants(of: id, in: sequencingLayers)
    }

    /// Re-seats every linked layer after its parent, front-to-back — see
    /// `OverlaySequencing.resolve`. Links to a layer that is gone (or to
    /// itself, or round a cycle) are dropped and the layer keeps its absolute
    /// times — the same spirit as `pruneDanglingPlacements`.
    mutating func resolveFollows() {
        var layers = sequencingLayers
        OverlaySequencing.resolve(&layers)
        for (index, layer) in layers.enumerated() where overlays[index].animation != layer.animation {
            overlays[index].animation = layer.animation
        }
    }

    /// Removes a layer. Its children keep their (already resolved) times and
    /// stop following.
    mutating func removeLayer(_ id: UUID) {
        overlays.removeAll { $0.id == id }
        for index in overlays.indices where overlays[index].animation?.follows?.layerID == id {
            overlays[index].animation?.follows = nil
        }
    }

    private var sequencingLayers: [OverlaySequencing.Layer] {
        overlays.map { OverlaySequencing.Layer(id: $0.id, animation: $0.animation) }
    }
}

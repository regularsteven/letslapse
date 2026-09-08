import Foundation
import LetsLapseKit

// Masks as adjustment layers.
//
// Until now a mask was a text-placement utility: `OverlayPlacement` named a
// region and the compositor let that region occlude a layer. This file is the
// second thing a mask can do — carry a grade of its own, applied inside it and
// nowhere else.
//
// The split the design insists on: a **Mask** is a SHAPE the project owns, and
// a **MaskGrade** is an APPLIED grade that names one. Same mask, two homes —
// the Masks tab authors the shape, the Editor tab authors the grade. Nothing
// here is baked: a MaskGrade is parameters, resolved at render time, exactly
// like the whole-picture grade it sits on top of.

/// Which of the project's masks something names.
///
/// Sky and Land have no identity of their own — they are two readings of one
/// segmentation — so they are cases rather than UUIDs, the same shape
/// `OverlayPlacement` has always had. `custom` is a `CustomMask` file;
/// `shape` is one of the new parametric masks.
enum MaskRef: Codable, Equatable, Hashable, Sendable {
    case sky
    case land
    case custom(UUID)
    case shape(UUID)

    /// The wire form, and the same grammar `OverlayPlacement.storageKey` uses
    /// so the two can be read side by side in a sidecar.
    var storageKey: String {
        switch self {
        case .sky: return "sky"
        case .land: return "land"
        case .custom(let id): return "m:\(id.uuidString)"
        case .shape(let id): return "s:\(id.uuidString)"
        }
    }

    init?(storageKey: String) {
        switch storageKey {
        case "sky": self = .sky
        case "land": self = .land
        default:
            let parts = storageKey.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return nil }
            switch parts[0] {
            case "m": self = .custom(id)
            case "s": self = .shape(id)
            default: return nil
            }
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let ref = MaskRef(storageKey: raw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Unknown mask reference \(raw)"))
        }
        self = ref
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageKey)
    }

    /// True when producing this mask needs the segmentation model to run.
    var needsSegmentationModel: Bool {
        switch self {
        case .sky, .land: return true
        case .custom, .shape: return false
        }
    }

    var customMaskID: UUID? {
        if case .custom(let id) = self { return id }
        return nil
    }

    var shapeMaskID: UUID? {
        if case .shape(let id) = self { return id }
        return nil
    }

    /// The text placement that names this mask's region, or its complement.
    /// The bridge between the two things a mask does.
    func placement(inverted: Bool) -> OverlayPlacement {
        switch self {
        case .sky: return inverted ? .land : .sky
        case .land: return inverted ? .sky : .land
        case .custom(let id): return inverted ? .customInverted(id) : .custom(id)
        case .shape(let id): return inverted ? .shapeInverted(id) : .shape(id)
        }
    }
}

/// One of the project's parametric masks: a drawn shape with a name.
///
/// The shape lives in `LetsLapseKit.MaskShape` — numbers only, so the mask
/// resolves identically at every render size and can ride the grade timeline
/// once keyframed geometry lands.
struct ShapeMask: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    /// The user's own name. Seeded "Linear 2" / "Radial 3" when drawn.
    var name: String = ""
    var shape: MaskShape

    private enum CodingKeys: String, CodingKey {
        case id, name = "n", shape = "s"
    }

    var displayName: String { name.isEmpty ? shape.kind.displayName : name }
    /// What the complement is called. Shapes have no second name of their own
    /// the way a custom mask does, so it is derived.
    var invertedName: String { "\(displayName) · inverted" }
}

/// A grade applied inside one mask.
///
/// **Unique on (mask, inverted)**: a mask has exactly two versions — as
/// created and inverted — and each can be added to the Editor once. Adding a
/// version that already exists re-opens it rather than stacking a duplicate,
/// which is what stops the Masks card filling with near-identical rows.
struct MaskGrade: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    /// The shape this grade is applied through.
    var mask: MaskRef
    /// True to apply the grade OUTSIDE the mask instead of inside it.
    var inverted: Bool = false
    /// Off keeps the grade and its values but takes it out of the render —
    /// the A/B a local adjustment always wants.
    var isEnabled: Bool = true
    /// The values, in the same units and ranges as the whole-picture grade.
    /// Only the subset in `MaskGrade.fields` is reachable from the UI; the
    /// rest stay neutral and cost nothing.
    var adjustments: PhotoAdjustments = .neutral

    private enum CodingKeys: String, CodingKey {
        case id, mask = "m", inverted = "i", isEnabled = "e", adjustments = "a"
    }

    init(id: UUID = UUID(), mask: MaskRef, inverted: Bool = false,
         isEnabled: Bool = true, adjustments: PhotoAdjustments = .neutral) {
        self.id = id
        self.mask = mask
        self.inverted = inverted
        self.isEnabled = isEnabled
        self.adjustments = adjustments
    }

    /// Tolerant per field, like every sidecar type here: a payload from a
    /// build with a smaller schema must keep its grade rather than throw the
    /// document away.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        mask = try c.decode(MaskRef.self, forKey: .mask)
        inverted = try c.decodeIfPresent(Bool.self, forKey: .inverted) ?? false
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        adjustments = try c.decodeIfPresent(
            PhotoAdjustments.self, forKey: .adjustments) ?? .neutral
    }

    /// The text placement that selects the pixels this grade applies to.
    var placement: OverlayPlacement { mask.placement(inverted: inverted) }

    /// True when this grade would move a pixel. A grade with nothing set is
    /// still worth keeping — it is a row somebody added and is about to
    /// use — but the renderer skips it.
    var isActive: Bool { isEnabled && !adjustments.isColorNeutral }

    // MARK: - The controls a masked grade offers
    //
    // Deliberately a subset of the whole-picture panel. Local adjustments are
    // corrections of a region, not a look: the capture-referred controls
    // (Sharpen, Noise Reduction, the owned white) belong to the frame as a
    // whole, and Rotation is geometry. What is left is the eight the design
    // specifies.

    static let fields: [PhotoAdjustmentField] = [
        .temperature, .tint,
        .exposure, .contrast, .highlights, .shadows,
        .saturation, .clarity, .dehaze,
    ]

    /// The masked grade's sections, in panel order, with the fields each holds.
    /// Dehaze joined Effects on 2026-09-08: Lightroom's local Dehaze imports
    /// into a mask, and a value the card cannot show cannot be reset either.
    static let sections: [(title: String, fields: [PhotoAdjustmentField])] = [
        ("White Balance", [.temperature, .tint]),
        ("Light", [.exposure, .contrast, .highlights, .shadows]),
        ("Color", [.saturation]),
        ("Effects", [.clarity, .dehaze]),
    ]

    /// Exposure inside a mask travels ±2 EV rather than the whole picture's
    /// ±5: a local lift beyond a couple of stops is a different photograph,
    /// not a correction, and the extra travel only makes the slider coarse.
    /// The Kit owns the number so an import clamps to it in the CLI too.
    static let exposureRange: ClosedRange<Float> = MaskedGradeStage.exposureRange

    /// Temp inside a mask is a RELATIVE warmth — a mired offset from
    /// whatever white the whole-picture grade landed on, not a white of its
    /// own. (The whole-picture Temp became absolute when the white was
    /// owned; a region cannot sensibly declare a second illuminant, and
    /// "warm this bit up" is what a local control is for.)
    ///
    /// ±25 mired rather than the field's full ±150. At daylight that is
    /// about +1270 K / −920 K, which is the design's ±1000 K; the full
    /// travel reads +2687 K a third of the way along and is unusable for the
    /// nudge this control is.
    static let temperatureRange: ClosedRange<Float> = MaskedGradeStage.temperatureRange

    static func range(for field: PhotoAdjustmentField) -> ClosedRange<Float> {
        switch field {
        case .exposure: return exposureRange
        case .temperature: return temperatureRange
        default: return field.range
        }
    }

    /// Whether one field is doing nothing.
    func isNeutral(_ field: PhotoAdjustmentField) -> Bool {
        adjustments[keyPath: field.keyPath] == field.neutralValue
    }

    /// The grade with every field of one section put back to neutral.
    mutating func reset(fields: [PhotoAdjustmentField]) {
        for field in fields {
            adjustments[keyPath: field.keyPath] = field.neutralValue
        }
    }

    /// The short "what does this do" line under a thumbnail and in the deck —
    /// at most three of the strongest things the grade says.
    var summary: String {
        var parts: [String] = []
        let values = adjustments
        if values.exposure != 0 { parts.append(String(format: "%+.2f EV", values.exposure)) }
        if values.shadows != 0 { parts.append("Shadows \(signed(values.shadows))") }
        if values.highlights != 0 { parts.append("Highlights \(signed(values.highlights))") }
        if values.temperature != 0 { parts.append(values.temperature > 0 ? "warm" : "cool") }
        if values.saturation != 0 { parts.append("Sat \(signed(values.saturation))") }
        if values.contrast != 0 { parts.append("Contrast \(signed(values.contrast))") }
        if values.clarity != 0 { parts.append("Clarity \(signed(values.clarity))") }
        if values.dehaze != 0 { parts.append("Dehaze \(signed(values.dehaze))") }
        if values.tint != 0 { parts.append("Tint \(signed(values.tint))") }
        guard !parts.isEmpty else { return "no adjustments yet" }
        return parts.prefix(3).joined(separator: " · ")
    }

    /// Panel vocabulary: the −1…1 engine units read as −100…100.
    private func signed(_ value: Float) -> String {
        String(format: "%+.0f", value * 100)
    }
}

// MARK: - The project's masks, as one list

/// One row of the project's mask vocabulary — what the Add menu lists and
/// what the Masks tab's deck shows. A façade over the three places a mask can
/// actually live (the segmenter, a `CustomMask` file, a `ShapeMask`), so
/// every surface can walk one array.
struct ProjectMask: Identifiable, Equatable {
    enum Kind: Equatable {
        case sky
        case land
        case custom
        case shape(MaskShapeKind)

        /// The caption under a name: "Sky · AUTO", "Radial", "Custom".
        var caption: String {
            switch self {
            case .sky: return "Sky · AUTO"
            case .land: return "Land · AUTO"
            case .custom: return "Custom"
            case .shape(let kind): return kind.displayName
            }
        }

        /// Semantic masks are re-derived per seam, so they carry the AUTO
        /// marker; everything else is fixed once made.
        var isAuto: Bool {
            switch self {
            case .sky, .land: return true
            case .custom, .shape: return false
            }
        }

        /// Only the parametric shapes can be removed from the Masks tab —
        /// Sky and Land belong to the analysis, and a custom mask is removed
        /// from its own list where its file is.
        var isRemovableInDeck: Bool {
            if case .shape = self { return true }
            return false
        }
    }

    var ref: MaskRef
    var name: String
    /// The complement's name: a custom mask's second field when it has one,
    /// otherwise "<name> · inverted".
    var invertedName: String
    var kind: Kind
    /// The parametric geometry, for the masks that have any.
    var shape: MaskShape?

    var id: String { ref.storageKey }

    /// The name of one version of this mask.
    func name(inverted: Bool) -> String { inverted ? invertedName : name }

    /// The caption for one version — the kind, plus the fact of inversion.
    func caption(inverted: Bool) -> String {
        inverted ? "\(kind.caption) · inverted" : kind.caption
    }
}

extension OverlayDocument {

    /// Every mask the project has, in menu and deck order: the two semantic
    /// regions, then the custom files, then the drawn shapes.
    ///
    /// Sky and Land drop out when a custom mask has claimed "Replace Sky &
    /// Land" — the same rule `placementRegions` has always applied, kept in
    /// one place by asking it.
    var projectMasks: [ProjectMask] {
        var out: [ProjectMask] = []
        if !customMasks.contains(where: \.replacesSkyAndLand) {
            out.append(ProjectMask(
                ref: .sky, name: "Sky", invertedName: "Sky · inverted", kind: .sky, shape: nil))
            out.append(ProjectMask(
                ref: .land, name: "Land", invertedName: "Land · inverted", kind: .land, shape: nil))
        }
        for mask in customMasks {
            out.append(ProjectMask(
                ref: .custom(mask.id), name: mask.displayName,
                invertedName: mask.invertedName.isEmpty
                    ? "\(mask.displayName) · inverted" : mask.invertedName,
                kind: .custom, shape: nil))
        }
        for mask in shapeMasks {
            out.append(ProjectMask(
                ref: .shape(mask.id), name: mask.displayName,
                invertedName: mask.invertedName,
                kind: .shape(mask.shape.kind), shape: mask.shape))
        }
        return out
    }

    func projectMask(_ ref: MaskRef) -> ProjectMask? {
        projectMasks.first { $0.ref == ref }
    }

    /// The grade already applied to one version of a mask, if there is one.
    func maskGrade(for ref: MaskRef, inverted: Bool) -> MaskGrade? {
        maskGrades.first { $0.mask == ref && $0.inverted == inverted }
    }

    func maskGrade(id: UUID) -> MaskGrade? {
        maskGrades.first { $0.id == id }
    }

    /// Adds a grade for one version of a mask, or returns the existing one.
    /// The uniqueness rule lives here so no caller can break it.
    @discardableResult
    mutating func addMaskGrade(for ref: MaskRef, inverted: Bool) -> UUID {
        if let existing = maskGrade(for: ref, inverted: inverted) { return existing.id }
        let grade = MaskGrade(mask: ref, inverted: inverted)
        maskGrades.append(grade)
        return grade.id
    }

    mutating func removeMaskGrade(id: UUID) {
        maskGrades.removeAll { $0.id == id }
    }

    /// Removes a parametric mask, everything graded through it, and any text
    /// placement that named it. A shape's grades cannot outlive the shape:
    /// there would be nothing left to select the pixels with.
    mutating func removeShapeMask(id: UUID) {
        shapeMasks.removeAll { $0.id == id }
        maskGrades.removeAll { $0.mask == .shape(id) }
        pruneDanglingPlacements()
    }

    /// A name for a freshly drawn shape: "Radial 3", numbered past whatever
    /// is already there so two masks never read the same.
    func nextShapeName(for kind: MaskShapeKind) -> String {
        let used = shapeMasks.count + 1
        var candidate = "\(kind.displayName) \(used)"
        var index = used
        while shapeMasks.contains(where: { $0.name == candidate }) {
            index += 1
            candidate = "\(kind.displayName) \(index)"
        }
        return candidate
    }

    /// Any layer pointing at a region that no longer exists falls back to
    /// None — the rule `OverlayMasksPanel` established when custom masks
    /// could vanish, now that shapes can too.
    mutating func pruneDanglingPlacements() {
        let live = Set(placementRegions.map(\.placement))
        for index in overlays.indices
        where overlays[index].placement != .none
            && !live.contains(overlays[index].placement) {
            overlays[index].placement = .none
        }
    }

    /// True when anything on the project — a text placement or an enabled
    /// grade — needs the segmentation model to run.
    var needsSegmentationForGrades: Bool {
        maskGrades.contains { $0.isActive && $0.mask.needsSegmentationModel }
    }

    /// The text layers placed inside one version of a mask — what the Masks
    /// tab's Text segment lists.
    func textLayers(placedIn ref: MaskRef, inverted: Bool) -> [SceneOverlay] {
        let placement = ref.placement(inverted: inverted)
        return overlays.filter { $0.placement == placement }
    }
}

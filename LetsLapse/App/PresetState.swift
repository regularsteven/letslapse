import Foundation
import SwiftUI

/// What a project's grade *is*, as opposed to what its numbers are.
///
/// The numbers (`PhotoPreset` + `PhotoAdjustments`) have always been stored on
/// the project; they say what to render but not where the look came from. This
/// says that, in the three states a project item can actually be in:
///
/// - `.original` — no edits. Nothing is applied, and an export hands over the
///   source file untouched, in its original format. For a blended output
///   (burst merge, timelapse) "original" means the app's blended result before
///   any preset was applied, not the raw frames it was made from.
/// - `.named` — a preset is applied, built-in or saved, and is shown as active.
///   The snapshot travels with the id: it is what the preset's parameters were
///   *at the moment it was applied*, so later edits to the preset definition
///   can't silently flip existing projects to Edited.
/// - `.edited` — manual edits that no longer match any named preset. Project
///   specific, and deliberately called "Edited" rather than "Custom": it is a
///   state the project fell into, not a look someone chose.
///
/// The state is derived live from the values in the editors (see
/// `PresetStateResolver`) and persisted alongside them on the project.
enum PresetState: Equatable, Sendable {
    case original
    case named(id: UUID, snapshot: PresetSnapshot)
    case edited

    /// The pill's text: the preset's name at apply time, or the state's own word.
    var label: String {
        switch self {
        case .original: return "Original"
        case .named(_, let snapshot): return snapshot.name
        case .edited: return "Edited"
        }
    }

    /// True when this state names `id` — how a chip knows it is the active one.
    func isNamed(_ id: UUID) -> Bool {
        guard case .named(let namedID, _) = self else { return false }
        return namedID == id
    }

    var isEdited: Bool {
        if case .edited = self { return true }
        return false
    }

    var isOriginal: Bool {
        if case .original = self { return true }
        return false
    }

    /// The applied preset's stored values, when there are any. This is the
    /// anchor every divergence check is made against.
    var snapshot: PresetSnapshot? {
        guard case .named(_, let snapshot) = self else { return nil }
        return snapshot
    }
}

/// A named preset's parameter values, frozen at the moment it was applied.
///
/// Stored on the project rather than looked up from the preset store, because
/// the store's copy is free to change afterwards — the user can rework "Sunset"
/// or delete it entirely — and a project that still holds the values it was
/// given is still, truthfully, using that preset.
struct PresetSnapshot: Codable, Equatable, Sendable {
    /// The name to show on the pill. Kept here so a deleted or renamed preset
    /// still labels the projects that carry it.
    var name: String
    var basePreset: PhotoPreset
    var adjustments: PhotoAdjustments
    /// True for the built-in chips (Natural, Cinema, Matte, Vivid), false for
    /// anything saved by the user.
    var isBuiltIn: Bool

    var grade: PhotoGrade { PhotoGrade(preset: basePreset, adjustments: adjustments) }

    /// Exact match, field for field: anything else is a divergence, and the
    /// project is Edited from that instant.
    func matches(preset: PhotoPreset, adjustments: PhotoAdjustments) -> Bool {
        basePreset == preset && self.adjustments == adjustments
    }
}

// MARK: - Preset identity

extension PhotoPreset {
    /// Fixed identity for the built-in presets, so `PresetState.named` can key
    /// every preset — built-in or saved — by one UUID. Literal constants: they
    /// are written into project sidecars and must never move.
    var presetID: UUID {
        switch self {
        case .natural: return UUID(uuidString: "1E750000-0000-4000-8000-000000000001")!
        case .cinema: return UUID(uuidString: "1E750000-0000-4000-8000-000000000002")!
        case .matte: return UUID(uuidString: "1E750000-0000-4000-8000-000000000003")!
        case .vivid: return UUID(uuidString: "1E750000-0000-4000-8000-000000000004")!
        // Never used in `.named` — Original is a state of its own, not a look —
        // but every case needs an id for the chip strip to key on.
        case .original: return UUID(uuidString: "1E750000-0000-4000-8000-000000000005")!
        }
    }

    /// The built-in a stored id refers to, if it is one.
    static func builtIn(id: UUID) -> PhotoPreset? {
        allCases.first { $0.presetID == id }
    }

    /// This preset as an applied snapshot: the chip on its own, no sliders.
    var snapshot: PresetSnapshot {
        PresetSnapshot(
            name: displayName, basePreset: self, adjustments: .neutral, isBuiltIn: true)
    }
}

extension CustomPreset {
    var snapshot: PresetSnapshot {
        PresetSnapshot(
            name: name, basePreset: basePreset, adjustments: adjustments, isBuiltIn: false)
    }
}

// MARK: - Resolving

/// Turns "what are the values right now" into "what state is this project in".
///
/// Every surface that can move a value runs this — the editors on each slider
/// tick, the model on each chip tap — so the state can never lag the numbers it
/// describes.
enum PresetStateResolver {
    /// The state `preset`/`adjustments` describe, given the state they are
    /// coming *from*.
    ///
    /// `anchor` matters for exactly one case: a named preset whose definition
    /// has since changed. The project still holds the values it was handed, so
    /// the anchor's snapshot still matches and the preset stays named; a lookup
    /// against the store's current copy would call it Edited instead.
    static func resolve(
        preset: PhotoPreset,
        adjustments: PhotoAdjustments,
        anchor: PresetState,
        customPresets: [CustomPreset]
    ) -> PresetState {
        // Original is "no filter": no preset, no sliders, nothing to bake.
        if preset == .original, adjustments.isNeutral { return .original }
        // Still exactly what the applied preset gave us — including when that
        // preset has been reworked or deleted since.
        if case .named(let id, let snapshot) = anchor,
           snapshot.matches(preset: preset, adjustments: adjustments) {
            return .named(id: id, snapshot: snapshot)
        }
        // A built-in on its own: the chip and nothing layered on it. This is
        // also how a project comes *back* from Edited when the sliders are
        // returned to neutral.
        if adjustments.isNeutral, preset != .original {
            return .named(id: preset.presetID, snapshot: preset.snapshot)
        }
        // A saved preset the values happen to match exactly.
        if let custom = customPresets.first(where: {
            $0.basePreset == preset && $0.adjustments == adjustments
        }) {
            return .named(id: custom.id, snapshot: custom.snapshot)
        }
        return .edited
    }
}

// MARK: - Codable

extension PresetState: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, id, snapshot
    }

    private enum Kind: String, Codable {
        case original, named, edited
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .original
        switch kind {
        case .original:
            self = .original
        case .edited:
            self = .edited
        case .named:
            // A named state missing either half is meaningless; rather than
            // claim a preset the project can't prove, fall back to Edited —
            // the honest state for "these values, no known source".
            guard let id = try container.decodeIfPresent(UUID.self, forKey: .id),
                  let snapshot = try container.decodeIfPresent(
                    PresetSnapshot.self, forKey: .snapshot) else {
                self = .edited
                return
            }
            self = .named(id: id, snapshot: snapshot)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .original:
            try container.encode(Kind.original, forKey: .kind)
        case .edited:
            try container.encode(Kind.edited, forKey: .kind)
        case .named(let id, let snapshot):
            try container.encode(Kind.named, forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(snapshot, forKey: .snapshot)
        }
    }
}

// MARK: - Applying a preset

/// A preset tap waiting on the user's word, because applying it would throw
/// manual edits away. Raised by every surface with a chip strip — the project
/// item screen and both editors — so the confirmation reads the same wherever
/// it comes up.
struct PresetApplyRequest: Identifiable {
    enum Target: Equatable {
        case builtIn(PhotoPreset)
        case custom(CustomPreset)
    }

    var target: Target

    var id: String {
        switch target {
        case .builtIn(let preset): return "builtin.\(preset.rawValue)"
        case .custom(let preset): return "custom.\(preset.id.uuidString)"
        }
    }

    var name: String {
        switch target {
        case .builtIn(let preset): return preset.displayName
        case .custom(let preset): return preset.name
        }
    }

    /// Original doesn't put a look in the edits' place — it takes the project
    /// back to the file as captured — so it says so rather than borrowing the
    /// "replace with" wording.
    var isOriginal: Bool {
        if case .builtIn(.original) = target { return true }
        return false
    }

    var confirmationTitle: String {
        isOriginal ? "Discard your edits?" : "Replace your edits with \(name)?"
    }

    var confirmationMessage: String {
        isOriginal
            ? "This clears every adjustment and returns the project to the original, unfiltered file."
            : "Your manual adjustments will be replaced by the \(name) preset. There's no undo."
    }

    var confirmationButton: String { isOriginal ? "Discard Edits" : "Replace" }
}

// MARK: - The pill

/// The state readout: which preset is applied, or that the project is Edited.
///
/// Edited is styled muted rather than accented on purpose — it is a state the
/// project is in, not a choice on offer, and painting it the same amber as an
/// applied preset would read as a fifth chip in the strip.
struct PresetStatePill: View {
    let state: PresetState
    /// The colour an applied preset is painted in. The light surfaces pass the
    /// app accent; the always-dark editors pass amber, per the design system's
    /// "highlights over dark" rule.
    var accent: Color = LL.accent
    /// Text colour over `accent`. White on the accent, black on amber.
    var onAccent: Color = .white

    var body: some View {
        Text(state.label)
            .font(.system(size: 12.5, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(background))
            .accessibilityLabel(accessibilityLabel)
    }

    private var foreground: Color {
        switch state {
        case .named: return onAccent
        case .original, .edited: return .secondary
        }
    }

    private var background: Color {
        switch state {
        case .named: return accent
        case .original, .edited: return LL.hairline
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .original: return "No preset applied"
        case .named(_, let snapshot): return "\(snapshot.name) preset applied"
        case .edited: return "Edited — manual adjustments that match no preset"
        }
    }
}

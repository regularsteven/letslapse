import Foundation
import LetsLapseKit
import SwiftUI

// Auto apply — a preset or LUT that new shoots start on, chosen per capture
// context on the preset's own screen (Create ▸ Manage presets). The rules
// live in the Kit (`AutoApplyRules`, docs/presets-auto-apply.md); this file
// is the app's side: the file, the capture screen's context, and what a
// rule resolves to for the registration path to stamp.

extension CaptureMode {
    /// The Kit's vocabulary for the same three modes.
    var autoApplyMode: AutoApplyMode {
        switch self {
        case .photo: return .photo
        case .interval: return .interval
        case .video: return .video
        }
    }
}

/// The context a finished shoot is registered from, as the capture screen
/// knew it at the moment the shoot ended. Built in the finish closures and
/// handed down to `registerCapture`; every other way a project enters the
/// library — an import, a transfer, a PicPlace pull, an archive clone —
/// passes nil, because "auto apply" is about what the camera makes.
struct AutoApplyContext: Equatable {
    let mode: CaptureMode
    /// The format that LANDED, not the dial: a DNG dial on a source with no
    /// Bayer RAW shoots JPEG, and a Holy Grail run takes RAW through the
    /// timer path. The frames' extensions are the truth.
    let dng: Bool
    /// The mode's Capture Flat toggle. Read from the still-frame path as
    /// well as the video one: a JPEG's flat grade is a save-time step the
    /// files carry no marker of, and the toggle can't change mid-run (the
    /// format sheet is locked while capturing).
    let flat: Bool

    var slot: AutoApplySlot {
        AutoApplySlot.slot(mode: mode.autoApplyMode, dng: dng, flat: flat)
    }

    /// A still shoot — Photo or Interval — from the frames it delivered.
    static func stills(mode: CaptureMode, urls: [URL], flat: Bool) -> AutoApplyContext {
        AutoApplyContext(
            mode: mode,
            dng: urls.first.map { $0.pathExtension.lowercased() == "dng" } ?? false,
            flat: flat)
    }

    static func video(flat: Bool) -> AutoApplyContext {
        AutoApplyContext(mode: .video, dng: false, flat: flat)
    }
}

/// What a rule resolved to for one shoot: exactly the fields `registerCapture`
/// stamps on the new record, mirroring `AppModel.applyPreset` /
/// `applyCustomPreset` without the level, crop and white a fresh project
/// hasn't got yet.
struct AutoAppliedLook {
    let presetID: UUID
    let name: String
    let preset: PhotoPreset
    let adjustments: PhotoAdjustments
    let state: PresetState
}

/// The rules of the current library, backed by `auto_apply.json` beside
/// `custom_presets.json` — the ids it names are that library's, so it
/// re-roots with the preset store on a library switch. Small, loaded once,
/// rewritten atomically on every change, exactly as the preset store is.
@MainActor
final class AutoApplyStore: ObservableObject {
    static private(set) var shared = AutoApplyStore()
    static func reroot() { shared = AutoApplyStore() }

    static let fileName = "auto_apply.json"

    @Published private(set) var rules = AutoApplyRules()

    /// Set when the file couldn't be written, so a screen can say so.
    @Published var lastError: String?

    private let fileURL: URL
    #if DEBUG
    /// False after `debugSeed`: rules staged for a screenshot never reach
    /// the file — the same rule every `LL_*` hook keeps.
    private var persistsChanges = true
    #endif

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? StorageRoot.current.appendingPathComponent(Self.fileName)
        load()
        if !rules.isEmpty {
            LLog("auto-apply: \(rules.owners.count) slot(s) held by \(rules.presetIDs.count) preset(s) at \(self.fileURL.path)")
        }
    }

    // MARK: - Reading

    func slots(for presetID: UUID) -> Set<AutoApplySlot> { rules.slots(for: presetID) }

    func conflicts(assigning slots: Set<AutoApplySlot>, to presetID: UUID) -> [AutoApplyRules.Conflict] {
        rules.conflicts(assigning: slots, to: presetID)
    }

    /// A preset's name as the conflict message says it — the built-in's, the
    /// saved one's, or a stand-in for an id nobody holds any more.
    func name(of presetID: UUID) -> String {
        if let builtIn = PhotoPreset.builtIn(id: presetID) { return builtIn.displayName }
        return CustomPresetStore.shared.preset(id: presetID)?.name ?? "A deleted preset"
    }

    /// The look `context` starts on, or nil when no rule holds its slot — or
    /// the rule names a preset that is gone, or a LUT whose cube isn't in
    /// this library's store (nothing is copied into a project any more, so
    /// a missing cube would be a look nothing can draw). Pure: the chip
    /// asks this from a view body, so a stale rule is dropped by
    /// `pruneStale()` at registration, not here.
    func resolve(_ context: AutoApplyContext) -> AutoAppliedLook? {
        guard let id = rules.owner(of: context.slot) else { return nil }
        return look(for: id)
    }

    /// The fields a project starting on `presetID` is stamped with.
    func look(for presetID: UUID) -> AutoAppliedLook? {
        if let builtIn = PhotoPreset.builtIn(id: presetID) {
            // Original is a state, not a look: a rule can't name it (its
            // screen doesn't exist), and if one did the project is Original
            // by construction anyway.
            guard builtIn != .original else { return nil }
            return AutoAppliedLook(
                presetID: presetID, name: builtIn.displayName, preset: builtIn, adjustments: .neutral,
                state: .named(id: presetID, snapshot: builtIn.snapshot))
        }
        guard let custom = CustomPresetStore.shared.preset(id: presetID) else { return nil }
        if let lut = custom.lut, LUTStore.shared.file(id: lut.id) == nil { return nil }
        return AutoAppliedLook(
            presetID: presetID, name: custom.name, preset: custom.basePreset,
            adjustments: custom.adjustments.withoutGeometry.withoutWhite,
            state: .named(id: custom.id, snapshot: custom.snapshot))
    }

    // MARK: - Writing

    /// Gives `slots` to `presetID`, whoever held them. The screen asks
    /// `conflicts(assigning:to:)` first and confirms; this just does it.
    func assign(_ slots: Set<AutoApplySlot>, to presetID: UUID) {
        guard !slots.isEmpty else { return }
        var next = rules
        next.assign(slots, to: presetID)
        commit(next)
    }

    /// The preset's None — and what `CustomPresetStore.delete` calls, so a
    /// deleted preset takes its rules with it whichever door deleted it.
    func release(_ presetID: UUID) {
        var next = rules
        next.release(presetID)
        commit(next)
    }

    /// Narrowing a mode's row: only these slots, only if this preset holds them.
    func release(_ slots: Set<AutoApplySlot>, from presetID: UUID) {
        var next = rules
        next.release(slots, from: presetID)
        commit(next)
    }

    /// A row's change in one write: what this preset lets go, then what it
    /// takes — a filter that both narrows and widens within a mode.
    func apply(assigning: Set<AutoApplySlot>, releasing: Set<AutoApplySlot>, for presetID: UUID) {
        var next = rules
        next.release(releasing, from: presetID)
        next.assign(assigning, to: presetID)
        commit(next)
    }

    /// Drops the rules of presets that no longer resolve — called on the
    /// registration path, where a mutation is safe, never from a view body.
    func pruneStale() {
        let known = rules.presetIDs.filter { look(for: $0) != nil }
        var next = rules
        let dropped = next.prune(keeping: known)
        guard !dropped.isEmpty else { return }
        LLog("auto-apply: dropped \(dropped.count) rule owner(s) that no longer resolve")
        commit(next)
    }

    #if DEBUG
    /// `LL_AUTOAPPLY`: the rules a screenshot needs, in memory only.
    func debugSeed(_ staged: AutoApplyRules) {
        persistsChanges = false
        rules = staged
    }
    #endif

    private func commit(_ next: AutoApplyRules) {
        guard next != rules else { return }
        rules = next
        persist()
    }

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            rules = try JSONDecoder().decode(AutoApplyRules.self, from: data)
        } catch {
            // A corrupt file must not take the capture screen down: no
            // rules until the next change rewrites it.
            LLog("auto-apply: couldn't read \(fileURL.lastPathComponent): \(error.localizedDescription)")
            rules = AutoApplyRules()
        }
    }

    private func persist() {
        #if DEBUG
        guard persistsChanges else { return }
        #endif
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rules).write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "Couldn't save the auto apply rules: \(error.localizedDescription)"
        }
    }
}

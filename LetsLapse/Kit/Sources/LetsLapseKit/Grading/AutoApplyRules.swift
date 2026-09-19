import Foundation

// MARK: - Auto apply: which new shoots start on which preset

/// The three kinds of shoot a rule can name. Scans are never a target —
/// they are documents, not looks — so this is deliberately not
/// `ProjectCategory`.
public enum AutoApplyMode: String, CaseIterable, Codable, Sendable {
    case photo, interval, video

    /// "Photo shoots" — the rows on the preset's screen and the words in the
    /// conflict message.
    public var displayName: String { "\(shortName) shoots" }

    /// "Photo" — the word the summary line joins: "Photo & Interval shoots".
    public var shortName: String {
        switch self {
        case .photo: return "Photo"
        case .interval: return "Interval"
        case .video: return "Video"
        }
    }
}

/// The contexts a new shoot can be registered from, as the "Auto apply to"
/// rules on a preset's or LUT's screen see them (Create ▸ Manage presets;
/// docs/presets-auto-apply.md).
///
/// Eight atomic contexts, each with at most one owning preset. What the
/// screen offers — Everything, Photo shoots · JPEGs, Video shoots · Capture
/// Flat ON — are SETS of these, so a preset's configuration is derived from
/// the slots it owns rather than stored beside them, and two rules can never
/// claim one shoot. Assigning a set overwrites those slots' owners; the other
/// presets' rules shrink to what they still own. That shrink is the cleanup
/// the conflict dialog warns about before it happens.
///
/// The raw values are written to `auto_apply.json` and must never move.
public enum AutoApplySlot: String, CaseIterable, Codable, Hashable, Sendable {
    case photoJPEGStandard = "photo.jpegStandard"
    case photoJPEGFlat = "photo.jpegFlat"
    case photoDNG = "photo.dng"
    case intervalJPEGStandard = "interval.jpegStandard"
    case intervalJPEGFlat = "interval.jpegFlat"
    case intervalDNG = "interval.dng"
    case videoFlatOff = "video.flatOff"
    case videoFlatOn = "video.flatOn"

    public static let all: Set<AutoApplySlot> = Set(allCases)

    public var mode: AutoApplyMode {
        switch self {
        case .photoJPEGStandard, .photoJPEGFlat, .photoDNG: return .photo
        case .intervalJPEGStandard, .intervalJPEGFlat, .intervalDNG: return .interval
        case .videoFlatOff, .videoFlatOn: return .video
        }
    }

    /// The context's own words: "JPEG Flat ON", "Capture Flat OFF".
    public var label: String {
        switch self {
        case .photoJPEGStandard, .intervalJPEGStandard: return "JPEG Standard"
        case .photoJPEGFlat, .intervalJPEGFlat: return "JPEG Flat ON"
        case .photoDNG, .intervalDNG: return "DNG"
        case .videoFlatOff: return "Capture Flat OFF"
        case .videoFlatOn: return "Capture Flat ON"
        }
    }

    /// Declaration order — what the comma lists and the conflict list sort by.
    public var ordinal: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public static func slots(in mode: AutoApplyMode) -> Set<AutoApplySlot> {
        Set(allCases.filter { $0.mode == mode })
    }

    /// The one slot a finished shoot lands in. A DNG has no flat variant —
    /// the flat grade is a JPEG save-time step — so `dng` wins over `flat`
    /// in the still modes, and Video has no format axis at all.
    public static func slot(mode: AutoApplyMode, dng: Bool, flat: Bool) -> AutoApplySlot {
        switch mode {
        case .photo: return dng ? .photoDNG : (flat ? .photoJPEGFlat : .photoJPEGStandard)
        case .interval: return dng ? .intervalDNG : (flat ? .intervalJPEGFlat : .intervalJPEGStandard)
        case .video: return flat ? .videoFlatOn : .videoFlatOff
        }
    }
}

/// The choices a mode's row offers — each a set of that mode's slots.
public enum AutoApplyFilter: String, CaseIterable, Sendable {
    case all, jpegs, jpegStandard, jpegFlat, dng, flatOff, flatOn

    public var label: String {
        switch self {
        case .all: return "All"
        case .jpegs: return "JPEGs"
        case .jpegStandard: return "JPEG Standard"
        case .jpegFlat: return "JPEG Flat ON"
        case .dng: return "DNG"
        case .flatOff: return "Capture Flat OFF"
        case .flatOn: return "Capture Flat ON"
        }
    }

    /// The row's menu, top to bottom.
    public static func options(for mode: AutoApplyMode) -> [AutoApplyFilter] {
        switch mode {
        case .photo, .interval: return [.all, .jpegs, .jpegStandard, .jpegFlat, .dng]
        case .video: return [.all, .flatOff, .flatOn]
        }
    }

    public func slots(in mode: AutoApplyMode) -> Set<AutoApplySlot> {
        let whole = AutoApplySlot.slots(in: mode)
        switch (self, mode) {
        case (.all, _): return whole
        case (.jpegs, .photo): return [.photoJPEGStandard, .photoJPEGFlat]
        case (.jpegs, .interval): return [.intervalJPEGStandard, .intervalJPEGFlat]
        case (.jpegStandard, .photo): return [.photoJPEGStandard]
        case (.jpegStandard, .interval): return [.intervalJPEGStandard]
        case (.jpegFlat, .photo): return [.photoJPEGFlat]
        case (.jpegFlat, .interval): return [.intervalJPEGFlat]
        case (.dng, .photo): return [.photoDNG]
        case (.dng, .interval): return [.intervalDNG]
        case (.flatOff, .video): return [.videoFlatOff]
        case (.flatOn, .video): return [.videoFlatOn]
        default: return []  // a video filter asked of a still mode, or vice versa
        }
    }

    /// The filter that names exactly `slots` within `mode`, if one does.
    public static func canonical(for slots: Set<AutoApplySlot>, in mode: AutoApplyMode) -> AutoApplyFilter? {
        let own = slots.filter { $0.mode == mode }
        guard !own.isEmpty else { return nil }
        return options(for: mode).first { $0.slots(in: mode) == own }
    }

    /// The row's value: the canonical name, else the slots by name in
    /// declaration order — what a preset is left with after another took
    /// part of its mode ("JPEG Standard, DNG"). Empty for no slots.
    public static func label(for slots: Set<AutoApplySlot>, in mode: AutoApplyMode) -> String {
        if let filter = canonical(for: slots, in: mode) { return filter.label }
        return slots.filter { $0.mode == mode }
            .sorted { $0.ordinal < $1.ordinal }
            .map(\.label)
            .joined(separator: ", ")
    }
}

/// The rules of one library: slot → the preset that new shoots there start
/// on. Persisted as `{"version": 1, "owners": {"photo.dng": "<uuid>"}}`;
/// a key or an id the reader doesn't know is skipped, not fatal.
public struct AutoApplyRules: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public private(set) var owners: [AutoApplySlot: UUID]

    public init(owners: [AutoApplySlot: UUID] = [:]) {
        self.owners = owners
    }

    public var isEmpty: Bool { owners.isEmpty }

    /// Every preset that holds at least one slot.
    public var presetIDs: Set<UUID> { Set(owners.values) }

    // MARK: Reading

    public func owner(of slot: AutoApplySlot) -> UUID? { owners[slot] }

    public func slots(for presetID: UUID) -> Set<AutoApplySlot> {
        Set(owners.filter { $0.value == presetID }.keys)
    }

    public func slots(for presetID: UUID, in mode: AutoApplyMode) -> Set<AutoApplySlot> {
        slots(for: presetID).filter { $0.mode == mode }
    }

    /// The modes a preset holds any slot of, in the screen's order.
    public func modes(for presetID: UUID) -> [AutoApplyMode] {
        let owned = slots(for: presetID)
        return AutoApplyMode.allCases.filter { mode in owned.contains { $0.mode == mode } }
    }

    public func ownsEverything(_ presetID: UUID) -> Bool {
        slots(for: presetID) == AutoApplySlot.all
    }

    /// The "Auto apply to" row's value: "None", "Everything – All shoots",
    /// "Photo shoots", "Photo & Interval shoots", "Photo, Interval & Video
    /// shoots". Three modes short of every slot is still the long form — the
    /// rows beneath say which contexts each one keeps.
    public func summary(for presetID: UUID) -> String {
        let owned = slots(for: presetID)
        if owned.isEmpty { return "None" }
        if owned == AutoApplySlot.all { return "Everything – All shoots" }
        let names = modes(for: presetID).map(\.shortName)
        switch names.count {
        case 1: return "\(names[0]) shoots"
        case 2: return "\(names[0]) & \(names[1]) shoots"
        default: return names.dropLast().joined(separator: ", ") + " & " + names[names.count - 1] + " shoots"
        }
    }

    /// Slots in words, per mode in the screen's order: "Photo shoots · JPEG
    /// Flat ON and Video shoots · Capture Flat ON". The conflict message's
    /// building block. Empty for no slots.
    public static func describe(_ slots: Set<AutoApplySlot>) -> String {
        AutoApplyMode.allCases.compactMap { mode -> String? in
            let own = slots.filter { $0.mode == mode }
            guard !own.isEmpty else { return nil }
            return "\(mode.displayName) · \(AutoApplyFilter.label(for: own, in: mode))"
        }.joined(separator: " and ")
    }

    // MARK: Conflicts

    /// What an assignment takes from another preset, and what that preset
    /// keeps — the dialog's list. Never the assignee's own slots.
    public struct Conflict: Equatable, Sendable {
        public let presetID: UUID
        /// The slots this assignment takes from `presetID`.
        public let slots: Set<AutoApplySlot>
        /// What `presetID` still owns afterwards; empty when the rule goes
        /// entirely.
        public let remaining: Set<AutoApplySlot>

        public init(presetID: UUID, slots: Set<AutoApplySlot>, remaining: Set<AutoApplySlot>) {
            self.presetID = presetID
            self.slots = slots
            self.remaining = remaining
        }
    }

    /// The presets `assign(slots, to: presetID)` would take slots from,
    /// ordered by the first slot taken (Photo before Video) then by id, so
    /// the message reads the same way twice.
    public func conflicts(assigning slots: Set<AutoApplySlot>, to presetID: UUID) -> [Conflict] {
        var taken: [UUID: Set<AutoApplySlot>] = [:]
        for slot in slots {
            guard let owner = owners[slot], owner != presetID else { continue }
            taken[owner, default: []].insert(slot)
        }
        return taken.map { owner, lost in
            Conflict(presetID: owner, slots: lost, remaining: self.slots(for: owner).subtracting(lost))
        }.sorted { a, b in
            let first = a.slots.map(\.ordinal).min() ?? 0
            let second = b.slots.map(\.ordinal).min() ?? 0
            return first != second ? first < second : a.presetID.uuidString < b.presetID.uuidString
        }
    }

    // MARK: Writing

    /// Gives `slots` to `presetID`, whoever held them.
    public mutating func assign(_ slots: Set<AutoApplySlot>, to presetID: UUID) {
        for slot in slots { owners[slot] = presetID }
    }

    /// Every slot `presetID` holds goes — the preset's None, and what a
    /// deleted preset leaves behind.
    public mutating func release(_ presetID: UUID) {
        owners = owners.filter { $0.value != presetID }
    }

    /// Only the given slots, and only if `presetID` holds them — narrowing a
    /// mode's row never touches another preset.
    public mutating func release(_ slots: Set<AutoApplySlot>, from presetID: UUID) {
        for slot in slots where owners[slot] == presetID {
            owners.removeValue(forKey: slot)
        }
    }

    /// Drops every owner not in `known` — a preset deleted while the rules
    /// file wasn't watching. Returns the ids dropped.
    @discardableResult
    public mutating func prune(keeping known: Set<UUID>) -> Set<UUID> {
        let dropped = presetIDs.subtracting(known)
        if !dropped.isEmpty {
            owners = owners.filter { known.contains($0.value) }
        }
        return dropped
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case version, owners
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decodeIfPresent(Int.self, forKey: .version)
        let raw = try container.decodeIfPresent([String: String].self, forKey: .owners) ?? [:]
        var owners: [AutoApplySlot: UUID] = [:]
        for (key, value) in raw {
            guard let slot = AutoApplySlot(rawValue: key), let id = UUID(uuidString: value) else { continue }
            owners[slot] = id
        }
        self.owners = owners
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        let raw = Dictionary(uniqueKeysWithValues: owners.map { ($0.key.rawValue, $0.value.uuidString) })
        try container.encode(raw, forKey: .owners)
    }
}

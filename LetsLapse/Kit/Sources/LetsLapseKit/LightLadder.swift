import Foundation
import CoreMedia

// MARK: - Light Ladder

/// A **Light Ladder**: one table of named light states — *rungs* — read
/// top-down by scene brightness. A shoot in Interval's Ladder MODE descends it
/// through dusk and climbs it through dawn; there is never a second table for
/// the other direction.
///
/// A rung is a **box of constraints** handed to the Holy Grail servo
/// (`HolyGrailRampEngine`), not an exposure: every exposure change is still
/// walked at ≤ ⅓ stop per window inside the box. Interval and blend depth may
/// step at a rung boundary; exposure never does.
///
/// Rungs store a **lower bound** only. The ladder is gap-free by construction
/// and the last rung is "and darker". Ranges are shown, never stored.
///
/// Pure value type with no I/O; the app owns the store (`light_ladders.json`)
/// and the engine hook. See `docs/light-ladder.md`.
public struct LightLadder: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Brightest first. Use `normalized()` before trusting the order.
    public var rungs: [Rung]
    /// The ladder this one was duplicated from, for the "cloned from the
    /// built-in" subtitle.
    public var clonedFromID: UUID?

    public init(id: UUID = UUID(), name: String, rungs: [Rung], clonedFromID: UUID? = nil) {
        self.id = id
        self.name = name
        self.rungs = rungs
        self.clonedFromID = clonedFromID
    }

    // MARK: The built-in

    /// Fixed so a shoot from six months ago still names the ladder it used.
    /// Never written to file — the store skips it (precedent:
    /// `App/PresetState.swift`'s built-in presets).
    public static let builtInID = UUID(uuidString: "5C6D7E8F-0A1B-4C2D-9E3F-A4B5C6D7E8F9")!

    public var isBuiltIn: Bool { id == Self.builtInID }

    /// **Bright & Fast, Dark & Slow** — always present, cloneable, never
    /// editable in place.
    ///
    /// Each boundary moves one exposure lever and no more: 13 → 8 changes only
    /// pacing, 8 → 4 releases ISO, 4 → night drops blend. Night's shutter is
    /// *auto ≤ 1 s*, not pinned (decision D1, 2026-09-03): the servo's
    /// shutter-first policy lands on 1 s as soon as it is dark enough, and a
    /// pin at the rung's EV 4 threshold would have needed ISO 20 — below the
    /// wide lens's floor — so the frames would have run ~1.4 stops over until
    /// EV 2.5. Night's honest change is "no stacking".
    public static let builtIn = LightLadder(
        id: builtInID,
        name: "Bright & Fast, Dark & Slow",
        rungs: [
            Rung(id: UUID(uuidString: "5C6D7E8F-0A1B-4C2D-9E3F-A4B5C6D7E801")!,
                 name: "Daylight", lowerBoundEV: 13,
                 iso: .min, shutter: .auto, whiteBalance: .auto,
                 intervalSeconds: 3, blendFrames: 10),
            Rung(id: UUID(uuidString: "5C6D7E8F-0A1B-4C2D-9E3F-A4B5C6D7E802")!,
                 name: "Fading", lowerBoundEV: 8,
                 iso: .min, shutter: .autoCapped(1), whiteBalance: .auto,
                 intervalSeconds: 2, blendFrames: 5),
            Rung(id: UUID(uuidString: "5C6D7E8F-0A1B-4C2D-9E3F-A4B5C6D7E803")!,
                 name: "Dusk", lowerBoundEV: 4,
                 iso: .auto, shutter: .autoCapped(1), whiteBalance: .auto,
                 intervalSeconds: 2, blendFrames: 3),
            Rung(id: UUID(uuidString: "5C6D7E8F-0A1B-4C2D-9E3F-A4B5C6D7E804")!,
                 name: "Night", lowerBoundEV: nil,
                 iso: .auto, shutter: .autoCapped(1), whiteBalance: .auto,
                 intervalSeconds: 2, blendFrames: 1),
        ])

    // MARK: Cloning

    /// A user copy: new ids throughout, `clonedFromID` pointing back here.
    public func cloned(named newName: String? = nil) -> LightLadder {
        LightLadder(
            id: UUID(),
            name: newName ?? "\(name) (copy)",
            rungs: rungs.map { rung in
                var copy = rung
                copy.id = UUID()
                return copy
            },
            clonedFromID: id)
    }

    // MARK: Normalisation

    /// The ladder with its invariants restored: rungs sorted brightest first,
    /// thresholds strictly descending (a duplicate threshold keeps the first
    /// rung and drops the rest), and exactly one unbounded rung — the last.
    ///
    /// A bounded last rung *becomes* unbounded ("the last rung has no lower
    /// bound"); an unbounded rung that isn't last keeps its place at the
    /// bottom of the order only if nothing else is unbounded. Applied on load
    /// so a hand-edited file can never break selection.
    public func normalized() -> LightLadder {
        guard !rungs.isEmpty else { return self }
        let sorted = rungs.enumerated().sorted { lhs, rhs in
            let l = lhs.element.lowerBoundEV ?? -.infinity
            let r = rhs.element.lowerBoundEV ?? -.infinity
            if l != r { return l > r }
            return lhs.offset < rhs.offset
        }.map(\.element)
        var kept: [Rung] = []
        var seen = Set<Double>()
        for rung in sorted {
            let key = rung.lowerBoundEV ?? -.infinity
            if seen.contains(key) { continue }
            seen.insert(key)
            kept.append(rung)
        }
        kept[kept.count - 1].lowerBoundEV = nil
        var copy = self
        copy.rungs = kept
        return copy
    }

    public var isNormalized: Bool { normalized() == self }

    // MARK: Reading the table

    public func index(of rungID: UUID) -> Int? {
        rungs.firstIndex { $0.id == rungID }
    }

    /// The rung's bright edge: the lower bound of the rung above it. `nil` for
    /// the first rung, which has no bright edge.
    public func upperBoundEV(at index: Int) -> Double? {
        guard index > 0, index < rungs.count else { return nil }
        return rungs[index - 1].lowerBoundEV
    }

    /// "EV 4 to 8" · "EV 13 and brighter" · "and darker" — the range a rung
    /// covers, derived from its neighbours. Never stored.
    public func rangeDescription(at index: Int) -> String {
        guard index >= 0, index < rungs.count else { return "" }
        let lower = rungs[index].lowerBoundEV
        let upper = upperBoundEV(at: index)
        switch (lower, upper) {
        case (nil, nil): return "all light"
        case (let l?, nil): return "EV \(LightLadderFormat.ev(l)) and brighter"
        case (nil, let u?): return "below EV \(LightLadderFormat.ev(u)) · and darker"
        case (let l?, let u?): return "EV \(LightLadderFormat.ev(l)) to \(LightLadderFormat.ev(u))"
        }
    }

    /// "4 rungs · EV 13 · 8 · 4 · darker" — the list subtitle.
    public var thresholdSummary: String {
        let count = rungs.count == 1 ? "1 rung" : "\(rungs.count) rungs"
        let bounds = rungs.compactMap(\.lowerBoundEV).map(LightLadderFormat.ev)
        var parts = [count]
        if !bounds.isEmpty {
            parts.append("EV " + bounds.joined(separator: " · "))
        }
        if rungs.last?.lowerBoundEV == nil {
            parts.append("darker")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Drawing

    /// The EV window every ladder is drawn in — the ribbon in the editor, the
    /// rail in the running HUD. Bright daylight at the top, deep night at the
    /// bottom; ticks at 13 daylight · 10 overcast · 7 dim · 4 dusk.
    public static let drawingTopEV: Double = 16
    public static let drawingBottomEV: Double = -2

    /// Each rung's EV span inside the drawing window, brightest first, so a
    /// bar's height (or a band's width) is proportional to the light it
    /// covers. Zero for a rung the window doesn't reach.
    public func drawingSpans(top: Double = drawingTopEV, bottom: Double = drawingBottomEV) -> [Double] {
        rungs.indices.map { index in
            let upper = min(upperBoundEV(at: index) ?? top, top)
            let lower = max(rungs[index].lowerBoundEV ?? bottom, bottom)
            return max(upper - lower, 0)
        }
    }
}

// MARK: - Rung

/// One threshold plus five levers. Three of the levers (ISO, shutter, white
/// balance) are constraints handed to the servo; two (interval, blend) step
/// at the boundary.
public struct Rung: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    /// User-editable. The running HUD has about 90 pt for it, so a long name
    /// truncates there before anywhere else.
    public var name: String
    /// "Scene EV and brighter". `nil` on the last rung only: "and darker".
    public var lowerBoundEV: Double?
    public var iso: ISOChoice
    public var shutter: ShutterChoice
    public var whiteBalance: WhiteBalanceChoice
    /// Never Auto — EVERY = Auto is unavailable in Ladder mode; a rung's
    /// interval is a number.
    public var intervalSeconds: Double
    /// 1 = "off" (no stacking).
    public var blendFrames: Int

    public init(
        id: UUID = UUID(),
        name: String,
        lowerBoundEV: Double?,
        iso: ISOChoice = .auto,
        shutter: ShutterChoice = .auto,
        whiteBalance: WhiteBalanceChoice = .auto,
        intervalSeconds: Double,
        blendFrames: Int
    ) {
        self.id = id
        self.name = name
        self.lowerBoundEV = lowerBoundEV
        self.iso = iso
        self.shutter = shutter
        self.whiteBalance = whiteBalance
        self.intervalSeconds = max(intervalSeconds, 0.1)
        self.blendFrames = max(blendFrames, 1)
    }

    /// True when both ISO and shutter are pinned — a manual lock, which the
    /// model allows on purpose. Anything left unpinned belongs to the servo.
    public var isManualLock: Bool {
        if case .value = iso, case .value = shutter { return true }
        return false
    }

    /// "ISO min · shutter auto ≤ 1 s · every 2 s · blend 5"
    public var leverSummary: String {
        "ISO \(iso.summary) · shutter \(shutter.summary) · every \(LightLadderFormat.seconds(intervalSeconds)) · \(blendSummary)"
    }

    /// "ISO min · auto ≤ 1 s · 2 s · blend 5" — the list row, where the
    /// lever names are the column order.
    public var shortLeverSummary: String {
        "ISO \(iso.summary) · \(shutter.summary) · \(LightLadderFormat.seconds(intervalSeconds)) · \(blendSummary)"
    }

    public var blendSummary: String {
        blendFrames <= 1 ? "blend off" : "blend \(blendFrames)"
    }

    // MARK: Codable — decode-tolerant

    private enum CodingKeys: String, CodingKey {
        case id, name, lowerBoundEV, iso, shutter, whiteBalance, intervalSeconds, blendFrames
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "Rung",
            lowerBoundEV: try c.decodeIfPresent(Double.self, forKey: .lowerBoundEV),
            iso: try c.decodeIfPresent(ISOChoice.self, forKey: .iso) ?? .auto,
            shutter: try c.decodeIfPresent(ShutterChoice.self, forKey: .shutter) ?? .auto,
            whiteBalance: try c.decodeIfPresent(WhiteBalanceChoice.self, forKey: .whiteBalance) ?? .auto,
            intervalSeconds: try c.decodeIfPresent(Double.self, forKey: .intervalSeconds) ?? 2,
            blendFrames: try c.decodeIfPresent(Int.self, forKey: .blendFrames) ?? 1)
    }
}

/// Symbolic ISO — what makes a ladder portable. Resolved at arm time from the
/// active lens's format, so "min" is 54 on one lens and 34 on another.
public enum ISOChoice: Equatable, Sendable, Codable {
    case min
    case max
    case auto
    case value(Float)

    public var summary: String {
        switch self {
        case .min: return "min"
        case .max: return "max"
        case .auto: return "auto"
        case .value(let v): return "\(Int(v.rounded()))"
        }
    }

    // Encoded as `"min"` / `"max"` / `"auto"` or a bare number, so the file
    // reads like the table it is.
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let word = try? c.decode(String.self) {
            switch word {
            case "min": self = .min
            case "max": self = .max
            case "auto": self = .auto
            default:
                if let number = Float(word) { self = .value(number) } else { self = .auto }
            }
        } else {
            self = .value(try c.decode(Float.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .min: try c.encode("min")
        case .max: try c.encode("max")
        case .auto: try c.encode("auto")
        case .value(let v): try c.encode(v)
        }
    }
}

/// The shutter lever. `autoCapped` lowers the servo's ceiling below the
/// hardware's; `value` pins it (min == max in the box).
public enum ShutterChoice: Equatable, Sendable, Codable {
    case auto
    case autoCapped(Double)
    case value(Double)

    public var summary: String {
        switch self {
        case .auto: return "auto"
        case .autoCapped(let s): return "auto ≤ \(LightLadderFormat.seconds(s))"
        case .value(let s): return LightLadderFormat.seconds(s)
        }
    }

    private struct Cap: Codable { var cap: Double }

    // `"auto"` · `{"cap": 1}` · a bare number of seconds.
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let word = try? c.decode(String.self) {
            self = word == "auto" ? .auto : (Double(word).map { .value($0) } ?? .auto)
        } else if let capped = try? c.decode(Cap.self) {
            self = .autoCapped(capped.cap)
        } else {
            self = .value(try c.decode(Double.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .auto: try c.encode("auto")
        case .autoCapped(let s): try c.encode(Cap(cap: s))
        case .value(let s): try c.encode(s)
        }
    }
}

/// White balance is auto or locked in v1 — no Kelvin. **Neither is continuous
/// AWB.** `auto` is the tracked behaviour every Holy Grail run already uses
/// (slew-limited gains on the JPEG path, locked at arm on DNG); `locked` is
/// frozen at arm on both. A rung must never reintroduce WB flicker.
public enum WhiteBalanceChoice: String, Codable, Equatable, Sendable, CaseIterable {
    case auto
    case locked

    public var summary: String { rawValue }
}

// MARK: - The exposure box

extension Rung {
    /// The margin the engine keeps between the longest exposure and the
    /// window — the same 0.3 s `holyGrailSettleSeconds` the app subtracts.
    public static let settleSeconds: Double = 0.3

    /// The longest exposure a frame of this rung can take: the rung's own cap,
    /// the hardware's, and the share of the window each of `blendFrames`
    /// frames gets. Frames are captured in sequence on both pipelines (a
    /// bracket's exposures back to back; the video tap's stream at
    /// depth ÷ interval), so five frames cannot each take a second inside a
    /// two-second window whatever the cap says.
    public func effectiveShutterCeiling(within format: HolyGrailRampEngine.HardwareLimits) -> Double {
        let hardware = format.maxShutter.seconds
        let window = max(intervalSeconds - Self.settleSeconds, 0.05) / Double(max(blendFrames, 1))
        var ceiling = min(hardware, window)
        switch shutter {
        case .auto: break
        case .autoCapped(let cap): ceiling = min(ceiling, cap)
        case .value(let pin): ceiling = min(ceiling, pin)
        }
        return max(ceiling, format.minShutter.seconds)
    }

    /// The box handed to the servo for this rung, inside what the format
    /// allows. A pin is min == max; everything is re-clamped to the format —
    /// an out-of-range manual bracket raises an uncatchable NSException, so
    /// the clamp is not optional.
    public func exposureBox(within format: HolyGrailRampEngine.HardwareLimits) -> HolyGrailRampEngine.HardwareLimits {
        let floor = format.minShutter.seconds
        let ceiling = effectiveShutterCeiling(within: format)
        let minShutter: Double
        let maxShutter: Double
        switch shutter {
        case .auto, .autoCapped:
            minShutter = floor
            maxShutter = ceiling
        case .value(let pin):
            let clamped = min(max(pin, floor), ceiling)
            minShutter = clamped
            maxShutter = clamped
        }

        let minISO: Float
        let maxISO: Float
        switch iso {
        case .auto:
            minISO = format.minISO
            maxISO = format.maxISO
        case .min:
            minISO = format.minISO
            maxISO = format.minISO
        case .max:
            minISO = format.maxISO
            maxISO = format.maxISO
        case .value(let v):
            let clamped = min(max(v, format.minISO), format.maxISO)
            minISO = clamped
            maxISO = clamped
        }

        return HolyGrailRampEngine.HardwareLimits(
            minShutter: HolyGrailRampEngine.time(minShutter),
            maxShutter: HolyGrailRampEngine.time(maxShutter),
            minISO: minISO,
            maxISO: maxISO,
            aperture: format.aperture)
    }

    /// The exposure the servo would settle on for `sceneEV` inside this
    /// rung's box — what the adjacency and feasibility checks compare.
    public func settledTarget(
        sceneEV: Double,
        within format: HolyGrailRampEngine.HardwareLimits
    ) -> HolyGrailRampEngine.ExposureTarget {
        let box = exposureBox(within: format)
        let gain = HolyGrailRampEngine.requiredGain(sceneEV100: sceneEV, aperture: box.aperture)
        return HolyGrailRampEngine.split(gain: gain, limits: box)
    }
}

// MARK: - Selection

/// Which rung the light is on. Follows the Zone band pattern
/// (`ZoneBlendStrategy`): the first rung whose lower bound the smoothed EV
/// clears wins — with a switching band, so a rung holds until the smoothed
/// EV passes its boundary by `switchingBandEV`, and AE hunting at a
/// threshold can't flap it.
///
/// Called **between windows only** — a change never lands mid-window. On no
/// reading the last rung holds.
public struct LightLadderSelector: Equatable, Sendable {
    /// How many windows of EV the rolling average spans — Zone's three.
    public static let smoothingWindow = 3
    /// How far past a boundary the smoothed EV must move before the rung
    /// follows. A Kit constant in v1 (decision D5): no field evidence for the
    /// number yet, so it is tuned on the bench, not per ladder.
    public static let switchingBandEV: Double = 0.5

    public let ladder: LightLadder
    private var readings: [Double] = []
    public private(set) var currentIndex: Int?
    public private(set) var lastSmoothedEV: Double?
    /// Whether the last `resolve` moved to a different rung — the running
    /// HUD's toast fires on it.
    public private(set) var changedOnLastResolve = false

    public init(ladder: LightLadder) {
        self.ladder = ladder.normalized()
    }

    public var currentRung: Rung? {
        currentIndex.map { ladder.rungs[$0] }
    }

    /// The rung a bare EV selects, no smoothing, no band.
    public static func plainIndex(forEV ev: Double, in ladder: LightLadder) -> Int {
        ladder.rungs.firstIndex { ev >= ($0.lowerBoundEV ?? -.infinity) } ?? max(ladder.rungs.count - 1, 0)
    }

    /// One window's resolution. Returns the rung index for the next window.
    @discardableResult
    public mutating func resolve(ev: Double?) -> Int {
        changedOnLastResolve = false
        guard !ladder.rungs.isEmpty else { return 0 }
        guard let ev, ev.isFinite else {
            if let held = currentIndex { return held }
            // Nothing measured yet and no history: the middle of the table,
            // as Zone does. The app seeds from the live preview's EV before
            // the first window, so this is the no-camera fallback.
            let middle = ladder.rungs.count / 2
            currentIndex = middle
            changedOnLastResolve = true
            return middle
        }
        readings.append(ev)
        if readings.count > Self.smoothingWindow {
            readings.removeFirst(readings.count - Self.smoothingWindow)
        }
        let smoothed = readings.reduce(0, +) / Double(readings.count)
        lastSmoothedEV = smoothed

        let plain = Self.plainIndex(forEV: smoothed, in: ladder)
        guard let current = currentIndex else {
            currentIndex = plain
            changedOnLastResolve = true
            return plain
        }
        let band = Self.switchingBandEV
        let rungs = ladder.rungs
        var next = current
        if plain < current {
            // Climbing: a brighter rung is entered only once the smoothed EV
            // clears its lower bound by the band. Walk back down toward the
            // current rung until one qualifies.
            var i = plain
            while i < current, smoothed < (rungs[i].lowerBoundEV ?? -.infinity) + band { i += 1 }
            next = i
        } else if plain > current {
            // Descending: the boundary into rung i is rung i−1's lower bound;
            // it is crossed only once the smoothed EV sits below it by the
            // band. Walk back up toward the current rung until one qualifies.
            var i = plain
            while i > current, smoothed >= (rungs[i - 1].lowerBoundEV ?? -.infinity) - band { i -= 1 }
            next = i
        }
        changedOnLastResolve = next != current
        currentIndex = next
        return next
    }
}

// MARK: - Pacing and the governor

/// What a window actually runs at once the processing governor has had its
/// say. A rung is a **ceiling, not a promise** (decision D2): the shipped AIMD
/// order of yield is depth first — down to `ProcessingCeiling`'s 2-frame
/// floor — and then the interval stretches to the pace the pipeline
/// demonstrably needs. A rung's EVERY is only ever lengthened, never
/// shortened.
public struct LightLadderPacing: Equatable, Sendable {
    public enum Yield: Equatable, Sendable {
        /// Blend depth was lowered below the rung's ask.
        case depth(asked: Int, applied: Int)
        /// The interval was stretched beyond the rung's ask.
        case pace(asked: Double, applied: Double)
    }

    public var intervalSeconds: Double
    public var blendFrames: Int
    public var yield: Yield?

    public init(intervalSeconds: Double, blendFrames: Int, yield: Yield? = nil) {
        self.intervalSeconds = intervalSeconds
        self.blendFrames = blendFrames
        self.yield = yield
    }

    /// The rung as asked — the JPEG path's answer, which has no governor.
    public init(rung: Rung) {
        self.init(intervalSeconds: rung.intervalSeconds, blendFrames: rung.blendFrames, yield: nil)
    }

    public static func apply(rung: Rung, ceiling: ProcessingCeiling) -> LightLadderPacing {
        let depth = min(rung.blendFrames, max(ceiling.ceiling, 1))
        let interval = max(rung.intervalSeconds, ceiling.sustainableIntervalSeconds ?? 0)
        var yield: Yield?
        if interval > rung.intervalSeconds + 0.001 {
            yield = .pace(asked: rung.intervalSeconds, applied: interval)
        } else if depth < rung.blendFrames {
            yield = .depth(asked: rung.blendFrames, applied: depth)
        }
        return LightLadderPacing(intervalSeconds: interval, blendFrames: depth, yield: yield)
    }

    /// The running HUD's third readout line: `Dusk · every 2 s · blend 3`, or
    /// with the governor's note — `blend 3 → 2, thermal` / `every 2 s → 4 s,
    /// processing`. `reason` is the app's word for why (thermal when the
    /// window opened under pressure, processing otherwise).
    public func readoutLine(rungName: String, reason: String = "processing") -> String {
        let every: String
        let blend: String
        switch yield {
        case .pace(let asked, let applied):
            every = "every \(LightLadderFormat.seconds(asked)) → \(LightLadderFormat.seconds(applied)), \(reason)"
            blend = blendFrames <= 1 ? "blend off" : "blend \(blendFrames)"
        case .depth(let asked, let applied):
            every = "every \(LightLadderFormat.seconds(intervalSeconds))"
            blend = "blend \(asked) → \(applied), \(reason)"
        case nil:
            every = "every \(LightLadderFormat.seconds(intervalSeconds))"
            blend = blendFrames <= 1 ? "blend off" : "blend \(blendFrames)"
        }
        return "\(rungName) · \(every) · \(blend)"
    }
}

// MARK: - Feasibility and adjacency

/// The sentences at the foot of the rung screen. Three invariants and one
/// adjacency rule, every one stated **visibly** — a rung is never silently
/// corrected and never locked.
public enum LightLadderAdvice {
    public struct Message: Equatable, Sendable {
        /// `fits` is the green line, `note` states a fact the servo will act
        /// on (no correction needed), `warning` is amber — something the
        /// author probably wants to change.
        public enum Kind: Equatable, Sendable { case fits, note, warning }
        public var kind: Kind
        public var text: String

        public init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// The fixed cost of one frame — capture and hand-off, not exposure —
    /// used to size a window's blend ceiling until the app has a measured
    /// figure for the device. With the 0.3 s settle margin a 2 s window
    /// holds 7 frames, a 3 s window 11.
    public static let defaultPerFrameSeconds: Double = 0.23

    /// How many frames a rung's window can hold at `perFrameSeconds` each.
    public static func blendCeiling(intervalSeconds: Double, perFrameSeconds: Double = defaultPerFrameSeconds) -> Int {
        max(1, Int(((intervalSeconds - Rung.settleSeconds) / max(perFrameSeconds, 0.01)).rounded(.down)))
    }

    /// What the boundary *above* rung `index` does to the exposure — the
    /// card's one-line statement, and the escalation when the one-lever
    /// rule is broken. `nil` for the first rung, which has no boundary above.
    public enum BoundaryEffect: Equatable, Sendable {
        /// The exposure carries straight through: pacing (and/or blend) only.
        case pacingOnly
        /// The servo's settled exposure differs by at most one step.
        case oneStep(lever: String)
        /// The rung above leaves the exposure `stops` away from where this
        /// rung's box settles; the servo walks it over `windows` windows.
        case jump(stops: Double, windows: Int, lever: String)
    }

    public static func boundaryEffect(
        above index: Int,
        in ladder: LightLadder,
        format: HolyGrailRampEngine.HardwareLimits,
        stopsPerStep: Double = HolyGrailRampEngine.defaultStopsPerStep
    ) -> BoundaryEffect? {
        guard index > 0, index < ladder.rungs.count,
              let boundary = ladder.rungs[index - 1].lowerBoundEV else { return nil }
        let above = ladder.rungs[index - 1].settledTarget(sceneEV: boundary, within: format)
        let below = ladder.rungs[index].settledTarget(sceneEV: boundary, within: format)
        let stops = abs(log2(max(above.lightGain, 1e-12) / max(below.lightGain, 1e-12)))
        let shutterMoves = abs(above.shutterSeconds - below.shutterSeconds) > 1e-6
        let isoMoves = abs(above.iso - below.iso) > 0.5
        let lever = shutterMoves && isoMoves ? "shutter and ISO" : shutterMoves ? "shutter" : "ISO"
        if !shutterMoves && !isoMoves { return .pacingOnly }
        if stops <= stopsPerStep + 1e-9 { return .oneStep(lever: lever) }
        return .jump(stops: stops, windows: Int((stops / stopsPerStep).rounded(.up)), lever: lever)
    }

    /// Every message for rung `index`, feasibility first, adjacency last.
    public static func messages(
        for index: Int,
        in ladder: LightLadder,
        format: HolyGrailRampEngine.HardwareLimits,
        perFrameSeconds: Double = defaultPerFrameSeconds,
        stopsPerStep: Double = HolyGrailRampEngine.defaultStopsPerStep
    ) -> [Message] {
        guard index >= 0, index < ladder.rungs.count else { return [] }
        let rung = ladder.rungs[index]
        var out: [Message] = []
        let interval = LightLadderFormat.seconds(rung.intervalSeconds)

        // 1 · Shutter fits the window (with the settle margin) and 2 · blend
        // fits the per-frame cost. Both are one "fits" line when they hold.
        let ceilingFrames = blendCeiling(intervalSeconds: rung.intervalSeconds, perFrameSeconds: perFrameSeconds)
        let stated = statedShutterSeconds(rung, format: format)
        let effective = rung.effectiveShutterCeiling(within: format)
        let window = rung.intervalSeconds - Rung.settleSeconds
        if stated > window + 1e-9 {
            out.append(Message(kind: .warning, text:
                "Shutter \(LightLadderFormat.seconds(stated)) does not fit a \(interval) interval with the \(LightLadderFormat.seconds(Rung.settleSeconds)) settle margin — the servo will get \(LightLadderFormat.seconds(effective)) at most."))
        }
        if rung.blendFrames > ceilingFrames {
            out.append(Message(kind: .warning, text:
                "Blend \(rung.blendFrames) will not fit a \(interval) interval at \(LightLadderFormat.seconds(perFrameSeconds)) a frame — the device will take \(ceilingFrames) at most, and the light panel will say so."))
        }
        if out.isEmpty {
            let shutterWord = LightLadderFormat.seconds(effective)
            let blendWord = rung.blendFrames <= 1 ? "no stacking" : "blend \(rung.blendFrames)"
            out.append(Message(kind: .fits, text:
                "Shutter \(shutterWord) and \(blendWord) both fit a \(interval) interval — \(LightLadderFormat.seconds(Rung.settleSeconds)) settle margin kept, ceiling \(ceilingFrames) frames."))
        }
        // A cap the window can't honour at this depth is a fact, not a fault:
        // the servo simply gets the share. Said once, in grey.
        if rung.blendFrames > 1, stated <= window + 1e-9, effective + 1e-9 < stated {
            out.append(Message(kind: .note, text:
                "\(rung.blendFrames) frames share a \(interval) window, so each gets \(LightLadderFormat.seconds(effective)) at most — the \(LightLadderFormat.seconds(stated)) shutter only applies once blend is off."))
        }

        // 3 · The box reaches the light at both edges of the rung. A pinned
        // lever (or a low cap) can leave the servo unable to expose the rung's
        // own threshold correctly — the case the built-in's original Night
        // rung had (1 s pinned at EV 4 → ISO 20, below the floor).
        out.append(contentsOf: reachMessages(for: index, in: ladder, format: format))

        // 4 · Adjacency: one exposure lever per boundary, walked at ≤ ⅓ stop.
        if let effect = boundaryEffect(above: index, in: ladder, format: format, stopsPerStep: stopsPerStep),
           case .jump(let stops, let windows, let lever) = effect {
            let above = ladder.rungs[index - 1].name
            out.append(Message(kind: .warning, text:
                "\(rung.name) leaves the \(lever) \(String(format: "%.1f", stops)) stops from where \(above) settles. The servo will walk that over about \(windows) windows — the frames in between are neither look. Consider bringing the two rungs' \(lever) closer."))
        }
        return out
    }

    /// "This boundary changes pacing only — the exposure carries straight
    /// through it." — the editor card's statement for a clean boundary.
    public static func boundaryStatement(
        above index: Int,
        in ladder: LightLadder,
        format: HolyGrailRampEngine.HardwareLimits
    ) -> String? {
        guard let effect = boundaryEffect(above: index, in: ladder, format: format) else { return nil }
        switch effect {
        case .pacingOnly:
            return "This boundary changes pacing only — the exposure carries straight through it."
        case .oneStep(let lever):
            return "This boundary moves the \(lever) by one step; the servo absorbs it in a window."
        case .jump(let stops, let windows, let lever):
            return "This boundary moves the \(lever) \(String(format: "%.1f", stops)) stops — about \(windows) windows of walking."
        }
    }

    // MARK: Internals

    private static func statedShutterSeconds(_ rung: Rung, format: HolyGrailRampEngine.HardwareLimits) -> Double {
        switch rung.shutter {
        case .auto: return format.maxShutter.seconds
        case .autoCapped(let cap): return min(cap, format.maxShutter.seconds)
        case .value(let pin): return pin
        }
    }

    private static func reachMessages(
        for index: Int,
        in ladder: LightLadder,
        format: HolyGrailRampEngine.HardwareLimits
    ) -> [Message] {
        let rung = ladder.rungs[index]
        let box = rung.exposureBox(within: format)
        let floorGain = HolyGrailRampEngine.lightGain(shutterSeconds: box.minShutter.seconds, iso: box.minISO)
        let ceilingGain = HolyGrailRampEngine.lightGain(shutterSeconds: box.maxShutter.seconds, iso: box.maxISO)
        var out: [Message] = []

        // Bright edge: the rung's top, where too much light is the risk.
        if let top = ladder.upperBoundEV(at: index) {
            let wanted = HolyGrailRampEngine.requiredGain(sceneEV100: top, aperture: box.aperture)
            if wanted < floorGain * 0.99 {
                let stops = log2(floorGain / wanted)
                let okEV = HolyGrailRampEngine.sceneEV100(forGain: floorGain, aperture: box.aperture)
                out.append(Message(kind: .warning, text:
                    "At EV \(LightLadderFormat.ev(top)) this box cannot close down far enough — frames run \(String(format: "%.1f", stops)) stops over until EV \(LightLadderFormat.ev(okEV)). \(reachHint(rung, over: true, format: format, box: box, atEV: top))"))
            }
        }
        // Dim edge: the rung's own threshold, where too little light is the
        // risk. The last rung has no dim edge — every box runs out of light
        // eventually, and that is night, not a mistake.
        if let bottom = rung.lowerBoundEV {
            let wanted = HolyGrailRampEngine.requiredGain(sceneEV100: bottom, aperture: box.aperture)
            if wanted > ceilingGain * 1.01 {
                let stops = log2(wanted / ceilingGain)
                let okEV = HolyGrailRampEngine.sceneEV100(forGain: ceilingGain, aperture: box.aperture)
                out.append(Message(kind: .warning, text:
                    "At EV \(LightLadderFormat.ev(bottom)) this box cannot open up far enough — frames run \(String(format: "%.1f", stops)) stops under from EV \(LightLadderFormat.ev(okEV)) down. \(reachHint(rung, over: false, format: format, box: box, atEV: bottom))"))
            }
        }
        return out
    }

    private static func reachHint(
        _ rung: Rung, over: Bool,
        format: HolyGrailRampEngine.HardwareLimits,
        box: HolyGrailRampEngine.HardwareLimits,
        atEV ev: Double
    ) -> String {
        let wanted = HolyGrailRampEngine.requiredGain(sceneEV100: ev, aperture: box.aperture)
        switch (rung.shutter, rung.iso) {
        case (.value(let pin), _):
            let iso = 100 * wanted / max(pin, 1e-6)
            return over
                ? "A \(LightLadderFormat.seconds(pin)) shutter here needs ISO \(Int(iso.rounded())), below this lens's \(Int(format.minISO.rounded()))."
                : "A \(LightLadderFormat.seconds(pin)) shutter here needs ISO \(Int(iso.rounded())), above this lens's \(Int(format.maxISO.rounded()))."
        case (_, .value(let iso)):
            let shutter = wanted * 100 / Double(max(iso, 1))
            return over
                ? "ISO \(Int(iso.rounded())) here needs a \(LightLadderFormat.seconds(shutter)) shutter, shorter than this format allows."
                : "ISO \(Int(iso.rounded())) here needs a \(LightLadderFormat.seconds(shutter)) shutter, longer than the \(LightLadderFormat.seconds(box.maxShutter.seconds)) the window allows."
        case (_, .min):
            return over ? "" : "ISO min holds the sensor at \(Int(format.minISO.rounded())); let ISO go auto here."
        case (_, .max):
            return over ? "ISO max holds the sensor at \(Int(format.maxISO.rounded())); let ISO go auto here." : ""
        default:
            return over ? "Raise the ISO floor or shorten the cap." : "Raise the shutter cap or the interval."
        }
    }
}

// MARK: - Formatting

/// The few numbers a ladder prints, formatted one way everywhere.
public enum LightLadderFormat {
    /// "13" · "4.5" · "−2"
    public static func ev(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return text.replacingOccurrences(of: "-", with: "−")
    }

    /// "3 s" · "0.5 s" · "1/8 s" · "1/2000 s"
    public static func seconds(_ value: Double) -> String {
        guard value > 0, value.isFinite else { return "0 s" }
        if value >= 1 {
            return value == value.rounded() ? "\(Int(value)) s" : String(format: "%.1f s", value)
        }
        let inverse = 1 / value
        let nearest = inverse.rounded()
        if nearest >= 2, abs(inverse - nearest) / nearest < 0.02 {
            return "1/\(Int(nearest)) s"
        }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        return text + " s"
    }
}

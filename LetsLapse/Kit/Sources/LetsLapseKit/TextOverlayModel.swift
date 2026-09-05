import Foundation

// The text overlay model — the copy, its runs, and how a layer reveals,
// leaves and follows another. Pure values with no UI or scene dependency,
// kept in the Kit so `swift test` covers the string and offset arithmetic
// the editor's fields lean on (a select-all-and-type over the placeholder
// trapped in the field on 2026-09-04). `SceneOverlay` in the app wraps
// these; `OverlaySequencing` below is what its document resolves with.

/// One styled stretch of a layer's copy. nil fields inherit the layer's
/// own style (`TextOverlayContent`), so a run that says nothing is plain
/// text and only the word someone tapped a swatch on carries a colour.
public struct TextRun: Codable, Equatable, Sendable {
    public var text: String
    /// `#RRGGBB`, or nil to inherit the layer colour.
    public var colorHex: String?
    public var isBold: Bool?
    public var isUnderlined: Bool?

    private enum CodingKeys: String, CodingKey {
        case text = "t", colorHex = "c", isBold = "b", isUnderlined = "u"
    }

    public init(text: String, colorHex: String? = nil, isBold: Bool? = nil, isUnderlined: Bool? = nil) {
        self.text = text
        self.colorHex = colorHex
        self.isBold = isBold
        self.isUnderlined = isUnderlined
    }

    /// The style alone — what has to match for two neighbours to merge.
    public var styleKey: String {
        "\(colorHex ?? "-")|\(isBold.map { $0 ? "b" : "r" } ?? "-")|\(isUnderlined.map { $0 ? "u" : "n" } ?? "-")"
    }

    public var hasOwnStyle: Bool { colorHex != nil || isBold != nil || isUnderlined != nil }
}

/// The overlay's text and how it is set. Typography arrived with the Text
/// Features design; the spike's single bold-white-system-font rule is now
/// this struct's default values, so a spike-era sidecar decodes to exactly
/// what it used to render. The copy itself is a list of `TextRun`s since the
/// reveals build (2026-09-03): a word inside a layer can carry its own
/// colour, weight or underline. `string` is the runs joined.
public struct TextOverlayContent: Codable, Equatable, Sendable {
    /// The copy, in order. Never empty — an empty layer is one empty run.
    public var runs: [TextRun]
    /// PostScript-ish family name, or nil for the system face. Resolved at
    /// raster time so a project that names a font the device lacks falls
    /// back rather than failing.
    public var fontFamily: String?
    public var isBold: Bool = true
    public var isItalic: Bool = false
    public var isUnderlined: Bool = false
    /// `#RRGGBB`. A string because it has to survive a JSON round trip on
    /// three platforms without a color space sneaking in.
    public var colorHex: String = "#FFFFFF"
    public var alignment: OverlayTextAlignment = .center
    /// Extra letter spacing, in points at the resolved font size ÷ 100 —
    /// i.e. a fraction of the em, so it scales with the type.
    public var kerning: Double = 0
    /// Multiple of the font size.
    public var lineHeight: Double = 1.05
    /// Extra space between paragraphs, as a multiple of the font size.
    public var paragraphSpacing: Double = 0

    private enum CodingKeys: String, CodingKey {
        case string = "s", runs = "r", fontFamily = "f", isBold = "b", isItalic = "i",
             isUnderlined = "u", colorHex = "cl", alignment = "al",
             kerning = "k", lineHeight = "lh", paragraphSpacing = "ps"
    }

    public init(string: String) {
        self.runs = [TextRun(text: string)]
    }

    public init(runs: [TextRun]) {
        self.runs = runs.isEmpty ? [TextRun(text: "")] : runs
    }

    /// Same contract as `SceneOverlay.init(from:)`: a spike-era sidecar holds
    /// only `s`, and must decode to the spike's own look; a Text Features
    /// sidecar holds a plain `s` and must decode as one run.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let decoded = try c.decodeIfPresent([TextRun].self, forKey: .runs), !decoded.isEmpty {
            runs = decoded
        } else {
            runs = [TextRun(text: try c.decodeIfPresent(String.self, forKey: .string) ?? "")]
        }
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

    /// Writes the joined string under the old key as well as the runs, so a
    /// build from before the runs existed still reads the copy (plain).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(string, forKey: .string)
        // Only worth the bytes when a run carries a style of its own.
        if runs.count > 1 || runs.contains(where: \.hasOwnStyle) {
            try c.encode(runs, forKey: .runs)
        }
        try c.encodeIfPresent(fontFamily, forKey: .fontFamily)
        try c.encode(isBold, forKey: .isBold)
        try c.encode(isItalic, forKey: .isItalic)
        try c.encode(isUnderlined, forKey: .isUnderlined)
        try c.encode(colorHex, forKey: .colorHex)
        try c.encode(alignment, forKey: .alignment)
        try c.encode(kerning, forKey: .kerning)
        try c.encode(lineHeight, forKey: .lineHeight)
        try c.encode(paragraphSpacing, forKey: .paragraphSpacing)
    }

    // MARK: Copy

    /// The runs joined. Setting it re-flows the runs around the edit rather
    /// than flattening them: the changed stretch is found by common prefix
    /// and suffix, the deleted characters come out of whichever runs held
    /// them, and typed text takes the style of the run it lands at the end
    /// of — so a bold word stays bold while the sentence around it is
    /// rewritten.
    public var string: String {
        get { runs.map(\.text).joined() }
        set { replaceDifference(with: newValue) }
    }

    /// The layer's copy as grapheme clusters, which is what every offset in
    /// this type counts in.
    public var characterCount: Int { runs.reduce(0) { $0 + $1.text.count } }

    private mutating func replaceDifference(with new: String) {
        let old = string
        guard new != old else { return }
        let oldChars = Array(old), newChars = Array(new)
        var prefix = 0
        while prefix < oldChars.count, prefix < newChars.count,
              oldChars[prefix] == newChars[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < oldChars.count - prefix, suffix < newChars.count - prefix,
              oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
            suffix += 1
        }
        replace(prefix..<(oldChars.count - suffix),
                with: String(newChars[prefix..<(newChars.count - suffix)]))
    }

    /// Replaces the characters in `range` (grapheme offsets into the joined
    /// string) with `text`. The inserted text inherits the style of the run
    /// that ends where it goes in — the run to the left — or the first run
    /// when it goes in at the very start.
    public mutating func replace(_ range: Range<Int>, with text: String) {
        // Remove first.
        if !range.isEmpty {
            var offset = 0
            for index in runs.indices {
                let length = runs[index].text.count
                let lo = max(range.lowerBound, offset)
                let hi = min(range.upperBound, offset + length)
                if lo < hi {
                    var chars = Array(runs[index].text)
                    chars.removeSubrange((lo - offset)..<(hi - offset))
                    runs[index].text = String(chars)
                }
                offset += length
            }
        }
        // Then insert, into the run whose end the insertion point sits at.
        if !text.isEmpty {
            let at = range.lowerBound
            var offset = 0
            var placed = false
            for index in runs.indices {
                let length = runs[index].text.count
                if at <= offset + length, (at > offset || index == 0 || at == 0) {
                    var chars = Array(runs[index].text)
                    chars.insert(contentsOf: Array(text), at: min(max(at - offset, 0), chars.count))
                    runs[index].text = String(chars)
                    placed = true
                    break
                }
                offset += length
            }
            if !placed {
                // Past the end (or every run emptied): extend the last run.
                if runs.isEmpty { runs = [TextRun(text: text)] } else { runs[runs.count - 1].text += text }
            }
        }
        normalizeRuns()
    }

    /// Drops empty runs and merges neighbours that share a style, so the
    /// list stays the minimal description of the copy.
    public mutating func normalizeRuns() {
        var merged: [TextRun] = []
        for run in runs where !run.text.isEmpty {
            if let last = merged.last, last.styleKey == run.styleKey {
                merged[merged.count - 1].text += run.text
            } else {
                merged.append(run)
            }
        }
        if merged.isEmpty {
            // Keep one (empty) run so the layer's own style survives.
            merged = [TextRun(text: "", colorHex: nil, isBold: nil, isUnderlined: nil)]
        }
        runs = merged
    }

    /// Applies `edit` to exactly the characters in `range` (grapheme offsets),
    /// splitting runs at its edges. Used by the run toolbar.
    public mutating func applyStyle(in range: Range<Int>, _ edit: (inout TextRun) -> Void) {
        guard !range.isEmpty else { return }
        var out: [TextRun] = []
        var offset = 0
        for run in runs {
            let length = run.text.count
            let lo = max(range.lowerBound, offset)
            let hi = min(range.upperBound, offset + length)
            if lo >= hi {
                out.append(run)
            } else {
                let chars = Array(run.text)
                let a = lo - offset, b = hi - offset
                if a > 0 {
                    var head = run; head.text = String(chars[0..<a]); out.append(head)
                }
                var middle = run; middle.text = String(chars[a..<b]); edit(&middle); out.append(middle)
                if b < chars.count {
                    var tail = run; tail.text = String(chars[b..<chars.count]); out.append(tail)
                }
            }
            offset += length
        }
        runs = out
        normalizeRuns()
    }

    /// The run under a character offset, for the toolbar's state.
    public func run(at offset: Int) -> TextRun? {
        var cursor = 0
        for run in runs {
            let next = cursor + run.text.count
            if offset < next || (offset == next && run.text.count > 0 && next == characterCount) { return run }
            cursor = next
        }
        return runs.last
    }

    /// Resolved style for one run: its own value, else the layer's.
    public func resolvedColorHex(_ run: TextRun) -> String { run.colorHex ?? colorHex }
    public func resolvedBold(_ run: TextRun) -> Bool { run.isBold ?? isBold }
    public func resolvedUnderline(_ run: TextRun) -> Bool { run.isUnderlined ?? isUnderlined }

    /// The word around `offset` — the whitespace-delimited stretch it sits
    /// in or at the end of — or nil when the offset is on whitespace.
    public func wordRange(at offset: Int) -> Range<Int>? {
        let chars = Array(string)
        guard !chars.isEmpty else { return nil }
        func isSpace(_ c: Character) -> Bool { c.isWhitespace || c.isNewline }
        var index = min(max(offset, 0), chars.count)
        // A caret at the end of a word counts as in the word.
        if index == chars.count || isSpace(chars[index]) {
            guard index > 0, !isSpace(chars[index - 1]) else { return nil }
            index -= 1
        }
        var start = index, end = index
        while start > 0, !isSpace(chars[start - 1]) { start -= 1 }
        while end + 1 < chars.count, !isSpace(chars[end + 1]) { end += 1 }
        return start..<(end + 1)
    }

    // MARK: Run styling

    /// Toggles bold on `range`, or on the whole layer when nil. Explicit
    /// values that merely repeat the layer's own are stored as nil, so the
    /// runs stay the minimal description of the copy.
    public mutating func toggleBold(in range: Range<Int>?) {
        guard let range, !range.isEmpty else { isBold.toggle(); return }
        let current = run(at: range.lowerBound).map(resolvedBold) ?? isBold
        let layerBold = isBold
        let next = !current
        applyStyle(in: range) { $0.isBold = next == layerBold ? nil : next }
    }

    public mutating func toggleUnderline(in range: Range<Int>?) {
        guard let range, !range.isEmpty else { isUnderlined.toggle(); return }
        let current = run(at: range.lowerBound).map(resolvedUnderline) ?? isUnderlined
        let layerUnderline = isUnderlined
        let next = !current
        applyStyle(in: range) { $0.isUnderlined = next == layerUnderline ? nil : next }
    }

    /// A swatch with a run selected recolours the run; with none it
    /// recolours the whole layer — every run's own colour is cleared so
    /// the layer really is that colour again.
    public mutating func setColor(_ hex: String, in range: Range<Int>?) {
        if let range, !range.isEmpty {
            let layerColor = colorHex
            applyStyle(in: range) {
                $0.colorHex = hex.caseInsensitiveCompare(layerColor) == .orderedSame ? nil : hex
            }
        } else {
            colorHex = hex
            for index in runs.indices { runs[index].colorHex = nil }
            normalizeRuns()
        }
    }

    // MARK: Reveal units

    /// Which reveal unit every grapheme cluster belongs to, and how many
    /// units there are. Characters are their own units; a word is a run of
    /// non-whitespace with the whitespace after it (spaces travel with the
    /// preceding word, so a gap never animates on its own); the element is
    /// the whole layer.
    public func unitIndices(for unit: OverlayReveal.Unit) -> (ofCluster: [Int], count: Int) {
        let chars = Array(string)
        switch unit {
        case .element:
            return (Array(repeating: 0, count: chars.count), chars.isEmpty ? 0 : 1)
        case .character:
            return (Array(0..<chars.count), chars.count)
        case .word:
            var indices: [Int] = []
            indices.reserveCapacity(chars.count)
            var current = -1
            var previousWasSpace = false
            // A unit opens on the first cluster of any kind, and a new one
            // on ink that follows whitespace — once the current unit has
            // ink of its own. Leading whitespace therefore rides with the
            // first word rather than revealing as a blank on its own.
            var unitHasInk = false
            for c in chars {
                let space = c.isWhitespace || c.isNewline
                if current < 0 {
                    current = 0
                } else if !space, previousWasSpace, unitHasInk {
                    current += 1
                    unitHasInk = false
                }
                if !space { unitHasInk = true }
                indices.append(current)
                previousWasSpace = space
            }
            return (indices, chars.isEmpty ? 0 : current + 1)
        }
    }

    public func unitCount(for unit: OverlayReveal.Unit) -> Int {
        unitIndices(for: unit).count
    }
}

/// Horizontal alignment inside the layer's own layout box.
public enum OverlayTextAlignment: String, Codable, Equatable, Sendable, CaseIterable {
    case left, center, right
}

/// One reveal — in or out — of a layer: which pieces of the copy move, how,
/// and across which span of the shoot.
public struct OverlayReveal: Codable, Equatable, Sendable {
    /// What animates as one piece.
    public enum Unit: String, Codable, Sendable, CaseIterable {
        case element, word, character

        public var displayName: String {
            switch self {
            case .element: return "Element"
            case .word: return "Word"
            case .character: return "Character"
            }
        }
    }

    /// How a unit arrives (or, read backwards, leaves).
    public enum Style: String, Codable, Sendable, CaseIterable {
        case fade, slide, bounce, pop, blur, wipe

        public var displayName: String { rawValue.capitalized }

        /// The styles a reveal OUT offers: no bounce out (it reads as a
        /// stumble), and typewriter never existed as a style — it is
        /// Character · Fade with the stagger at zero.
        public static let exitStyles: [Style] = [.fade, .slide, .pop, .blur, .wipe]

        /// Bounce and Pop take raw progress into ease-out-back; everything
        /// else takes the house cubic.
        public var usesBackEase: Bool { self == .bounce || self == .pop }
    }

    public var unit: Unit = .element
    /// nil = hard cut: the text is simply there from `start` (or gone after
    /// `end`, for an exit).
    public var style: Style? = .fade
    /// Where a sliding unit arrives from (leaves toward, for an exit). Slide
    /// only.
    public var direction: OverlayAnimation.Direction = .bottom
    /// The span, SOURCE position 0…1 — the grade strip's own axis, immune
    /// to the speed layer for exactly the reason `GradeKeyframe.position` is.
    public var start: Double
    public var end: Double
    /// 0 = one unit at a time, 1 = every unit together. Ignored for
    /// `.element`, which is one unit.
    public var overlap: Double = 0.6

    private enum CodingKeys: String, CodingKey {
        case unit = "u", style = "st", direction = "d", start = "a", end = "b", overlap = "o"
    }

    public init(unit: Unit = .element, style: Style? = .fade,
         direction: OverlayAnimation.Direction = .bottom,
         start: Double, end: Double, overlap: Double = 0.6) {
        self.unit = unit
        self.style = style
        self.direction = direction
        self.start = start
        self.end = end
        self.overlap = overlap
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unit = try c.decodeIfPresent(Unit.self, forKey: .unit) ?? .element
        // An absent key is a cut; the key present with null is a cut too.
        style = try c.decodeIfPresent(Style.self, forKey: .style)
        direction = try c.decodeIfPresent(OverlayAnimation.Direction.self, forKey: .direction) ?? .bottom
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? start
        overlap = try c.decodeIfPresent(Double.self, forKey: .overlap) ?? 0.6
    }

    public var duration: Double { max(end - start, 0) }

    /// The smallest band the editor lets a reveal have, as a fraction of
    /// the shoot.
    public static let minimumDuration: Double = 0.02

    /// Raw per-unit progress at `position`, one value per unit. Easing is
    /// applied at raster time, not here.
    ///
    /// Unit *i* owns the sub-interval `[stride·i, stride·i + width]` of the
    /// band, sized so unit 0 starts at the band's start and the last unit
    /// completes exactly at its end — which is what makes the raster at
    /// `position ≥ end` byte-identical to a no-animation raster: the "final
    /// layout is always the end state" guarantee, structurally.
    public func phases(at position: Double, unitCount: Int) -> [Double] {
        guard unitCount > 0 else { return [] }
        let band = max(end - start, 0.0001)
        let t = (position - start) / band
        let n = Double(unitCount)
        let overlap = unit == .element ? 1 : min(max(overlap, 0), 1)
        let width = 1.0 / (1.0 + (n - 1) * (1.0 - overlap))
        let stride = unitCount > 1 ? (1.0 - width) / (n - 1) : 0
        return (0..<unitCount).map { i in
            min(max((t - stride * Double(i)) / width, 0), 1)
        }
    }
}

/// "Starts after another layer": this layer's reveal opens `gap` after its
/// parent's reveal ends, and — unless it holds its own position — travels
/// with the parent on the picture too.
public struct OverlayFollow: Codable, Equatable, Sendable {
    public var layerID: UUID
    /// Source fraction, measured from `parent.reveal.end`; negative overlaps
    /// the parent's reveal.
    public var gap: Double = 0
    /// On: only the TIMING follows. The layer keeps the spot it was put in
    /// when its parent is dragged across the picture — which is what a
    /// pinned byline or a URL in a corner needs, since it belongs to the
    /// story's clock but not to the headline's place on the frame.
    ///
    /// It lives on the association rather than the layer because it has no
    /// meaning without one: a layer that follows nothing already holds its
    /// own position. Removing the association therefore forgets it, which is
    /// the same thing the menu says it does.
    public var independentPosition: Bool = false

    private enum CodingKeys: String, CodingKey {
        case layerID = "p", gap = "g", independentPosition = "i"
    }

    public init(layerID: UUID, gap: Double = 0, independentPosition: Bool = false) {
        self.layerID = layerID
        self.gap = gap
        self.independentPosition = independentPosition
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layerID = try c.decode(UUID.self, forKey: .layerID)
        gap = try c.decodeIfPresent(Double.self, forKey: .gap) ?? 0
        independentPosition = try c.decodeIfPresent(
            Bool.self, forKey: .independentPosition) ?? false
    }
}

/// How an overlay arrives at its resolved final state, and how it leaves.
/// The animation answers "how does it get there", never "where is it" —
/// the final layout is the user's, set by dragging, and every reveal ends
/// exactly on it.
public struct OverlayAnimation: Codable, Equatable, Sendable {
    /// Where a sliding unit arrives FROM.
    public enum Direction: String, Codable, Sendable, CaseIterable {
        case top, bottom, left, right
        public var displayName: String { rawValue.capitalized }
    }

    /// The reveal in.
    public var reveal: OverlayReveal
    /// The reveal out; nil = the text holds to the end of the shoot.
    public var exit: OverlayReveal?
    /// Sequencing: nil = starts at its own time.
    public var follows: OverlayFollow?

    private enum CodingKeys: String, CodingKey {
        case reveal = "in", exit = "out", follows = "f"
        // The single-band struct this replaced (2026-08-31 … 2026-09-03).
        case legacyStyle = "st", legacyDirection = "d", legacyStart = "a",
             legacyEnd = "b", legacyOverlap = "o"
    }

    public init(reveal: OverlayReveal, exit: OverlayReveal? = nil, follows: OverlayFollow? = nil) {
        self.reveal = reveal
        self.exit = exit
        self.follows = follows
    }

    /// Reads both shapes: the reveal/exit/follows form, and the spike's
    /// single character band (`st`/`d`/`a`/`b`/`o`), which becomes a
    /// Character-unit reveal in of the same style and span.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let reveal = try c.decodeIfPresent(OverlayReveal.self, forKey: .reveal) {
            self.reveal = reveal
            exit = try c.decodeIfPresent(OverlayReveal.self, forKey: .exit)
            follows = try c.decodeIfPresent(OverlayFollow.self, forKey: .follows)
            return
        }
        let legacy = try c.decodeIfPresent(String.self, forKey: .legacyStyle)
        let start = try c.decodeIfPresent(Double.self, forKey: .legacyStart) ?? 0
        let end = try c.decodeIfPresent(Double.self, forKey: .legacyEnd) ?? 0.25
        reveal = OverlayReveal(
            unit: .character,
            style: legacy == "characterSlide" ? .slide : .fade,
            direction: try c.decodeIfPresent(Direction.self, forKey: .legacyDirection) ?? .bottom,
            start: start, end: end,
            overlap: try c.decodeIfPresent(Double.self, forKey: .legacyOverlap) ?? 0.6)
        exit = nil
        follows = nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(reveal, forKey: .reveal)
        try c.encodeIfPresent(exit, forKey: .exit)
        try c.encodeIfPresent(follows, forKey: .follows)
    }

    /// What a layer with no animation means: on from the first frame, no
    /// exit. The band is empty — a cut has no duration — and the panel seeds
    /// a real one at the playhead the moment a style is chosen.
    public static let alwaysOn = OverlayAnimation(
        reveal: OverlayReveal(unit: .element, style: nil, start: 0, end: 0))

    /// The band Add Text opens with: the copy simply appears at the
    /// playhead. Plain text arrives with NO reveal style — a hard cut —
    /// because someone typing a line is placing it, not choreographing it,
    /// and a style chosen for them is a style they have to notice and
    /// undo. Crafted lines are the opposite case and always arrive
    /// animated; the band is kept here either way so choosing a style is a
    /// tap rather than a re-timing.
    public static func seeded(at playhead: Double) -> OverlayAnimation {
        let start = min(max(playhead, 0), 0.9)
        return OverlayAnimation(
            reveal: OverlayReveal(unit: .element, style: nil, start: start, end: min(start + 0.06, 1)))
    }

    /// The exit the toggle seeds when there was none: a short fade a while
    /// after the reveal finishes.
    public static func seededExit(after reveal: OverlayReveal) -> OverlayReveal {
        let start = min(0.95, reveal.end + 0.3)
        return OverlayReveal(unit: .element, style: .fade, start: start, end: min(start + 0.06, 1))
    }

    /// The layer's whole span on screen — reveal start to exit end (or the
    /// end of the shoot).
    public var visibleSpan: ClosedRange<Double> {
        let from = min(max(reveal.start, 0), 1)
        return from...max(from, min(exit?.end ?? 1, 1))
    }

    public func isOnScreen(at position: Double) -> Bool {
        visibleSpan.contains(position)
    }

    /// What the render should draw at `position`.
    public enum Moment: Equatable {
        /// Before the reveal, or after the exit: nothing.
        case hidden
        /// Mid reveal in: per-unit raw progress.
        case revealing(OverlayReveal, [Double])
        /// Between the reveal and the exit: the resting layout, exactly.
        case settled
        /// Mid reveal out: per-unit raw progress (1 = gone).
        case exiting(OverlayReveal, [Double])
    }

    /// Resolves the moment for a copy of `content`. Unit counts come from
    /// the copy, so the same animation reads differently on a one-word and a
    /// twelve-word layer.
    public func moment(at position: Double, content: TextOverlayContent) -> Moment {
        if position < reveal.start { return .hidden }
        if let exit {
            if position > exit.end { return .hidden }
            if position >= exit.start {
                guard exit.style != nil else { return .settled }  // cut: there until exit.end
                let phases = exit.phases(at: position, unitCount: content.unitCount(for: exit.unit))
                if phases.allSatisfy({ $0 >= 1 }) { return .hidden }
                return .exiting(exit, phases)
            }
        }
        guard reveal.style != nil, position < reveal.end else { return .settled }
        let phases = reveal.phases(at: position, unitCount: content.unitCount(for: reveal.unit))
        if phases.allSatisfy({ $0 >= 1 }) { return .settled }
        if phases.allSatisfy({ $0 <= 0 }) { return .hidden }
        return .revealing(reveal, phases)
    }

    // MARK: Editing helpers

    /// Moves the whole layer in time by `delta`, clamped so the reveal stays
    /// inside the shoot; the exit rides along and never starts before the
    /// reveal ends.
    public mutating func shift(by delta: Double) {
        let duration = reveal.duration
        let start = min(max(reveal.start + delta, 0), 1 - duration)
        let applied = start - reveal.start
        reveal.start = start
        reveal.end = min(start + duration, 1)
        if var exit {
            exit.start = min(max(exit.start + applied, reveal.end), 1)
            exit.end = min(max(exit.end + applied, exit.start + 0.01), 1)
            self.exit = exit
        }
    }

    /// Re-seats this layer after its parent: the reveal opens `gap` after
    /// the parent's reveal ends, keeps its own duration, and the exit shifts
    /// by the same amount.
    public mutating func seat(after parent: OverlayReveal, gap: Double) {
        let start = min(max(parent.end + gap, 0), 0.98)
        shift(by: start - reveal.start)
    }
}


/// Sequencing over a list of layers, front-to-back: "starts after another
/// layer" resolved as absolute times. Works on the animations alone so the
/// document type that owns the layers stays in the app.
public enum OverlaySequencing {
    /// One layer as the sequencer sees it.
    public struct Layer: Equatable, Sendable {
        public var id: UUID
        public var animation: OverlayAnimation?
        public init(id: UUID, animation: OverlayAnimation?) {
            self.id = id
            self.animation = animation
        }
    }

    /// The layers `id` may NOT follow: itself and everything already
    /// following it, directly or down a chain — a parent cannot follow one of
    /// its descendants.
    public static func descendants(of id: UUID, in layers: [Layer]) -> Set<UUID> {
        var out: Set<UUID> = []
        var frontier: [UUID] = [id]
        while let next = frontier.popLast() {
            for layer in layers where layer.animation?.follows?.layerID == next && !out.contains(layer.id) {
                out.insert(layer.id)
                frontier.append(layer.id)
            }
        }
        return out
    }

    /// The layers that travel with `id` when it is DRAGGED across the
    /// picture: everything following it, down the chain, minus any layer
    /// holding an independent position — and minus that layer's own
    /// followers, which are pinned to it rather than to the layer being
    /// moved. A subtree that opts out opts its children out with it.
    ///
    /// Timing is unaffected: an independent layer still re-seats after its
    /// parent's reveal, which is the whole point of the distinction.
    public static func movers(of id: UUID, in layers: [Layer]) -> [UUID] {
        var out: [UUID] = []
        var frontier: [UUID] = [id]
        while let next = frontier.popLast() {
            for layer in layers {
                guard let follow = layer.animation?.follows, follow.layerID == next,
                      !follow.independentPosition, !out.contains(layer.id), layer.id != id
                else { continue }
                out.append(layer.id)
                frontier.append(layer.id)
            }
        }
        return out
    }

    /// Re-seats every linked layer after its parent, as many passes as there
    /// are layers so a chain resolves whatever order the list is in. Links to
    /// a layer that is gone (or to itself, or round a cycle) are dropped and
    /// the layer keeps its absolute times.
    public static func resolve(_ layers: inout [Layer]) {
        let ids = Set(layers.map(\.id))
        for index in layers.indices {
            guard let follow = layers[index].animation?.follows else { continue }
            if follow.layerID == layers[index].id || !ids.contains(follow.layerID) {
                layers[index].animation?.follows = nil
            }
        }
        // Cycles: walk each layer's parent chain; a chain that comes back to
        // its start is cut at the layer we started from.
        for index in layers.indices {
            let origin = layers[index].id
            var seen: Set<UUID> = [origin]
            var cursor = layers[index].animation?.follows?.layerID
            while let next = cursor {
                if next == origin || seen.contains(next) {
                    layers[index].animation?.follows = nil
                    break
                }
                seen.insert(next)
                cursor = layers.first { $0.id == next }?.animation?.follows?.layerID
            }
        }
        guard layers.contains(where: { $0.animation?.follows != nil }) else { return }
        for _ in 0..<max(1, layers.count) {
            for index in layers.indices {
                guard var animation = layers[index].animation, let follow = animation.follows,
                      let parent = layers.first(where: { $0.id == follow.layerID })
                else { continue }
                animation.seat(after: (parent.animation ?? .alwaysOn).reveal, gap: follow.gap)
                layers[index].animation = animation
            }
        }
    }

    /// Drops `id` and unlinks its children, which keep their (resolved) times.
    public static func removing(_ id: UUID, from layers: inout [Layer]) {
        layers.removeAll { $0.id == id }
        for index in layers.indices where layers[index].animation?.follows?.layerID == id {
            layers[index].animation?.follows = nil
        }
    }
}

extension TextOverlayContent {
    /// A selection's character-offset range in `text`, for a selection whose
    /// indices may have been made in an EARLIER value of the same field:
    /// SwiftUI hands the field's selection back as `String.Index`es, and a
    /// select-all-and-type leaves them pointing past the shorter text that
    /// replaced it. Both ends are clamped to the text before anything is
    /// measured, so nothing here can trap. An empty result means a caret.
    public static func characterRange(of range: Range<String.Index>, in text: String) -> Range<Int> {
        let end = text.endIndex
        let lowerIndex = range.lowerBound < end ? range.lowerBound : end
        let upperIndex = range.upperBound < end ? range.upperBound : end
        let lower = text.distance(from: text.startIndex, to: lowerIndex)
        let upper = text.distance(from: text.startIndex, to: upperIndex)
        return lower..<max(lower, upper)
    }

    /// Where the caret sits after one edit turned `old` into `new`: at the
    /// end of the inserted text, which is the end of the changed stretch —
    /// `new` minus the suffix the edit left untouched. A grapheme offset
    /// into `new`, always within it.
    public static func caretAfterEdit(from old: String, to new: String) -> Int {
        let oldChars = Array(old), newChars = Array(new)
        var prefix = 0
        while prefix < oldChars.count, prefix < newChars.count, oldChars[prefix] == newChars[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldChars.count - prefix, suffix < newChars.count - prefix,
              oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
            suffix += 1
        }
        return newChars.count - suffix
    }

    /// The toolbar's target for a selection: the range when it has length,
    /// else the word under the caret, else nil (whole layer).
    public static func styleTarget(for range: Range<String.Index>, in text: String) -> Range<Int>? {
        let offsets = characterRange(of: range, in: text)
        if !offsets.isEmpty { return offsets }
        return TextOverlayContent(string: text).wordRange(at: offsets.lowerBound)
    }
}

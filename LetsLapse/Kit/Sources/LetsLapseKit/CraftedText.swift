import Foundation

// Crafted text — the arithmetic behind "Add Crafted Text", kept out of the
// view so it can be tested without a model, a window or a font.
//
// The on-device model's job is small and well bounded: turn what someone
// wants to say into 1–5 PARTS, each with its copy, the words worth
// emphasising, and a priority (1 = the payoff line). Everything after that
// is typography, and typography is arithmetic: the priority picks a size,
// weight, colour and reveal; the copy is fitted so the longest line stays
// inside the frame; the lines stack, centred, and each one follows the one
// above in time. That is what this file does, and why the same layout
// arrives whether the parts came from Gemma or from the fallback splitter
// below.

/// One line the model (or the splitter) proposes.
public struct CraftedTextPart: Equatable, Sendable {
    /// The line itself.
    public var copy: String
    /// Stretches of `copy` worth setting apart — matched case-insensitively
    /// and in order. A stretch the copy does not contain is ignored rather
    /// than forced, so a model that paraphrases cannot corrupt the runs.
    public var emphasis: [String]
    /// 1 = the payoff line (largest, in amber); 5 = the quietest. Clamped.
    public var priority: Int

    public init(copy: String, emphasis: [String] = [], priority: Int = 2) {
        self.copy = copy
        self.emphasis = emphasis
        self.priority = priority
    }
}

/// Which kind of face a line asks for. The design mocked these with three
/// Google faces (Chango, Amatic SC, Quicksand) standing in for *imported*
/// fonts — its own README says they are not to be bundled — so the role is
/// what travels and the app resolves it against the fonts the project
/// actually has, falling back to the system face.
public enum CraftedTextFontRole: String, Equatable, Sendable, CaseIterable {
    /// Heavy, wide, poster-weight — the payoff line.
    case display
    /// A condensed hand, for the lines around it.
    case hand
    /// A quiet rounded sans, for the small print.
    case sans
}

/// The designer defaults one priority carries.
public struct CraftedTextStyle: Equatable, Sendable {
    /// Fraction of the frame's LONG edge, before the width fit.
    public var size: Double
    public var role: CraftedTextFontRole
    public var isBold: Bool
    /// The line's colour, `#RRGGBB`.
    public var colorHex: String
    /// The colour its emphasised runs take.
    public var emphasisColorHex: String
    public var unit: OverlayReveal.Unit
    public var style: OverlayReveal.Style

    /// The table straight out of the design: 1 is the payoff line, amber and
    /// popping; 2–3 are the story around it; 4–5 are the quiet lines.
    public static func forPriority(_ priority: Int) -> CraftedTextStyle {
        switch min(max(priority, 1), 5) {
        case 1:
            return .init(size: 0.13, role: .display, isBold: false,
                         colorHex: "#FFB340", emphasisColorHex: "#FFFFFF",
                         unit: .element, style: .pop)
        case 2:
            return .init(size: 0.075, role: .hand, isBold: true,
                         colorHex: "#FFFFFF", emphasisColorHex: "#F3E37C",
                         unit: .word, style: .slide)
        case 3:
            return .init(size: 0.06, role: .hand, isBold: true,
                         colorHex: "#FFFFFF", emphasisColorHex: "#F3E37C",
                         unit: .word, style: .slide)
        case 4:
            return .init(size: 0.05, role: .sans, isBold: true,
                         colorHex: "#FFFFFF", emphasisColorHex: "#F3E37C",
                         unit: .element, style: .fade)
        default:
            return .init(size: 0.045, role: .sans, isBold: true,
                         colorHex: "#FFFFFF", emphasisColorHex: "#F3E37C",
                         unit: .element, style: .fade)
        }
    }
}

public enum CraftedTextLayout {
    /// How wide a crafted line is allowed to get, as a fraction of the frame
    /// width. The rest is breathing room.
    public static let widthLimit: Double = 0.84
    /// Line box as a multiple of the type size.
    public static let lineHeightFactor: Double = 1.3
    /// Where the stack is centred vertically — a shade below the middle,
    /// which is where a title sits better than dead centre.
    public static let stackCenterY: Double = 0.56

    /// One laid-out line, ready for the app to turn into a `SceneOverlay`.
    public struct Line: Equatable, Sendable {
        public var runs: [TextRun]
        public var style: CraftedTextStyle
        /// The fitted size — `style.size` or smaller.
        public var size: Double
        public var centerX: Double
        public var centerY: Double
        /// nil for the first line; otherwise the index of the line it
        /// follows, which is always the one above it.
        public var followsIndex: Int?
    }

    /// Lays parts out as a designer would: sizes from the priority table,
    /// shrunk until the longest line fits, stacked in reading order and
    /// centred as a block.
    ///
    /// `aspect` is width ÷ height of the output frame. `measure` returns a
    /// line's width in EMs at the given style (the app measures with Core
    /// Text; the tests pass a simple per-character stand-in), so the fit is
    /// honest about the face that will actually draw it.
    public static func lines(
        for parts: [CraftedTextPart],
        aspect: Double,
        measure: (String, CraftedTextStyle) -> Double
    ) -> [Line] {
        let parts = Array(parts.prefix(5)).filter { !$0.copy.trimmed.isEmpty }
        guard !parts.isEmpty else { return [] }

        // 1. The priority's size, capped so the line fits the frame's width.
        //    `size` is a long-edge fraction, so on a landscape frame it is
        //    already a width fraction and on a portrait one it is not.
        let longEdgeOverWidth = aspect >= 1 ? 1.0 : 1.0 / aspect
        var styles = parts.map { CraftedTextStyle.forPriority($0.priority) }
        for index in parts.indices {
            let ems = max(measure(parts[index].copy, styles[index]), 0.001)
            // width(fraction of frame) = size · longEdgeOverWidth · ems
            styles[index].size = min(
                styles[index].size, widthLimit / (ems * longEdgeOverWidth))
        }

        // 2. Keep the hierarchy the priorities asked for: a more important
        //    line that the fit shrank must not end up smaller than a less
        //    important one, so the quieter line gives way instead.
        for i in parts.indices {
            for j in parts.indices where parts[i].priority < parts[j].priority {
                if styles[i].size < styles[j].size {
                    styles[j].size = styles[i].size * 0.8
                }
            }
        }

        // 3. Stack them, centred as a block.
        let longEdgeOverHeight = aspect >= 1 ? aspect : 1.0
        let heights = styles.map { $0.size * longEdgeOverHeight * lineHeightFactor }
        let total = heights.reduce(0, +)
        var y = stackCenterY - total / 2
        return parts.indices.map { index in
            let centerY = y + heights[index] / 2
            y += heights[index]
            return Line(
                runs: runs(for: parts[index], style: styles[index]),
                style: styles[index],
                size: styles[index].size,
                centerX: 0.5,
                centerY: min(max(centerY, 0.02), 0.98),
                followsIndex: index == 0 ? nil : index - 1)
        }
    }

    /// How much of a line SEVERAL stretches of emphasis may cover before the
    /// highlight has eaten the line.
    ///
    /// Coverage alone cannot make this call, and the 2026-09-04 sweep of ten
    /// real briefs is what showed it: the design's own example emphasises
    /// "wash away the woes" inside "helps wash away the woes" — 86% of the
    /// line, and obviously right, because it is ONE phrase. The failure mode
    /// looks completely different: the model enumerates every word
    /// separately ("Visit", "Prague", "summer"; "Grand", "opening"), which
    /// leaves the base colour showing through the gaps and inverts the whole
    /// scheme — a payoff line drawn amber with three of four words in white
    /// reads as a white line with amber spaces.
    ///
    /// So the count is the signal. One contiguous stretch is a highlight at
    /// any length; two or more that between them cover most of the ink is an
    /// enumeration, and gets dropped. Every observed case sorts correctly:
    /// kept — "Sunset"/"Vltava" (63%), "early"/"bird" (56%), the design's
    /// 86% phrase; dropped — 3 stretches at 79–88%, 2–4 stretches at 100%.
    public static let emphasisCoverageLimit: Double = 0.75

    /// A single stretch that is essentially the entire line is not a
    /// highlight either — emphasising the only word in "Prague" says nothing,
    /// and the no-model splitter produces exactly that on a one-word brief.
    public static let emphasisWholeLineLimit: Double = 0.98

    /// The line's copy as runs: the emphasised stretches carry the style's
    /// emphasis colour and bold, everything else inherits the line.
    ///
    /// Emphasis that covers most of the line is dropped whole — see
    /// `emphasisCoverageLimit`. Dropping ALL of it rather than trimming to
    /// the limit is deliberate: which two words the model meant is not
    /// recoverable once it has said "all of them", and a plain line is a
    /// better answer than an arbitrary pair.
    public static func runs(for part: CraftedTextPart, style: CraftedTextStyle) -> [TextRun] {
        var out: [TextRun] = []
        var rest = Substring(part.copy)
        var wanted = part.emphasis.filter { !$0.trimmed.isEmpty }
        if coversTooMuch(wanted, of: part.copy) { wanted = [] }
        while !rest.isEmpty {
            // The earliest emphasis still ahead of us wins, so the runs come
            // out in the copy's order however the model listed them.
            var best: (index: Substring.Index, text: Substring)?
            for phrase in wanted {
                guard let found = rest.range(of: phrase, options: .caseInsensitive) else { continue }
                let snapped = snappedToWords(found, in: rest)
                if best == nil || snapped.lowerBound < best!.index {
                    best = (snapped.lowerBound, rest[snapped])
                }
            }
            guard let best else {
                out.append(TextRun(text: String(rest), colorHex: style.colorHex))
                break
            }
            if best.index > rest.startIndex {
                out.append(TextRun(text: String(rest[rest.startIndex..<best.index]),
                                   colorHex: style.colorHex))
            }
            out.append(TextRun(text: String(best.text),
                               colorHex: style.emphasisColorHex, isBold: true))
            rest = rest[best.text.endIndex...]
        }
        return out.isEmpty ? [TextRun(text: part.copy, colorHex: style.colorHex)] : out
    }

    /// Grows a match outward until both ends sit on a word boundary.
    ///
    /// The model emphasises the STEM often enough to matter: asked about
    /// "Time passes." it answered "pass", and a plain substring match drew
    /// `Time **pass**es.` — a word split down the middle, which no designer
    /// would ever set. Snapping to the enclosing words highlights "passes",
    /// which is plainly what was meant. A phrase that already begins and ends
    /// on boundaries is untouched, so the ordinary case pays nothing.
    static func snappedToWords(
        _ range: Range<Substring.Index>, in text: Substring
    ) -> Range<Substring.Index> {
        func isWord(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "'" || character == "’"
        }
        var lower = range.lowerBound
        while lower > text.startIndex {
            let previous = text.index(before: lower)
            guard isWord(text[previous]), isWord(text[lower]) else { break }
            lower = previous
        }
        var upper = range.upperBound
        while upper < text.endIndex, isWord(text[upper]) {
            // Only grow when the match itself ended inside a word.
            guard let last = text[..<upper].last, isWord(last) else { break }
            upper = text.index(after: upper)
        }
        return lower..<upper
    }

    /// Whether these stretches cover more of the line's ink than emphasis
    /// should. Measured on letters and digits, so spacing and punctuation
    /// cannot flatter the count, and each stretch is counted where it
    /// actually occurs — a phrase the copy does not contain covers nothing.
    static func coversTooMuch(_ emphasis: [String], of copy: String) -> Bool {
        let ink = copy.filter { $0.isLetter || $0.isNumber }.count
        guard ink > 0, !emphasis.isEmpty else { return false }
        var covered = 0
        var found = 0
        for phrase in emphasis where copy.range(of: phrase, options: .caseInsensitive) != nil {
            covered += phrase.filter { $0.isLetter || $0.isNumber }.count
            found += 1
        }
        guard found > 0 else { return false }
        let coverage = Double(covered) / Double(ink)
        if coverage >= emphasisWholeLineLimit { return true }
        return found >= 2 && coverage > emphasisCoverageLimit
    }

    /// The fallback when there is no model to ask — and the same shape its
    /// answer takes. Breaks the copy on its own punctuation, halves a single
    /// long line, keeps at most five parts, makes the LAST one the payoff
    /// (priority 1) and nominates each line's longest word for emphasis.
    public static func split(_ text: String) -> [CraftedTextPart] {
        let separators = CharacterSet(charactersIn: ",.;:!?\n—–")
        var pieces = text.components(separatedBy: separators)
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
        if pieces.count == 1 {
            let words = pieces[0].split(separator: " ").map(String.init)
            if words.count >= 6 {
                let middle = Int((Double(words.count) / 2).rounded(.up))
                pieces = [words[0..<middle].joined(separator: " "),
                          words[middle...].joined(separator: " ")]
            }
        }
        pieces = Array(pieces.prefix(5))
        return pieces.enumerated().map { index, copy in
            let longest = copy.split(separator: " ")
                .map { $0.filter(\.isLetter) }
                .max(by: { $0.count < $1.count }) ?? ""
            return CraftedTextPart(
                copy: copy,
                emphasis: longest.count > 3 ? [String(longest)] : [],
                priority: index == pieces.count - 1 ? 1 : index + 2)
        }
    }

    /// A width estimate that does not depend on a font being installed.
    ///
    /// The app measures with Core Text, in the face that will actually draw
    /// the line, because that is what "fits the frame" means at render time.
    /// A CI machine has no such guarantee — font metrics move between OS
    /// versions and an imported face may not be there at all — so the
    /// headless path (`lapse craft`) defaults to this instead: crude, but
    /// identical everywhere, which is what an assertion needs. Widths are in
    /// EMs, the same unit `measure` takes.
    public static func estimatedEmWidth(of copy: String, style: CraftedTextStyle) -> Double {
        var total = 0.0
        for character in copy {
            switch character {
            case "i", "l", "j", "t", "f", "r", "I", ".", ",", ":", ";", "'", "!", "|", " ":
                total += 0.30
            case "m", "w", "M", "W", "@":
                total += 0.85
            default:
                total += character.isUppercase ? 0.62 : 0.52
            }
        }
        return max(total * (style.isBold ? 1.06 : 1.0), 0.001)
    }

    /// The band a crafted line opens with: finished just before the
    /// playhead, so the copy is already up when the sheet closes and the
    /// editor is showing the frame it was written against.
    public static func revealBand(at playhead: Double) -> (start: Double, end: Double) {
        (min(max(playhead - 0.06, 0), 0.9), min(max(playhead - 0.01, 0.02), 1))
    }
}

extension StringProtocol {
    fileprivate var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

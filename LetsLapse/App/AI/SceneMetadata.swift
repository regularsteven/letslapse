import Foundation
import LetsLapseKit

/// What one on-device vision pass says about a capture.
///
/// `place` and `light` are echoed back from the context handed to the model rather than
/// invented by it — the model is told them and asked to use them verbatim in the title, so
/// carrying them on the result keeps a stored metadata record self-describing.
struct SceneMetadata: Codable, Equatable, Sendable {
    var title: String
    var tags: [String]
    /// Short nouns for what is actually in frame ("waterfall", "mossy rocks"). Free-form, unlike
    /// `tags` — the model names these rather than picking from a list.
    var elements: [String] = []
    var place: String?
    var light: String?

    /// The closed tag taxonomy from the scene prompt, in the order the prompt lists it — which is
    /// also the order the filter chips sit in, so a library's chip row doesn't reshuffle itself as
    /// projects are analysed. Anything outside it is dropped by the parser rather than surfaced —
    /// a 4-bit E2B invents an out-of-taxonomy tag now and then (see docs/ai/phase0-findings.md).
    static let orderedTaxonomy: [String] = [
        "water", "skyWeather", "urban", "nature", "landmark", "people",
        "vehicles", "lightTrails", "animals", "construction", "interior", "event",
    ]

    /// The same set, for the parser's membership test.
    static let taxonomy: Set<String> = Set(orderedTaxonomy)

    /// Human wording for a tag — the chips show these, the model speaks the raw values.
    ///
    /// A hand-typed tag falls through to the default and is shown as it was stored, first letter
    /// raised: the taxonomy's two camel-cased values are the only ones that need translating.
    static func label(for tag: String) -> String {
        // The words live in the Kit (M2): the index puts the label beside
        // the raw tag in its search table.
        SceneTagLabel.label(for: tag)
    }

    /// What to store for something a person typed.
    ///
    /// Whitespace trimmed and collapsed, and nothing else: a tag is the user's own word and the
    /// app has no business re-casing it. Empty means "there is no tag here" — callers refuse it.
    static func normalizedTag(_ typed: String) -> String {
        typed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The taxonomy value a typed word names, if it names one.
    ///
    /// Matched against both the raw value and the human label, case-insensitively, so typing
    /// "water", "Water" or "sky & weather" joins the existing tag instead of creating a
    /// near-duplicate that filters and searches as a separate thing.
    static func canonicalTag(for typed: String) -> String? {
        let needle = normalizedTag(typed).lowercased()
        guard !needle.isEmpty else { return nil }
        return orderedTaxonomy.first {
            $0.lowercased() == needle || label(for: $0).lowercased() == needle
        }
    }

    /// True for a tag a person typed rather than one the taxonomy defines.
    ///
    /// Nothing in the UI treats the two differently — once applied there is no difference worth
    /// showing — but the library-wide lists group by it, and the search index has to know that a
    /// custom tag will never be found by filtering through `orderedTaxonomy`.
    static func isCustom(_ tag: String) -> Bool { !taxonomy.contains(tag) }

    /// Written by hand rather than synthesised so a record stored before `elements` existed still
    /// decodes — the synthesised version treats a defaulted property as required.
    init(title: String, tags: [String], elements: [String] = [], place: String? = nil, light: String? = nil) {
        self.title = title
        self.tags = tags
        self.elements = elements
        self.place = place
        self.light = light
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        elements = try container.decodeIfPresent([String].self, forKey: .elements) ?? []
        place = try container.decodeIfPresent(String.self, forKey: .place)
        light = try container.decodeIfPresent(String.self, forKey: .light)
    }
}

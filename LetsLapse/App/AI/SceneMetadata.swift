import Foundation

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

    /// Human wording for a taxonomy tag — the chips show these, the model speaks the raw values.
    static func label(for tag: String) -> String {
        switch tag {
        case "skyWeather": return "Sky & weather"
        case "lightTrails": return "Light trails"
        default: return tag.prefix(1).uppercased() + tag.dropFirst()
        }
    }

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

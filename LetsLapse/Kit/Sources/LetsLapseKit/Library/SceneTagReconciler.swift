import Foundation

/// Turns a tag the model suggested — a string — into a tag the library
/// already knows, or a new one (Auto rename & tag §5.1, 2026-09-16).
///
/// Suggestions arrive as words: `building`, `Sky`, `waterfront`, `Šumava`.
/// Minted freely they fill the sidebar with near-duplicates within a week,
/// so each one is resolved, in order:
///
/// 1. **Exact match** — case- and diacritic-insensitive — against an
///    existing tag, by its stored value or its chip label (`Sky & weather`
///    names `skyWeather`) → the existing tag.
/// 2. **Alias match** against the small built-in synonym table below
///    (`building` → `urban`, `sky` → `skyWeather`) → the tag it maps to.
/// 3. **Otherwise** → a new tag, first letter raised, created only when the
///    row is accepted.
///
/// No fuzzy or edit-distance matching: it is unpredictable and it mis-merges
/// proper nouns.
public enum SceneTagReconciler {

    /// Where a suggestion landed.
    public enum Resolution: Equatable, Sendable {
        /// A tag the library (or the closed taxonomy) already has, as stored.
        case existing(String)
        /// A tag nobody has yet, as it would be stored.
        case new(String)

        /// The stored form either way.
        public var tag: String {
            switch self {
            case .existing(let tag), .new(let tag): return tag
            }
        }

        public var isNew: Bool {
            if case .new = self { return true }
            return false
        }
    }

    /// The synonym table: folded alias → the taxonomy value it means. Small
    /// on purpose, and one-directional — a word that is a subject in its own
    /// right (`sunset`, `hills`, `waterfront`) is *not* here, so it becomes
    /// its own tag beside the taxonomy's rather than being folded into one.
    public static let aliases: [String: String] = {
        var table: [String: String] = [:]
        func add(_ words: [String], _ tag: String) {
            for word in words { table[fold(word)] = tag }
        }
        add(["building", "buildings", "city", "cityscape", "street", "streets", "skyline",
             "downtown", "town", "skyscraper", "skyscrapers", "urban area"], "urban")
        add(["sky", "skies", "cloud", "clouds", "cloudy", "weather", "overcast"], "skyWeather")
        add(["river", "lake", "sea", "ocean", "waterfall", "pond", "stream", "harbour", "harbor",
             "coast", "waves", "water body"], "water")
        add(["forest", "woods", "tree", "trees", "plant", "plants", "foliage", "grass", "garden",
             "park", "meadow", "countryside"], "nature")
        add(["person", "people", "crowd", "man", "woman", "child", "children", "portrait",
             "faces", "face"], "people")
        add(["vehicle", "vehicles", "car", "cars", "bus", "train", "tram", "truck", "boat",
             "boats", "ship", "bicycle", "motorcycle", "aircraft", "airplane", "plane"], "vehicles")
        add(["animal", "animals", "dog", "cat", "bird", "birds", "horse", "wildlife"], "animals")
        add(["monument", "castle", "cathedral", "church", "temple", "statue", "ruins", "tower"], "landmark")
        add(["crane", "cranes", "scaffolding", "construction site", "building site"], "construction")
        add(["indoor", "indoors", "inside", "room", "interior"], "interior")
        add(["concert", "festival", "parade", "wedding", "party", "market"], "event")
        add(["light trails", "traffic", "night traffic", "headlights", "taillights"], "lightTrails")
        return table
    }()

    /// The comparison key: whitespace collapsed, case and diacritics dropped.
    public static func fold(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
    }

    /// Resolves one suggestion against `existing` — every tag the library
    /// holds plus the closed taxonomy, in whatever order. Empty suggestions
    /// resolve to nil.
    public static func reconcile(_ suggestion: String, existing: [String]) -> Resolution? {
        let cleaned = suggestion.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !cleaned.isEmpty else { return nil }
        let key = fold(cleaned)

        // 1. Exact: by stored value, then by the chip label the person reads.
        if let match = existing.first(where: { fold($0) == key || fold(SceneTagLabel.label(for: $0)) == key }) {
            return .existing(match)
        }
        // 2. Alias: to a taxonomy value — which is existing by definition, even
        //    in a library that has never used it, since the picker offers the
        //    whole taxonomy; it is returned as stored so it matches what is
        //    there when the library does hold it.
        if let target = aliases[key] {
            let stored = existing.first { fold($0) == fold(target) } ?? target
            return .existing(stored)
        }
        // 3. New, first letter raised so the sidebar reads as one list.
        return .new(cleaned.prefix(1).uppercased() + cleaned.dropFirst())
    }

    /// Resolves a list, dropping duplicates by their resolved form (two
    /// suggestions that land on one tag propose it once) and anything
    /// already in `applied`.
    public static func reconcile(_ suggestions: [String], existing: [String], applied: [String] = []) -> [Resolution] {
        var seen = Set(applied.map(fold))
        var resolved: [Resolution] = []
        for suggestion in suggestions {
            guard let resolution = reconcile(suggestion, existing: existing) else { continue }
            let key = fold(resolution.tag)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            resolved.append(resolution)
        }
        return resolved
    }
}

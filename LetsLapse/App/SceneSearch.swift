import SwiftUI

/// Finding a project by what is *in* it rather than by when it was shot.
///
/// The on-device analysis already writes two things onto a project — a closed set of subject tags
/// and the free-form nouns the model named for the frame — and until now neither could be searched
/// for. This is the query those become useful through: typed words match the project's name, its
/// tags and its elements; the chips narrow to projects carrying every selected tag.
///
/// Deliberately a value type with no view or model dependency: the same query drives the Projects
/// list, its empty state, and the "N of M" count, and all three must agree.
struct SceneQuery: Equatable {
    var text: String = ""
    /// Tags the user has switched on. A capture must carry **all** of them — chips narrow, the way
    /// a filter is expected to. (Union would mean each extra tap showed *more* projects.)
    var tags: Set<String> = []

    static let empty = SceneQuery()

    var isActive: Bool { !searchTokens.isEmpty || !tags.isEmpty }

    /// Lowercased words from the field. Splitting means "night water" finds a project tagged
    /// `water` and titled "…at night" — neither field holds the whole phrase.
    var searchTokens: [String] {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    func matches(_ capture: AppModel.CaptureProject) -> Bool {
        guard tags.isSubset(of: Set(capture.sceneTags ?? [])) else { return false }
        let tokens = searchTokens
        guard !tokens.isEmpty else { return true }
        let haystack = Self.haystack(for: capture)
        // Every token must land somewhere; a token may land anywhere. Typing more words narrows.
        return tokens.allSatisfy { token in
            haystack.contains { $0.contains(token) }
        }
    }

    /// Everything a typed word is allowed to match, lowercased once per test.
    ///
    /// Tags go in twice — raw and as their human label — because the model speaks `skyWeather`
    /// while the chip (and therefore the user) says "Sky & weather".
    private static func haystack(for capture: AppModel.CaptureProject) -> [String] {
        var terms = [capture.displayTitle.lowercased()]
        for tag in capture.sceneTags ?? [] {
            terms.append(tag.lowercased())
            terms.append(SceneMetadata.label(for: tag).lowercased())
        }
        terms.append(contentsOf: (capture.sceneElements ?? []).map { $0.lowercased() })
        return terms
    }
}

extension Array where Element == AppModel.CaptureProject {
    func matching(_ query: SceneQuery) -> [AppModel.CaptureProject] {
        query.isActive ? filter { query.matches($0) } : self
    }

    /// The tags actually present in this library, in taxonomy order.
    ///
    /// Chips are drawn from what exists, not from the whole taxonomy: a chip that can only ever
    /// return nothing is a dead control, and a library with no analysed projects should show no
    /// chip row at all rather than twelve useless ones.
    var presentSceneTags: [String] {
        let present = Set(flatMap { $0.sceneTags ?? [] })
        return SceneMetadata.orderedTaxonomy.filter(present.contains)
    }
}

// MARK: - Controls

/// The rounded search field the Projects header carries.
///
/// Hand-built rather than `.searchable`: Projects hides its navigation bar on iOS, which is the
/// only place the system search field can live, and the Gallery/Projects header rhythm is a custom
/// stack anyway.
struct SceneSearchField: View {
    @Binding var text: String
    var placeholder: String = "Search projects"

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text)
                .font(.system(size: 15))
                .textFieldStyle(.plain)
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

/// The horizontal row of subject-tag chips under the search field.
///
/// Scrolls rather than wraps: the row sits in a fixed-height header, and a wrapping row would
/// change the header's height as projects are analysed.
struct SceneTagChips: View {
    let tags: [String]
    @Binding var selection: Set<String>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(tags, id: \.self) { tag in
                    let isOn = selection.contains(tag)
                    Button {
                        if isOn { selection.remove(tag) } else { selection.insert(tag) }
                    } label: {
                        Text(SceneMetadata.label(for: tag))
                            .font(.system(size: 13, weight: isOn ? .semibold : .regular))
                            .foregroundStyle(isOn ? Color.white : Color.primary.opacity(0.75))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(isOn ? LL.accent : Color.primary.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            // The row is drawn inside a container that already supplies the leading inset, so the
            // scroll content starts flush and only pads its trailing end.
            .padding(.trailing, 16)
        }
    }
}

/// A project card's tags, shown small.
///
/// Without this the chips filter by something invisible: a project would drop out of a filtered
/// list with nothing on it explaining why it was ever in.
struct SceneTagLine: View {
    let tags: [String]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(tags.prefix(3), id: \.self) { tag in
                Text(SceneMetadata.label(for: tag))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(LL.accentDeep)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(LL.accent.opacity(0.13), in: Capsule())
            }
            if tags.count > 3 {
                Text("+\(tags.count - 3)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tags: \(tags.map(SceneMetadata.label(for:)).joined(separator: ", "))")
    }
}

import SwiftUI

/// The one tag editor, shared by every door onto a project's subject tags: the SUBJECT TAGS
/// section of `AutoNameSheet`, the **Tags** row of `ProjectDetailView.managementCard`, and the
/// TAGS block of `GalleryPreviewPanel`. Photo, Interval and Video need no variants — all three
/// are one `CaptureProject` with one `sceneTags` field, and nothing here reads the shoot type.
///
/// See docs/design/components/README.md ("Tag editor") and its
/// `tag-field.<state>.<width>.svg` / `tag-suggestions.<state>.svg` files for the spec.
///
/// Two views, never one: `TagField` is the applied tags (an xmark drops each), `TagSuggestions`
/// is everything that is *not* applied plus the field that filters and creates. Nothing is ever
/// drawn twice between them, so there is no tick state to reconcile and no way to see the same
/// word in two places — tap a suggestion and it moves up, tap an xmark and it moves back down.
///
/// This replaces a row of tick chips that could only ever be UNticked, and only during the one run
/// of Auto rename & tag that proposed them: there was no way to add a tag the model never thought
/// of, no way to type one of your own, and — because both call sites were wrapped in an `isEmpty`
/// guard — no tag UI at all on a project the analysis returned nothing for.

// MARK: - The applied tags

/// A wrapping row of the tags a project carries, each with an xmark that drops it, and — unless
/// the caller is the picker, which has a search field doing the same job — a dashed "+ Add tag"
/// chip that raises the picker.
///
/// The picker is a sheet on iOS and a popover on the Mac, and this view owns that choice so every
/// call site is one line.
struct TagField: View {
    @Binding var tags: [String]
    /// Every tag already used somewhere in this library, for the picker's YOUR TAGS group.
    var libraryTags: [String] = []
    /// False inside the picker itself, where the search field is already the add affordance.
    var showsAddChip = true

    @State private var isPicking = false

    var body: some View {
        TagChipFlow(spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                Button {
                    remove(tag)
                } label: {
                    appliedChip(tag)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove tag \(SceneMetadata.label(for: tag))")
            }

            if showsAddChip {
                Button {
                    isPicking = true
                } label: {
                    addChip
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add tag")
                .tagPicker(isPresented: $isPicking, tags: $tags, libraryTags: libraryTags)
            }
        }
    }

    private func appliedChip(_ tag: String) -> some View {
        HStack(spacing: 8) {
            Text(SceneMetadata.label(for: tag))
                .font(.system(size: 14, weight: .semibold))
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                // Decorative: the accessibility label on the button already says what it does,
                // and VoiceOver would otherwise read the symbol's own name.
                .accessibilityHidden(true)
        }
        .foregroundStyle(Color.white)
        .lineLimit(1)
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .padding(.vertical, 7)
        .background(LL.accent, in: Capsule())
    }

    private var addChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)
            Text("Add tag")
                .font(.system(size: 14, weight: .medium))
        }
        .foregroundStyle(LL.accent)
        .lineLimit(1)
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(LL.cardBackground)
                .overlay(
                    Capsule().strokeBorder(
                        LL.accent,
                        style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                )
        )
    }

    private func remove(_ tag: String) {
        tags.removeAll { $0 == tag }
    }
}

// MARK: - Everything not applied

/// The picker's body: a field that both filters and creates, then the tags on offer — SUGGESTED
/// (the closed taxonomy, minus what is applied) and YOUR TAGS (custom tags this library already
/// holds, so a word is typed once and tapped from then on).
///
/// Typing filters both groups in place. The Create row sits above whatever survives and is offered
/// until the text names a tag exactly — including a taxonomy tag under its human label, so typing
/// "sky & weather" joins that tag rather than creating a near-duplicate beside it.
struct TagSuggestions: View {
    @Binding var tags: [String]
    var libraryTags: [String] = []

    @State private var query = ""
    /// Custom tags created in this sitting, so one that is typed, applied and then thought better
    /// of can be tapped back rather than retyped. `libraryTags` is a snapshot taken when the
    /// picker opened and cannot know about them.
    @State private var created: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField

            if let creatable {
                createRow(creatable)
                    .padding(.top, 12)
            }

            group("Suggested", tags: filtered(offeredTaxonomy))
            group("Your tags", tags: filtered(offeredCustom))

            if creatable != nil, filtered(offeredTaxonomy).isEmpty, filtered(offeredCustom).isEmpty {
                Text("No existing tag matches “\(SceneMetadata.normalizedTag(query))”.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                    .padding(.horizontal, 2)
            }
        }
    }

    // MARK: Field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Add or find a tag", text: $query)
                .font(.system(size: 14))
                .textFieldStyle(.plain)
                .onSubmit { if let creatable { add(creatable) } }
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                #endif

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Color.primary.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func createRow(_ tag: String) -> some View {
        Button {
            add(tag)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityHidden(true)
                Text("Create “\(SceneMetadata.label(for: tag))”")
                    .font(.system(size: 14.5, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(LL.accent)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background(
                Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func group(_ title: String, tags offered: [String]) -> some View {
        if !offered.isEmpty {
            LLSectionHeader(title)
                .padding(.top, 16)

            TagChipFlow(spacing: 8) {
                ForEach(offered, id: \.self) { tag in
                    Button {
                        add(tag)
                    } label: {
                        Text(SceneMetadata.label(for: tag))
                            .font(.system(size: 14))
                            .foregroundStyle(Color.primary.opacity(0.75))
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add tag \(SceneMetadata.label(for: tag))")
                }
            }
            .padding(.top, 9)
        }
    }

    // MARK: What is on offer

    /// The closed taxonomy in prompt order, minus what is already applied. Prompt order rather
    /// than alphabetical for the same reason the Gallery sidebar uses it: the row must not
    /// reshuffle itself as tags are added and removed.
    private var offeredTaxonomy: [String] {
        SceneMetadata.orderedTaxonomy.filter { !tags.contains($0) }
    }

    private var offeredCustom: [String] {
        var seen = Set<String>()
        return (libraryTags + created)
            .filter {
                SceneMetadata.isCustom($0)
                    && !tags.contains($0)
                    && seen.insert($0.lowercased()).inserted
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func filtered(_ offered: [String]) -> [String] {
        let needle = SceneMetadata.normalizedTag(query).lowercased()
        guard !needle.isEmpty else { return offered }
        return offered.filter {
            $0.lowercased().contains(needle)
                || SceneMetadata.label(for: $0).lowercased().contains(needle)
        }
    }

    /// What Create would make, or nil when there is nothing to make: an empty field, or text that
    /// already names a tag this project carries.
    private var creatable: String? {
        let typed = SceneMetadata.normalizedTag(query)
        guard !typed.isEmpty else { return nil }
        let tag = SceneMetadata.canonicalTag(for: typed) ?? typed
        guard !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else {
            return nil
        }
        return tag
    }

    private func add(_ tag: String) {
        guard !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else {
            return
        }
        tags.append(tag)
        if SceneMetadata.isCustom(tag),
           !created.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            created.append(tag)
        }
        query = ""
    }
}

// MARK: - Presentation

/// The picker, as the platform wants it: a sheet on iOS, a popover on the Mac.
///
/// A popover is right where the trigger sits beside the thing being edited (the Gallery preview
/// panel, the Auto rename & tag sheet's own chip) and wrong on a phone, which has no popovers to
/// speak of; the sheet is the same content with a title and Done over it.
private struct TagPickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var tags: [String]
    var libraryTags: [String]

    func body(content: Content) -> some View {
        #if os(macOS)
        content.popover(isPresented: $isPresented, arrowEdge: .bottom) {
            TagSuggestions(tags: $tags, libraryTags: libraryTags)
                .padding(16)
                .frame(width: 361)
        }
        #else
        content.sheet(isPresented: $isPresented) {
            TagPickerSheet(tags: $tags, libraryTags: libraryTags)
        }
        #endif
    }
}

extension View {
    /// Raises the tag picker from this view. See `TagPickerModifier`.
    func tagPicker(
        isPresented: Binding<Bool>,
        tags: Binding<[String]>,
        libraryTags: [String]
    ) -> some View {
        modifier(TagPickerModifier(isPresented: isPresented, tags: tags, libraryTags: libraryTags))
    }
}

/// The picker as its own screen: the applied tags on top, everything else below.
///
/// Reached from the **Tags** row of a project's management card as well as from a "+ Add tag"
/// chip, which is why it carries the field too — the row it came from is no longer on screen.
///
/// **Done, and no Cancel.** Unlike `AutoNameSheet`, which is reviewing a proposal that does not
/// exist yet and where Cancel has to be free, this edits a project that already has tags: every
/// change is one tap to reverse, and the Gallery panel edits the same field with no confirmation
/// step at all. A Cancel here would have to mean "put them all back", which is a promise the
/// panel does not make and this should not either.
struct TagPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var tags: [String]
    var libraryTags: [String] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    LLSectionHeader("On this project")
                    Group {
                        if tags.isEmpty {
                            Text("No tags yet.")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            TagField(tags: $tags, showsAddChip: false)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .llCard()

                    TagSuggestions(tags: $tags, libraryTags: libraryTags)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                        .llCard()
                        .padding(.top, 8)

                    Text("Tags are what Projects search and the Gallery sidebar filter on. "
                         + "Your own tags work there too.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.top, 6)

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(LL.screenBackground)
            .navigationTitle("Tags")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 393, height: 560)
        #endif
    }
}

// MARK: - Layout

/// A plain wrapping row of chips.
///
/// `LazyVGrid` can't do variable-width items, so this measures and wraps by hand — which also
/// means it behaves identically on macOS, where the tag field has to wrap the same way inside a
/// 272pt panel column as it does inside a 329pt card.
///
/// Moved here from `AutoNameSheet` in the 2026-09-08 tag pass: three screens now need it.
struct TagChipFlow<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        TagChipFlowLayout(spacing: spacing) { content }
    }
}

struct TagChipFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var total = CGSize(width: 0, height: 0)

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > width {
                total.width = max(total.width, rowWidth)
                total.height += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += rowWidth > 0 ? spacing + size.width : size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        total.width = max(total.width, rowWidth)
        total.height += rowHeight
        return total
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

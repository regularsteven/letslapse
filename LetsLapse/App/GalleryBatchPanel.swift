import SwiftUI
import LetsLapseKit

// MARK: - Gallery batch panel

/// The 300 pt pane (the iPhone's sheet) over MORE than one selected project
/// (2026-09-13): every edit here lands on all of them.
///
/// Three groups, the same three the single-project panel leads with and in
/// the same order, each reading the selection as one record:
/// - **Tags** — the union of the projects' keywords: a tag on every project
///   is a solid chip, a tag on some a mixed chip that says how many; the
///   xmark takes a tag off every project, tapping a mixed chip puts it on
///   every project, and + Add tag adds to all through the shared picker.
/// - **Presets** — the editor's tiles (`EditorPresetsContext.tiles`),
///   previewed on the first selected project; a tap applies the preset to
///   every selected project through `AppModel.applyPreset` /
///   `applyCustomPreset`, which keep each project's own rotation, crop and
///   owned white, after a confirmation naming how many carry manual edits.
/// - **Metadata** — the editable IPTC Core record, project scope: a field
///   shows the value every project agrees on, or "Mixed"; a commit writes
///   the value to all of them, a revert reverts all of them.
///
/// INFO is not here (nothing the files said is true of several files at
/// once), nor the meta rows, the footer or the clips list — those describe
/// one project.
struct GalleryBatchPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var presetStore = CustomPresetStore.shared
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    /// The selected projects, in the grid's order.
    var captures: [AppModel.CaptureProject]
    /// Auto rename & tag over the selection: the host swaps its grid for the
    /// review list (2026-09-16). Nil where no host can (the row is hidden).
    var onAutoRename: (() -> Void)? = nil

    @ObservedObject private var models = ModelManager.shared
    @State private var presetsExpanded = GalleryBatchPanel.presetsInitiallyExpanded
    @State private var pendingPreset: BatchPresetRequest?
    @StateObject private var presetThumbnails = PresetThumbnailCache()

    /// `LL_PANEL=presets` opens the row here as it does on the single panel.
    private static var presetsInitiallyExpanded: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["LL_PANEL"] == "presets"
        #else
        return false
        #endif
    }

    /// Scanner captures are not looks; the row is hidden when there is
    /// nothing to apply a preset to.
    private var presetTargets: [AppModel.CaptureProject] {
        captures.filter { !$0.isScannerCapture }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                titleSection
                    .padding(.top, 22)
                    .padding(.horizontal, 14)

                Divider()
                    .padding(.top, 16)

                VStack(alignment: .leading, spacing: 14) {
                    if onAutoRename != nil {
                        autoRenameRow
                    }
                    tagsSection
                    if !presetTargets.isEmpty {
                        presetsSection
                    }
                    metadataSection
                }
                .padding(.top, 12)
                .padding(.horizontal, 14)

                Color.clear.frame(height: 82) // floating tab bar clearance
            }
        }
        .scrollContentBackground(.hidden)
        .background(LL.cardBackground)
        .alert(item: $pendingPreset) { request in
            Alert(
                title: Text(request.title),
                message: Text(request.message),
                primaryButton: .destructive(Text(request.button)) {
                    applyPreset(request.target)
                },
                secondaryButton: .cancel())
        }
    }

    // MARK: Title

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(captures.count) projects")
                .font(.system(size: 16, weight: .bold))
            Text("Changes here apply to every selected project.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Auto rename & tag

    /// Directly above TAGS (2026-09-16): the whole selection through the
    /// review list — a row per project, each with its own suggestion,
    /// accepted or discarded one at a time (`AutoRenameReviewList`). The
    /// label carries the count, so what the tap covers is on the button.
    /// Inert without a model to run — the built-in one is always there, so
    /// in practice only a catalog that failed to load disables it.
    private var autoRenameRow: some View {
        Button {
            onAutoRename?()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityHidden(true)
                Text("Auto rename & tag")
                    .font(.system(size: 14, weight: .semibold))
                Text("×\(captures.count) selected")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(models.isReady ? LL.accent : Color.secondary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!models.isReady)
        .accessibilityLabel("Auto rename & tag, \(captures.count) selected")
    }

    // MARK: Tags

    private var tagsSection: some View {
        let _ = model.metadataRevision
        let lists = captures.map { model.resolvedKeywords(for: $0) }
        // The union in first-seen order, and how many projects carry each.
        var union: [String] = []
        var counts: [String: Int] = [:]
        for list in lists {
            for tag in list {
                if counts[tag] == nil { union.append(tag) }
                counts[tag, default: 0] += 1
            }
        }
        let onAll = union.filter { counts[$0] == captures.count }
        return VStack(alignment: .leading, spacing: 5) {
            LLSectionHeader("Tags")
            BatchTagField(
                tags: union.map { BatchTagField.Entry(tag: $0, count: counts[$0] ?? 0, total: captures.count) },
                onAll: Binding(
                    get: { onAll },
                    set: { next in
                        for tag in next where !onAll.contains(tag) { addTag(tag) }
                        for tag in onAll where !next.contains(tag) { removeTag(tag) }
                    }),
                libraryTags: model.libraryTags,
                onAdd: addTag,
                onRemove: removeTag)
        }
    }

    /// Puts `tag` on every selected project that lacks it.
    private func addTag(_ tag: String) {
        for capture in captures {
            let tags = model.resolvedKeywords(for: capture)
            guard !tags.contains(tag) else { continue }
            model.setMetadata(.list(tags + [tag]), for: .keywords, on: capture, scope: .project)
        }
    }

    /// Takes `tag` off every selected project that carries it.
    private func removeTag(_ tag: String) {
        for capture in captures {
            let tags = model.resolvedKeywords(for: capture)
            guard tags.contains(tag) else { continue }
            model.setMetadata(.list(tags.filter { $0 != tag }), for: .keywords, on: capture, scope: .project)
        }
    }

    // MARK: Presets

    /// The state every selected project is in, or nil when they differ.
    private var commonPresetState: PresetState? {
        let states = presetTargets.map { model.presetState(for: $0) }
        guard let first = states.first, states.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { presetsExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    LLSectionHeader("Presets")
                    if let state = commonPresetState {
                        PresetStatePill(state: state)
                    } else {
                        mixedPill
                    }
                    Image(systemName: presetsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Presets")
            .accessibilityValue(presetsExpanded ? "expanded" : "collapsed")

            if presetsExpanded {
                presetTiles
                if let first = presetTargets.first {
                    Text("Previewed on \(first.displayTitle)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    /// The pill's "Mixed" form — the projects are not all on one look. Styled
    /// as Edited is: a state, not a choice on offer.
    private var mixedPill: some View {
        Text("Mixed")
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(LL.hairline))
            .accessibilityLabel("Mixed — the selected projects are on different presets")
    }

    @ViewBuilder private var presetTiles: some View {
        #if os(macOS)
        presetGrid
        #else
        if horizontalSizeClass == .compact {
            presetStrip
        } else {
            presetGrid
        }
        #endif
    }

    private var presetGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
            spacing: 8
        ) {
            presetsContext.tiles(style: .macGrid, accent: LL.accent)
        }
    }

    private var presetStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                presetsContext.tiles(style: .phone, accent: LL.accent, isOnDark: false)
            }
            .padding(.horizontal, 14)
        }
        .padding(.horizontal, -14)
    }

    /// Previewed on the first selected project. With the projects on one
    /// state its tile is ringed; with them mixed nothing is (`.edited` over
    /// an `.original` base rings no tile).
    private var presetsContext: EditorPresetsContext {
        let first = presetTargets.first
        let frame = first.flatMap { model.presetPreviewFrame(preferring: $0.id) }
        let common = commonPresetState
        return EditorPresetsContext(
            frame: frame?.captureID == first?.id ? frame : nil,
            presetState: common ?? .edited,
            basePreset: common != nil ? PhotoPreset.resolve(first?.selectedPreset) : .original,
            customPresets: presetStore.presets,
            cache: presetThumbnails,
            onSelect: { requestPreset($0) },
            onDelete: { presetStore.delete($0) },
            onSaveAsPreset: {})
    }

    /// A tile tap: straight through when no selected project is Edited,
    /// otherwise the confirmation, which says how many are.
    private func requestPreset(_ target: PresetApplyRequest.Target) {
        let edited = presetTargets.filter { model.presetState(for: $0).isEdited }.count
        guard edited > 0 else {
            applyPreset(target)
            return
        }
        pendingPreset = BatchPresetRequest(target: target, edited: edited, total: presetTargets.count)
    }

    private func applyPreset(_ target: PresetApplyRequest.Target) {
        for capture in presetTargets {
            switch target {
            case .builtIn(let preset): model.applyPreset(preset, for: capture)
            case .custom(let preset): model.applyCustomPreset(preset, for: capture)
            }
        }
    }

    // MARK: Metadata

    private var metadataSection: some View {
        let _ = model.metadataRevision
        let resolved = captures.map { model.resolvedMetadata(for: $0, scope: .project) }
        return VStack(alignment: .leading, spacing: 10) {
            LLSectionHeader("Metadata")
            textRow(.title, resolved)
            textRow(.caption, resolved, multiline: true)
            textRow(.creator, resolved, placeholder: "Name, name")
            textRow(.rights, resolved, placeholder: "© year name")
            ratingRow(resolved)
            statusRow(resolved)
            textRow(.rightsURL, resolved, placeholder: "https://")
            textRow(.usageTerms, resolved)

            groupLabel("Creator contact")
            ForEach([MetadataField.contactAddress, .contactCity, .contactState, .contactPostcode,
                     .contactCountry, .contactPhone, .contactEmail, .contactWebsite], id: \.self) { field in
                textRow(field, resolved)
            }

            groupLabel("Location")
            ForEach([MetadataField.locationSublocation, .locationCity, .locationState,
                     .locationCountry, .locationCountryCode], id: \.self) { field in
                textRow(field, resolved)
            }
        }
    }

    private func groupLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
    }

    /// The value every project agrees on, or nil.
    private func commonText(_ field: MetadataField, _ resolved: [AppModel.ResolvedMetadata]) -> String? {
        let values = resolved.map { $0.value[field]?.textValue ?? "" }
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// The origin every project agrees on, or nil — a mixed provenance
    /// shows no marker, and the revert with it.
    private func commonOrigin(_ field: MetadataField, _ resolved: [AppModel.ResolvedMetadata]) -> AppModel.MetadataOrigin? {
        let origins = resolved.map { $0.origin(field) }
        guard let first = origins.first, origins.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    private func rowKey(_ field: MetadataField) -> String {
        "batch|" + captures.map { $0.id.uuidString }.joined(separator: ",") + "|" + field.rawValue
    }

    private func textRow(_ field: MetadataField, _ resolved: [AppModel.ResolvedMetadata],
                         placeholder: String = "", multiline: Bool = false) -> some View {
        let common = commonText(field, resolved)
        return MetadataTextRow(
            field: field,
            text: common ?? "",
            origin: commonOrigin(field, resolved),
            placeholder: common == nil ? "Mixed" : placeholder,
            multiline: multiline,
            commit: { text in
                let value: MetadataValue? = text.isEmpty
                    ? nil
                    : (field == .creator ? .list(MetadataValue.text(text).listValue ?? []) : .text(text))
                for capture in captures {
                    model.setMetadata(value, for: field, on: capture, scope: .project)
                }
            },
            revert: { revert(field) })
        .id(rowKey(field))
    }

    private func revert(_ field: MetadataField) {
        for capture in captures {
            model.revertMetadata(field, on: capture, scope: .project)
        }
    }

    private func ratingRow(_ resolved: [AppModel.ResolvedMetadata]) -> some View {
        let ratings = resolved.map { $0.value.rating ?? 0 }
        let common = ratings.first.flatMap { first in ratings.allSatisfy({ $0 == first }) ? first : nil }
        let rating = common ?? 0
        return MetadataRowFrame(field: .rating, origin: commonOrigin(.rating, resolved),
                                revert: { revert(.rating) }) {
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        // The same star again clears, as it does in Lightroom.
                        let next = star == rating ? 0 : star
                        for capture in captures {
                            model.setMetadata(.integer(next), for: .rating, on: capture, scope: .project)
                        }
                    } label: {
                        Image(systemName: star <= rating ? "star.fill" : "star")
                            .font(.system(size: 15))
                            .foregroundStyle(star <= rating ? LL.amber : Color.secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                }
                if common == nil {
                    Text("Mixed")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func statusRow(_ resolved: [AppModel.ResolvedMetadata]) -> some View {
        let statuses = resolved.map { $0.value.rightsStatus ?? .unknown }
        let common = statuses.first.flatMap { first in statuses.allSatisfy({ $0 == first }) ? first : nil }
        return MetadataRowFrame(field: .rightsStatus, origin: commonOrigin(.rightsStatus, resolved),
                                revert: { revert(.rightsStatus) }) {
            Menu {
                ForEach(AssetMetadata.RightsStatus.allCases, id: \.self) { status in
                    Button(Self.label(for: status)) {
                        for capture in captures {
                            model.setMetadata(.text(status.rawValue), for: .rightsStatus, on: capture, scope: .project)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(common.map(Self.label(for:)) ?? "Mixed")
                        .font(.system(size: 13, weight: .medium))
                    #if os(iOS)
                    // The Mac's borderless menu draws its own up/down control.
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                    #endif
                }
                .foregroundStyle(LL.accent)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func label(for status: AssetMetadata.RightsStatus) -> String {
        switch status {
        case .copyrighted: return "Copyrighted"
        case .publicDomain: return "Public domain"
        case .unknown: return "Unknown"
        }
    }
}

// MARK: - The batch preset confirmation

/// The batch panel's version of `PresetApplyRequest`'s wording: the count of
/// projects whose manual edits the apply would replace.
struct BatchPresetRequest: Identifiable {
    var target: PresetApplyRequest.Target
    var edited: Int
    var total: Int

    var id: String {
        switch target {
        case .builtIn(let preset): return "builtin.\(preset.rawValue)"
        case .custom(let preset): return "custom.\(preset.id.uuidString)"
        }
    }

    private var name: String {
        switch target {
        case .builtIn(let preset): return preset.displayName
        case .custom(let preset): return preset.name
        }
    }

    private var isOriginal: Bool {
        if case .builtIn(.original) = target { return true }
        return false
    }

    private var editedPhrase: String {
        edited == total
            ? (total == 2 ? "Both selected projects carry" : "All \(total) selected projects carry")
            : "\(edited) of the \(total) selected projects \(edited == 1 ? "carries" : "carry")"
    }

    var title: String {
        isOriginal ? "Discard the edits?" : "Replace the edits with \(name)?"
    }

    var message: String {
        if isOriginal {
            return "\(editedPhrase) manual adjustments. Original clears every adjustment on all \(total) and returns them to their original, unfiltered files. There's no undo."
        }
        return "\(editedPhrase) manual adjustments, which the \(name) preset will replace; the rest simply take the preset. There's no undo."
    }

    var button: String { isOriginal ? "Discard Edits" : "Replace" }
}

// MARK: - The batch tag field

/// The tag editor over several projects: the union of their tags, a solid
/// chip for a tag on every one, a mixed chip — accent at 13 %, the count in
/// it — for a tag on some. The xmark takes the tag off all of them; the body
/// of a mixed chip puts it on all of them; + Add tag raises the shared picker
/// over the tags on all, so anything it adds lands on every project.
struct BatchTagField: View {
    struct Entry: Identifiable {
        var tag: String
        var count: Int
        var total: Int
        var id: String { tag }
        var isOnAll: Bool { count == total }
    }

    var tags: [Entry]
    /// The tags on every project — what the picker edits.
    @Binding var onAll: [String]
    var libraryTags: [String] = []
    var onAdd: (String) -> Void
    var onRemove: (String) -> Void

    @State private var isPicking = false

    var body: some View {
        TagChipFlow(spacing: 8) {
            ForEach(tags) { entry in
                if entry.isOnAll {
                    Button {
                        onRemove(entry.tag)
                    } label: {
                        chip(entry, solid: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove tag \(SceneMetadata.label(for: entry.tag)) from all")
                } else {
                    HStack(spacing: 0) {
                        Button {
                            onAdd(entry.tag)
                        } label: {
                            HStack(spacing: 6) {
                                Text(SceneMetadata.label(for: entry.tag))
                                    .font(.system(size: 14, weight: .semibold))
                                Text("\(entry.count)/\(entry.total)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .opacity(0.7)
                            }
                            .lineLimit(1)
                            .padding(.leading, 12)
                            .padding(.trailing, 6)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add tag \(SceneMetadata.label(for: entry.tag)) to all — on \(entry.count) of \(entry.total)")
                        Button {
                            onRemove(entry.tag)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.leading, 2)
                                .padding(.trailing, 12)
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove tag \(SceneMetadata.label(for: entry.tag)) from all")
                    }
                    .foregroundStyle(LL.accentDeep)
                    .background(LL.accent.opacity(0.13), in: Capsule())
                }
            }

            Button {
                isPicking = true
            } label: {
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
            .buttonStyle(.plain)
            .accessibilityLabel("Add tag to all")
            .tagPicker(isPresented: $isPicking, tags: $onAll, libraryTags: libraryTags)
        }
    }

    private func chip(_ entry: Entry, solid: Bool) -> some View {
        HStack(spacing: 8) {
            Text(SceneMetadata.label(for: entry.tag))
                .font(.system(size: 14, weight: .semibold))
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .accessibilityHidden(true)
        }
        .foregroundStyle(Color.white)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(LL.accent, in: Capsule())
    }
}

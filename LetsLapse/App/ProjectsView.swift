import SwiftUI
import LetsLapseKit

/// What the Projects list and the Gallery can be ordered by.
///
/// Four axes because four questions get asked of a library: when was this
/// shot, when did it turn up here, when did I last work on it, and what is it
/// costing me. The first two are only the same question on a device that
/// shoots everything it holds — every import path deliberately keeps the
/// shoot's own date, so a timelapse shot last August lands under last August
/// however recently it arrived, and Added is the axis that finds it again.
/// Each has its own direction words — "oldest" and "smallest" are the same
/// gesture but not the same sentence — so the triangle's accessibility label
/// comes from here rather than from a generic ascending/descending.
enum ProjectSort: String, CaseIterable, Identifiable {
    case capture
    case added
    case edit
    case size

    var id: String { rawValue }

    var label: String {
        switch self {
        case .capture: return "Capture"
        case .added: return "Added"
        case .edit: return "Edit"
        case .size: return "Size"
        }
    }

    var ascendingLabel: String {
        switch self {
        case .capture: return "Oldest capture first"
        case .added: return "Longest in the library first"
        case .edit: return "Least recently edited first"
        case .size: return "Smallest first"
        }
    }

    var descendingLabel: String {
        switch self {
        case .capture: return "Newest capture first"
        case .added: return "Most recently added first"
        case .edit: return "Most recently edited first"
        case .size: return "Biggest first"
        }
    }
}

/// One card per original — Library and Blends unified, with no
/// expand/collapse state at all.
/// A List (restyled to match the ScrollView look) so cards get native
/// swipe-to-delete.
struct ProjectsView: View {
    @EnvironmentObject var model: AppModel
    /// Owned by ContentView so the tab bar can pop this stack to the list.
    @Binding var path: [UUID]
    @State private var previewItem: MediaPreviewItem?
    @State private var deleteFailure: String?
    @State private var filter: CaptureFilter = .all
    /// Settings ▸ Advanced ▸ Layout. With the Scans tab off, scanner runs have
    /// nowhere else to be listed, so this list takes them in behind its own
    /// Scans filter.
    @AppStorage(LayoutSettings.scansMenuKey) private var scansMenuEnabled = true
    @AppStorage(LayoutSettings.projectCountsKey) private var showsCounts = false
    /// Typed words and tag chips, together — the two narrow the same list and share one
    /// empty state, so they are one value rather than two pieces of view state.
    @State private var query = SceneQuery.empty
    /// The sort, remembered. Unlike the transfer picker's filter this is a
    /// preference rather than a per-visit question: a library somebody sorts by
    /// size is one they are managing storage on, and re-choosing that on every
    /// launch is the kind of thing a file browser has never asked of anyone.
    /// Descending by default, which is the newest-first order the list has
    /// always opened in.
    @AppStorage("projects.sortKey") private var sortKeyRaw = ProjectSort.capture.rawValue
    @AppStorage("projects.sortAscending") private var sortAscending = false

    private var sortKey: ProjectSort { ProjectSort(rawValue: sortKeyRaw) ?? .capture }
    /// Serving this library to another device. Owned here rather than by the
    /// model so it lives exactly as long as the Projects tab does — which is
    /// the whole session, since a `@StateObject` on a tab survives switching
    /// away from it. That is deliberate: an in-flight transfer must not die
    /// because somebody looked at Settings.
    @AppStorage(ProjectTransferServer.enabledKey) private var sharingEnabled = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                // Title and filter bar share ONE row, so the List's per-row
                // insets can't open a gap between them (or under the bar) that
                // the Gallery — a plain VStack — doesn't have.
                header
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 0, trailing: 16))

                Group {
                    // With the Scans tab on, scans are excluded outright — a
                    // scanner run is a document and lives in its own tab, and
                    // the project itself is still reachable from that tab's
                    // "View as timelapse". With the tab off they come back
                    // here, because otherwise nothing lists them.
                    //
                    // The rows, their order and the two empty states come
                    // from the index (M2) — one question, `listQuery` —
                    // and each card from its record by id. The arrays are
                    // sorted and filtered here only for a library with no
                    // index to ask.
                    let visible = visibleIDs
                    if libraryIsEmpty {
                        emptyState
                    } else if visible.isEmpty {
                        filteredEmptyState
                    } else {
                        // One record per row, read as the row comes on
                        // screen (M3): the list holds ids, never the library.
                        ForEach(visible, id: \.self) { id in
                            if let capture = model.capture(id: id) {
                            ProjectCard(
                                capture: capture,
                                onOpen: { path.append(capture.id) },
                                onNewVersion: { model.openCapture(capture) },
                                onPreview: { preview(capture) },
                                onDelete: { delete(capture) }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    delete(capture)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            }
                        }
                    }

                    // Clearance for the floating tab bar.
                    Color.clear.frame(height: 82)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                // All of the 14pt card rhythm hangs below each row, so the
                // first card sits flush against the filter bar's own 8pt of
                // bottom padding — exactly where the Gallery grid starts.
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 14, trailing: 16))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            #if os(iOS)
            // A deliberate pull on the list is "Check PicPlace now": what the
            // check brings here, updates or trashes reaches the list through
            // the index, and the Gallery the same way. On the List itself,
            // not the stack — a pushed detail's scroll view must not inherit it.
            .refreshable { await model.picplace.checkNow() }
            #endif
            .background(LL.screenBackground)
            .alert(
                "Couldn't delete",
                isPresented: Binding(get: { deleteFailure != nil }, set: { if !$0 { deleteFailure = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deleteFailure ?? "")
            }
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #else
            .navigationTitle("Projects")
            #endif
            .navigationDestination(for: UUID.self) { captureID in
                ProjectDetailView(captureID: captureID)
            }
            .sheet(item: $previewItem) { item in
                ProjectMediaPreviewSheet(item: item)
            }
        }
        // The Scans filter can vanish under the selection — the tab it defers
        // to came back. Fall back to All rather than leave a selection nothing
        // in the bar points at.
        .onChange(of: listsScans) { lists in
            if !lists, filter == .scans { filter = .all }
        }
        // Sizes are measured only for the sort that needs them, and only for
        // projects edited since their last measurement — so this is a full
        // library walk exactly once, and nothing at all on every visit after.
        // `task(id:)` rather than `onChange` so choosing Size on a cold launch
        // starts the sweep too.
        .task(id: sortKey) {
            guard sortKey == .size else { return }
            await model.measureProjectSizes()
        }
        .onAppear { consumeDetailRequest(model.requestedProjectDetailID) }
        .onReceive(model.$requestedProjectDetailID) { requested in
            consumeDetailRequest(requested)
        }
        .onAppear { consumeFilterRequest(model.requestedProjectsFilter) }
        .onReceive(model.$requestedProjectsFilter) { requested in
            consumeFilterRequest(requested)
        }
        #if DEBUG
        .onAppear {
            if let hooked = ListDebugHooks.filter { filter = hooked }
            if let text = ListDebugHooks.queryText { query.text = text }
            if let chips = ListDebugHooks.chips { query.tags = chips }
        }
        .onChange(of: renderedOrder, initial: true) { _, ids in
            ListDebugHooks.dump(screen: "projects", sort: sortKey.rawValue, ascending: sortAscending, filter: filter, query: query, ids: ids)
        }
        #endif
        // The nearby-device server is the model's (the Gallery header shows
        // the same pill); this list arms it and stands it down like the
        // Gallery does, through one modifier.
        .armsProjectSharing(model.transferServer, isEnabled: sharingEnabled)
        #if os(iOS)
        // No transfer dim, by decision (2026-08-29): direct peer-to-peer
        // moved a 10 GB pull in ~9 minutes at thermal "fair" — too short for
        // panel heat to matter. The keep-awake in `ProjectTransferServer`
        // stays: auto-lock killing a serve is still real. If hour-long pulls
        // ever return, a duration-aware dim is sketched in TODO (Phase C).
        #endif
    }

    /// The Gallery's `VStack(spacing: 0)` header, reproduced as a single list
    /// row: 34pt title 15pt from the top (7 row inset + 8 here), 20pt in from
    /// the leading edge (16 row inset + 4 here), then the search field, the
    /// filter bar — whose own 8pt vertical padding is the only spacing above
    /// and below it — and, when the library has any, the tag chips.
    ///
    /// Projects carries search and Gallery does not: search matches a project's
    /// name and what the on-device analysis found in it, and the Gallery shows
    /// assets rather than projects.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The sharing control sits opposite the title rather than in a row
            // of its own under it (which is where it lived until 2026-09-06).
            // A glyph can say the one thing that row said — green on, red off —
            // in the corner, and everything else it carried (the switch, the
            // code, the QR, what is being sent) belongs behind it rather than
            // across the header of every session that never touches sharing.
            HStack(alignment: .firstTextBaseline) {
                Text("Projects")
                    .font(.system(size: 34, weight: .bold))
                Spacer(minLength: 8)
                ProjectSharingChip(server: model.transferServer, picplace: model.picplace, isEnabled: $sharingEnabled)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            .padding(.trailing, 4)
            .padding(.top, 8)

            // Same segmented filter the Gallery grid uses, so the two tabs
            // narrow a library the same way.
            if libraryIsEmpty {
                // Nothing to filter — stand in for the bar's bottom padding so
                // the empty-state card doesn't butt against the title.
                Color.clear.frame(height: 8)
            } else {
                // Search and sort share the row: two halves of "which
                // projects, in what order", and the header has no vertical
                // room to spare above the filter bar and the tag chips.
                HStack(spacing: 8) {
                    SceneSearchField(text: $query.text)
                    sortControl
                }
                .padding(.top, 10)

                CaptureFilterBar(
                    selection: $filter,
                    filters: availableFilters,
                    counts: showsCounts ? filterCounts : nil)

                let tags = model.tagChips(listsScans: listsScans) ?? []
                if !tags.isEmpty {
                    // Bleeds past the row's trailing inset so a long chip row
                    // scrolls out to the screen edge rather than stopping short.
                    SceneTagChips(tags: tags, selection: $query.tags)
                        .padding(.bottom, 8)
                }
            }
        }
    }

    /// The sort menu and its direction triangle, in the search row's trailing
    /// half.
    ///
    /// The menu carries its own capsule rather than taking a `.borderless`
    /// button style: AppKit drops the capsule behind a `Menu` with a custom
    /// label, so on the Mac the row would otherwise read as two bare words
    /// beside a filled search field.
    private var sortControl: some View {
        HStack(spacing: 4) {
            Menu {
                Picker("Sort by", selection: $sortKeyRaw) {
                    ForEach(ProjectSort.allCases) { key in
                        Text(key.label).tag(key.rawValue)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    if model.isMeasuringSizes, sortKey == .size {
                        // A size sort on a library that has never been measured
                        // settles as the walks land; saying so beats a list
                        // that appears to re-order itself for no reason.
                        ProgressView().controlSize(.mini)
                    }
                    Text(sortKey.label)
                        .font(.system(size: 14, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(LL.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .contentShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Sort by \(sortKey.label)")

            Button {
                sortAscending.toggle()
            } label: {
                Image(systemName: sortAscending ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LL.accent)
                    .frame(width: 30, height: 32)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(sortAscending ? sortKey.ascendingLabel : sortKey.descendingLabel)
        }
    }

    /// The list's whole question, for the index (M2).
    private var listQuery: ProjectListQuery {
        ProjectListQuery(sort: sortKey, ascending: sortAscending, filter: filter, query: query, listsScans: listsScans)
    }

    /// The ids the list renders, in order: the index's answer (M2; a
    /// library with no index lists nothing, M3). Each row reads its own
    /// record.
    private var visibleIDs: [UUID] {
        model.projectIDs(for: listQuery) ?? []
    }

    /// Nothing to list at all — as opposed to nothing left after the
    /// filter, the search or the chips.
    private var libraryIsEmpty: Bool {
        model.libraryIsEmpty(for: listQuery) ?? true
    }

    #if DEBUG
    /// The ids the list renders, in order — what `LL_DUMP_ORDER` logs.
    private var renderedOrder: [UUID] {
        visibleIDs
    }
    #endif

    /// Scans belong to this list exactly when they have no tab of their own.
    /// Deliberately not conditional on any scan existing: an empty Scans filter
    /// says where scans would be, which is the point of moving them here.
    private var listsScans: Bool { !scansMenuEnabled }

    private var availableFilters: [CaptureFilter] {
        listsScans ? CaptureFilter.allCases : CaptureFilter.withoutScans
    }

    /// How many projects each filter would show, counted after the search has
    /// had its say so the numbers agree with what tapping one produces.
    private var filterCounts: [CaptureFilter: Int] {
        model.listCounts(for: listQuery, filters: availableFilters) ?? [:]
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No projects yet")
                .font(.headline)
            Text("Record or import something in Create — every original becomes a project here, with all its blended clips.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(20)
        .llCard(cornerRadius: 18)
    }

    /// The library has projects, just none that survived what is switched on —
    /// say so rather than repeating the "record something" pitch. A search that
    /// found nothing says what was searched for, because "No videos" would be a
    /// lie when the kind filter is on All and it was the typed word that missed.
    private var filteredEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: query.isActive
                ? "magnifyingglass"
                : "line.3.horizontal.decrease.circle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(query.isActive ? "No matching projects" : filter.emptyMessage)
                .font(.headline)
            if query.isActive {
                Text(noMatchDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(query.isActive ? "Clear filters" : "Show all") {
                query = .empty
                filter = .all
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(LL.accent)
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(20)
        .llCard(cornerRadius: 18)
    }

    /// Names what is actually narrowing the list, so "clear filters" is an
    /// informed tap rather than a guess.
    private var noMatchDetail: String {
        var parts: [String] = []
        let typed = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { parts.append("“\(typed)”") }
        if !query.tags.isEmpty {
            let names = SceneMetadata.orderedTaxonomy
                .filter(query.tags.contains)
                .map(SceneMetadata.label(for:))
            parts.append(names.joined(separator: " + "))
        }
        let subject = parts.joined(separator: " and ")
        return filter == .all
            ? "Nothing in your library matches \(subject)."
            : "Nothing under \(filter.rawValue) matches \(subject)."
    }

    private func preview(_ capture: AppModel.CaptureProject) {
        // A Photo-mode capture previews as its one photo, not a burst frame.
        let url = capture.isPhotoCapture
            ? model.heroImageURL(for: capture)
            : model.mediaURL(for: capture)
        guard let url else { return }
        previewItem = MediaPreviewItem(
            title: capture.displayTitle,
            subtitle: model.formatLine(for: capture),
            url: url,
            kind: model.mediaKind(for: capture)
        )
    }

    /// `requested` must arrive as a parameter: @Published emits on willSet, so
    /// during the emission the model property still holds the OLD value — the
    /// previous re-read here made a live ProjectsView drop every request (the
    /// macOS "clicking a project in Settings does nothing" bug; iOS was saved
    /// only by onAppear re-firing on tab switches).
    private func consumeDetailRequest(_ requested: UUID?) {
        guard let requested else { return }
        guard model.capture(id: requested) != nil else { return }
        path = [requested]
        // Clear once the emission has settled; writing back during it would
        // re-enter the publisher mid-publish.
        DispatchQueue.main.async {
            if model.requestedProjectDetailID == requested {
                model.requestedProjectDetailID = nil
            }
        }
    }

    /// A batch import asking for the list, filtered to what it made. Same
    /// shape as the detail request above, for the same publisher-timing
    /// reason.
    private func consumeFilterRequest(_ requested: CaptureFilter?) {
        guard let requested else { return }
        path = []
        filter = requested
        query = .empty
        DispatchQueue.main.async {
            if model.requestedProjectsFilter == requested {
                model.requestedProjectsFilter = nil
            }
        }
    }

    /// Deliberately unconfirmed: swiping is the confirmation. Failures
    /// (e.g. the project is mid-processing) surface in an alert.
    private func delete(_ capture: AppModel.CaptureProject) {
        do {
            try withAnimation {
                try model.deleteCapture(capture)
            }
        } catch {
            deleteFailure = error.localizedDescription
        }
    }
}

// MARK: - Project card

private struct ProjectCard: View {
    @EnvironmentObject var model: AppModel
    var capture: AppModel.CaptureProject
    var onOpen: () -> Void
    var onNewVersion: () -> Void
    var onPreview: () -> Void
    var onDelete: () -> Void

    @State private var projectBytes: Int64?
    @State private var burstSummary: AppModel.BurstClipSummary?
    @State private var sourceFormat: AppModel.SourceFormatSummary?

    var body: some View {
        let versions = model.blends(for: capture)

        // A one-child stack, and left that way deliberately: the card's
        // chrome (llCard, the context menu, the size and metadata tasks) hangs
        // off it, and `.llCard` on the Button itself would put a filled
        // background inside a button style rather than around it.
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    ZStack(alignment: .bottomTrailing) {
                        ProjectThumbnailView(url: thumbnailURL, kind: model.mediaKind(for: capture))
                            .frame(width: 86, height: 64)
                        MediaBadge(text: durationBadge)
                            .scaleEffect(0.82, anchor: .bottomTrailing)
                            .padding(4)
                    }
                    // Synced / syncing / failed on PicPlace, top-right, 4pt in;
                    // nothing for a project never synced (picplace-pill.*.svg).
                    .overlay(alignment: .topTrailing) {
                        PicPlaceThumbnailPill(picplace: model.picplace, captureID: capture.id)
                            .padding(4)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(capture.displayTitle)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("\(model.formatLine(for: capture)) · \(capture.createdAt.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        // The shoot's make-up, video only: an interval card
                        // already counts its photos in the format line, and a
                        // photo capture reads as one asset — no counts at all.
                        if capture.kind == .video {
                            Text(sourceLine)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        HStack(spacing: 7) {
                            Text(versionsLine(count: versions.count))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(
                                    versions.isEmpty || capture.isPhotoCapture
                                        ? Color.secondary : LL.accent)
                                // One line, like every other line of the
                                // stack — the pill beside it must not be able
                                // to wrap "1 blended clip · 21 MB" in half.
                                // It shrinks a hair rather than truncating in
                                // the one case that is genuinely tight: a
                                // blended project wearing a FLAT pill too.
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            // What the source assets actually are — stills or
                            // footage, in what file type, shot flat or not.
                            // Absent until the sidecar read lands, and absent
                            // for good on a project whose files have no
                            // extension to read.
                            if let format = sourceFormat, !format.formats.isEmpty {
                                SourceFormatPill(
                                    summary: format,
                                    isStills: capture.kind == .photos)
                                    .fixedSize()
                            }
                        }
                        .padding(.top, 2)

                        // Only on analysed projects, so an untagged library's
                        // cards keep exactly the height they always had.
                        if let tags = capture.sceneTags, !tags.isEmpty {
                            HStack(spacing: 6) {
                                SceneTagLine(tags: tags)
                                // Tagged by the app on its own, not from a run
                                // the user confirmed — worth marking, quietly.
                                // It sits inside the existing tag row, so it
                                // costs the card no height at all.
                                if capture.sceneTaggedAutomatically == true {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(LL.accent.opacity(0.7))
                                        .accessibilityLabel("Tagged automatically")
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .llCard(cornerRadius: 18)
        .contextMenu {
            Button {
                onPreview()
            } label: {
                Label(capture.isPhotoCapture ? "View photo" : "Play original",
                      systemImage: capture.isPhotoCapture ? "photo" : "play.rectangle")
            }
            if !capture.isPhotoCapture {
                Button {
                    onNewVersion()
                } label: {
                    Label("New blended clip", systemImage: "plus")
                }
            }
            Button {
                onOpen()
            } label: {
                Label("Project details", systemImage: "info.circle")
            }
            Divider()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete project", systemImage: "trash")
            }
        }
        .task(id: versions.count) {
            // nil is a cancelled walk (this row scrolled away) — leave the size
            // that is already on screen alone rather than showing "…" again.
            if let bytes = await model.storageBytes(for: capture) {
                projectBytes = bytes
            }
        }
        .task(id: capture.id) {
            guard capture.kind == .video else { return }
            // nil is a cancelled read — keep the line's current tail.
            if let summary = await model.burstClipSummary(for: capture) {
                burstSummary = summary
            }
        }
        .task(id: capture.id) {
            // nil is a cancelled read — keep whatever pill is already up.
            if let summary = await model.sourceFormatSummary(for: capture) {
                sourceFormat = summary
            }
        }
    }

    /// A photo project's tile is the photo itself; everything else shows its
    /// source media — an interval shoot skipping any opening frames the user
    /// nominated as bad.
    private var thumbnailURL: URL? {
        model.thumbnailURL(for: capture)
    }

    /// "4 source clips · 2 bursts at 120 fps": the clip count is knowable
    /// synchronously, the burst tail joins once the sequence sidecar has been
    /// read — and only when the shoot actually recorded bursts.
    private var sourceLine: String {
        let clips = capture.sourceMediaCount
        let base = clips == 1 ? "1 source clip" : "\(clips) source clips"
        guard let bursts = burstSummary?.label else { return base }
        return "\(base) · \(bursts)"
    }

    private var durationBadge: String {
        if capture.isPhotoCapture {
            return "Photo"
        }
        if capture.kind == .photos {
            // What the shoot has left to show, not what is on disk — a project
            // hiding two bad frames badges 248, and the viewer it opens has
            // exactly 248 places to stand.
            return "\(model.effectiveFrameCount(for: capture)) photos"
        }
        if let duration = capture.sourceDurationSeconds {
            return DurationFormatter.recordingTime(from: duration)
        }
        return "Video"
    }

    private func versionsLine(count: Int) -> String {
        let size = projectBytes.map(LLFormat.bytes)
        // A photo capture is a single asset: size only, never a version count.
        if capture.isPhotoCapture {
            return size ?? "…"
        }
        switch count {
        case 0: return size ?? "…"
        case 1: return size.map { "1 blended clip · \($0)" } ?? "1 blended clip"
        default: return size.map { "\(count) blended clips · \($0)" } ?? "\(count) blended clips"
        }
    }
}

/// "▣ DNG" · "▶ MOV FLAT" — what a project's SOURCE is, in one glance: stills
/// or footage (the icon), the file type they were written in (the text), and
/// whether the shoot was captured flat.
///
/// FLAT is tinted rather than set in the same grey as the rest, because it is
/// the one part that changes what the media LOOKS like — everything else in
/// the pill only describes it.
private struct SourceFormatPill: View {
    var summary: AppModel.SourceFormatSummary
    var isStills: Bool

    var body: some View {
        HStack(spacing: 3.5) {
            Image(systemName: isStills ? "photo" : "video")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(summary.formats.joined(separator: " · "))
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.secondary)
            if summary.flat {
                Text("FLAT")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(LL.accent)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(isStills ? "Source photos" : "Source video"): \(summary.label ?? "")")
    }
}


/// The PicPlace pill a card wears once its project has been synced — its own
/// view so the card re-renders on the controller's changes without the whole
/// list observing it.
private struct PicPlaceThumbnailPill: View {
    @ObservedObject var picplace: PicPlaceController
    let captureID: UUID

    var body: some View {
        if let state = picplace.listState(for: captureID) {
            PicPlacePill(state: state)
        }
    }
}

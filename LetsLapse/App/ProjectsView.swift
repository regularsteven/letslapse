import SwiftUI

/// One card per original, blended clips always visible as a thumbnail strip —
/// Library and Blends unified, with no expand/collapse state at all.
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
                    let library = sourceCaptures
                    let visible = library
                        .filtered(by: filter, isScan: model.isScannerProject)
                        .matching(query)
                    if library.isEmpty {
                        emptyState
                    } else if visible.isEmpty {
                        filteredEmptyState
                    } else {
                        ForEach(visible) { capture in
                            ProjectCard(
                                capture: capture,
                                onOpen: { path.append(capture.id) },
                                onNewVersion: { model.openCapture(capture) },
                                onOpenVersion: { blend in model.openBlend(blend) },
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
        .onAppear { consumeDetailRequest(model.requestedProjectDetailID) }
        .onReceive(model.$requestedProjectDetailID) { requested in
            consumeDetailRequest(requested)
        }
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
            Text("Projects")
                .font(.system(size: 34, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
                .padding(.trailing, 4)
                .padding(.top, 8)

            // Same segmented filter the Gallery grid uses, so the two tabs
            // narrow a library the same way.
            if sourceCaptures.isEmpty {
                // Nothing to filter — stand in for the bar's bottom padding so
                // the empty-state card doesn't butt against the title.
                Color.clear.frame(height: 8)
            } else {
                SceneSearchField(text: $query.text)
                    .padding(.top, 10)

                CaptureFilterBar(
                    selection: $filter,
                    filters: availableFilters,
                    counts: showsCounts ? filterCounts : nil)

                let tags = sourceCaptures.presentSceneTags
                if !tags.isEmpty {
                    // Bleeds past the row's trailing inset so a long chip row
                    // scrolls out to the screen edge rather than stopping short.
                    SceneTagChips(tags: tags, selection: $query.tags)
                        .padding(.bottom, 8)
                }
            }
        }
    }

    /// What this list is built from: the scan-free library, or everything —
    /// whichever the Layout setting leaves without another home.
    private var sourceCaptures: [AppModel.CaptureProject] {
        listsScans ? model.captures : model.libraryCaptures
    }

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
        let searched = sourceCaptures.matching(query)
        return availableFilters.reduce(into: [:]) { counts, filter in
            counts[filter] = searched
                .filter { filter.matches($0, isScan: model.isScannerProject($0)) }
                .count
        }
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
        guard model.captures.contains(where: { $0.id == requested }) else { return }
        path = [requested]
        // Clear once the emission has settled; writing back during it would
        // re-enter the publisher mid-publish.
        DispatchQueue.main.async {
            if model.requestedProjectDetailID == requested {
                model.requestedProjectDetailID = nil
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
    var onOpenVersion: (AppModel.BlendProject) -> Void
    var onPreview: () -> Void
    var onDelete: () -> Void

    @State private var projectBytes: Int64?
    @State private var burstSummary: AppModel.BurstClipSummary?

    var body: some View {
        let versions = model.blends(for: capture)

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
                        Text(versionsLine(count: versions.count))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(
                                versions.isEmpty || capture.isPhotoCapture
                                    ? Color.secondary : LL.accent)
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

            // A photo is one asset — no version strip, nothing to add.
            if !capture.isPhotoCapture {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(versions) { blend in
                            Button {
                                onOpenVersion(blend)
                            } label: {
                                ZStack(alignment: .bottomLeading) {
                                    ProjectThumbnailView(url: model.mediaURL(for: blend), kind: model.mediaKind(for: blend))
                                        .frame(width: 96, height: 54)
                                    MediaBadge(text: blend.badgeLabel, tint: LL.amber)
                                        .scaleEffect(0.78, anchor: .bottomLeading)
                                        .padding(4)
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        Button(action: onNewVersion) {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(
                                    Color.primary.opacity(0.18),
                                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                                )
                                .frame(width: versions.isEmpty ? 96 : 54, height: 54)
                                .overlay {
                                    Image(systemName: "plus")
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundStyle(LL.accent)
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("New blended clip")
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
            }
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

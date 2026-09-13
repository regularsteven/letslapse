import SwiftUI

// MARK: - Gallery (main container)

/// The Gallery tab: a searchable, filterable grid of all projects, with a
/// toggleable sidebar (Library / Tags / Collections / Shapes), a preview panel that
/// slides in on selection, and a Hero view reachable by double-clicking a tile.
///
/// Layout strategy
/// ───────────────
/// macOS and wide iPad (regular width):   sidebar | grid | preview panel  (HStack)
/// iPhone and narrow iPad (compact width): just the grid; sidebar and preview
///   are sheets.
struct GalleryView: View {
    @EnvironmentObject var model: AppModel
    /// Owned by ContentView so the tab bar can pop to the list.
    @Binding var path: [UUID]

    // MARK: Persistent state
    @AppStorage("gallery.showSidebar")   private var showSidebar   = true
    @AppStorage("gallery.sortKey")       private var sortKeyRaw    = ProjectSort.capture.rawValue
    @AppStorage("gallery.sortAscending") private var sortAscending = false
    @AppStorage("gallery.columnCount")   private var columnCount   = 3
    @AppStorage("gallery.timelineMode")  private var timelineMode  = false

    // MARK: Ephemeral state
    @State private var query       = SceneQuery.empty
    @State private var filter      = CaptureFilter.all
    @State private var shapeSelection = GalleryView.initialShapeSelection  // sidebar Shapes rows
    @State private var selectedID: UUID?          // single-click → preview panel
    @State private var showSidebarSheet  = false  // iPhone/compact only
    @State private var showPreviewSheet  = false  // iPhone/compact only
    @State private var deleteFailure: String?

    @Environment(\.horizontalSizeClass) private var hSizeClass
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var vSizeClass
    #endif

    private var isWide: Bool {
        #if os(macOS)
        return true
        #else
        return hSizeClass == .regular
        #endif
    }

    /// An iPhone held upright — the one width the full header row cannot fit.
    ///
    /// Idiom + vertical size class rather than the horizontal class alone: a
    /// Max/Plus iPhone in landscape reports regular width and takes the wide
    /// three-pane branch, a narrow iPad split reports compact width but has
    /// the height of a tablet, and neither is the 361pt column this decides for.
    private var isPhonePortrait: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone && vSizeClass == .regular
        #else
        return false
        #endif
    }

    /// `LL_SHAPES=ellipse,rectangle,square,empty` — Shapes rows lit from launch,
    /// for screenshots.
    private static var initialShapeSelection: Set<ShapeFilter> {
        #if DEBUG
        let raw = ProcessInfo.processInfo.environment["LL_SHAPES"] ?? ""
        return Set(raw.split(separator: ",").compactMap {
            ShapeFilter(rawValue: $0.trimmingCharacters(in: .whitespaces))
        })
        #else
        return []
        #endif
    }

    private var sortKey: ProjectSort {
        ProjectSort(rawValue: sortKeyRaw) ?? .capture
    }

    /// `LL_SELECT=latest|<capture-uuid>` — selects that tile on appear, which
    /// raises the preview panel (the iPhone's sheet), for screenshots: the
    /// panel is otherwise only reachable by a click no headless run can make.
    /// `latest` is the first tile in the current sort. Pair with
    /// `LL_TAB=gallery`; `LL_PANEL=presets` opens the panel's Presets row.
    private func consumeSelectHook() {
        #if DEBUG
        guard selectedID == nil,
              let raw = ProcessInfo.processInfo.environment["LL_SELECT"] else { return }
        let target = raw == "latest" ? sortedCaptures.first?.id : UUID(uuidString: raw)
        guard let target, model.libraryCaptures.contains(where: { $0.id == target }) else { return }
        selectedID = target
        #endif
    }

    // MARK: Body

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .bottom) {
                mainLayout
                    .background(LL.screenBackground)
            }
            .alert("Couldn't delete",
                   isPresented: Binding(
                       get: { deleteFailure != nil },
                       set: { if !$0 { deleteFailure = nil } }
                   )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deleteFailure ?? "")
            }
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #else
            .navigationTitle("Gallery")
            #endif
            .navigationDestination(for: UUID.self) { captureID in
                ProjectDetailView(captureID: captureID)
            }
            // External navigation requests (from Settings or other tabs).
            .onAppear   { consumeDetailRequest(model.requestedProjectDetailID) }
            .onReceive(model.$requestedProjectDetailID) { consumeDetailRequest($0) }
            // The Shapes rows read each project's `shapes.json`; re-check on every visit.
            .onAppear   { model.refreshShapeSummaries() }
            .onAppear   { consumeSelectHook() }
        }
        // iPhone/compact: sidebar sheet
        .sheet(isPresented: $showSidebarSheet) {
            NavigationStack {
                GallerySidebar(
                    filter: $filter,
                    tagSelection: $query.tags,
                    shapeSelection: $shapeSelection,
                    allCaptures: visibleCaptures
                )
                .navigationTitle("Library")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showSidebarSheet = false }
                    }
                }
            }
        }
        // iPhone/compact: preview sheet
        .sheet(isPresented: $showPreviewSheet) {
            if let id = selectedID,
               let capture = model.libraryCaptures.first(where: { $0.id == id }) {
                NavigationStack {
                    GalleryPreviewPanel(
                        capture: capture,
                        onOpen:    { path.append(capture.id); showPreviewSheet = false },
                        // The flow rises over the tabs, not over this sheet —
                        // left up, the sheet would hide it.
                        onNewClip: { model.openCapture(capture); showPreviewSheet = false },
                        onDelete:  { delete(capture); showPreviewSheet = false }
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showPreviewSheet = false }
                        }
                    }
                }
            }
        }
    }

    // MARK: Layout

    @ViewBuilder
    private var mainLayout: some View {
        if isWide {
            HStack(spacing: 0) {
                if showSidebar {
                    GallerySidebar(
                        filter: $filter,
                        tagSelection: $query.tags,
                        shapeSelection: $shapeSelection,
                        allCaptures: visibleCaptures
                    )
                    .frame(width: 200)
                    Divider()
                }

                VStack(spacing: 0) {
                    galleryHeader
                    Divider()
                    GalleryGridContent(
                        captures:     sortedCaptures,
                        columnCount:  columnCount,
                        timelineMode: timelineMode,
                        selectedID:   $selectedID,
                        onOpen: { path.append($0) }
                    )
                }

                if let id = selectedID,
                   let capture = model.libraryCaptures.first(where: { $0.id == id }) {
                    Divider()
                    GalleryPreviewPanel(
                        capture: capture,
                        onOpen:    { path.append(capture.id) },
                        onNewClip: { model.openCapture(capture) },
                        onDelete:  { delete(capture) }
                    )
                    .frame(width: 300)
                }
            }
        } else {
            // Compact: just the grid + header
            VStack(spacing: 0) {
                galleryHeader
                Divider()
                GalleryGridContent(
                    captures:     sortedCaptures,
                    columnCount:  columnCount,
                    timelineMode: timelineMode,
                    selectedID:   $selectedID,
                    onOpen: { path.append($0) }
                )
            }
            // On compact devices, single-click opens the preview sheet.
            .onChange(of: selectedID) { id in
                if id != nil { showPreviewSheet = true }
            }
        }
    }

    // MARK: Header

    /// Two forms of one header. The full row — library toggle, title, search,
    /// sort, zoom slider, Timeline — is about 691pt wide and has nothing that
    /// collapses, so on an upright iPhone SwiftUI crushed the title to zero
    /// width (it wrapped one glyph per line, which is where the ~180pt blank
    /// band came from) and laid the whole column out wider than the screen,
    /// grid included. iPhone portrait gets the compact row instead.
    @ViewBuilder
    private var galleryHeader: some View {
        if isPhonePortrait {
            compactHeader
        } else {
            fullHeader
        }
    }

    /// iPhone portrait: the tab's large title, with the three controls that
    /// earn a seat on a 361pt row opposite it — library (the sheet that holds
    /// the kind and tag filters), sort, and the Timeline toggle as a glyph.
    ///
    /// No search field here by decision (Steven, 2026-09-08): the row is for
    /// filter · order · mode, and search on a phone was costing the whole
    /// header. No zoom slider either — the grid already takes a pinch over
    /// the same 2–6 columns, through the same `gallery.columnCount` key.
    /// Rhythm matches the Projects tab: 34pt title 15pt down and 20pt in,
    /// controls centred 6pt above its baseline like the sharing chip there.
    private var compactHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Gallery")
                .font(.system(size: 34, weight: .bold))
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                libraryButton
                sortControl
                timelineGlyphToggle
            }
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.top, 15)
        .padding(.bottom, 10)
    }

    /// Mac, iPad and iPhone landscape: the single toolbar row. The search
    /// field yields down to 120pt before anything else gives, which is what
    /// keeps a small iPhone's landscape row (an SE has 635pt to work in) from
    /// overflowing the way portrait did.
    private var fullHeader: some View {
        HStack(spacing: 10) {
            libraryButton

            Spacer(minLength: 0)

            Text("Gallery")
                .font(.system(size: 20, weight: .bold))

            Spacer(minLength: 0)

            // Search
            SceneSearchField(text: $query.text, placeholder: "Search titles, tags, in frame")
                .frame(minWidth: 120, idealWidth: 190, maxWidth: 190)

            // Sort menu
            sortControl

            // Zoom slider
            HStack(spacing: 4) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(columnCount) },
                        set: { columnCount = Int($0.rounded()) }
                    ),
                    in: 2...6,
                    step: 1
                )
                .frame(width: 80)
                Image(systemName: "square.grid.3x3")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // Timeline toggle
            Toggle(isOn: $timelineMode) {
                Label("Timeline", systemImage: "calendar")
                    .font(.system(size: 13))
            }
            .toggleStyle(.button)
            .tint(LL.accent)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// ▤ Library — collapses the sidebar where it is inline, opens it as a
    /// sheet where it is not.
    ///
    /// The accent glyph means "the pane is open" on the wide layout and "the
    /// library is narrowed" on the compact one: `showSidebar` is a Mac pane
    /// state, and reading it on an iPhone lit the button permanently.
    private var libraryButton: some View {
        let isLit = isWide ? showSidebar : (filter != .all || !query.tags.isEmpty || !shapeSelection.isEmpty)
        return Button {
            if isWide {
                withAnimation(.easeInOut(duration: 0.22)) { showSidebar.toggle() }
            } else {
                showSidebarSheet = true
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isLit ? LL.accent : .secondary)
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isWide ? (showSidebar ? "Hide library sidebar" : "Show library sidebar") : "Library")
        .accessibilityValue(isWide ? "" : (isLit ? "Filtered" : "All projects"))
    }

    /// The Timeline toggle as a 32pt square, the library button's twin: accent
    /// glyph while timeline mode is on, secondary while the grid is plain.
    private var timelineGlyphToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { timelineMode.toggle() }
        } label: {
            Image(systemName: "calendar")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(timelineMode ? LL.accent : .secondary)
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Timeline")
        .accessibilityValue(timelineMode ? "On" : "Off")
        .accessibilityAddTraits(timelineMode ? .isSelected : [])
    }

    // MARK: Sort control

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
                    Text(sortKey.label)
                        .font(.system(size: 13, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(LL.accent)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                sortAscending.toggle()
            } label: {
                Image(systemName: sortAscending ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LL.accent)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(sortAscending ? "Ascending" : "Descending")
        }
    }

    // MARK: Data pipeline

    /// The library after filtering by type, search and the sidebar's Shapes rows.
    private var visibleCaptures: [AppModel.CaptureProject] {
        let base = model.libraryCaptures
            .filtered(by: filter)
            .matching(query)
        guard !shapeSelection.isEmpty else { return base }
        return base.filter { shapeSelection.allows(model.shapeSummaries[$0.id]) }
    }

    /// Filtered then sorted.
    private var sortedCaptures: [AppModel.CaptureProject] {
        let filtered = visibleCaptures
        let ascending: [AppModel.CaptureProject]
        switch sortKey {
        case .capture:
            ascending = filtered.sorted { $0.createdAt < $1.createdAt }
        case .added:
            ascending = filtered.sorted {
                (model.addedAt($0), $0.createdAt) < (model.addedAt($1), $1.createdAt)
            }
        case .edit:
            ascending = filtered.sorted { model.lastEdited($0) < model.lastEdited($1) }
        case .size:
            ascending = filtered.sorted {
                ($0.sizeBytes ?? -1, $0.createdAt) < ($1.sizeBytes ?? -1, $1.createdAt)
            }
        }
        return sortAscending ? ascending : ascending.reversed()
    }

    // MARK: Actions

    private func delete(_ capture: AppModel.CaptureProject) {
        do {
            try withAnimation { try model.deleteCapture(capture) }
            if selectedID == capture.id { selectedID = nil }
        } catch {
            deleteFailure = error.localizedDescription
        }
    }

    private func consumeDetailRequest(_ requested: UUID?) {
        guard let requested else { return }
        guard model.captures.contains(where: { $0.id == requested }) else { return }
        path = [requested]
        DispatchQueue.main.async {
            if model.requestedProjectDetailID == requested {
                model.requestedProjectDetailID = nil
            }
        }
    }
}

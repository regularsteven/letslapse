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
///
/// The item view (macOS, 2026-09-13 — see GalleryItemView.swift): with a
/// project in `focus` the same three columns change mode instead of pushing a
/// screen — Library → inspector on the left, grid + pane → editor with its own
/// rail in the middle and right — and a filmstrip runs under them. Open, Edit,
/// Text and Shapes all lead here; the Mac's editor windows are no longer the
/// Gallery's door to the editor.
struct GalleryView: View {
    @EnvironmentObject var model: AppModel
    /// Owned by ContentView so the tab bar can pop to the list.
    @Binding var path: [UUID]
    /// The item view's project — owned by ContentView too, for the same
    /// reason: the tab's view is rebuilt on every tab switch.
    @Binding var focus: GalleryFocus?

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
    /// One tile → the preview panel; more → batch mode (GallerySelection).
    @State private var selection = GallerySelection()
    @State private var showSidebarSheet  = false  // iPhone/compact only
    @State private var showPreviewSheet  = false  // iPhone/compact only
    @State private var showBatchSheet    = false  // iPhone/compact only
    @State private var deleteFailure: String?
    /// A tile the keyboard moved the selection to, for the grid to scroll to.
    @State private var scrollTarget: UUID?
    /// The item view's way out: the editor is asked to leave (so its exit path
    /// runs — the debounced writes, the library flush, the Back button's
    /// preset offer), and `itemTransition` says where to go once it has.
    @State private var exitRequest: EditorExitRequest?
    @State private var itemTransition: ItemTransition?

    /// Where the editor goes once it has left: back to the grid, or on to the
    /// project the filmstrip (or an arrow) named.
    private enum ItemTransition: Equatable {
        case back
        case move(GalleryFocus)
    }
    #if os(macOS)
    /// The Gallery's keys — see `installKeyboardShortcuts`.
    @State private var keyMonitor: Any?
    @State private var hostWindow: NSWindow?
    #endif

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

    /// `LL_SELECT=latest|all|multiple|<capture-uuid>[,…]` — selects on appear,
    /// for screenshots: the preview panel is otherwise only reachable by a
    /// click no headless run can make. `latest` is the first tile in the
    /// current sort; `all` selects every visible tile (batch mode, as ⌘A
    /// does); `multiple` enters selection mode with nothing selected (the
    /// tile menu's Select Multiple); a UUID selects that tile, and a comma
    /// list of them a batch. Pair with `LL_TAB=gallery`; `LL_PANEL=presets`
    /// opens the panel's Presets row.
    private func consumeSelectHook() {
        #if DEBUG
        guard selection.isEmpty, !selection.isSelecting,
              let raw = ProcessInfo.processInfo.environment["LL_SELECT"] else { return }
        let visible = sortedCaptures.map(\.id)
        for token in raw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch token {
            case "all": selection.selectAll(visible)
            case "multiple": selection.isSelecting = true
            case "latest": if let id = visible.first { selection.toggle(id) }
            default:
                if let id = UUID(uuidString: token), visible.contains(id) { selection.toggle(id) }
            }
        }
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
            .navigationTitle(focusedCapture?.displayTitle ?? "Gallery")
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
            .onAppear   { consumeItemHook() }
            #if DEBUG
            .onAppear {
                if let hooked = ListDebugHooks.filter { filter = hooked }
                if let text = ListDebugHooks.queryText { query.text = text }
                if let chips = ListDebugHooks.chips { query.tags = chips }
            }
            .onChange(of: sortedCaptures.map(\.id), initial: true) { _, ids in
                ListDebugHooks.dump(screen: "gallery", sort: sortKey.rawValue, ascending: sortAscending, filter: filter, query: query, ids: ids)
            }
            #endif
            // A focused project that leaves the library (deleted here, or
            // from another tab) takes the item view with it — there is no
            // editor left to ask.
            .onChange(of: model.libraryCaptures.map(\.id)) { _, ids in
                if let focus, !ids.contains(focus.captureID) { self.focus = nil }
            }
            // A filter or search that hides a selected tile drops it from the
            // selection, so "N selected" only ever counts what is on screen.
            .onChange(of: sortedCaptures.map(\.id)) { _, visible in
                selection.keepOnly(visible)
            }
            #if os(macOS)
            .background(WindowReader(window: $hostWindow))
            .onAppear { installKeyboardShortcuts() }
            .onDisappear { removeKeyboardShortcuts() }
            #endif
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
        // iPhone/compact: the batch panel, raised by the selection row's Edit
        .sheet(isPresented: $showBatchSheet) {
            NavigationStack {
                GalleryBatchPanel(captures: batchCaptures)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showBatchSheet = false }
                        }
                    }
            }
        }
        // iPhone/compact: preview sheet
        .sheet(isPresented: $showPreviewSheet) {
            if let id = selection.single,
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
            wideLayout
        } else {
            // Compact: just the grid + header
            VStack(spacing: 0) {
                galleryHeader
                Divider()
                GalleryGridContent(
                    captures:     sortedCaptures,
                    columnCount:  columnCount,
                    timelineMode: timelineMode,
                    selection:    $selection,
                    scrollTarget: $scrollTarget,
                    onOpen: { path.append($0) }
                )
            }
            // On compact devices a plain tap opens the preview sheet; in
            // selection mode taps toggle and the sheet stays down. Closing
            // the sheet clears the selection, so the same tile can be tapped
            // straight back open.
            .onChange(of: selection) { _, next in
                if !next.isSelecting, !next.isBatch, next.single != nil { showPreviewSheet = true }
            }
            .onChange(of: showPreviewSheet) { _, shown in
                if !shown, !selection.isSelecting, !selection.isBatch { selection.deselectAll() }
            }
        }
    }

    /// The selected projects in the grid's order — what the batch panel
    /// edits and what its preset tiles are previewed on (the first).
    private var batchCaptures: [AppModel.CaptureProject] {
        sortedCaptures.filter { selection.ids.contains($0.id) }
    }

    // MARK: Wide layout (grid mode and the item view)

    /// The Gallery's column widths. The pane and the editor's rail share one
    /// width (the rail's 330, `railWidth(in:)` in both editors) so the
    /// right-hand divider never moves between the grid and the item view; the
    /// left column widens from the Library's 200 to the inspector's 330 on
    /// the way in. Set `sidebar` to 330 to try the version where nothing
    /// moves at all.
    private enum GalleryColumns {
        static let sidebar: CGFloat = 200
        static let inspector: CGFloat = 330
        static let pane: CGFloat = 330
    }

    /// The project the item view is showing — `focus` resolved against the
    /// library, nil once it is gone.
    private var focusedCapture: AppModel.CaptureProject? {
        guard let focus else { return nil }
        return model.libraryCaptures.first { $0.id == focus.captureID }
    }

    /// One `HStack` for both modes, so the columns swap content in place: the
    /// left column is the Library or the inspector, the rest of the row is
    /// the grid with its pane or the editor with its rail. The filmstrip is
    /// a row under the whole thing, full width.
    private var wideLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if showSidebar {
                    leftColumn
                        .frame(width: focusedCapture == nil
                               ? GalleryColumns.sidebar : GalleryColumns.inspector)
                    Divider()
                }

                if let focus, let capture = focusedCapture {
                    itemColumn(focus: focus, capture: capture)
                        .transition(.opacity)
                } else {
                    gridColumn
                        .transition(.opacity)
                    paneColumn
                        .transition(.opacity)
                }
            }

            if let focus, focusedCapture != nil {
                Divider()
                GalleryFilmstrip(
                    captures: sortedCaptures,
                    focusedID: focus.captureID,
                    onSelect: { move(to: $0) })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    /// Library in grid mode, the project's inspector in the item view — the
    /// preview panel in its `.inspector` dress: what the project is and what
    /// came of it, with the editor doing the rest beside it.
    @ViewBuilder
    private var leftColumn: some View {
        if let capture = focusedCapture {
            GalleryPreviewPanel(
                capture: capture,
                onOpen:    {},
                onNewClip: { model.openCapture(capture) },
                onDelete:  { delete(capture) },
                style: .inspector
            )
            .transition(.opacity)
        } else {
            GallerySidebar(
                filter: $filter,
                tagSelection: $query.tags,
                shapeSelection: $shapeSelection,
                allCaptures: visibleCaptures
            )
            .transition(.opacity)
        }
    }

    private var gridColumn: some View {
        VStack(spacing: 0) {
            galleryHeader
            Divider()
            GalleryGridContent(
                captures:     sortedCaptures,
                columnCount:  columnCount,
                timelineMode: timelineMode,
                selection:    $selection,
                scrollTarget: $scrollTarget,
                onOpen: { open($0) },
                onEdit: gridEditHandler
            )
        }
    }

    /// The item view is the Mac's (2026-09-13). Elsewhere the panel and the
    /// tile menu keep their own doors to the editor — the iPad's cover has
    /// chrome of its own that a column of the Gallery cannot host yet.
    private var gridEditHandler: ((UUID) -> Void)? {
        #if os(macOS)
        return { id in
            if let capture = model.libraryCaptures.first(where: { $0.id == id }) {
                enterItem(capture, page: .editor)
            }
        }
        #else
        return nil
        #endif
    }

    private func paneEditHandler(for capture: AppModel.CaptureProject) -> ((RailTab) -> Void)? {
        #if os(macOS)
        return { page in enterItem(capture, page: page) }
        #else
        return nil
        #endif
    }

    /// The pane: the batch panel over more than one project, the preview
    /// panel over exactly one, nothing over none.
    @ViewBuilder
    private var paneColumn: some View {
        if selection.isBatch {
            Divider()
            GalleryBatchPanel(captures: batchCaptures)
                .frame(width: GalleryColumns.pane)
        } else if let id = selection.single,
                  let capture = model.libraryCaptures.first(where: { $0.id == id }) {
            Divider()
            GalleryPreviewPanel(
                capture: capture,
                onOpen:    { open(capture.id) },
                onNewClip: { model.openCapture(capture) },
                onDelete:  { delete(capture) },
                onEdit:    paneEditHandler(for: capture)
            )
            .frame(width: GalleryColumns.pane)
        }
    }

    /// The item view's middle and right: its header where the grid's was,
    /// then the editor — media beside its own rail.
    private func itemColumn(focus: GalleryFocus, capture: AppModel.CaptureProject) -> some View {
        VStack(spacing: 0) {
            itemHeader(capture)
            Divider()
            GalleryItemEditor(
                focus: focus,
                exitRequest: exitRequest,
                onExit: completeItemTransition)
        }
    }

    /// The grid header's row, in the item view: the library toggle keeps its
    /// seat (it now collapses the inspector), Back beside it, the project's
    /// name where "Gallery" was, and its place in the filmstrip trailing.
    private func itemHeader(_ capture: AppModel.CaptureProject) -> some View {
        HStack(spacing: 10) {
            libraryButton

            Button {
                leaveItem()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Gallery")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(LL.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to the gallery")

            Spacer(minLength: 0)

            Text(capture.displayTitle)
                .font(.system(size: 16, weight: .bold))
                .lineLimit(1)

            Spacer(minLength: 0)

            if let position = filmstripPosition {
                Text("\(position.index) of \(position.count)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
    }

    /// "3 of 48": where the focused project sits in the grid's order.
    private var filmstripPosition: (index: Int, count: Int)? {
        guard let focus,
              let index = sortedCaptures.firstIndex(where: { $0.id == focus.captureID })
        else { return nil }
        return (index + 1, sortedCaptures.count)
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
        if selection.showsSelectionHeader {
            selectionHeader
        } else if isPhonePortrait {
            compactHeader
        } else {
            fullHeader
        }
    }

    // MARK: Selection header

    /// The row that stands in for the header while the Gallery is selecting
    /// (2026-09-13): Done leading, "N selected" as the title, Select All /
    /// Deselect All trailing — and on the phone, where there is no pane, the
    /// Edit button that raises the batch sheet. Search, sort, zoom and
    /// Timeline are not here on purpose: a selection is a set of tiles in
    /// one order, and re-sorting or re-filtering under it would change what
    /// "N selected" means.
    private var selectionHeader: some View {
        let all = sortedCaptures.map(\.id)
        let allSelected = !all.isEmpty && selection.ids.count == all.count
        return HStack(spacing: 10) {
            Button("Done") {
                withAnimation(.easeInOut(duration: 0.2)) { selection.clear() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(LL.accent)

            Spacer(minLength: 0)

            Text(selection.ids.isEmpty ? "Select projects" : "\(selection.ids.count) selected")
                .font(.system(size: isPhonePortrait ? 17 : 20, weight: .bold))
                .lineLimit(1)

            Spacer(minLength: 0)

            Button(allSelected ? "Deselect All" : "Select All") {
                if allSelected { selection.deselectAll() } else { selection.selectAll(all) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(LL.accent)
            .disabled(all.isEmpty)

            if !isWide {
                Button {
                    showBatchSheet = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(selection.isBatch ? LL.accent : .secondary)
                        .frame(width: 32, height: 32)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(!selection.isBatch)
                .accessibilityLabel("Edit selected projects")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, isPhonePortrait ? 12 : 10)
        .frame(minHeight: isPhonePortrait ? 0 : 52)
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
            selection.remove(capture.id)
            if focus?.captureID == capture.id { focus = nil }
        } catch {
            deleteFailure = error.localizedDescription
        }
    }

    /// Open — a double-click, the panel's Open, ⏎, the tile menu: the item
    /// view on the Mac, the project screen elsewhere (and on the Mac when the
    /// project has nothing the editor can open).
    private func open(_ id: UUID) {
        #if os(macOS)
        if let capture = model.libraryCaptures.first(where: { $0.id == id }),
           enterItem(capture, page: .editor) {
            return
        }
        #endif
        path.append(id)
    }

    // MARK: Item view

    /// Enters the item view on `capture`, the editor on `page`. False when
    /// the project has no asset to open on. The tile is selected too, so the
    /// grid is on it on the way back.
    @discardableResult
    private func enterItem(_ capture: AppModel.CaptureProject, page: RailTab) -> Bool {
        guard let request = model.stageEditor(for: capture, page: page) else { return false }
        selection.select(only: capture.id)
        scrollTarget = capture.id
        withAnimation(.easeInOut(duration: 0.25)) {
            focus = GalleryFocus(request: request, page: page)
        }
        return true
    }

    /// Back: through the editor's own exit, offer and all.
    private func leaveItem() {
        guard focus != nil else { return }
        itemTransition = .back
        exitRequest = EditorExitRequest(offersPresetSave: true)
    }

    /// The filmstrip (or an arrow): the current editor leaves — writes made,
    /// no offer in the way — and the next project's editor takes its place.
    /// The page carries over where the next editor has it; a video has no
    /// Masks page, so that one falls back to Editor.
    private func move(to id: UUID) {
        guard let focus, id != focus.captureID, itemTransition == nil,
              let capture = sortedCaptures.first(where: { $0.id == id }) else { return }
        let page: RailTab = (capture.kind == .video && focus.page == .masks) ? .editor : focus.page
        guard let request = model.stageEditor(for: capture, page: page) else { return }
        itemTransition = .move(GalleryFocus(request: request, page: page))
        exitRequest = EditorExitRequest(offersPresetSave: false)
    }

    /// ← / → in the item view: the neighbour in the grid's order.
    private func step(_ delta: Int) {
        guard let focus,
              let index = sortedCaptures.firstIndex(where: { $0.id == focus.captureID })
        else { return }
        let next = index + delta
        guard sortedCaptures.indices.contains(next) else { return }
        move(to: sortedCaptures[next].id)
    }

    /// The editor has left. Go where the transition said.
    private func completeItemTransition() {
        let transition = itemTransition
        itemTransition = nil
        exitRequest = nil
        switch transition {
        case .move(let next):
            selection.select(only: next.captureID)
            scrollTarget = next.captureID
            withAnimation(.easeInOut(duration: 0.2)) { focus = next }
        case .back, nil:
            withAnimation(.easeInOut(duration: 0.25)) { focus = nil }
        }
    }

    /// `LL_ITEM=latest|<capture-uuid>[:editor|text|frames|masks]` — the item
    /// view open from launch, for screenshots. `latest` is the first tile in
    /// the current sort. Pair with `LL_TAB=gallery`.
    private func consumeItemHook() {
        #if DEBUG && os(macOS)
        guard focus == nil,
              let raw = ProcessInfo.processInfo.environment["LL_ITEM"] else { return }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        let page = parts.count > 1 ? (RailTab(rawValue: parts[1].capitalized) ?? .editor) : .editor
        let capture: AppModel.CaptureProject?
        if parts[0] == "latest" {
            capture = sortedCaptures.first
        } else {
            capture = UUID(uuidString: parts[0]).flatMap { id in sortedCaptures.first { $0.id == id } }
        }
        if let capture { enterItem(capture, page: page) }
        #endif
    }

    #if os(macOS)
    /// The Gallery's keyboard (2026-09-13): ⌘A selects every tile the sidebar
    /// and the search field leave visible, ⌘D selects none, the arrows move
    /// the selection to the neighbouring tile (⇧ grows the run by it instead),
    /// and 0–5 set the star rating on every selected project — 0 clears it.
    /// A local key monitor rather than `keyboardShortcut` buttons, because
    /// those would take ⌘A and the digits away from a focused text field
    /// (the search field, a metadata row); this steps aside while the first
    /// responder is text, and answers only in the window the Gallery is in —
    /// an editor window's keys are not this one.
    private func installKeyboardShortcuts() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = event.window,
                  !(window.firstResponder is NSTextView) else { return event }
            // The arrows report `.numericPad` and `.function` on a real
            // keyboard (AppKit counts them as keypad and function keys), and
            // neither is a modifier anyone holds — drop them so a plain arrow
            // reads as plain.
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function])
            let key = event.charactersIgnoringModifiers ?? ""
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard window === hostWindow else { return false }
                // The item view: ← → walk the filmstrip, ⎋ leaves. The rest
                // of the Gallery's keys are the grid's.
                if focus != nil {
                    guard flags.isEmpty else { return false }
                    if event.keyCode == 53 { leaveItem(); return true }   // ⎋
                    switch Self.arrow(for: event) {
                    case .left?:  step(-1); return true
                    case .right?: step(1);  return true
                    default: return false
                    }
                }
                // ⏎ on one selected tile opens it.
                if flags.isEmpty, event.keyCode == 36 || event.keyCode == 76,
                   !selection.isSelecting, let id = selection.single {
                    open(id)
                    return true
                }
                if flags == .command, key == "a" {
                    selection.selectAll(sortedCaptures.map(\.id))
                    return true
                }
                if flags == .command, key == "d" {
                    selection.deselectAll()
                    return true
                }
                if let arrow = Self.arrow(for: event), flags.subtracting(.shift).isEmpty {
                    moveSelection(arrow, extending: flags.contains(.shift))
                    return true
                }
                if flags.isEmpty, key.count == 1, let digit = Int(key), (0...5).contains(digit),
                   !selection.isEmpty {
                    rateSelection(digit)
                    return true
                }
                return false
            }
            return handled ? nil : event
        }
    }

    /// By key code first: the arrows' codes are the same on every layout,
    /// and a posted event (the run skill's `hid key right`) carries the code
    /// but not always the function-key character `specialKey` is read from.
    private static func arrow(for event: NSEvent) -> GalleryArrow? {
        switch event.keyCode {
        case 123: return .left
        case 124: return .right
        case 126: return .up
        case 125: return .down
        default: break
        }
        switch event.specialKey {
        case .leftArrow?: return .left
        case .rightArrow?: return .right
        case .upArrow?: return .up
        case .downArrow?: return .down
        default: return nil
        }
    }

    /// The grid as rows, the way it is drawn — the standard grid by its
    /// column count, the timeline by its day groups five across.
    private var gridRows: [[UUID]] {
        if timelineMode {
            return timelineGroups(sortedCaptures).flatMap {
                GallerySelection.rows($0.captures.map(\.id), columns: timelineColumnCount)
            }
        }
        return GallerySelection.rows(sortedCaptures.map(\.id), columns: max(2, columnCount))
    }

    /// An arrow: from the anchor (or the first tile, with nothing selected)
    /// to its neighbour, selecting that alone — or, with ⇧, adding it.
    private func moveSelection(_ arrow: GalleryArrow, extending: Bool) {
        let rows = gridRows
        guard let first = rows.first?.first else { return }
        let from = selection.anchor ?? selection.ids.first
        let target: UUID
        if let from, let next = GallerySelection.neighbour(of: from, in: rows, arrow) {
            target = next
        } else if from == nil {
            target = first
        } else {
            return
        }
        if extending { selection.add(target) } else { selection.select(only: target) }
        scrollTarget = target
    }

    /// 1–5 stars on every selected project, 0 none — the same write the
    /// panels' star rows make, project scope.
    private func rateSelection(_ stars: Int) {
        for capture in sortedCaptures where selection.ids.contains(capture.id) {
            model.setMetadata(.integer(stars), for: .rating, on: capture, scope: .project)
        }
    }

    private func removeKeyboardShortcuts() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
    #endif

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

#if os(macOS)
/// Hands the NSWindow a SwiftUI view ends up in to its owner — the ⌘A monitor
/// needs to know which window's events are its own.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if window !== view.window { DispatchQueue.main.async { window = view.window } }
    }
}
#endif

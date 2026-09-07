import SwiftUI

// MARK: - Gallery (main container)

/// The Gallery tab: a searchable, filterable grid of all projects, with a
/// toggleable sidebar (Library / Tags / Collections), a preview panel that
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
    @State private var selectedID: UUID?          // single-click → preview panel
    @State private var showSidebarSheet  = false  // iPhone/compact only
    @State private var showPreviewSheet  = false  // iPhone/compact only
    @State private var deleteFailure: String?

    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var isWide: Bool {
        #if os(macOS)
        return true
        #else
        return hSizeClass == .regular
        #endif
    }

    private var sortKey: ProjectSort {
        ProjectSort(rawValue: sortKeyRaw) ?? .capture
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
        }
        // iPhone/compact: sidebar sheet
        .sheet(isPresented: $showSidebarSheet) {
            NavigationStack {
                GallerySidebar(
                    filter: $filter,
                    tagSelection: $query.tags,
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
                        onOpen:   { path.append(capture.id); showPreviewSheet = false },
                        onDelete: { delete(capture); showPreviewSheet = false }
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
                        onOpen:   { path.append(capture.id) },
                        onDelete: { delete(capture) }
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

    private var galleryHeader: some View {
        HStack(spacing: 10) {
            // ▤ Library toggle
            Button {
                if isWide {
                    withAnimation(.easeInOut(duration: 0.22)) { showSidebar.toggle() }
                } else {
                    showSidebarSheet = true
                }
            } label: {
                Image(systemName: showSidebar ? "sidebar.left" : "sidebar.left")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(showSidebar ? LL.accent : .secondary)
                    .frame(width: 32, height: 32)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showSidebar ? "Hide library sidebar" : "Show library sidebar")

            Spacer(minLength: 0)

            Text("Gallery")
                .font(.system(size: 20, weight: .bold))

            Spacer(minLength: 0)

            // Search
            SceneSearchField(text: $query.text, placeholder: "Search titles, tags, in frame")
                .frame(width: 190)

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

    /// The library after filtering by type and search.
    private var visibleCaptures: [AppModel.CaptureProject] {
        model.libraryCaptures
            .filtered(by: filter)
            .matching(query)
    }

    /// Filtered then sorted.
    private var sortedCaptures: [AppModel.CaptureProject] {
        let filtered = visibleCaptures
        let ascending: [AppModel.CaptureProject]
        switch sortKey {
        case .capture:
            ascending = filtered.sorted { $0.createdAt < $1.createdAt }
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

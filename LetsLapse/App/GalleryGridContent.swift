import SwiftUI

// MARK: - Gallery grid

/// The main content area of the Gallery tab.
///
/// Two modes:
/// - **Default**: adaptive-column grid of 4:3 tiles (column density controlled
///   by `columnCount`, shared with the photo-browser grid through the
///   `gallery.columnCount` AppStorage key).
/// - **Timeline**: tiles grouped by shoot day under date headers, with a
///   month scrubber rail on the trailing edge.
struct GalleryGridContent: View {
    @EnvironmentObject var model: AppModel
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    var captures: [AppModel.CaptureProject]
    var columnCount: Int
    var timelineMode: Bool
    @Binding var selection: GallerySelection
    /// A tile the keyboard moved the selection to; the grid scrolls it into
    /// view and clears the request.
    @Binding var scrollTarget: UUID?
    var onOpen: (UUID) -> Void    // double-click or "Open" action
    /// The tile menu's Edit, when the host has a place of its own for the
    /// editor (the Gallery's item view on the Mac); nil opens the editor the
    /// way the menu always did — a window on the Mac, a cover on iOS.
    var onEdit: ((UUID) -> Void)? = nil

    // Shared zoom-level key — pinch on either grid keeps them in sync.
    @AppStorage("gallery.columnCount") private var storedColumnCount = 3
    #if os(iOS)
    /// The editor the tile menu's Edit presents (a window on the Mac).
    @State private var editorRequest: EditorOpenRequest?
    #endif

    var body: some View {
        Group {
            if captures.isEmpty {
                emptyState
            } else if timelineMode {
                TimelineGalleryGrid(
                    captures: captures,
                    selection: $selection,
                    scrollTarget: $scrollTarget,
                    onTap: { capture, order in tap(capture, order: order) },
                    onOpen: onOpen,
                    menu: { capture in tileContextMenu(for: capture) }
                )
            } else {
                standardGrid
            }
        }
        #if os(iOS)
        .editorCover($editorRequest)
        #endif
    }

    // MARK: Standard grid

    private var standardGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    LazyVGrid(
                        columns: columns,
                        spacing: 12
                    ) {
                        ForEach(captures) { capture in
                            GalleryTile(
                                capture: capture,
                                isSelected: selection.ids.contains(capture.id),
                                showsCircle: selection.showsCircles,
                                onTap:       { tap(capture, order: captures.map(\.id)) },
                                onToggle:    { selection.toggle(capture.id) },
                                onOpen:      { onOpen(capture.id) },
                                onOutsideTap: { deselectAllFromBackground() }
                            )
                            .id(capture.id)
                            .contextMenu { tileContextMenu(for: capture) }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    // Clearance for the floating tab bar.
                    Color.clear.frame(height: 82)
                }
            }
            // The margins, the gaps between tiles and the empty space under a
            // short grid: a click there selects none. On the scroll view, not
            // the content, so it covers the whole pane; the tiles' own
            // gestures take the clicks on them.
            .contentShape(Rectangle())
            .onTapGesture { deselectAllFromBackground() }
            .onChange(of: scrollTarget) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id) }
                scrollTarget = nil
            }
        }
        .scrollContentBackground(.hidden)
        .gesture(
            MagnificationGesture()
                .onEnded { scale in
                    let next = scale < 1
                        ? min(storedColumnCount + 1, 6)
                        : max(storedColumnCount - 1, 2)
                    withAnimation(.easeInOut(duration: 0.2)) { storedColumnCount = next }
                }
        )
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 12),
            count: max(2, columnCount)
        )
    }

    // MARK: Selection

    /// A click in the gaps or the margins: nothing selected. Selection mode
    /// (Select Multiple) stays on; the circles just empty.
    private func deselectAllFromBackground() {
        guard !selection.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.15)) { selection.deselectAll() }
    }

    /// A tap on a tile. On the Mac the modifiers decide first — ⌘ toggles the
    /// tile, ⇧ selects the run from the anchor to it in `order` (the grid's
    /// own order, so a timeline run follows its day groups). In selection
    /// mode a tap toggles; otherwise it selects this tile alone, which is
    /// what raises the preview panel.
    private func tap(_ capture: AppModel.CaptureProject, order: [UUID]) {
        #if os(macOS)
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            selection.toggle(capture.id)
            return
        }
        if flags.contains(.shift) {
            selection.extend(to: capture.id, in: order)
            return
        }
        #endif
        if selection.isSelecting {
            selection.toggle(capture.id)
        } else {
            selection.select(only: capture.id)
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No projects")
                .font(.headline)
            Text("Adjust the filter or search to see your library.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: Context menu

    @ViewBuilder
    private func tileContextMenu(for capture: AppModel.CaptureProject) -> some View {
        Button {
            onOpen(capture.id)
        } label: {
            Label("Open", systemImage: "arrow.up.forward.square")
        }

        if !capture.isPhotoCapture {
            Button {
                model.openCapture(capture)
            } label: {
                Label("New blended clip", systemImage: "plus")
            }
        }

        Divider()

        // Selection (2026-09-13): Select Multiple puts the empty circle on
        // every tile — tap, and tap, and tap — and Select All ticks the whole
        // filtered grid; either way the header becomes the selection row.
        if selection.isSelecting {
            Button {
                selection.clear()
            } label: {
                Label("Done Selecting", systemImage: "checkmark.circle")
            }
        } else {
            Button {
                selection.isSelecting = true
            } label: {
                Label("Select Multiple", systemImage: "checkmark.circle")
            }
        }
        Button {
            selection.selectAll(captures.map(\.id))
        } label: {
            Label("Select All", systemImage: "checkmark.circle.fill")
        }
        .disabled(selection.ids.count == captures.count)

        Divider()

        Button {
            // The editor itself — the same door as the preview panel's Edit
            // button (EditorLaunch.swift); this used to start the New clip
            // flow instead.
            if let onEdit { onEdit(capture.id); return }
            guard let request = model.stageEditor(for: capture) else { return }
            #if os(macOS)
            request.open(with: openWindow)
            #else
            editorRequest = request
            #endif
        } label: {
            Label("Edit", systemImage: "pencil")
        }

        #if os(macOS)
        Button {
            if let url = model.heroImageURL(for: capture) {
                NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
            }
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }
        #endif

        Divider()

        Button(role: .destructive) {
            do {
                try model.deleteCapture(capture)
                selection.remove(capture.id)
            } catch {}
        } label: {
            Label("Delete\u{2026}", systemImage: "trash")
        }
    }
}

// MARK: - Timeline grid

/// The Gallery's timeline mode: captures grouped by shoot day, with a
/// month-scrubber rail on the trailing edge.
private struct TimelineGalleryGrid<Menu: View>: View {
    @EnvironmentObject var model: AppModel
    var captures: [AppModel.CaptureProject]
    @Binding var selection: GallerySelection
    @Binding var scrollTarget: UUID?
    /// The tap, with the timeline's own order for a ⇧-click run.
    var onTap: (AppModel.CaptureProject, [UUID]) -> Void
    var onOpen: (UUID) -> Void
    @ViewBuilder var menu: (AppModel.CaptureProject) -> Menu

    @State private var scrollProxy: ScrollViewProxy?

    // Group captures by calendar day (in user's timezone).
    private var groups: [(day: Date, captures: [AppModel.CaptureProject])] {
        timelineGroups(captures)
    }

    /// The tiles as drawn, top to bottom — what a ⇧-click run walks.
    private var order: [UUID] { groups.flatMap { $0.captures.map(\.id) } }

    private func deselectAll() {
        guard !selection.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.15)) { selection.deselectAll() }
    }

    // Unique months present, for the scrubber.
    private var months: [Date] {
        let cal = Calendar.current
        let monthStarts = groups.map { cal.date(from: cal.dateComponents([.year, .month], from: $0.day))! }
        return Array(OrderedSet(monthStarts))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                ScrollViewReader { proxy in
                    LazyVStack(alignment: .leading, spacing: 20, pinnedViews: .sectionHeaders) {
                        ForEach(groups, id: \.day) { group in
                            Section {
                                LazyVGrid(
                                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: timelineColumnCount),
                                    spacing: 10
                                ) {
                                    ForEach(group.captures) { capture in
                                        GalleryTile(
                                            capture: capture,
                                            isSelected: selection.ids.contains(capture.id),
                                            showsCircle: selection.showsCircles,
                                            onTap:  { onTap(capture, order) },
                                            onToggle: { selection.toggle(capture.id) },
                                            onOpen: { onOpen(capture.id) },
                                            onOutsideTap: { deselectAll() }
                                        )
                                        .id(capture.id)
                                        .contextMenu { menu(capture) }
                                    }
                                }
                            } header: {
                                TimelineDayHeader(day: group.day, count: group.captures.count)
                                    .id(group.day)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .onAppear { scrollProxy = proxy }
                    .onChange(of: scrollTarget) { _, id in
                        guard let id else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id) }
                        scrollTarget = nil
                    }
                }
                Color.clear.frame(height: 82)
            }
            .scrollContentBackground(.hidden)
            // The gaps and the margins select none, as on the standard grid.
            .contentShape(Rectangle())
            .onTapGesture { deselectAll() }

            // Month scrubber rail (56pt wide, right edge)
            MonthScrubberRail(months: months) { month in
                let target = groups.first { Calendar.current.isDate($0.day, equalTo: month, toGranularity: .month) }?.day
                if let t = target { withAnimation { scrollProxy?.scrollTo(t, anchor: .top) } }
            }
            .frame(width: 56)
        }
    }
}

/// The timeline's grouping — by shoot day, newest day first, newest capture
/// first within a day — shared with the keyboard's row geometry so an arrow
/// walks the tiles as they are drawn.
func timelineGroups(_ captures: [AppModel.CaptureProject]) -> [(day: Date, captures: [AppModel.CaptureProject])] {
    let cal = Calendar.current
    let dict = Dictionary(grouping: captures) { capture in
        cal.startOfDay(for: capture.createdAt)
    }
    return dict.keys.sorted(by: >).map { day in
        (day: day, captures: dict[day]!.sorted { $0.createdAt > $1.createdAt })
    }
}

/// The timeline grid's column count — fixed, whatever the zoom slider says.
let timelineColumnCount = 5

// MARK: Day header

private struct TimelineDayHeader: View {
    var day: Date
    var count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(day.formatted(.dateTime.weekday(.wide).month().day().year()))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Text("\(count)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.07), in: Capsule())
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 2)
        .background(LL.screenBackground)
    }
}

// MARK: Month scrubber

private struct MonthScrubberRail: View {
    var months: [Date]
    var onSelect: (Date) -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(months, id: \.self) { month in
                    Button { onSelect(month) } label: {
                        scrubberLabel(for: month)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
        }
        .background(LL.screenBackground)
    }

    @ViewBuilder
    private func scrubberLabel(for month: Date) -> some View {
        let cal = Calendar.current
        let components = cal.dateComponents([.month, .year], from: month)
        let isJanuary = components.month == 1

        VStack(spacing: 1) {
            if isJanuary {
                Text(month.formatted(.dateTime.year()))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(month.formatted(.dateTime.month(.abbreviated)))
                .font(.system(size: 11, weight: isJanuary ? .bold : .regular))
                .foregroundStyle(isJanuary ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

// MARK: - Ordered set helper (lightweight, value-type)

private struct OrderedSet<T: Hashable>: Sequence {
    private var order: [T] = []
    private var set: Set<T> = []

    mutating func append(_ element: T) {
        guard !set.contains(element) else { return }
        set.insert(element)
        order.append(element)
    }

    init<S: Sequence>(_ sequence: S) where S.Element == T {
        for element in sequence { append(element) }
    }

    func makeIterator() -> IndexingIterator<[T]> { order.makeIterator() }
}

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
    var captures: [AppModel.CaptureProject]
    var columnCount: Int
    var timelineMode: Bool
    @Binding var selectedID: UUID?
    var onOpen: (UUID) -> Void    // double-click or "Open" action

    // Shared zoom-level key — pinch on either grid keeps them in sync.
    @AppStorage("gallery.columnCount") private var storedColumnCount = 3

    var body: some View {
        if captures.isEmpty {
            emptyState
        } else if timelineMode {
            TimelineGalleryGrid(
                captures: captures,
                selectedID: $selectedID,
                onOpen: onOpen
            )
        } else {
            standardGrid
        }
    }

    // MARK: Standard grid

    private var standardGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: columns,
                spacing: 12
            ) {
                ForEach(captures) { capture in
                    GalleryTile(
                        capture: capture,
                        isSelected: selectedID == capture.id,
                        onTap:       { selectedID = capture.id },
                        onOpen:      { onOpen(capture.id) }
                    )
                    .contextMenu { tileContextMenu(for: capture) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            // Clearance for the floating tab bar.
            Color.clear.frame(height: 82)
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

        Button {
            model.openCapture(capture)   // same as "Edit" entry point
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
                if selectedID == capture.id { selectedID = nil }
            } catch {}
        } label: {
            Label("Delete\u{2026}", systemImage: "trash")
        }
    }
}

// MARK: - Timeline grid

/// The Gallery's timeline mode: captures grouped by shoot day, with a
/// month-scrubber rail on the trailing edge.
private struct TimelineGalleryGrid: View {
    @EnvironmentObject var model: AppModel
    var captures: [AppModel.CaptureProject]
    @Binding var selectedID: UUID?
    var onOpen: (UUID) -> Void

    @State private var scrollProxy: ScrollViewProxy?

    // Group captures by calendar day (in user's timezone).
    private var groups: [(day: Date, captures: [AppModel.CaptureProject])] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: captures) { capture in
            cal.startOfDay(for: capture.createdAt)
        }
        return dict.keys.sorted(by: >).map { day in
            (day: day, captures: dict[day]!.sorted { $0.createdAt > $1.createdAt })
        }
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
                                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5),
                                    spacing: 10
                                ) {
                                    ForEach(group.captures) { capture in
                                        GalleryTile(
                                            capture: capture,
                                            isSelected: selectedID == capture.id,
                                            onTap:  { selectedID = capture.id },
                                            onOpen: { onOpen(capture.id) }
                                        )
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
                }
                Color.clear.frame(height: 82)
            }
            .scrollContentBackground(.hidden)

            // Month scrubber rail (56pt wide, right edge)
            MonthScrubberRail(months: months) { month in
                let target = groups.first { Calendar.current.isDate($0.day, equalTo: month, toGranularity: .month) }?.day
                if let t = target { withAnimation { scrollProxy?.scrollTo(t, anchor: .top) } }
            }
            .frame(width: 56)
        }
    }
}

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

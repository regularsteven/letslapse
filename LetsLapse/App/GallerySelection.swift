import Foundation

/// What the Gallery has selected, and how it is selecting.
///
/// One tile selected is the preview panel's project. More than one is
/// **batch mode** (2026-09-13): the header swaps to the selection row and the
/// panel becomes `GalleryBatchPanel`, whose edits go to every selected
/// project at once. `isSelecting` is the explicit mode the tile menu's
/// *Select Multiple* enters — every tile wears a circle and a tap toggles —
/// which the Mac reaches without it as well, by ⌘-click, ⇧-click and ⌘A.
///
/// The anchor is the tile the last plain or ⌘ click landed on: a ⇧-click
/// selects everything between it and the clicked tile, in the grid's own
/// order, and adds that run to what is already selected.
struct GallerySelection: Equatable {
    var ids: Set<UUID> = []
    var anchor: UUID?
    var isSelecting = false

    var isEmpty: Bool { ids.isEmpty }
    /// More than one project: the batch header and the batch panel.
    var isBatch: Bool { ids.count > 1 }
    /// Exactly one project: the preview panel's.
    var single: UUID? { ids.count == 1 ? ids.first : nil }
    /// Tiles wear their circle (tick when selected) in selection mode and
    /// whenever more than one is selected — a ⌘-click run reads as one.
    var showsCircles: Bool { isSelecting || isBatch }
    /// The selection row stands in for the header in either case.
    var showsSelectionHeader: Bool { isSelecting || isBatch }

    mutating func select(only id: UUID) {
        ids = [id]
        anchor = id
    }

    /// Adds `id` (⇧-arrow: the run grows by one) and makes it the anchor.
    mutating func add(_ id: UUID) {
        ids.insert(id)
        anchor = id
    }

    mutating func toggle(_ id: UUID) {
        if ids.contains(id) {
            ids.remove(id)
            if anchor == id { anchor = ids.first }
        } else {
            ids.insert(id)
            anchor = id
        }
    }

    /// ⇧-click: everything from the anchor to `id` in `order`, added to the
    /// selection; with no anchor it is a plain click.
    mutating func extend(to id: UUID, in order: [UUID]) {
        guard let anchor,
              let a = order.firstIndex(of: anchor),
              let b = order.firstIndex(of: id) else {
            select(only: id)
            return
        }
        ids.formUnion(order[min(a, b)...max(a, b)])
    }

    mutating func selectAll(_ order: [UUID]) {
        ids = Set(order)
        if anchor == nil { anchor = order.first }
    }

    /// Nothing selected, and out of selection mode.
    mutating func clear() {
        ids = []
        anchor = nil
        isSelecting = false
    }

    /// Nothing selected, but still selecting — the header's Deselect All.
    mutating func deselectAll() {
        ids = []
        anchor = nil
    }

    mutating func remove(_ id: UUID) {
        ids.remove(id)
        if anchor == id { anchor = nil }
    }

    /// Drops whatever the grid no longer shows, so "N selected" and the
    /// batch panel only ever speak for tiles on screen.
    mutating func keepOnly(_ visible: [UUID]) {
        let set = Set(visible)
        ids = ids.intersection(set)
        if let anchor, !set.contains(anchor) { self.anchor = nil }
    }
}

// MARK: - Keyboard geometry

/// Which way an arrow key moves the selection.
enum GalleryArrow {
    case left, right, up, down
}

extension GallerySelection {
    /// The tile an arrow lands on from `id`, given the grid as rows of ids in
    /// reading order (a standard grid chunked by its column count; the
    /// timeline's day groups each chunked by five). Left and right walk the
    /// flattened order and stop at the ends; up and down keep the column,
    /// clamped to the row above or below, and stop at the first and last
    /// rows — no wrapping, as in Finder.
    static func neighbour(of id: UUID, in rows: [[UUID]], _ arrow: GalleryArrow) -> UUID? {
        guard let row = rows.firstIndex(where: { $0.contains(id) }),
              let column = rows[row].firstIndex(of: id) else { return nil }
        switch arrow {
        case .left:
            if column > 0 { return rows[row][column - 1] }
            return row > 0 ? rows[row - 1].last : nil
        case .right:
            if column + 1 < rows[row].count { return rows[row][column + 1] }
            return row + 1 < rows.count ? rows[row + 1].first : nil
        case .up:
            guard row > 0 else { return nil }
            let above = rows[row - 1]
            return above[min(column, above.count - 1)]
        case .down:
            guard row + 1 < rows.count else { return nil }
            let below = rows[row + 1]
            return below[min(column, below.count - 1)]
        }
    }

    /// `ids` cut into rows of `columns`.
    static func rows(_ ids: [UUID], columns: Int) -> [[UUID]] {
        let width = max(1, columns)
        return stride(from: 0, to: ids.count, by: width).map { Array(ids[$0..<min($0 + width, ids.count)]) }
    }
}

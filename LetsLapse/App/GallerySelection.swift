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

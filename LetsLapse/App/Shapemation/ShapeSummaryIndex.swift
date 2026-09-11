import SwiftUI
import LetsLapseKit

// The Gallery's SHAPES rows — Ellipse · Rectangle · Square · No Shapes — read
// each project's `shapes.json` (written by Find shapes and by hand in the
// Masks tab). Registers are sidecars, not library records, so the model keeps
// a small summary per project here: counts by row, tagged with the file's
// modification date so a refresh only decodes what changed.

/// What a project's register holds, as the Shapes rows count it.
struct ShapeSummary: Equatable, Sendable {
    var ellipses = 0
    var rectangles = 0
    var squares = 0
    /// `shapes.json`'s modification date when it was read.
    var modified: Date?

    var isEmpty: Bool { ellipses + rectangles + squares == 0 }

    init(ellipses: Int = 0, rectangles: Int = 0, squares: Int = 0, modified: Date? = nil) {
        self.ellipses = ellipses
        self.rectangles = rectangles
        self.squares = squares
        self.modified = modified
    }

    /// Ellipses are one row whatever their obliquity; quads split by family,
    /// the way the Shape-mation builder offers them.
    init(register: ShapeRegister, modified: Date?) {
        self.modified = modified
        for shape in register.shapes {
            switch shape.kind {
            case .ellipse: ellipses += 1
            case .quad: if shape.family == .square { squares += 1 } else { rectangles += 1 }
            }
        }
    }

    /// `nil` when the project has no register at all.
    static func modificationDate(ofRegisterIn folder: URL) -> Date? {
        try? ShapeRegister.url(inProjectFolder: folder)
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }
}

/// One row of the Gallery sidebar's SHAPES section.
enum ShapeFilter: String, CaseIterable, Identifiable {
    case ellipse, rectangle, square
    /// Projects with an empty register or none at all — the ones Find shapes
    /// missed or never visited, so a shape can be drawn on them by hand.
    case empty

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ellipse: return "Ellipse"
        case .rectangle: return "Rectangle"
        case .square: return "Square"
        case .empty: return "No Shapes"
        }
    }

    var symbolName: String {
        switch self {
        case .ellipse: return "oval"
        case .rectangle: return "rectangle"
        case .square: return "square"
        case .empty: return "circle.slash"
        }
    }

    /// `nil` is a project with no register, which counts as having no shapes.
    func matches(_ summary: ShapeSummary?) -> Bool {
        switch self {
        case .ellipse: return (summary?.ellipses ?? 0) > 0
        case .rectangle: return (summary?.rectangles ?? 0) > 0
        case .square: return (summary?.squares ?? 0) > 0
        case .empty: return summary?.isEmpty ?? true
        }
    }
}

extension Set where Element == ShapeFilter {
    /// Rows narrow, the way the tag chips do: a project must satisfy every lit row.
    func allows(_ summary: ShapeSummary?) -> Bool {
        allSatisfy { $0.matches(summary) }
    }

    /// No Shapes cannot hold alongside a shape row, so lighting it clears the
    /// others and lighting a shape clears it.
    mutating func toggle(_ row: ShapeFilter) {
        if contains(row) {
            remove(row)
        } else if row == .empty {
            self = [.empty]
        } else {
            remove(.empty)
            insert(row)
        }
    }
}

extension AppModel {
    /// Re-read every library project's register summary. Cheap to call on each
    /// Gallery visit: a file whose modification date has not moved keeps its
    /// old summary without being decoded again.
    func refreshShapeSummaries() {
        let targets = libraryCaptures.map { ($0.id, projectFolderURL(for: $0)) }
        let known = shapeSummaries
        Task.detached(priority: .utility) { [weak self] in
            var next: [UUID: ShapeSummary] = [:]
            for (id, folder) in targets {
                guard let modified = ShapeSummary.modificationDate(ofRegisterIn: folder) else { continue }
                if let old = known[id], old.modified == modified {
                    next[id] = old
                    continue
                }
                guard let register = ShapeRegister.load(inProjectFolder: folder) else { continue }
                next[id] = ShapeSummary(register: register, modified: modified)
            }
            let result = next
            await MainActor.run {
                guard let self, self.shapeSummaries != result else { return }
                self.shapeSummaries = result
            }
        }
    }

    /// After the editor writes a register: that one project, right away, so
    /// the Gallery rows agree with what was just drawn or removed.
    func shapeRegisterDidChange(for capture: CaptureProject) {
        let folder = projectFolderURL(for: capture)
        if let register = ShapeRegister.load(inProjectFolder: folder) {
            shapeSummaries[capture.id] = ShapeSummary(register: register,
                                                      modified: ShapeSummary.modificationDate(ofRegisterIn: folder))
        } else {
            shapeSummaries[capture.id] = nil
        }
    }
}

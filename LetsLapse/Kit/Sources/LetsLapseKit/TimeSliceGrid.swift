import Foundation

/// Grid slicing — the two-axis generalisation of `TimeSlice`. The frame is cut
/// into square cells on both axes at once and each cell's lag follows its
/// distance from a chosen **origin corner**, so the time gradient reads as a
/// wavefront sweeping diagonally across the frame instead of a curtain
/// crossing it.
///
/// This file is pure geometry — cell rects, the derived row count, and the
/// distance ladder. The pass that reads master frames and writes cells is the
/// same loop the banded path uses (`TimeSliceRenderer`); only the plan differs.
/// Plan: `LetsLapse/docs/time-slicing.md` §10.

/// The corner holding the NEWEST cell — lag 0, the point the wavefront sweeps
/// away from. The same convention as `TimeSliceEdge`, one dimension up.
public enum TimeSliceGridOrigin: String, Codable, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    /// Whether column 0 (in display reading order) is the near side.
    public var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    /// Whether row 0 (in display reading order) is the near side.
    public var isTop: Bool { self == .topLeft || self == .topRight }

    /// The token the derived display name uses.
    public var nameToken: String {
        switch self {
        case .topLeft: return "tl"
        case .topRight: return "tr"
        case .bottomLeft: return "bl"
        case .bottomRight: return "br"
        }
    }

    public var label: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }

    /// The corner diagonally opposite — where the oldest cell sits.
    public var opposite: TimeSliceGridOrigin {
        switch self {
        case .topLeft: return .bottomRight
        case .topRight: return .bottomLeft
        case .bottomLeft: return .topRight
        case .bottomRight: return .topLeft
        }
    }
}

/// How a cell's distance from the origin corner is measured. Manhattan gives
/// stepped diagonal bands (every cell on an anti-diagonal shares a moment);
/// Euclidean gives a curved, radial wavefront.
public enum TimeSliceGridMetric: String, Codable, CaseIterable, Sendable {
    case manhattan
    case euclidean

    public var nameToken: String { self == .manhattan ? "manh" : "eucl" }
    public var label: String { self == .manhattan ? "Manhattan" : "Euclidean" }
}

/// The grid half of a slicing recipe. Present = grid mode; absent = the
/// original single-axis banding, untouched. The column count is **not** here:
/// it is `TimeSliceSettings.segments`, because the user-facing segment count
/// applies to the horizontal axis (§5.1) and the row count is derived.
public struct TimeSliceGrid: Codable, Equatable, Sendable {
    public var origin: TimeSliceGridOrigin
    public var metric: TimeSliceGridMetric

    public init(origin: TimeSliceGridOrigin = .topLeft, metric: TimeSliceGridMetric = .manhattan) {
        self.origin = origin
        self.metric = metric
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TimeSliceGrid()
        origin = (try? container.decodeIfPresent(TimeSliceGridOrigin.self, forKey: .origin))
            .flatMap { $0 } ?? defaults.origin
        metric = (try? container.decodeIfPresent(TimeSliceGridMetric.self, forKey: .metric))
            .flatMap { $0 } ?? defaults.metric
    }
}

/// A resolved grid: square cells of `cellPixels` a side, laid over a frame of
/// a given size. Column ranges run along the display-horizontal axis, rows
/// down the display-vertical one; the renderer maps both into encoded pixel
/// space through the master's transform.
public struct TimeSliceGridLayout: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    /// The square cell's side, in pixels. Interior cells are exactly this on
    /// both axes; the outer row and column crop (§5.1 — squareness wins over
    /// full coverage).
    public let cellPixels: Int
    public let columnRanges: [Range<Int>]
    public let rowRanges: [Range<Int>]
    /// Pixels the grid overhangs the frame by, split between the two outer
    /// cells of each axis. The metadata §5.1 asks for.
    public let croppedX: Int
    public let croppedY: Int

    public var cellCount: Int { columns * rows }

    /// "24 × 14 cells of 160 px (edges cropped 0/40 px)" — the line that goes
    /// into a sliced output's summary so the geometry is on the record.
    public var summary: String {
        var text = "\(columns)×\(rows) cells of \(cellPixels) px"
        if croppedX > 0 || croppedY > 0 {
            text += " · edges cropped \(croppedX)/\(croppedY) px"
        }
        return text
    }
}

/// Cell geometry and the distance ladder — pure functions, no pixels.
public enum TimeSliceGridGeometry {

    /// A grid cell smaller than this stops reading as a cell and starts
    /// reading as noise. Stricter than the banded path's 2 px floor
    /// deliberately: a band is one pixel-column tall in the other axis by
    /// definition, a cell is not (open question 3).
    public static let minimumCellPixels = 8

    /// The practical column ceiling. Above it the wavefront's step count grows
    /// faster than the spread can usefully cover — see `maximumDistance`.
    public static let maximumColumns = 48

    /// Resolves the grid for a frame. Returns nil when the cells would fall
    /// under the floor, or when the derived row count collapses to one (that
    /// is a banded slice, and the banded path renders it better).
    ///
    /// `width`/`height` are **display-space** lengths: the column count always
    /// applies to the axis the viewer sees as horizontal.
    public static func layout(width: Int, height: Int, columns: Int) -> TimeSliceGridLayout? {
        guard width > 0, height > 0, columns >= 2 else { return nil }

        // The cell side comes from the horizontal count (§5.1). Rounded UP so
        // the columns always cover the frame: the alternative leaves an
        // uncovered strip, which is unwritten output — black — not a crop.
        let cell = Int((Double(width) / Double(columns)).rounded(.up))
        guard cell >= minimumCellPixels else { return nil }

        // Rows derived from the shoot's aspect so the cells stay square,
        // rounded to nearest — bumped up by one only where rounding down
        // would leave that uncovered strip.
        var rows = max(1, Int((Double(height) / Double(cell)).rounded()))
        if rows * cell < height { rows += 1 }
        guard rows >= 2 else { return nil }

        let columnRanges = croppedRanges(count: columns, cell: cell, axisLength: width)
        let rowRanges = croppedRanges(count: rows, cell: cell, axisLength: height)
        // The outer cells crop; a crop that eats a cell whole (or takes it
        // under the banded floor) is a broken grid, not a tight one.
        guard columnRanges.allSatisfy({ $0.count >= TimeSliceGeometry.minimumBandPixels }),
              rowRanges.allSatisfy({ $0.count >= TimeSliceGeometry.minimumBandPixels })
        else { return nil }

        return TimeSliceGridLayout(
            columns: columns, rows: rows, cellPixels: cell,
            columnRanges: columnRanges, rowRanges: rowRanges,
            croppedX: max(0, columns * cell - width),
            croppedY: max(0, rows * cell - height))
    }

    /// `count` cells of exactly `cell` px, centred over `axisLength` and
    /// clipped to it. The overhang is split between the two outer cells, so
    /// every interior cell is square and only the edges crop.
    static func croppedRanges(count: Int, cell: Int, axisLength: Int) -> [Range<Int>] {
        let overhang = max(0, count * cell - axisLength)
        let offset = overhang / 2
        return (0..<count).map { index in
            let lower = max(0, index * cell - offset)
            let upper = min(axisLength, (index + 1) * cell - offset)
            return lower..<max(lower, upper)
        }
    }

    /// A cell's distance from the origin corner, in cells.
    public static func distance(
        column: Int, row: Int, columns: Int, rows: Int,
        origin: TimeSliceGridOrigin, metric: TimeSliceGridMetric
    ) -> Double {
        let dc = origin.isLeft ? column : (columns - 1 - column)
        let dr = origin.isTop ? row : (rows - 1 - row)
        switch metric {
        case .manhattan:
            return Double(dc + dr)
        case .euclidean:
            return (Double(dc * dc) + Double(dr * dr)).squareRoot()
        }
    }

    /// The far corner's distance — the ladder's span, and the number the
    /// spread arithmetic divides by (the grid's answer to `segments − 1`).
    public static func maximumDistance(
        columns: Int, rows: Int, metric: TimeSliceGridMetric
    ) -> Double {
        distance(column: columns - 1, row: rows - 1, columns: columns, rows: rows,
                 origin: .topLeft, metric: metric)
    }

    /// The lag ladder in **row-major display order** — `ladder[row * columns +
    /// column]` — so a cell's lag is a lookup, exactly as the banded path's is.
    /// Euclidean distances are rounded to whole master frames here: the
    /// sampler and the spool both need an integer ladder.
    public static func lagLadder(
        columns: Int, rows: Int, origin: TimeSliceGridOrigin,
        metric: TimeSliceGridMetric, offsetFrames: Int
    ) -> [Int] {
        let offset = max(1, offsetFrames)
        var ladder = [Int](repeating: 0, count: max(0, columns * rows))
        for row in 0..<max(0, rows) {
            for column in 0..<max(0, columns) {
                let d = distance(column: column, row: row, columns: columns, rows: rows,
                                 origin: origin, metric: metric)
                ladder[row * columns + column] = Int((d * Double(offset)).rounded())
            }
        }
        return ladder
    }

    /// The poster's master index per cell: the ladder spread evenly over the
    /// ENTIRE master by distance rank, newest at the origin corner — the
    /// banded poster's rule, in two dimensions. A short master repeats frames
    /// rather than failing.
    public static func posterIndices(
        masterFrames: Int, columns: Int, rows: Int,
        origin: TimeSliceGridOrigin, metric: TimeSliceGridMetric
    ) -> [Int]? {
        guard masterFrames >= 1, columns >= 2, rows >= 1 else { return nil }
        let last = masterFrames - 1
        let span = maximumDistance(columns: columns, rows: rows, metric: metric)
        guard span > 0 else { return [Int](repeating: last, count: columns * rows) }
        var indices = [Int](repeating: 0, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let d = distance(column: column, row: row, columns: columns, rows: rows,
                                 origin: origin, metric: metric)
                indices[row * columns + column] = Int((Double(last) * (1 - d / span)).rounded())
            }
        }
        return indices
    }
}

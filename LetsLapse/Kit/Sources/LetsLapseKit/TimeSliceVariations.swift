import Foundation

/// Variation batches — one blend, several slices.
///
/// Generating blended frames is the expensive part of a run; slicing them is a
/// per-cell read out of a file that already exists. So a run can spend the
/// expensive budget once and hand back a spread of takes instead of a single
/// guess at parameters nobody can picture in advance.
///
/// This file is the pure core: the batch's shape (how many, what varies) and
/// the deterministic generator that turns a seed plus the user's baseline into
/// N distinct, individually valid recipes. Plan: `docs/time-slicing.md` §10.

/// What varies across a batch.
public enum TimeSliceVariationMode: String, Codable, CaseIterable, Sendable {
    /// All variations band the frame across Y (horizontal bands).
    case horizontal
    /// All variations band the frame across X (vertical bands).
    case vertical
    /// All variations are grids; origin corner, metric and column count vary.
    case grid
    /// The batch draws across all of the above.
    case mixed

    public var label: String {
        switch self {
        case .horizontal: return "Horizontal"
        case .vertical: return "Vertical"
        case .grid: return "Grid"
        case .mixed: return "Mixed"
        }
    }
}

/// Stamped onto every recipe a batch produces, so an output can say which
/// variation it is and the whole batch can be regenerated from the seed (§6).
public struct TimeSliceVariationStamp: Codable, Equatable, Sendable {
    /// 1-based.
    public var index: Int
    public var count: Int
    public var mode: TimeSliceVariationMode
    public var seed: UInt64

    public init(index: Int, count: Int, mode: TimeSliceVariationMode, seed: UInt64) {
        self.index = index
        self.count = count
        self.mode = mode
        self.seed = seed
    }

    /// The name token: `v3of8`.
    public var label: String { "v\(index)of\(count)" }
    /// "Variation 3 of 8"
    public var caption: String { "Variation \(index) of \(count)" }
    /// The seed as it is quoted to a person who wants the batch back.
    public var seedToken: String { String(format: "%016llX", seed) }
}

/// The batch a run is armed with. Absent = the single-slice path, unchanged.
public struct TimeSliceVariationPlan: Codable, Equatable, Sendable {
    /// The counts the UI offers. Nothing here depends on them being these.
    public static let allowedCounts = [2, 4, 8]

    public var count: Int
    public var mode: TimeSliceVariationMode
    /// Recorded so a batch is reproducible (§6).
    public var seed: UInt64

    public init(count: Int = 4, mode: TimeSliceVariationMode = .mixed, seed: UInt64 = Self.freshSeed()) {
        self.count = count
        self.mode = mode
        self.seed = seed
    }

    public static func freshSeed() -> UInt64 { UInt64.random(in: 1...UInt64.max) }

    public var seedToken: String { String(format: "%016llX", seed) }
}

/// A small, explicit, portable PRNG. `SystemRandomNumberGenerator` is not
/// seedable and `Int.random` is not reproducible, and reproducibility is the
/// whole point of recording a seed.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Turns a plan plus the user's baseline into the batch's recipes.
public enum TimeSliceVariationGenerator {

    /// The shape a variation takes. Ordered by visible effect: which of these
    /// a variation is dominates everything else about how it reads (§6).
    private enum Shape {
        case banded(TimeSliceAxis)
        case grid
    }

    /// Segment-count multipliers, applied in this order to successive
    /// variations of the same shape — the batch walks coarse and fine before
    /// it ever touches the spread.
    private static let segmentMultipliers: [Double] = [1.0, 0.5, 2.0, 0.75, 1.5, 0.35, 3.0, 1.25]
    /// Spread multipliers — the subtlest of the four, so it changes last and
    /// least (§6: largest visible effect first).
    private static let spreadMultipliers: [Double] = [1.0, 1.0, 0.7, 1.4, 0.55, 1.15, 0.85, 1.8]

    /// Generates the batch.
    ///
    /// Every returned recipe is **individually valid** for this master —
    /// its bands clear the pixel floor, its grid resolves, and its spread
    /// leaves at least one output frame — and **distinct** from every other
    /// (§6). Where the master is too small or too short to yield `plan.count`
    /// distinct valid recipes, fewer are returned rather than duplicates; the
    /// caller reports what it actually got.
    ///
    /// `width`/`height` are display-space pixels, `masterFrames` the finished
    /// blended clip's frame count.
    public static func variations(
        plan: TimeSliceVariationPlan,
        baseline: TimeSliceSettings,
        masterFrames: Int,
        width: Int,
        height: Int
    ) -> [TimeSliceSettings] {
        guard plan.count >= 1, masterFrames >= 2, width > 0, height > 0 else { return [] }
        var rng = SplitMix64(seed: plan.seed)

        let shapes = shapeOrder(mode: plan.mode, baseline: baseline, count: plan.count)
        // Edges and corners are shuffled once per batch, then consumed in
        // order — so the batch sweeps the whole set before repeating one, and
        // a different seed sweeps it differently.
        var edgePool: [TimeSliceAxis: [TimeSliceEdge]] = [
            .vertical: shuffled([.left, .right], using: &rng),
            .horizontal: shuffled([.top, .bottom], using: &rng),
        ]
        // The baseline's own edge leads its axis, so variation 1 of a
        // single-axis batch is recognisably the take the user set up.
        if plan.mode != .grid, var pool = edgePool[baseline.axis] {
            pool.removeAll { $0 == baseline.newestEdge }
            edgePool[baseline.axis] = [baseline.newestEdge] + pool
        }
        let cornerPool = shuffled(TimeSliceGridOrigin.allCases, using: &rng)
        let metrics: [TimeSliceGridMetric] = [.manhattan, .euclidean]

        let baselineSpread = TimeSliceGeometry.spreadFraction(
            offsetFrames: baseline.offsetFrames, masterFrames: masterFrames,
            segments: baseline.segments)

        var results: [TimeSliceSettings] = []
        var seen = Set<String>()
        var shapeOccurrence: [String: Int] = [:]

        for (index, shape) in shapes.enumerated() {
            let key = shapeKey(shape)
            let occurrence = shapeOccurrence[key, default: 0]
            shapeOccurrence[key] = occurrence + 1

            var candidate = baseline
            candidate.variation = nil
            candidate.grid = nil
            let spreadTarget = baselineSpread * spreadMultipliers[index % spreadMultipliers.count]
            let segmentScale = segmentMultipliers[occurrence % segmentMultipliers.count]

            switch shape {
            case .banded(let axis):
                let pool = edgePool[axis] ?? [axis == .vertical ? .right : .bottom]
                candidate.newestEdge = pool[occurrence % pool.count]
            case .grid:
                // Corner and metric turn at different rates so even a batch
                // with only two grids in it shows both wavefront shapes.
                candidate.grid = TimeSliceGrid(
                    origin: cornerPool[occurrence % cornerPool.count],
                    metric: metrics[occurrence % metrics.count])
            }

            guard var resolved = resolve(
                candidate, segmentScale: segmentScale, spread: spreadTarget,
                baselineSegments: baseline.segments, masterFrames: masterFrames,
                width: width, height: height)
            else { continue }

            // No two variations identical (§6). Nudge the segment count first
            // — the loudest knob still available — then the spread.
            if seen.contains(identity(resolved)) {
                guard let distinct = makeDistinct(
                    resolved, seen: seen, spread: spreadTarget,
                    baselineSegments: baseline.segments, masterFrames: masterFrames,
                    width: width, height: height)
                else { continue }
                resolved = distinct
            }
            seen.insert(identity(resolved))
            results.append(resolved)
        }

        // Stamp in final order, once the set is settled.
        return results.enumerated().map { position, settings in
            var stamped = settings
            stamped.variation = TimeSliceVariationStamp(
                index: position + 1, count: results.count, mode: plan.mode, seed: plan.seed)
            return stamped
        }
    }

    // MARK: - Shape order

    /// Which shape each variation takes, in batch order. Mixed alternates the
    /// banded axes with grids rather than cycling all three evenly: grid is
    /// the most visibly different of the three, so half a mixed batch is grid.
    private static func shapeOrder(
        mode: TimeSliceVariationMode, baseline: TimeSliceSettings, count: Int
    ) -> [Shape] {
        let ownAxis = baseline.axis
        let otherAxis: TimeSliceAxis = ownAxis == .vertical ? .horizontal : .vertical
        let cycle: [Shape]
        switch mode {
        case .horizontal: cycle = [.banded(.horizontal)]
        case .vertical: cycle = [.banded(.vertical)]
        case .grid: cycle = [.grid]
        case .mixed: cycle = [.banded(ownAxis), .grid, .banded(otherAxis), .grid]
        }
        return (0..<count).map { cycle[$0 % cycle.count] }
    }

    private static func shapeKey(_ shape: Shape) -> String {
        switch shape {
        case .banded(let axis): return axis.nameToken
        case .grid: return "grid"
        }
    }

    // MARK: - Resolution

    /// Applies the segment scale and the spread target, then clamps both until
    /// the recipe is renderable — or gives up and returns nil.
    private static func resolve(
        _ candidate: TimeSliceSettings, segmentScale: Double, spread: Double,
        baselineSegments: Int, masterFrames: Int, width: Int, height: Int
    ) -> TimeSliceSettings? {
        var settings = candidate
        let wanted = Int((Double(baselineSegments) * segmentScale).rounded())
        guard let segments = nearestValidSegments(
            wanted, isGrid: settings.grid != nil, axis: settings.axis,
            width: width, height: height)
        else { return nil }
        settings.segments = segments
        return applySpread(settings, spread: spread, masterFrames: masterFrames,
                           width: width, height: height)
    }

    /// Walks outward from `wanted` for the first segment count this frame can
    /// actually carry — the pixel floor is a hard wall, and a scaled-up count
    /// runs into it on small frames.
    private static func nearestValidSegments(
        _ wanted: Int, isGrid: Bool, axis: TimeSliceAxis, width: Int, height: Int
    ) -> Int? {
        let ceiling = isGrid ? TimeSliceGridGeometry.maximumColumns : 96
        let start = min(max(2, wanted), ceiling)
        for delta in 0...(ceiling - 2) {
            for candidate in [start - delta, start + delta] where candidate >= 2 && candidate <= ceiling {
                if isValidSegments(candidate, isGrid: isGrid, axis: axis, width: width, height: height) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func isValidSegments(
        _ segments: Int, isGrid: Bool, axis: TimeSliceAxis, width: Int, height: Int
    ) -> Bool {
        if isGrid {
            return TimeSliceGridGeometry.layout(width: width, height: height, columns: segments) != nil
        }
        let axisLength = axis == .vertical ? width : height
        return TimeSliceGeometry.bandRanges(axisLength: axisLength, segments: segments) != nil
    }

    /// Derives the lag from the wanted spread and clamps it so the animation
    /// keeps at least a second's worth of frames — a batch member that refuses
    /// at render time is worse than a batch member that reads a little tamer.
    private static func applySpread(
        _ candidate: TimeSliceSettings, spread: Double, masterFrames: Int,
        width: Int, height: Int
    ) -> TimeSliceSettings? {
        var settings = candidate
        let steps = ladderSteps(settings, width: width, height: height)
        guard steps > 0 else { return nil }
        let wanted = TimeSliceGeometry.offsetFrames(
            spreadFraction: min(0.95, max(0.02, spread)), masterFrames: masterFrames, steps: steps)
        // Leave a floor of output frames rather than trimming to nothing.
        let maximumLag = max(1, masterFrames - max(1, masterFrames / 20))
        let ceiling = max(1, Int(Double(maximumLag) / steps))
        settings.offsetFrames = min(max(1, wanted), ceiling)
        guard settings.maxLagFrames(width: width, height: height) < masterFrames else { return nil }
        return settings
    }

    /// The ladder's span in cells: `segments − 1` banded, the far corner's
    /// distance for a grid.
    private static func ladderSteps(_ settings: TimeSliceSettings, width: Int, height: Int) -> Double {
        guard let grid = settings.grid else { return Double(max(1, settings.segments - 1)) }
        guard let layout = TimeSliceGridGeometry.layout(
            width: width, height: height, columns: settings.segments) else { return 0 }
        return TimeSliceGridGeometry.maximumDistance(
            columns: layout.columns, rows: layout.rows, metric: grid.metric)
    }

    /// The distinctness key — everything that changes what the render looks
    /// like. The variation stamp is deliberately not in it.
    private static func identity(_ settings: TimeSliceSettings) -> String {
        let shape = settings.grid.map { "grid-\($0.origin.rawValue)-\($0.metric.rawValue)" }
            ?? "band-\(settings.newestEdge.rawValue)"
        return "\(shape)-\(settings.segments)-\(settings.offsetFrames)"
    }

    /// Nudges a colliding recipe until it is new: segment count first (it is
    /// the loudest knob left once shape and origin are fixed), then the lag.
    private static func makeDistinct(
        _ settings: TimeSliceSettings, seen: Set<String>, spread: Double,
        baselineSegments: Int, masterFrames: Int, width: Int, height: Int
    ) -> TimeSliceSettings? {
        for delta in 1...24 {
            for wanted in [settings.segments + delta, settings.segments - delta] where wanted >= 2 {
                guard let segments = nearestValidSegments(
                    wanted, isGrid: settings.grid != nil, axis: settings.axis,
                    width: width, height: height), segments == wanted else { continue }
                var candidate = settings
                candidate.segments = segments
                guard let resolved = applySpread(
                    candidate, spread: spread, masterFrames: masterFrames,
                    width: width, height: height) else { continue }
                if !seen.contains(identity(resolved)) { return resolved }
            }
        }
        for delta in 1...12 {
            for lag in [settings.offsetFrames + delta, settings.offsetFrames - delta] where lag >= 1 {
                var candidate = settings
                candidate.offsetFrames = lag
                guard candidate.maxLagFrames(width: width, height: height) < masterFrames else { continue }
                if !seen.contains(identity(candidate)) { return candidate }
            }
        }
        return nil
    }

    private static func shuffled<T>(_ items: [T], using rng: inout SplitMix64) -> [T] {
        var items = items
        guard items.count > 1 else { return items }
        for index in stride(from: items.count - 1, to: 0, by: -1) {
            let swap = Int(rng.next() % UInt64(index + 1))
            items.swapAt(index, swap)
        }
        return items
    }
}

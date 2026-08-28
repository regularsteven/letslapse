import Foundation

/// Time slicing partitions the output frame into bands, each showing a
/// different point on the timeline — a constant per-band lag, so the time
/// gradient scrolls across the frame during playback. It is a sampler, not a
/// compositor: band j of sliced frame t shows master frame
/// `t + maxLag − lag[j]`, and no new pixel values are generated. The
/// single-frame variant spreads the bands across the entire master — the
/// whole-day-in-one-photograph poster.
///
/// This file is the pure core: settings, band geometry, and the lag ladder.
/// The pass that reads a finished blended clip and writes sliced outputs
/// lives with the renderer. Plan: `LetsLapse/docs/time-slicing.md`.

/// Which way the frame is cut. Derived from the newest edge, never stored —
/// left/right mean vertical bands (slicing across X), top/bottom horizontal.
public enum TimeSliceAxis: String, Sendable {
    case vertical
    case horizontal

    /// The token the derived display name uses: `vert` / `horiz`.
    public var nameToken: String { self == .vertical ? "vert" : "horiz" }
}

/// The edge holding the NEWEST band — the reference clip's leftmost band.
/// One field with no invalid states: the axis follows from the edge.
public enum TimeSliceEdge: String, Codable, CaseIterable, Sendable {
    case left, right, top, bottom

    public var axis: TimeSliceAxis {
        switch self {
        case .left, .right: return .vertical
        case .top, .bottom: return .horizontal
        }
    }

    /// Whether the newest band sits at the start of the geometric band order
    /// (bands are always enumerated left→right or top→bottom).
    public var newestLeadsGeometry: Bool { self == .left || self == .top }
}

/// The lag ladder's shape. Linear is the reference clip's measured behaviour
/// (a dead-straight 0, o, 2o … ladder); eased/exponential shapes are a new
/// array here, never a new sampler.
public enum TimeSliceDistribution: String, Codable, Sendable {
    case linear
}

/// What a sliced render emits.
public enum TimeSliceOutput: String, Codable, Sendable {
    case animation
    case image
    case both

    public var wantsAnimation: Bool { self != .image }
    public var wantsImage: Bool { self != .animation }
}

/// The recipe for one sliced render. Rides `BlendProject` so every sliced
/// output is reproducible and re-editable; decodes field by field with
/// defaults, so manifests written before a field existed still load.
public struct TimeSliceSettings: Codable, Equatable, Sendable {
    /// The edge holding the newest band. The axis is derived from it.
    public var newestEdge: TimeSliceEdge
    /// Band count across the sliced axis. Widths are auto-calculated (§3.2
    /// of the plan) and never part of the recipe.
    public var segments: Int
    /// Frames of lag per band, in MASTER frames — a constant integer ladder
    /// is what keeps the render's memory flat, so capture-time is a derived
    /// readout, never the stored unit.
    public var offsetFrames: Int
    /// 0 = hard cuts (the reference clip, and all v1 renders). A feather
    /// width is carried for the future overlap cross-dissolve.
    public var featherPixels: Int
    public var distribution: TimeSliceDistribution
    public var output: TimeSliceOutput
    /// Whether the standard blended timelapse is registered alongside the
    /// sliced output. Blended frames exist either way — this governs what is
    /// kept, not what is rendered.
    public var includeRegularClip: Bool

    public var axis: TimeSliceAxis { newestEdge.axis }
    /// The oldest band's lag — how many master frames the spread consumes.
    public var maxLagFrames: Int { (max(2, segments) - 1) * max(1, offsetFrames) }

    public init(
        // Default flipped 2026-08-28 (test-output review): the first band in
        // reading order holds the EARLIEST time — day at the left / top,
        // night arriving at the far edge — so the time gradient opposes the
        // sky's own luminance gradient instead of collapsing into it. This
        // deliberately deviates from the reference clip, which ran
        // newest-left; Direction remains the override.
        newestEdge: TimeSliceEdge = .right,
        segments: Int = 24,
        offsetFrames: Int = 2,
        featherPixels: Int = 0,
        distribution: TimeSliceDistribution = .linear,
        output: TimeSliceOutput = .both,
        includeRegularClip: Bool = true
    ) {
        self.newestEdge = newestEdge
        self.segments = segments
        self.offsetFrames = offsetFrames
        self.featherPixels = featherPixels
        self.distribution = distribution
        self.output = output
        self.includeRegularClip = includeRegularClip
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TimeSliceSettings()
        newestEdge = (try? container.decodeIfPresent(TimeSliceEdge.self, forKey: .newestEdge))
            .flatMap { $0 } ?? defaults.newestEdge
        segments = try container.decodeIfPresent(Int.self, forKey: .segments) ?? defaults.segments
        offsetFrames = try container.decodeIfPresent(Int.self, forKey: .offsetFrames) ?? defaults.offsetFrames
        featherPixels = try container.decodeIfPresent(Int.self, forKey: .featherPixels) ?? defaults.featherPixels
        distribution = (try? container.decodeIfPresent(TimeSliceDistribution.self, forKey: .distribution))
            .flatMap { $0 } ?? defaults.distribution
        output = (try? container.decodeIfPresent(TimeSliceOutput.self, forKey: .output))
            .flatMap { $0 } ?? defaults.output
        includeRegularClip = try container.decodeIfPresent(Bool.self, forKey: .includeRegularClip)
            ?? defaults.includeRegularClip
    }

    /// The derived display name carrying the key attributes (decided
    /// 2026-08-28): `timeslice-vert-left-segs_24-lag_2`. Band width never
    /// appears — it is auto-calculated.
    public var displayName: String {
        "timeslice-\(axis.nameToken)-\(newestEdge.rawValue)-segs_\(segments)-lag_\(offsetFrames)"
    }

    /// The poster's name drops the lag — its spread is the full shoot.
    public var posterDisplayName: String {
        "timeslice-poster-\(axis.nameToken)-\(newestEdge.rawValue)-segs_\(segments)"
    }
}

/// Band geometry and ladder math — pure functions, no pixels.
public enum TimeSliceGeometry {

    /// Bands thinner than this are rejected outright.
    public static let minimumBandPixels = 2

    /// Partitions an axis into consecutive band ranges, the division
    /// remainder distributed across the bands rather than left as a runt at
    /// one edge. With `evenBoundaries` (4:2:0 chroma siting) every interior
    /// boundary lands on an even pixel; the outer edges are always 0 and
    /// `axisLength`. Returns nil when the inputs can't produce bands of at
    /// least `minimumBandPixels`.
    public static func bandRanges(
        axisLength: Int,
        segments: Int,
        evenBoundaries: Bool = false
    ) -> [Range<Int>]? {
        guard segments >= 2, axisLength >= segments * minimumBandPixels else { return nil }

        var boundaries: [Int] = []
        boundaries.reserveCapacity(segments + 1)
        for index in 0...segments {
            let exact = Double(axisLength) * Double(index) / Double(segments)
            let boundary: Int
            if evenBoundaries, index != 0, index != segments {
                boundary = Int((exact / 2).rounded()) * 2
            } else {
                boundary = Int(exact.rounded(.down))
            }
            boundaries.append(boundary)
        }
        boundaries[0] = 0
        boundaries[segments] = axisLength

        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(segments)
        for index in 0..<segments {
            let range = boundaries[index]..<boundaries[index + 1]
            guard range.count >= minimumBandPixels else { return nil }
            ranges.append(range)
        }
        return ranges
    }

    /// The linear lag ladder: `[0, o, 2o, …]`, newest first. Built as an
    /// array up front so a non-linear distribution is a different array, not
    /// a different sampler.
    public static func lagLadder(
        segments: Int,
        offsetFrames: Int,
        distribution: TimeSliceDistribution = .linear
    ) -> [Int] {
        let segments = max(2, segments)
        let offset = max(1, offsetFrames)
        switch distribution {
        case .linear:
            return (0..<segments).map { $0 * offset }
        }
    }

    /// The ladder rearranged into geometric band order (left→right or
    /// top→bottom): `bandLags[b]` is the lag of the b-th band across the
    /// frame, so the newest band sits at the configured edge.
    public static func bandLags(ladder: [Int], newestEdge: TimeSliceEdge) -> [Int] {
        newestEdge.newestLeadsGeometry ? ladder : ladder.reversed()
    }

    /// Sliced animation length: the spread is trimmed off the end — the
    /// reference clip's own behaviour ("the source ran longer than the
    /// output by exactly the spread"). Zero means the spread ate the clip
    /// and the render must refuse.
    public static func slicedFrameCount(masterFrames: Int, maxLag: Int) -> Int {
        max(0, masterFrames - max(0, maxLag))
    }

    /// The spread expressed as a fraction of the clip — the number a person
    /// can actually reason about (the reference clip ran ~28%; under ~5% the
    /// bands stop reading as different times and the output is seams, not an
    /// effect — the 2026-08-28 test-output finding). The recipe still stores
    /// integer frames; these are the UI's exact two-way mapping.
    public static func offsetFrames(
        spreadFraction: Double, masterFrames: Int, segments: Int
    ) -> Int {
        let steps = max(1, max(2, segments) - 1)
        let targetFrames = max(0, spreadFraction) * Double(max(1, masterFrames))
        return max(1, Int((targetFrames / Double(steps)).rounded()))
    }

    public static func spreadFraction(
        offsetFrames: Int, masterFrames: Int, segments: Int
    ) -> Double {
        guard masterFrames > 0 else { return 0 }
        let steps = max(1, max(2, segments) - 1)
        return Double(max(1, offsetFrames) * steps) / Double(masterFrames)
    }

    /// The poster's master indices: the bands spread evenly over the ENTIRE
    /// master, newest first, independent of the animation's lag. A short
    /// master repeats frames rather than failing — 24 bands over 10 frames
    /// is still a poster.
    public static func posterIndices(masterFrames: Int, segments: Int) -> [Int]? {
        guard masterFrames >= 1, segments >= 2 else { return nil }
        let last = masterFrames - 1
        return (0..<segments).map { band in
            let exact = Double(last) * Double(segments - 1 - band) / Double(segments - 1)
            return Int(exact.rounded())
        }
    }
}

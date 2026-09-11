import Foundation

// How a Shape-mation plays (design signed off 2026-09-11): a frame rate, and
// either one hold for every photo or a ramp — a hold at the start, an
// optional one in the middle, one at the end — interpolated across the
// sequence in whole frames at that rate. Selects, not sliders: the holds are
// a fixed list, in seconds or in frames, and seconds round to whole frames at
// the chosen rate, never under one.

public struct ShapemationTiming: Equatable, Codable, Sendable {
    public static let frameRates = [24, 25, 30, 50, 60]

    /// A per-photo hold, as offered.
    public enum Hold: Equatable, Codable, Sendable, Hashable {
        case seconds(Double)
        case frames(Int)

        public static let options: [Hold] = [
            .seconds(2), .seconds(1), .seconds(0.5), .seconds(0.25), .seconds(0.1),
            .frames(3), .frames(2), .frames(1),
        ]

        public var title: String {
            switch self {
            case .seconds(let s):
                return s == s.rounded() ? "\(Int(s)) s" : "\(String(format: "%g", s)) s"
            case .frames(let n):
                return n == 1 ? "1 frame" : "\(n) frames"
            }
        }

        /// Whole frames at `fps`, never under one.
        public func frames(at fps: Int) -> Int {
            switch self {
            case .seconds(let s): return max(1, Int((s * Double(fps)).rounded()))
            case .frames(let n): return max(1, n)
            }
        }

        private enum CodingKeys: String, CodingKey { case seconds, frames }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let s = try c.decodeIfPresent(Double.self, forKey: .seconds) { self = .seconds(s) }
            else { self = .frames(try c.decode(Int.self, forKey: .frames)) }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .seconds(let s): try c.encode(s, forKey: .seconds)
            case .frames(let n): try c.encode(n, forKey: .frames)
            }
        }
    }

    public struct Ramp: Equatable, Codable, Sendable {
        public var start: Hold
        /// nil: a straight run from start to end.
        public var middle: Hold?
        public var end: Hold
        public init(start: Hold, middle: Hold?, end: Hold) { self.start = start; self.middle = middle; self.end = end }
    }

    public var fps: Int = 25
    /// The hold when there is no ramp.
    public var each: Hold = .seconds(1)
    public var ramp: Ramp?

    public init(fps: Int = 25, each: Hold = .seconds(1), ramp: Ramp? = nil) {
        self.fps = fps; self.each = each; self.ramp = ramp
    }

    /// The hold of every photo in order, in frames: constant without a ramp;
    /// with one, start → middle across the first half of the photos and middle
    /// → end across the second (start → end straight when middle is nil),
    /// each rounded to whole frames and never under one.
    public func holds(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        guard let ramp else { return Array(repeating: each.frames(at: fps), count: count) }
        // The anchors stay exact (0.5 s is 12.5 frames at 25) and only each
        // photo's own hold is rounded — the design's estimate is measured
        // this way, and it keeps a ramp symmetric about its middle.
        func exact(_ h: Hold) -> Double {
            switch h {
            case .seconds(let secs): return secs * Double(fps)
            case .frames(let n): return Double(max(1, n))
            }
        }
        let s = exact(ramp.start), e = exact(ramp.end)
        let m = ramp.middle.map(exact)
        return (0..<count).map { i in
            let t = count > 1 ? Double(i) / Double(count - 1) : 0
            let d: Double
            if let m {
                d = t <= 0.5 ? s + (m - s) * (t / 0.5) : m + (e - m) * ((t - 0.5) / 0.5)
            } else {
                d = s + (e - s) * t
            }
            return max(1, Int(d.rounded()))
        }
    }

    public func totalFrames(count: Int) -> Int { holds(count: count).reduce(0, +) }
    public func totalSeconds(count: Int) -> Double { Double(totalFrames(count: count)) / Double(fps) }

    /// "25 fps · ramp 2 s → 0.5 s → 1 s" / "25 fps · 1 s each".
    public var summary: String {
        if let ramp {
            let mid = ramp.middle.map { " → \($0.title)" } ?? ""
            return "\(fps) fps · ramp \(ramp.start.title)\(mid) → \(ramp.end.title)"
        }
        return "\(fps) fps · \(each.title) each"
    }

    /// "12 photos · 12.4 s of playback · 310 frames".
    public func estimate(count: Int) -> String {
        let photos = count == 1 ? "1 photo" : "\(count) photos"
        return String(format: "%@ · %.1f s of playback · %d frames", photos, totalSeconds(count: count), totalFrames(count: count))
    }
}

/// The order the photos play in — the builder's Sort, largest share first by
/// default: each photo a little further away than the last reads as a zoom
/// rather than a shuffle.
public enum ShapemationSort: String, Codable, CaseIterable, Sendable {
    case largestFirst, smallestFirst, newestFirst

    public var title: String {
        switch self {
        case .largestFirst: return "Largest first"
        case .smallestFirst: return "Smallest first"
        case .newestFirst: return "Newest first"
        }
    }

    /// The key: the shape's diameter as a share of its photo's short edge —
    /// a share, not pixels, so a small photo with a big circle sorts ahead of
    /// a large photo with a small one.
    public static func share(of item: ShapemationItem) -> Double {
        let short = Double(min(item.pixelSize.width, item.pixelSize.height))
        return short > 0 ? item.shape.nativeDiameterPx / short : 0
    }

    /// `items` in this order; `newestFirst` keeps the order given.
    public func sorted(_ items: [ShapemationItem]) -> [ShapemationItem] {
        switch self {
        case .newestFirst: return items
        case .largestFirst: return items.sorted { Self.share(of: $0) > Self.share(of: $1) }
        case .smallestFirst: return items.sorted { Self.share(of: $0) < Self.share(of: $1) }
        }
    }
}

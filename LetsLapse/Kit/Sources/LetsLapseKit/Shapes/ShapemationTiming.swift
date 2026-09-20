import Foundation
import CoreGraphics

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

    /// One photo's own hold, set on the board: it wins over the ramp and the
    /// constant for that photo.
    public struct Override: Equatable, Codable, Sendable, Identifiable {
        public var id: UUID
        public var hold: Hold
        public init(id: UUID, hold: Hold) { self.id = id; self.hold = hold }
    }
    /// Nil and empty read the same; nil is what a record from before the
    /// board says.
    public var overrides: [Override]?

    public init(fps: Int = 25, each: Hold = .seconds(1), ramp: Ramp? = nil, overrides: [Override]? = nil) {
        self.fps = fps; self.each = each; self.ramp = ramp; self.overrides = overrides
    }

    public func override(for id: UUID) -> Hold? { overrides?.first { $0.id == id }?.hold }

    public mutating func setOverride(_ hold: Hold?, for id: UUID) {
        var list = overrides ?? []
        list.removeAll { $0.id == id }
        if let hold { list.append(Override(id: id, hold: hold)) }
        overrides = list.isEmpty ? nil : list
    }

    /// The hold of every photo in order, by id: `holds(count:)` with each
    /// photo's own override in place of its ramp or constant hold.
    public func holds(for ids: [UUID]) -> [Int] {
        var frames = holds(count: ids.count)
        guard let overrides, !overrides.isEmpty else { return frames }
        for (i, id) in ids.enumerated() {
            if let hold = override(for: id) { frames[i] = hold.frames(at: fps) }
        }
        return frames
    }

    public func totalFrames(for ids: [UUID]) -> Int { holds(for: ids).reduce(0, +) }
    public func totalSeconds(for ids: [UUID]) -> Double { Double(totalFrames(for: ids)) / Double(fps) }

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

/// The order the photos play in — the builder's Sort. Smallest first is the
/// approach of the brief's §1 and the default since the board (2026-09-20);
/// largest first is the same zoom the other way; `alignment` is the least-
/// crop model's greedy chain (`ShapemationLeastCrop.ordered`): size order,
/// but among the next few by size the one nearest the last one's place.
public enum ShapemationSort: String, Codable, CaseIterable, Sendable {
    /// `captureOrder` is the order given — oldest → newest as the builder
    /// loads them; until 2026-09-19 it was called `newestFirst`, a misnomer.
    case largestFirst, smallestFirst, captureOrder, alignment

    public var title: String {
        switch self {
        case .largestFirst: return "Largest first"
        case .smallestFirst: return "Smallest first"
        case .captureOrder: return "Capture order"
        case .alignment: return "Alignment"
        }
    }

    /// Shape-mation records written before the rename say `newestFirst`; they
    /// mean this order, and the store decodes its whole index in one go, so a
    /// strict miss here would lose every record with it.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "newestFirst" { self = .captureOrder; return }
        guard let sort = ShapemationSort(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown ShapemationSort \(raw)"))
        }
        self = sort
    }

    /// The key: the share of its frame the shape takes — its extent on each
    /// axis as a fraction of the frame's own, the larger of the two
    /// (`ShapemationLeastCrop.Photo.share`); a share, not pixels, so a small
    /// photo with a big circle sorts ahead of a large photo with a small one,
    /// and bounded by 1 whichever way the shape lies (the diameter over the
    /// short edge passed 1 for a door filling a portrait frame).
    public static func share(of item: ShapemationItem) -> Double {
        share(of: item.shape, in: item.pixelSize)
    }

    public static func share(of shape: DetectedShape, in frame: CGSize) -> Double {
        guard frame.width > 0, frame.height > 0 else { return 0 }
        let b = shape.bounds(in: frame)
        return max(Double(b.width) / Double(frame.width), Double(b.height) / Double(frame.height))
    }

    /// `items` in this order, keyed by `share` — the one rule the builder and
    /// the `lapse` CLI both order by; `captureOrder` keeps the order given.
    /// `alignment` needs the shapes' places and a rect, which only
    /// `ShapemationLeastCrop.ordered` has: here it is the size order.
    public func sorted<T>(_ items: [T], share: (T) -> Double) -> [T] {
        switch self {
        case .captureOrder: return items
        case .largestFirst: return items.sorted { share($0) > share($1) }
        case .smallestFirst, .alignment: return items.sorted { share($0) < share($1) }
        }
    }

    /// The builder's items by their own share.
    public func sorted(_ items: [ShapemationItem]) -> [ShapemationItem] {
        sorted(items, share: Self.share(of:))
    }
}

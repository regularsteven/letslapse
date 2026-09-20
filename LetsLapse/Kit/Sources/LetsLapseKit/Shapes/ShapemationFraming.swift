import Foundation
import CoreGraphics

// The Shape-mation output frame (docs/shapemation/output-frame.md §1): the
// user chooses the output rectangle and where the face sits in it — its
// centre in unit coordinates of the rect and its long side as a fraction of
// the rect's height — at the first photo and at the last, with any number
// of keys between. Every photo is then scaled and placed to put its face
// there (`ShapemationPlan.make` in `.frame` mode); what does not fill the
// frame is flagged, never dropped. A photo's framing is read at
// `t = index / (count − 1)`: motion inside a hold is a later pass.

public struct ShapemationFraming: Codable, Equatable, Sendable {
    /// Even pixels, e.g. 1920×1080 or 1080×1080.
    public var outputSize: CGSize

    public struct Key: Codable, Equatable, Sendable {
        /// 0 = the first photo, 1 = the last (by index).
        public var at: Double
        /// Where the face's centre sits: unit coordinates of the output rect, y-down.
        public var face: CGPoint
        /// The face's long side as a fraction of the output HEIGHT.
        public var size: Double
        public init(at: Double, face: CGPoint, size: Double) { self.at = at; self.face = face; self.size = size }
    }

    /// At least two, sorted by `at`; the first at 0, the last at 1.
    public var keys: [Key]

    public enum Ease: String, Codable, Sendable, CaseIterable {
        case linear, inOut
        public var title: String { self == .linear ? "Linear" : "Ease in and out" }
    }
    /// Between neighbouring keys.
    public var ease: Ease
    /// A photo scaled up beyond this is flagged `upscaled`.
    public var upscaleCap: Double

    public static let defaultFace = CGPoint(x: 0.5, y: 0.55)
    public static let defaultSize = 0.25
    public static let defaultUpscaleCap = 2.0

    /// Keys are put in order and pinned to the ends: fewer than two become a
    /// still (the one given, or the default framing, at both 0 and 1); the
    /// first is moved to 0 and the last to 1, the ones between clamped into
    /// the unit range — so `framing(at:)` always has a key at each end.
    public init(outputSize: CGSize, keys: [Key], ease: Ease = .linear, upscaleCap: Double = ShapemationFraming.defaultUpscaleCap) {
        self.outputSize = outputSize
        self.keys = Self.validated(keys)
        self.ease = ease
        self.upscaleCap = upscaleCap
    }

    static func validated(_ given: [Key]) -> [Key] {
        var keys = given.sorted { $0.at < $1.at }
        if keys.isEmpty { keys = [Key(at: 0, face: defaultFace, size: defaultSize)] }
        if keys.count == 1 { keys.append(keys[0]) }
        for i in keys.indices { keys[i].at = min(1, max(0, keys[i].at)) }
        keys[0].at = 0
        keys[keys.count - 1].at = 1
        return keys
    }

    // MARK: - Codable, tolerant

    private enum CodingKeys: String, CodingKey { case outputSize, keys, ease, upscaleCap }

    /// A record written by a later build decodes: an ease this build does
    /// not know reads as linear, a missing cap as the default, and the keys
    /// pass through the same validation as a hand-built framing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outputSize = try c.decode(CGSize.self, forKey: .outputSize)
        keys = Self.validated(try c.decodeIfPresent([Key].self, forKey: .keys) ?? [])
        let easeName = try c.decodeIfPresent(String.self, forKey: .ease)
        ease = easeName.flatMap(Ease.init(rawValue:)) ?? .linear
        upscaleCap = try c.decodeIfPresent(Double.self, forKey: .upscaleCap) ?? Self.defaultUpscaleCap
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(outputSize, forKey: .outputSize)
        try c.encode(keys, forKey: .keys)
        try c.encode(ease, forKey: .ease)
        try c.encode(upscaleCap, forKey: .upscaleCap)
    }

    // MARK: - Reading the framing

    /// The face's place and size at `t` (clamped to 0…1): the neighbouring
    /// keys interpolated, straight or by smoothstep, per the ease.
    public func framing(at t: Double) -> (face: CGPoint, size: Double) {
        let t = t.isFinite ? min(1, max(0, t)) : 0
        guard keys.count >= 2 else {
            let k = keys.first ?? Key(at: 0, face: Self.defaultFace, size: Self.defaultSize)
            return (k.face, k.size)
        }
        // The last key whose `at` is not past t, and the one after it.
        var i = 0
        while i + 2 < keys.count, keys[i + 1].at <= t { i += 1 }
        let a = keys[i], b = keys[i + 1]
        let span = b.at - a.at
        var u = span > 0 ? (t - a.at) / span : (t >= b.at ? 1 : 0)
        u = min(1, max(0, u))
        if ease == .inOut { u = u * u * (3 - 2 * u) }
        let face = CGPoint(x: Double(a.face.x) + (Double(b.face.x) - Double(a.face.x)) * u,
                           y: Double(a.face.y) + (Double(b.face.y) - Double(a.face.y)) * u)
        return (face, a.size + (b.size - a.size) * u)
    }

    // MARK: - Factories

    /// One framing throughout.
    public static func still(outputSize: CGSize, face: CGPoint = defaultFace, size: Double = defaultSize,
                             upscaleCap: Double = defaultUpscaleCap) -> ShapemationFraming {
        ShapemationFraming(outputSize: outputSize, keys: [Key(at: 0, face: face, size: size), Key(at: 1, face: face, size: size)],
                           ease: .linear, upscaleCap: upscaleCap)
    }

    /// The size (and place) at the first and at the last photo, eased between.
    public static func approach(outputSize: CGSize, from: (face: CGPoint, size: Double), to: (face: CGPoint, size: Double),
                                ease: Ease = .linear, upscaleCap: Double = defaultUpscaleCap) -> ShapemationFraming {
        ShapemationFraming(outputSize: outputSize, keys: [Key(at: 0, face: from.face, size: from.size), Key(at: 1, face: to.face, size: to.size)],
                           ease: ease, upscaleCap: upscaleCap)
    }

    // MARK: - The presets the builder and the CLI share

    /// An output aspect as offered: width by height, in small integers.
    public struct Aspect: Identifiable, Equatable, Sendable {
        public var width: Int
        public var height: Int
        public var id: String { label }
        public var label: String { "\(width):\(height)" }
        public var ratio: Double { Double(width) / Double(height) }
        public init(_ width: Int, _ height: Int) { self.width = width; self.height = height }
    }

    /// 1:1 · 4:5 · 3:2 · 16:9 · 2:3 · 9:16.
    public static let aspectPresets: [Aspect] = [Aspect(1, 1), Aspect(4, 5), Aspect(3, 2), Aspect(16, 9), Aspect(2, 3), Aspect(9, 16)]
    /// Long edges offered, in pixels.
    public static let sizePresets: [Int] = [1080, 1920, 2160]

    /// The even pixel size of `aspect` at `longEdge` on its longer side — a
    /// square's long edge is both sides.
    public static func outputSize(aspect: Aspect, longEdge: Int) -> CGSize {
        outputSize(ratio: aspect.ratio, longEdge: longEdge)
    }

    /// The same for any width ÷ height — the Source rect, a shortlist's own
    /// dominant aspect, need not be a preset.
    public static func outputSize(ratio: Double, longEdge: Int) -> CGSize {
        let r = ratio.isFinite && ratio > 0 ? ratio : 1
        let long = Double(longEdge)
        let short = long / max(r, 1 / r)
        let size = r >= 1 ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
        return CGSize(width: max(2, floor(size.width / 2) * 2), height: max(2, floor(size.height / 2) * 2))
    }

    /// A ratio as small integers — 0.75 → "3:4", 1.5 → "3:2" — the nearest
    /// fraction with sides up to 32; "1.42:1" when none is close.
    public static func aspectLabel(ratio: Double) -> String {
        guard ratio.isFinite, ratio > 0 else { return "1:1" }
        var best: (w: Int, h: Int, err: Double) = (1, 1, abs(ratio - 1))
        for h in 1...32 {
            let w = Int((ratio * Double(h)).rounded())
            guard w >= 1, w <= 32 else { continue }
            let err = abs(Double(w) / Double(h) - ratio)
            if err < best.err { best = (w, h, err) }
        }
        if best.err <= 0.004 {
            func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
            let g = gcd(best.w, best.h)
            return "\(best.w / g):\(best.h / g)"
        }
        return String(format: "%.2f:1", ratio)
    }
}

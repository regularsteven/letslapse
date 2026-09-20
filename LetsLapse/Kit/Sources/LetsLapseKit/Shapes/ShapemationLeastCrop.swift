import Foundation
import CoreGraphics

// Least crop — the Sequence board's model (docs/shapemation/prototype-review.md
// §3–§6; the prototype's model.js; brief §4). One computation feeds the
// Projects rows' badges, the board, the Output step's scrub and the render:
// every photo is cover-fitted into the output rect, the target for its shape
// is a running median of where the shapes fall naturally in the play order
// (keys pin it; the ends hold the median or continue the trend), and the
// crop a photo pays to bring its shape onto that target is a zoom — a
// cover-fitted photo can only shift by zooming so the window slides inside
// it. `f = 1 − 1/z²` is the badge; `L` adds what the aspect crop already
// took. Rejects re-smooth the path without them. The path lets go as the
// shape grows: placement matters while the shape is small, not once it fills
// the frame (brief §1), and how soon it lets go follows the crop tolerance.
//
// Everything is a ratio of the photo's own frame and of the rect, so the
// register's normalised geometry is enough; nothing here decodes a pixel.
// "The shape" is whatever the register holds — a tram's face today, a door
// frame, an archway, a plate or a manhole tomorrow — and every rule below is
// per shortlist, never per subject.

public enum ShapemationLeastCrop {

    // MARK: - Photos

    /// One photo as the model sees it: its frame, its shape's bounds in that
    /// frame, and where it sits in the capture order.
    public struct Photo: Identifiable, Equatable, Sendable {
        public var id: UUID
        /// The frame's oriented pixel size.
        public var frame: CGSize
        /// The shape's axis-aligned bounds in the frame's pixels (`DetectedShape.bounds(in:)`).
        public var bounds: CGRect
        /// The place in the capture order (oldest first) — `captureOrder`'s key.
        public var captureOrder: Int
        /// Groups photos shot from one angle, for the same-angle tie-break;
        /// nil while the register records no pose.
        public var angleKey: String?

        public init(id: UUID, frame: CGSize, bounds: CGRect, captureOrder: Int, angleKey: String? = nil) {
            self.id = id; self.frame = frame; self.bounds = bounds; self.captureOrder = captureOrder; self.angleKey = angleKey
        }

        /// The builder's and the CLI's item, its shape measured on its frame.
        public init(item: ShapemationItem, captureOrder: Int) {
            self.init(id: item.id, frame: item.pixelSize, bounds: item.shape.bounds(in: item.pixelSize),
                      captureOrder: item.captureIndex ?? captureOrder)
        }

        /// Width ÷ height of the frame.
        public var aspect: Double { frame.height > 0 ? Double(frame.width) / Double(frame.height) : 1 }

        /// The shape's centre in unit coordinates of its own frame, y-down.
        public var centre: CGPoint {
            CGPoint(x: frame.width > 0 ? Double(bounds.midX) / Double(frame.width) : 0.5,
                    y: frame.height > 0 ? Double(bounds.midY) / Double(frame.height) : 0.5)
        }

        /// The share of the frame the shape takes: its extent on each axis
        /// as a fraction of the frame's own extent on that axis, the larger
        /// of the two. Bounded by 1 for any shape inside its frame — the long
        /// side over the short edge passes 1 for a door in a portrait photo
        /// and turns `(1 − s)` negative in every weight below.
        public var share: Double {
            guard frame.width > 0, frame.height > 0 else { return 0 }
            return max(Double(bounds.width) / Double(frame.width), Double(bounds.height) / Double(frame.height))
        }

        /// The shape's long side in the frame's pixels.
        public var longSidePx: Double { Double(max(bounds.width, bounds.height)) }
    }

    // MARK: - Settings

    /// How much crop a sequence tolerates — a per-sequence setting, never a
    /// constant, because only the person knows whether the scene around the
    /// shape is the picture (a tram in its street, an archway) or the shape
    /// is (a plate, a manhole). Each level names the flag and reject lines on
    /// `f` and how soon the path lets go of a growing shape.
    public enum Tolerance: String, Codable, CaseIterable, Sendable {
        /// The scene is the picture: flag early, reject early, let go early.
        case strict
        case normal
        /// The shape is what matters: crop freely, hold the place.
        case loose
        /// Nothing rejected, every shape pulled to the path whatever it costs.
        case none

        public var title: String {
            switch self {
            case .strict: return "Strict"
            case .normal: return "Normal"
            case .loose: return "Loose"
            case .none: return "None"
            }
        }

        /// Amber from this crop on.
        public var flag: Double {
            switch self {
            case .strict: return 0.10
            case .normal: return 0.15
            case .loose: return 0.25
            case .none: return 0.30
            }
        }

        /// Red from this crop on, and out when auto-reject is on; nil never rejects.
        public var reject: Double? {
            switch self {
            case .strict: return 0.20
            case .normal: return 0.30
            case .loose: return 0.50
            case .none: return nil
            }
        }

        /// The exponent γ of the let-go: the shape is pulled to the path by
        /// `(1 − σ)^γ`, so 0 pulls every shape all the way and a larger γ
        /// leaves a big shape where it was shot.
        public var letGo: Double {
            switch self {
            case .strict: return 1.0
            case .normal: return 0.5
            case .loose, .none: return 0
            }
        }

        public var summary: String {
            switch self {
            case .strict: return "Flag at 10 %, reject at 20 % — the scene is the picture; a big shape stays where it was shot."
            case .normal: return "Flag at 15 %, reject at 30 %; a growing shape is pulled less and less."
            case .loose: return "Flag at 25 %, reject at 50 %; every shape is pulled to the path."
            case .none: return "Nothing is rejected; every shape is pulled to the path whatever it costs."
            }
        }
    }

    /// A key: where one photo's shape must land, by photo — a reject can
    /// never move it to another photo — and a deliberate zoom past cover fit.
    public struct Key: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        /// Unit coordinates of the output rect, y-down.
        public var place: CGPoint
        /// ≥ 1; a tighter crop the person asked for, raising that photo's own `f`.
        public var zoom: Double

        public init(id: UUID, place: CGPoint, zoom: Double = 1) { self.id = id; self.place = place; self.zoom = max(1, zoom) }

        private enum CodingKeys: String, CodingKey { case id, place, zoom }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            place = try c.decode(CGPoint.self, forKey: .place)
            zoom = max(1, try c.decodeIfPresent(Double.self, forKey: .zoom) ?? 1)
        }
    }

    /// The board's answer, kept with the record so a Shape-mation can be
    /// rendered again exactly, or differently.
    public struct Settings: Codable, Equatable, Sendable {
        /// Even pixels; its aspect is the rect every photo is cover-fitted into.
        public var outputSize: CGSize
        public var tolerance: Tolerance
        /// The running median's window over the play order: 3, 5 or 7.
        public var window: Int
        public enum Ends: String, Codable, CaseIterable, Sendable {
            /// The window shortens at the ends and the median is held there.
            case median
            /// A local line over the first and last `window` photos continues the drift.
            case trend
            public var title: String { self == .median ? "Median" : "Trend" }
        }
        public var ends: Ends
        /// Between keys.
        public var ease: ShapemationFraming.Ease
        /// γ of the let-go; nil takes the tolerance's own.
        public var letGo: Double?
        /// Rejects re-smooth the path and the reds are taken again until none
        /// is left, never below the floor; false takes one pass.
        public var fixpoint: Bool
        public var autoReject: Bool
        public var keys: [Key]
        /// Rejected by hand.
        public var rejected: [UUID]
        /// Red but kept: they pay their crop and pin nothing.
        public var keptAnyway: [UUID]
        public var sort: ShapemationSort
        /// K of the alignment sort's greedy chain.
        public var chainWidth: Int
        public var sameAngle: Bool

        public static let windows = [3, 5, 7]
        public static let defaultWindow = 5

        public init(outputSize: CGSize, tolerance: Tolerance = .normal, window: Int = Settings.defaultWindow, ends: Ends = .median,
                    ease: ShapemationFraming.Ease = .linear, letGo: Double? = nil, fixpoint: Bool = true, autoReject: Bool = true,
                    keys: [Key] = [], rejected: [UUID] = [], keptAnyway: [UUID] = [], sort: ShapemationSort = .smallestFirst,
                    chainWidth: Int = 3, sameAngle: Bool = false) {
            self.outputSize = outputSize; self.tolerance = tolerance; self.window = window; self.ends = ends; self.ease = ease
            self.letGo = letGo; self.fixpoint = fixpoint; self.autoReject = autoReject; self.keys = keys; self.rejected = rejected
            self.keptAnyway = keptAnyway; self.sort = sort; self.chainWidth = chainWidth; self.sameAngle = sameAngle
        }

        /// Width ÷ height of the rect.
        public var aspect: Double { outputSize.height > 0 ? Double(outputSize.width) / Double(outputSize.height) : 1 }

        /// The γ in force.
        public var effectiveLetGo: Double { max(0, letGo ?? tolerance.letGo) }

        public func key(for id: UUID) -> Key? { keys.first { $0.id == id } }

        public mutating func setKey(_ key: Key) {
            if let i = keys.firstIndex(where: { $0.id == key.id }) { keys[i] = key } else { keys.append(key) }
        }
        public mutating func removeKey(for id: UUID) { keys.removeAll { $0.id == id } }

        public mutating func reject(_ id: UUID) {
            if !rejected.contains(id) { rejected.append(id) }
            keptAnyway.removeAll { $0 == id }
        }
        public mutating func unreject(_ id: UUID) { rejected.removeAll { $0 == id } }
        public mutating func keepAnyway(_ id: UUID) {
            if !keptAnyway.contains(id) { keptAnyway.append(id) }
            rejected.removeAll { $0 == id }
        }
        public mutating func unkeep(_ id: UUID) { keptAnyway.removeAll { $0 == id } }

        // Tolerant: a record written by a later build reads with this build's
        // defaults for whatever it does not know, and never fails to decode.
        private enum CodingKeys: String, CodingKey {
            case outputSize, tolerance, window, ends, ease, letGo, fixpoint, autoReject, keys, rejected, keptAnyway, sort, chainWidth, sameAngle
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            outputSize = try c.decode(CGSize.self, forKey: .outputSize)
            tolerance = (try? c.decodeIfPresent(String.self, forKey: .tolerance)).flatMap { $0 }.flatMap(Tolerance.init(rawValue:)) ?? .normal
            let w = try c.decodeIfPresent(Int.self, forKey: .window) ?? Settings.defaultWindow
            window = Settings.windows.contains(w) ? w : Settings.defaultWindow
            ends = (try? c.decodeIfPresent(String.self, forKey: .ends)).flatMap { $0 }.flatMap(Ends.init(rawValue:)) ?? .median
            ease = (try? c.decodeIfPresent(String.self, forKey: .ease)).flatMap { $0 }.flatMap(ShapemationFraming.Ease.init(rawValue:)) ?? .linear
            letGo = try c.decodeIfPresent(Double.self, forKey: .letGo)
            fixpoint = try c.decodeIfPresent(Bool.self, forKey: .fixpoint) ?? true
            autoReject = try c.decodeIfPresent(Bool.self, forKey: .autoReject) ?? true
            keys = (try? c.decodeIfPresent([Key].self, forKey: .keys)).flatMap { $0 } ?? []
            rejected = try c.decodeIfPresent([UUID].self, forKey: .rejected) ?? []
            keptAnyway = try c.decodeIfPresent([UUID].self, forKey: .keptAnyway) ?? []
            sort = (try? c.decodeIfPresent(ShapemationSort.self, forKey: .sort)).flatMap { $0 } ?? .smallestFirst
            chainWidth = max(2, try c.decodeIfPresent(Int.self, forKey: .chainWidth) ?? 3)
            sameAngle = try c.decodeIfPresent(Bool.self, forKey: .sameAngle) ?? false
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(outputSize, forKey: .outputSize)
            try c.encode(tolerance, forKey: .tolerance)
            try c.encode(window, forKey: .window)
            try c.encode(ends, forKey: .ends)
            try c.encode(ease, forKey: .ease)
            try c.encodeIfPresent(letGo, forKey: .letGo)
            try c.encode(fixpoint, forKey: .fixpoint)
            try c.encode(autoReject, forKey: .autoReject)
            try c.encode(keys, forKey: .keys)
            try c.encode(rejected, forKey: .rejected)
            try c.encode(keptAnyway, forKey: .keptAnyway)
            try c.encode(sort, forKey: .sort)
            try c.encode(chainWidth, forKey: .chainWidth)
            try c.encode(sameAngle, forKey: .sameAngle)
        }
    }

    // MARK: - Geometry

    /// Cover fit: the photo scaled to exactly cover the rect, centred. On the
    /// one axis the photo is longer than the rect the overhang is free
    /// shifting room; the shape lands at `place` — its centre carried out by
    /// the overhang — never upscaled beyond the fit.
    public struct Natural: Equatable, Sendable {
        /// `a ÷ A − 1` when the photo is wider than the rect, else 0.
        public var overhangX: Double
        /// `A ÷ a − 1` when the photo is taller, else 0.
        public var overhangY: Double
        /// Where the shape's centre falls, unit coordinates of the rect.
        public var place: CGPoint
    }

    public static func natural(_ photo: Photo, aspect A: Double) -> Natural {
        let a = photo.aspect
        let ex = a > A ? a / A - 1 : 0
        let ey = a < A ? A / a - 1 : 0
        let c = photo.centre
        return Natural(overhangX: ex, overhangY: ey,
                       place: CGPoint(x: 0.5 + (Double(c.x) - 0.5) * (1 + ex), y: 0.5 + (Double(c.y) - 0.5) * (1 + ey)))
    }

    /// The share of the RECT the shape takes under cover fit — what the eye
    /// sees, and the sort's key: a square photo's small shape into 3:2 shows
    /// half again as large as its own frame says. Per axis against the
    /// rect's own extent, the larger of the two; bounded like `Photo.share`.
    public static func renderedShare(_ photo: Photo, aspect A: Double) -> Double {
        guard photo.frame.width > 0, photo.frame.height > 0, A > 0 else { return 0 }
        let a = photo.aspect
        let heights = max(1, A / a)          // the photo's height in rect heights
        let widths = a * heights             // its width, in rect heights (the rect is A wide)
        let sw = Double(photo.bounds.width) / Double(photo.frame.width) * widths / A
        let sh = Double(photo.bounds.height) / Double(photo.frame.height) * heights
        return max(sw, sh)
    }

    /// The zoom one axis needs so that the window can put the shape at `P`
    /// when it falls at `p` with overhang `e`: each side of the shape needs
    /// as much room in the photo as the window asks for.
    static func zoom(target P: Double, place p: Double, overhang e: Double) -> Double {
        let left = p + e / 2, right = 1 + e / 2 - p
        var z = 1.0
        if left > 0 { z = max(z, P / left) } else if P > 0 { z = .infinity }
        if right > 0 { z = max(z, (1 - P) / right) } else if P < 1 { z = .infinity }
        return min(z, 1e6)
    }

    public struct Evaluation: Equatable, Sendable {
        public var natural: Natural
        public var zoomX: Double
        public var zoomY: Double
        /// The zoom past cover fit the shift asks for (× the key's own).
        public var zoom: Double
        /// `1 − 1/z²`: the share of the photo's pixels lost beyond the aspect crop — the badge.
        public var crop: Double
        /// Everything gone from the source, aspect crop included.
        public var loss: Double
        /// What the aspect alone took, before any shift.
        public var aspectLoss: Double
        /// The shape's share of the rect as rendered: the cover-fit share × the zoom.
        public var renderedShare: Double
        /// The output window over the source, unit coordinates of the source photo.
        public var window: CGRect
    }

    /// The crop a photo pays to bring its shape from where it falls onto
    /// `target`, and the window that does it. `zoom` ≥ 1 is a key's
    /// deliberate zoom beyond cover fit.
    public static func evaluate(_ photo: Photo, aspect A: Double, target P: CGPoint, zoom key: Double = 1) -> Evaluation {
        let n = natural(photo, aspect: A)
        let zx = zoom(target: Double(P.x), place: Double(n.place.x), overhang: n.overhangX)
        let zy = zoom(target: Double(P.y), place: Double(n.place.y), overhang: n.overhangY)
        let z = max(zx, zy) * max(1, key)
        let f = 1 - 1 / (z * z)
        let aspectFactor = (1 + n.overhangX) * (1 + n.overhangY)
        let L = 1 - 1 / (aspectFactor * z * z)
        let winW = 1 / (z * (1 + n.overhangX)), winH = 1 / (z * (1 + n.overhangY))
        let c = photo.centre
        var left = Double(c.x) - Double(P.x) * winW, top = Double(c.y) - Double(P.y) * winH
        left = min(max(left, 0), 1 - winW)
        top = min(max(top, 0), 1 - winH)
        return Evaluation(natural: n, zoomX: zx, zoomY: zy, zoom: z, crop: f, loss: L, aspectLoss: 1 - 1 / aspectFactor,
                          renderedShare: renderedShare(photo, aspect: A) * z,
                          window: CGRect(x: left, y: top, width: winW, height: winH))
    }

    public enum Verdict: String, Sendable {
        case green, amber, red
        public var isFlagged: Bool { self != .green }
    }

    public static func verdict(crop f: Double, tolerance: Tolerance) -> Verdict {
        if let reject = tolerance.reject, f >= reject { return .red }
        return f >= tolerance.flag ? .amber : .green
    }

    // MARK: - The path

    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return 0.5 }
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    /// A running median over `window` neighbours in order — one outlier does
    /// not bend it; the window shortens at the ends.
    public static func runningMedian(_ values: [Double], window: Int) -> [Double] {
        let h = max(0, window / 2)
        return values.indices.map { i in median(Array(values[max(0, i - h)...min(values.count - 1, i + h)])) }
    }

    static func lineFit(_ xs: [Double], _ ys: [Double]) -> (m: Double, b: Double) {
        let n = xs.count
        guard n >= 2 else { return (0, ys.first ?? 0.5) }
        let mx = xs.reduce(0, +) / Double(n), my = ys.reduce(0, +) / Double(n)
        var num = 0.0, den = 0.0
        for i in 0..<n { num += (xs[i] - mx) * (ys[i] - my); den += (xs[i] - mx) * (xs[i] - mx) }
        let m = den > 0 ? num / den : 0
        return (m, my - m * mx)
    }

    /// The ends continue the drift: a local line over the first and the last
    /// `window` values replaces the shortened median there.
    static func continueEnds(_ path: [Double], values: [Double], window: Int) -> [Double] {
        let n = values.count
        guard n >= 3 else { return path }
        let h = max(0, window / 2), k = min(n, window)
        let head = lineFit((0..<k).map(Double.init), Array(values[0..<k]))
        let tail = lineFit(((n - k)..<n).map(Double.init), Array(values[(n - k)..<n]))
        var out = path
        for i in 0..<min(h, n) { out[i] = clamp01(head.m * Double(i) + head.b) }
        for i in max(0, n - h)..<n { out[i] = clamp01(tail.m * Double(i) + tail.b) }
        return out
    }

    static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

    /// The target for every index of the play order: the running median of
    /// the natural places (ends per `ends`), then the keys — the offset each
    /// pin makes from the automatic path is eased between neighbouring pins,
    /// and the ends are pinned to no offset unless keyed.
    public static func path(naturals: [CGPoint], keys: [Int: CGPoint], window: Int, ends: Settings.Ends,
                            ease: ShapemationFraming.Ease) -> [CGPoint] {
        let n = naturals.count
        guard n > 0 else { return [] }
        let xs = naturals.map { Double($0.x) }, ys = naturals.map { Double($0.y) }
        var px = runningMedian(xs, window: window), py = runningMedian(ys, window: window)
        if ends == .trend {
            px = continueEnds(px, values: xs, window: window)
            py = continueEnds(py, values: ys, window: window)
        }
        let auto = (0..<n).map { CGPoint(x: px[$0], y: py[$0]) }
        let pins = keys.filter { $0.key >= 0 && $0.key < n }
        guard !pins.isEmpty else { return auto }
        var anchors: [(i: Int, dx: Double, dy: Double)] = [(0, 0, 0), (n - 1, 0, 0)]
        for (i, place) in pins {
            let dx = Double(place.x) - Double(auto[i].x), dy = Double(place.y) - Double(auto[i].y)
            if let j = anchors.firstIndex(where: { $0.i == i }) { anchors[j] = (i, dx, dy) } else { anchors.append((i, dx, dy)) }
        }
        anchors.sort { $0.i < $1.i }
        return auto.enumerated().map { i, p in
            var lo = anchors[0], hi = anchors[anchors.count - 1]
            for j in 0..<(anchors.count - 1) where i >= anchors[j].i && i <= anchors[j + 1].i {
                lo = anchors[j]; hi = anchors[j + 1]; break
            }
            var u = hi.i == lo.i ? 0 : Double(i - lo.i) / Double(hi.i - lo.i)
            if ease == .inOut { u = u * u * (3 - 2 * u) }
            return CGPoint(x: clamp01(Double(p.x) + lo.dx + (hi.dx - lo.dx) * u),
                           y: clamp01(Double(p.y) + lo.dy + (hi.dy - lo.dy) * u))
        }
    }

    // MARK: - Sorts

    /// The play order: by the rendered share (smallest first is the
    /// approach), the capture order, or the alignment chain — from the
    /// smallest, each next photo is whichever of the next `chainWidth` by
    /// size falls nearest the current one's place, the jump discounted as
    /// the shape fills the frame, a change of angle penalised when asked.
    public static func ordered(_ photos: [Photo], sort: ShapemationSort, aspect A: Double,
                               chainWidth: Int = 3, sameAngle: Bool = false) -> [Photo] {
        let bySize = photos.sorted { a, b in
            let sa = renderedShare(a, aspect: A), sb = renderedShare(b, aspect: A)
            return sa == sb ? a.captureOrder < b.captureOrder : sa < sb
        }
        switch sort {
        case .smallestFirst:
            return bySize
        case .largestFirst:
            return Array(bySize.reversed())
        case .captureOrder:
            return photos.sorted { $0.captureOrder == $1.captureOrder ? $0.id.uuidString < $1.id.uuidString : $0.captureOrder < $1.captureOrder }
        case .alignment:
            guard bySize.count >= 3 else { return bySize }
            var pool = bySize
            var out = [pool.removeFirst()]
            let K = max(1, chainWidth)
            while !pool.isEmpty {
                let cur = out[out.count - 1]
                let nc = natural(cur, aspect: A), sc = min(1, renderedShare(cur, aspect: A))
                var best = 0, bestCost = Double.infinity
                for j in 0..<min(K, pool.count) {
                    let n = natural(pool[j], aspect: A)
                    var cost = hypot(Double(n.place.x - nc.place.x), Double(n.place.y - nc.place.y)) * (1 - sc)
                    if sameAngle, let a = cur.angleKey, let b = pool[j].angleKey, a != b { cost += 0.05 }
                    cost += Double(j) * 0.002   // the size order on ties
                    if cost < bestCost { bestCost = cost; best = j }
                }
                out.append(pool.remove(at: best))
            }
            return out
        }
    }

    // MARK: - The board

    public struct Row: Identifiable, Equatable, Sendable {
        public var id: UUID { photo.id }
        public var photo: Photo
        /// The place in the play order; −1 for a rejected photo.
        public var index: Int
        /// The path's point for this index.
        public var path: CGPoint
        /// Where the shape is put: the path, or short of it once the shape is big.
        public var target: CGPoint
        public var evaluation: Evaluation
        public var verdict: Verdict
        public var key: Key?
        public var rejected: Bool
        public var rejectedByHand: Bool
        /// Red but kept on request.
        public var keptAnyway: Bool
    }

    public struct Board: Equatable, Sendable {
        /// The kept photos in the play order — what renders.
        public var rows: [Row]
        /// Rejected by hand or by the rule, in the sorted order, each judged
        /// at the path point of the nearest kept photo by size.
        public var rejected: [Row]
        public var path: [CGPoint]
        /// Σ J over the natural places — the shortlist's coherence, the alignment sort's number.
        public var sumJ: Double
        /// Σ |ΔT| over the targets — the jump the viewer sees.
        public var renderedJump: Double
        public var largestStep: Double
        /// Mean `f` over the kept rows.
        public var meanCrop: Double
        /// Mean `L`.
        public var meanLoss: Double
        public var meanAspectLoss: Double
        /// Amber rows kept.
        public var flagged: Int
        /// Red rows kept — one pass, the floor, or Keep anyway.
        public var red: Int
        /// Steps where the rendered share falls against the sort's direction.
        public var sizeBreaks: Int
        public var angleChanges: Int
        /// The rejects stopped at the floor.
        public var floorHit: Bool

        public var isEmpty: Bool { rows.isEmpty }
        public var members: Int { rows.count }

        /// "61 members · 22 rejected · 26 flagged · 2 red".
        public var countLine: String {
            var parts = ["\(rows.count) member\(rows.count == 1 ? "" : "s")", "\(rejected.count) rejected", "\(flagged) flagged"]
            if red > 0 { parts.append("\(red) red") }
            return parts.joined(separator: " · ")
        }
    }

    /// Never fewer kept than this: the larger of three and half the shortlist.
    public static func floor(of count: Int) -> Int { max(3, (count + 1) / 2) }

    /// One evaluation of the board: the play order, the path, every photo's
    /// target and crop, the rejects, the numbers. Auto-reject takes the reds
    /// (Keep anyway excepted), re-smooths without them and, to a fixpoint,
    /// looks again — never below `floor(of:)`; when the floor is reached only
    /// the worst reds go and the rest stay red.
    public static func board(_ photos: [Photo], settings: Settings) -> Board {
        let A = settings.aspect
        let manual = Set(settings.rejected), keep = Set(settings.keptAnyway)
        let all = ordered(photos, sort: settings.sort, aspect: A, chainWidth: settings.chainWidth, sameAngle: settings.sameAngle)
        let candidates = all.filter { !manual.contains($0.id) }
        var kept = candidates
        var auto = Set<UUID>()
        let gamma = settings.effectiveLetGo

        func pass(_ kept: [Photo]) -> (path: [CGPoint], rows: [Row]) {
            let naturals = kept.map { natural($0, aspect: A).place }
            var pins: [Int: CGPoint] = [:], keyAt: [Int: Key] = [:]
            for (i, ph) in kept.enumerated() {
                if let k = settings.key(for: ph.id) { pins[i] = k.place; keyAt[i] = k }
            }
            let path = self.path(naturals: naturals, keys: pins, window: settings.window, ends: settings.ends, ease: settings.ease)
            let rows = kept.enumerated().map { i, ph -> Row in
                let n = naturals[i], key = keyAt[i]
                let target: CGPoint
                if key != nil {
                    target = path[i]
                } else {
                    let w = gamma == 0 ? 1 : pow(1 - min(1, renderedShare(ph, aspect: A)), gamma)
                    target = CGPoint(x: Double(n.x) + (Double(path[i].x) - Double(n.x)) * w,
                                     y: Double(n.y) + (Double(path[i].y) - Double(n.y)) * w)
                }
                let ev = evaluate(ph, aspect: A, target: target, zoom: key?.zoom ?? 1)
                return Row(photo: ph, index: i, path: path[i], target: target, evaluation: ev,
                           verdict: verdict(crop: ev.crop, tolerance: settings.tolerance), key: key,
                           rejected: false, rejectedByHand: false, keptAnyway: keep.contains(ph.id))
            }
            return (path, rows)
        }

        var (path, rows) = pass(kept)
        var floorHit = false
        if settings.autoReject, settings.tolerance.reject != nil {
            let floor = Self.floor(of: candidates.count)
            for _ in 0..<(settings.fixpoint ? 10 : 1) {
                var reds = rows.filter { $0.verdict == .red && !keep.contains($0.id) }
                    .sorted { $0.evaluation.crop > $1.evaluation.crop }
                if reds.isEmpty { break }
                let room = kept.count - floor
                if room <= 0 { floorHit = true; break }
                if reds.count > room { reds = Array(reds.prefix(room)); floorHit = true }
                for r in reds { auto.insert(r.id) }
                kept = kept.filter { !auto.contains($0.id) }
                (path, rows) = pass(kept)
                if floorHit { break }
            }
        }

        // The numbers.
        var sumJ = 0.0, jump = 0.0, largest = 0.0, breaks = 0, angles = 0
        let ascending = settings.sort != .largestFirst
        for i in 0..<max(0, rows.count - 1) {
            let a = rows[i], b = rows[i + 1]
            let na = a.evaluation.natural.place, nb = b.evaluation.natural.place
            sumJ += hypot(Double(nb.x - na.x), Double(nb.y - na.y)) * (1 - min(1, renderedShare(a.photo, aspect: A)))
            let step = hypot(Double(b.target.x - a.target.x), Double(b.target.y - a.target.y))
            jump += step
            largest = max(largest, step)
            let d = b.evaluation.renderedShare - a.evaluation.renderedShare
            if (ascending ? d : -d) < -0.002 { breaks += 1 }
            if let ka = a.photo.angleKey, let kb = b.photo.angleKey, ka != kb { angles += 1 }
        }
        let n = Double(max(1, rows.count))
        let meanCrop = rows.reduce(0) { $0 + $1.evaluation.crop } / n
        let meanLoss = rows.reduce(0) { $0 + $1.evaluation.loss } / n
        let meanAspect = rows.reduce(0) { $0 + $1.evaluation.aspectLoss } / n

        // The rejects, judged where they would have sat: the path point of
        // the kept photo nearest in size, let go by their own share.
        let rejectedRows: [Row] = all.filter { manual.contains($0.id) || auto.contains($0.id) }.map { ph in
            let sigma = renderedShare(ph, aspect: A)
            let nearest = rows.min { abs($0.evaluation.renderedShare / max($0.evaluation.zoom, 1e-9) - sigma)
                                   < abs($1.evaluation.renderedShare / max($1.evaluation.zoom, 1e-9) - sigma) }
            let P = nearest?.path ?? CGPoint(x: 0.5, y: 0.55)
            let n = natural(ph, aspect: A).place
            let w = gamma == 0 ? 1 : pow(1 - min(1, sigma), gamma)
            let target = CGPoint(x: Double(n.x) + (Double(P.x) - Double(n.x)) * w, y: Double(n.y) + (Double(P.y) - Double(n.y)) * w)
            let ev = evaluate(ph, aspect: A, target: target)
            return Row(photo: ph, index: -1, path: P, target: target, evaluation: ev,
                       verdict: verdict(crop: ev.crop, tolerance: settings.tolerance), key: settings.key(for: ph.id),
                       rejected: true, rejectedByHand: manual.contains(ph.id), keptAnyway: false)
        }

        return Board(rows: rows, rejected: rejectedRows, path: path, sumJ: sumJ, renderedJump: jump, largestStep: largest,
                     meanCrop: rows.isEmpty ? 0 : meanCrop, meanLoss: rows.isEmpty ? 0 : meanLoss,
                     meanAspectLoss: rows.isEmpty ? 0 : meanAspect,
                     flagged: rows.filter { $0.verdict == .amber }.count, red: rows.filter { $0.verdict == .red }.count,
                     sizeBreaks: breaks, angleChanges: angles, floorHit: floorHit)
    }

    // MARK: - The rect

    /// The shortlist's dominant frame aspect (width ÷ height) — the Source
    /// rect, the default. A tie goes to the wider. Nil for no photos.
    public static func dominantAspect(of photos: [Photo]) -> Double? {
        guard !photos.isEmpty else { return nil }
        var counts: [Int: (count: Int, aspect: Double)] = [:]
        for p in photos {
            let key = Int((p.aspect * 1000).rounded())
            counts[key, default: (0, p.aspect)].count += 1
        }
        return counts.values.max { a, b in a.count == b.count ? a.aspect < b.aspect : a.count < b.count }?.aspect
    }

    /// Whether the shortlist's sizes progress at all: the largest rendered
    /// share over the smallest, below which a size sort is a shuffle and the
    /// capture order is the better default.
    public static func sizeSpread(of photos: [Photo], aspect A: Double) -> Double {
        let shares = photos.map { renderedShare($0, aspect: A) }.filter { $0 > 0 }
        guard let lo = shares.min(), let hi = shares.max(), lo > 0 else { return 1 }
        return hi / lo
    }
    public static let approachSpread = 1.5
}

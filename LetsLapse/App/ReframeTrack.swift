import CoreGraphics
import Foundation

/// The punch-in reframe track: spatial keyframes over the source, kept
/// deliberately apart from the warp timeline. A key carries only *where the
/// crop sits* at one source moment — speed lives in `WarpTimeline`, and blur
/// follows speed through the compiled windows. The two tracks are related by
/// adjacency on the same bar, never by data.
///
/// Empty track = the full frame at the chosen canvas, playing per the warp.
/// One key = one constant crop, the way one stretch is one constant speed.
struct ReframeTrack: Codable, Equatable {
    /// Where the crop sits at one source moment.
    struct Key: Identifiable, Codable, Equatable {
        var id = UUID()
        /// Source time, seconds.
        var t: Double
        /// Punch factor. 1 = the whole frame at the canvas ratio; 6 = the
        /// tightest crop the track allows.
        var z: Double
        /// Crop centre in source pixels, display-oriented — the same space as
        /// `AppModel.sourceDisplaySize()`, so a metadata rotation needs no
        /// fixups.
        var cx: Double
        var cy: Double
    }

    /// How the move between two neighbouring keys plays out. Durations are
    /// OUTPUT (clip) seconds — the viewer's clock, same as a seam's ramp — and
    /// the move *arrives*: the crop holds the earlier key's framing, then
    /// eases into the later key over the last `span` of the gap. "Be locked on
    /// by here; take this long to get there."
    struct Move: Codable, Equatable {
        enum Span: String, Codable, CaseIterable {
            /// The move fills the whole gap between the two keys.
            case gap = "span"
            case half = "0.5s"
            case one = "1s"
            case two = "2s"

            /// Move length in output seconds; nil = the whole gap.
            var seconds: Double? {
                switch self {
                case .gap: return nil
                case .half: return 0.5
                case .one: return 1
                case .two: return 2
                }
            }

            var label: String { rawValue }
        }

        enum Curve: String, Codable, CaseIterable {
            /// Cubic ease-in-out — a planned move that settles. The default.
            case ease
            /// Linear "through" motion — for the interior keys of a tracking
            /// chain, so a follow doesn't pulse to a stop at every key.
            case linear

            var label: String {
                switch self {
                case .ease: return "ease"
                case .linear: return "thru"
                }
            }
        }

        var span: Span = .gap
        var curve: Curve = .ease
    }

    /// Sorted by `t`. `moves.count == max(0, keys.count - 1)` — move `i`
    /// describes the travel from key `i` to key `i + 1`.
    var keys: [Key] = []
    var moves: [Move] = []

    var isEmpty: Bool { keys.isEmpty }

    // MARK: - Limits

    static let minZoom = 1.0
    static let maxZoom = 6.0
    /// Keys closer than this in source seconds merge rather than stack — a
    /// couple of output frames, not an editing gate.
    static let minimumKeySpacing = 0.05

    // MARK: - Edits

    /// Insert a key at `t`, keeping order and the move array aligned. A key
    /// within `minimumKeySpacing` of an existing one updates that key instead.
    /// Returns the key's index.
    @discardableResult
    mutating func addKey(t: Double, z: Double, cx: Double, cy: Double) -> Int {
        if let index = keys.firstIndex(where: { abs($0.t - t) < Self.minimumKeySpacing }) {
            keys[index].z = z
            keys[index].cx = cx
            keys[index].cy = cy
            return index
        }
        let key = Key(t: t, z: z, cx: cx, cy: cy)
        let index = keys.firstIndex { $0.t > t } ?? keys.count
        keys.insert(key, at: index)
        if keys.count > 1 {
            // The new gap inherits an ease — the planned-move default.
            moves.insert(Move(), at: max(0, index - 1))
        }
        return index
    }

    /// Remove the key at `index`, merging its two moves into one (the
    /// earlier gap's settings survive, like a removed stretch keeping its
    /// neighbour's speed).
    mutating func removeKey(at index: Int) {
        guard keys.indices.contains(index) else { return }
        keys.remove(at: index)
        if !moves.isEmpty {
            moves.remove(at: index == 0 ? 0 : index - 1)
        }
    }

    /// Move a key in time, clamped at its neighbours (a key can't cross one —
    /// the same rule as a stretch boundary), so the surrounding moves keep
    /// their settings.
    mutating func setTime(_ t: Double, forKey index: Int) {
        guard keys.indices.contains(index) else { return }
        let lo = index > 0 ? keys[index - 1].t + Self.minimumKeySpacing : 0
        let hi = index < keys.count - 1 ? keys[index + 1].t - Self.minimumKeySpacing : .infinity
        keys[index].t = min(max(t, lo), max(lo, hi))
    }

    mutating func setMove(_ move: Move, at index: Int) {
        guard moves.indices.contains(index) else { return }
        moves[index] = move
    }

    /// Re-clamp every key against a (possibly new) canvas — a crop flush with
    /// the right edge at 16:9 has to move to stay inside 9:16.
    mutating func clamp(aspect: Double, sourceSize: CGSize) {
        for index in keys.indices {
            keys[index].z = min(max(keys[index].z, Self.minZoom), Self.maxZoom)
            let centre = ReframeMath.clampCenter(
                z: keys[index].z, cx: keys[index].cx, cy: keys[index].cy,
                aspect: aspect, sourceSize: sourceSize)
            keys[index].cx = centre.cx
            keys[index].cy = centre.cy
        }
    }

    // MARK: - Evaluation

    /// The crop state at source time `t`.
    ///
    /// `outputTime` maps source seconds to clip seconds through the warp —
    /// the UI hands in the timeline's piecewise mapping, the renderer the
    /// exact compiled schedule — so an arrive-anchored move measures its span
    /// on the viewer's clock no matter what the speed curve is doing.
    func frame(
        atSource t: Double,
        outputTime: (Double) -> Double
    ) -> (z: Double, cx: Double, cy: Double) {
        guard let first = keys.first else { return (1, 0, 0) }
        guard keys.count > 1 else { return (first.z, first.cx, first.cy) }
        if t <= first.t { return (first.z, first.cx, first.cy) }
        guard let last = keys.last, t < last.t else {
            let last = keys[keys.count - 1]
            return (last.z, last.cx, last.cy)
        }

        var lowerIndex = 0
        for index in 1..<keys.count where keys[index].t >= t {
            lowerIndex = index - 1
            break
        }
        let a = keys[lowerIndex]
        let b = keys[lowerIndex + 1]
        let move = moves.indices.contains(lowerIndex) ? moves[lowerIndex] : Move()

        let outA = outputTime(a.t)
        let outB = outputTime(b.t)
        let gap = max(0.0001, outB - outA)
        let span = min(move.span.seconds ?? gap, gap)
        let start = outB - span
        let u = min(max((outputTime(t) - start) / max(0.0001, span), 0), 1)
        let e = move.curve == .ease ? Self.ease(u) : u

        return (
            z: ReframeMath.logLerp(a.z, b.z, e, floor: Self.minZoom),
            cx: a.cx + (b.cx - a.cx) * e,
            cy: a.cy + (b.cy - a.cy) * e
        )
    }

    /// The crop window at source time `t`, clamped inside the frame.
    func crop(
        atSource t: Double,
        aspect: Double,
        sourceSize: CGSize,
        outputTime: (Double) -> Double
    ) -> CGRect {
        let frame = frame(atSource: t, outputTime: outputTime)
        return ReframeMath.cropRect(
            z: frame.z, cx: frame.cx, cy: frame.cy,
            aspect: aspect, sourceSize: sourceSize)
    }

    /// Cubic ease-in-out — the same curve the reframe has always used, so a
    /// punch reads as one racking move, not three animations.
    static func ease(_ u: Double) -> Double {
        let u = min(max(u, 0), 1)
        if u < 0.5 { return 4 * u * u * u }
        let f = -2 * u + 2
        return 1 - (f * f * f) / 2
    }
}

// MARK: - Crop maths

/// The reframe's geometry — no state, nothing to mock. The lane, the player
/// and the renderer all read the crop from here, so what you scrub is exactly
/// what gets written out.
enum ReframeMath {
    /// The largest window of `aspect` (width ÷ height) that fits inside the
    /// source — the crop at zoom 1, and the unit every zoom divides.
    static func baseCrop(aspect: Double, sourceSize: CGSize) -> CGSize {
        let width = Double(sourceSize.width)
        let height = Double(sourceSize.height)
        guard width > 0, height > 0, aspect > 0, aspect.isFinite else { return .zero }
        if width / height > aspect {
            return CGSize(width: height * aspect, height: height)
        }
        return CGSize(width: width, height: width / aspect)
    }

    /// A centre that keeps the whole crop window inside the source. A crop
    /// wider than the source (only reachable with a nonsense zoom) centres.
    static func clampCenter(
        z: Double,
        cx: Double,
        cy: Double,
        aspect: Double,
        sourceSize: CGSize
    ) -> (cx: Double, cy: Double) {
        let base = baseCrop(aspect: aspect, sourceSize: sourceSize)
        guard base.width > 0, base.height > 0 else { return (cx, cy) }
        let zoom = min(max(z, ReframeTrack.minZoom), ReframeTrack.maxZoom)
        let w = Double(base.width) / zoom
        let h = Double(base.height) / zoom
        let width = Double(sourceSize.width)
        let height = Double(sourceSize.height)

        let x = w >= width ? width / 2 : min(max(cx, w / 2), width - w / 2)
        let y = h >= height ? height / 2 : min(max(cy, h / 2), height - h / 2)
        return (x, y)
    }

    /// The crop window in source pixels, already clamped to the frame.
    static func cropRect(
        z: Double,
        cx: Double,
        cy: Double,
        aspect: Double,
        sourceSize: CGSize
    ) -> CGRect {
        let base = baseCrop(aspect: aspect, sourceSize: sourceSize)
        guard base.width > 0, base.height > 0 else { return .zero }
        let zoom = min(max(z, ReframeTrack.minZoom), ReframeTrack.maxZoom)
        let w = min(Double(base.width) / zoom, Double(sourceSize.width))
        let h = min(Double(base.height) / zoom, Double(sourceSize.height))
        let centre = clampCenter(z: zoom, cx: cx, cy: cy, aspect: aspect, sourceSize: sourceSize)
        return CGRect(x: centre.cx - w / 2, y: centre.cy - h / 2, width: w, height: h)
    }

    static func logLerp(_ a: Double, _ b: Double, _ e: Double, floor: Double) -> Double {
        let a = max(a, floor)
        let b = max(b, floor)
        return exp(log(a) + (log(b) - log(a)) * e)
    }
}

import Foundation
import CoreGraphics

// The Shape-mation alignment scorer (docs/shapemation/synthetic-corpus.md §2
// and §5): a synthetic scene's manifest — the exact outline the drawing put
// in the frame and the perturbed one the pipeline is given — and the maths
// that pushes the truth through a plan's placements and says how far each
// landed from where the plan promised. The `lapse shapemation` subcommand
// stages, plans and scores with it; the Kit holds the model and the sums so
// the tests can pin them without a file in sight.

/// One scene folder's `scene.json`, as Python writes it. Geometry is in the
/// oriented frame's pixels, y-down, origin top-left — what
/// `DetectedShape.quad(corners:frame:)` and `.ellipse(centre:…frame:)` take.
public struct SceneManifest: Codable, Equatable, Sendable {
    public static let fileName = "scene.json"

    public struct Frame: Codable, Equatable, Sendable {
        public var width: Int
        public var height: Int
        public init(width: Int, height: Int) { self.width = width; self.height = height }
    }

    public struct Subject: Codable, Equatable, Sendable {
        public var part: String
        public var viewpoint: String
        public var scene: String
        /// The Kit family the outline intends under this viewpoint — what the
        /// staged register must load back as (`stage`'s acceptance).
        public var family: DetectedShape.Family
        public init(part: String, viewpoint: String, scene: String, family: DetectedShape.Family) {
            self.part = part; self.viewpoint = viewpoint; self.scene = scene; self.family = family
        }
    }

    public struct Sequence: Codable, Equatable, Sendable {
        public var index: Int
        public var of: Int
        /// Where the scene sits in its run, 0…1 — the subject's true scale grows with it.
        public var approach: Double
        public init(index: Int, of: Int, approach: Double) { self.index = index; self.of = of; self.approach = approach }
    }

    /// An outline: a quad by its four corners (clockwise from top-left, the
    /// register's order) or an ellipse by centre, semi-axes (a ≥ b) and the
    /// major axis's angle in radians. Pose travels with the truth and is not
    /// a register field yet.
    public struct Geometry: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case quad, ellipse }
        public var kind: Kind
        public var cornersPx: [CGPoint]?
        public var centrePx: CGPoint?
        public var semiAxesPx: [Double]?
        public var rotation: Double?
        public var tiltDeg: Double?
        public var yawDeg: Double?

        public init(kind: Kind, cornersPx: [CGPoint]? = nil, centrePx: CGPoint? = nil, semiAxesPx: [Double]? = nil,
                    rotation: Double? = nil, tiltDeg: Double? = nil, yawDeg: Double? = nil) {
            self.kind = kind; self.cornersPx = cornersPx; self.centrePx = centrePx; self.semiAxesPx = semiAxesPx
            self.rotation = rotation; self.tiltDeg = tiltDeg; self.yawDeg = yawDeg
        }

        public static func quad(_ corners: [CGPoint], tiltDeg: Double? = nil, yawDeg: Double? = nil) -> Geometry {
            Geometry(kind: .quad, cornersPx: corners, tiltDeg: tiltDeg, yawDeg: yawDeg)
        }
        public static func ellipse(centre: CGPoint, semiAxes: (Double, Double), rotation: Double,
                                   tiltDeg: Double? = nil, yawDeg: Double? = nil) -> Geometry {
            Geometry(kind: .ellipse, centrePx: centre, semiAxesPx: [semiAxes.0, semiAxes.1], rotation: rotation, tiltDeg: tiltDeg, yawDeg: yawDeg)
        }
    }

    public struct Perturbation: Codable, Equatable, Sendable {
        public var sigmaScale: Double
        public var sigmaCentre: Double
        public var sigmaRotationDeg: Double
        public var seed: Int
        public init(sigmaScale: Double, sigmaCentre: Double, sigmaRotationDeg: Double, seed: Int) {
            self.sigmaScale = sigmaScale; self.sigmaCentre = sigmaCentre; self.sigmaRotationDeg = sigmaRotationDeg; self.seed = seed
        }
    }

    public var schema: Int
    public var id: String
    public var set: String
    public var frame: Frame
    public var subject: Subject
    public var sequence: Sequence
    /// Exact: the subject part's outline through the placement transform.
    public var truth: Geometry
    /// What the pipeline is given: the truth with the three dials applied.
    public var perturbed: Geometry
    public var perturbation: Perturbation

    public init(schema: Int = 1, id: String, set: String, frame: Frame, subject: Subject, sequence: Sequence,
                truth: Geometry, perturbed: Geometry, perturbation: Perturbation) {
        self.schema = schema; self.id = id; self.set = set; self.frame = frame; self.subject = subject
        self.sequence = sequence; self.truth = truth; self.perturbed = perturbed; self.perturbation = perturbation
    }

    public var frameSize: CGSize { CGSize(width: frame.width, height: frame.height) }

    public static func url(inProjectFolder folder: URL) -> URL {
        folder.appendingPathComponent(fileName, isDirectory: false)
    }

    /// The manifest beside a staged project's register. Throws so the CLI can
    /// say which scene could not be read rather than dropping it in silence.
    public static func load(inProjectFolder folder: URL) throws -> SceneManifest {
        try load(from: url(inProjectFolder: folder))
    }

    public static func load(from url: URL) throws -> SceneManifest {
        try JSONDecoder().decode(SceneManifest.self, from: Data(contentsOf: url))
    }

    public enum GeometryError: Error, CustomStringConvertible {
        case quadNeedsFourCorners(Int)
        case ellipseNeedsCentreAndAxes

        public var description: String {
            switch self {
            case .quadNeedsFourCorners(let n): return "a quad needs four cornersPx, got \(n)"
            case .ellipseNeedsCentreAndAxes: return "an ellipse needs centrePx and semiAxesPx [a, b]"
            }
        }
    }

    /// The register shape for a manifest geometry, on a frame of `frame`
    /// pixels — through the same factories the Masks tab draws with, so the
    /// corpus and a hand never disagree about normalisation. Source `manual`.
    public static func makeShape(_ geometry: Geometry, frame: CGSize) throws -> DetectedShape {
        switch geometry.kind {
        case .quad:
            let corners = geometry.cornersPx ?? []
            guard corners.count == 4 else { throw GeometryError.quadNeedsFourCorners(corners.count) }
            return DetectedShape.quad(corners: corners, frame: frame, source: .manual)
        case .ellipse:
            guard let centre = geometry.centrePx, let axes = geometry.semiAxesPx, axes.count == 2 else {
                throw GeometryError.ellipseNeedsCentreAndAxes
            }
            return DetectedShape.ellipse(centre: centre, semiAxisX: axes[0], semiAxisY: axes[1],
                                         rotation: geometry.rotation ?? 0, frame: frame, source: .manual)
        }
    }
}

/// What a plan did to the truth. The plan promises that the register shape
/// lands centred on the placement's `target` at `targetSizePx` (long side)
/// and levelled — the one anchor under the stack modes, each photo's own
/// framing under `.frame`; the truth pushed through the same transform says
/// how far the perturbed register missed. Everything is in canvas pixels,
/// the headline residual `centre` in units of `targetSizePx` so a small
/// subject and a large one read on one scale.
public struct ShapemationScore: Codable, Equatable, Sendable {
    public struct ItemScore: Codable, Equatable, Sendable {
        public var itemID: UUID
        /// Transformed truth centre to the placement's `target`, canvas pixels.
        public var centrePx: Double
        /// `centrePx / targetSizePx`.
        public var centre: Double
        /// Transformed truth long side ÷ `targetSizePx` − 1.
        public var scale: Double
        /// The transformed truth's top edge (quads) or major axis (ovals) from
        /// horizontal, in degrees; 0 for a circle by definition.
        public var rotationDeg: Double
        /// Quads: RMS corner distance to the rectangle the plan targets —
        /// centred on `target`, long side `targetSizePx`, the truth's own
        /// aspect, lying the way the truth does.
        public var cornerRmsPx: Double?
        /// The plan's own feasibility call on this placement (`fits` under
        /// the stack modes by construction).
        public var verdict: ShapemationPlan.Placement.Feasibility.Verdict
    }

    /// Median · p90 (nearest rank) · max of one residual over the placed items.
    public struct Stat: Codable, Equatable, Sendable {
        public var median: Double
        public var p90: Double
        public var max: Double

        public init?(_ values: [Double]) {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            median = ShapemationScore.median(sorted)
            p90 = ShapemationScore.percentile(sorted, 0.9)
            max = sorted[sorted.count - 1]
        }
    }

    /// In the plan's placement order.
    public var items: [ItemScore]
    /// The aggregates are over magnitudes — a signed `scale` or `rotationDeg`
    /// that scatters either way would median to nothing.
    public var centre: Stat?
    public var scale: Stat?
    public var rotationDeg: Stat?
    /// Nil when no quad was placed.
    public var cornerRmsPx: Stat?
    /// IoU of consecutive placed footprints in the plan's order — the "does
    /// it read as one motion" number. Nil under two placements.
    public var pairwiseOverlap: Stat?
    /// Of the scored items, how many the plan flagged as short of the frame
    /// and how many as upscaled past the cap (one that is both counts twice).
    public var flaggedShort: Int
    public var flaggedUpscaled: Int

    public var placed: Int { items.count }

    /// No plan, nothing placed.
    public static let empty = ShapemationScore(items: [], centre: nil, scale: nil, rotationDeg: nil, cornerRmsPx: nil, pairwiseOverlap: nil,
                                               flaggedShort: 0, flaggedUpscaled: 0)

    /// Scores every placement of `plan` whose item has a truth. `truths` is
    /// keyed by item id and holds the manifest's `truth`, in the item's own
    /// frame pixels. An item without a truth is not scored — the caller
    /// reports it as dropped; a scorer that counted only what it could see
    /// would call a lossy run clean.
    public static func measure(plan: ShapemationPlan, items: [ShapemationItem], truths: [UUID: SceneManifest.Geometry]) -> ShapemationScore {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var scores: [ItemScore] = []
        for placement in plan.placements {
            guard let item = byID[placement.itemID], let truth = truths[placement.itemID],
                  let score = score(placement, item: item, truth: truth, plan: plan) else { continue }
            scores.append(score)
        }
        var overlaps: [Double] = []
        for (a, b) in zip(plan.placements, plan.placements.dropFirst()) {
            overlaps.append(iou(a.footprint, b.footprint))
        }
        return ShapemationScore(
            items: scores,
            centre: Stat(scores.map(\.centre)),
            scale: Stat(scores.map { abs($0.scale) }),
            rotationDeg: Stat(scores.map { abs($0.rotationDeg) }),
            cornerRmsPx: Stat(scores.compactMap(\.cornerRmsPx)),
            pairwiseOverlap: Stat(overlaps),
            flaggedShort: scores.filter { $0.verdict.isShort }.count,
            flaggedUpscaled: scores.filter { $0.verdict.isUpscaled }.count)
    }

    static func score(_ placement: ShapemationPlan.Placement, item: ShapemationItem, truth: SceneManifest.Geometry,
                      plan: ShapemationPlan) -> ItemScore? {
        let h = placement.transform
        let anchor = placement.target
        let size = placement.targetSizePx
        let verdict = placement.feasibility.verdict
        guard size > 0 else { return nil }
        switch truth.kind {
        case .quad:
            guard let src = truth.cornersPx, src.count == 4 else { return nil }
            let dst = src.map { h.apply($0) }
            let centre = CGPoint(x: dst.map(\.x).reduce(0, +) / 4, y: dst.map(\.y).reduce(0, +) / 4)
            let placed = DetectedShape.quadMetrics(cornersPx: dst)
            // The rectangle the plan targets, from the truth's own proportions
            // in its source frame and the way it lies there.
            let own = DetectedShape.quadMetrics(cornersPx: src)
            let landscape = own.minor > 0 ? own.major / own.minor : 1
            let long = size, short = size / landscape
            let (w, hgt) = own.wide ? (long, short) : (short, long)
            let target = [CGPoint(x: anchor.x - w / 2, y: anchor.y - hgt / 2), CGPoint(x: anchor.x + w / 2, y: anchor.y - hgt / 2),
                          CGPoint(x: anchor.x + w / 2, y: anchor.y + hgt / 2), CGPoint(x: anchor.x - w / 2, y: anchor.y + hgt / 2)]
            var sum = 0.0
            for (p, q) in zip(dst, target) { sum += Double((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y)) }
            let centrePx = Double(hypot(centre.x - anchor.x, centre.y - anchor.y))
            return ItemScore(itemID: item.id, centrePx: centrePx, centre: centrePx / size, scale: placed.major / size - 1,
                             rotationDeg: placed.rotation * 180 / .pi, cornerRmsPx: (sum / 4).squareRoot(), verdict: verdict)
        case .ellipse:
            guard let c = truth.centrePx, let axes = truth.semiAxesPx, axes.count == 2 else { return nil }
            let a = axes[0], rot = truth.rotation ?? 0
            // The centre and the two ends of the major axis carry the size
            // and the angle through a projective transform well enough.
            let centre = h.apply(c)
            let e1 = h.apply(CGPoint(x: Double(c.x) + a * cos(rot), y: Double(c.y) + a * sin(rot)))
            let e2 = h.apply(CGPoint(x: Double(c.x) - a * cos(rot), y: Double(c.y) - a * sin(rot)))
            let long = Double(hypot(e1.x - e2.x, e1.y - e2.y))
            let isCircle = (try? SceneManifest.makeShape(truth, frame: item.pixelSize))?.family == .circle
            let angle = isCircle ? 0 : DetectedShape.wrapped(atan2(Double(e1.y - e2.y), Double(e1.x - e2.x)))
            let centrePx = Double(hypot(centre.x - anchor.x, centre.y - anchor.y))
            return ItemScore(itemID: item.id, centrePx: centrePx, centre: centrePx / size, scale: long / size - 1,
                             rotationDeg: angle * 180 / .pi, cornerRmsPx: nil, verdict: verdict)
        }
    }

    /// Intersection over union of two footprints; 0 when either is empty.
    public static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let ia = Double(inter.width * inter.height)
        let union = Double(a.width * a.height) + Double(b.width * b.height) - ia
        return union > 0 ? ia / union : 0
    }

    /// Of an ascending list; the mean of the two middles when even.
    public static func median(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    /// Nearest-rank percentile of an ascending list (p in 0…1).
    public static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Swift.max(1, Int((p * Double(sorted.count)).rounded(.up)))
        return sorted[Swift.min(rank, sorted.count) - 1]
    }

    /// The greppable line the CLI ends with; `dropped` is the caller's count.
    public func summaryLine(dropped: Int) -> String {
        func f(_ v: Double?, _ format: String) -> String { v.map { String(format: format, $0) } ?? "n/a" }
        return "SHAPEMATION SCORE: placed \(placed) · dropped \(dropped)"
            + " · centre median \(f(centre?.median, "%.3f")) p90 \(f(centre?.p90, "%.3f")) max \(f(centre?.max, "%.3f"))"
            + " · scale median \(f(scale?.median, "%.3f"))"
            + " · rotation median \(f(rotationDeg?.median, "%.1f"))°"
            + " · corners rms \(cornerRmsPx.map { String(format: "%.1f px", $0.median) } ?? "n/a")"
            + " · flagged: short \(flaggedShort) · upscaled \(flaggedUpscaled)"
    }
}

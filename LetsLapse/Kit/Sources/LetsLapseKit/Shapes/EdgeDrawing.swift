import Foundation
import simd

// Edge Drawing (Topal & Akinlar, "Edge Drawing: a combined real-time edge and
// segment detector", J. Vis. Commun. Image R. 23, 2012) as the fourth
// proposal source of the still-photo pass, ported 2026-09-12 from OpenCV's
// ximgproc `edge_drawing.cpp` (BSD) — the implementation behind the benchmark
// rig's `edge-drawing` detector (tools/shapebench/detect_ed.py), whose closed
// chains alone measured 51 hits / 9 false positives on the corpus's 153 labels
// against the region pass's 74 / 69 (docs/shape-benchmark/review-2026-09-12.md
// §4). What it does that the region maps do not: anchors on the gradient
// ridge are joined into one-pixel, ordered, 8-connected chains by walking
// along the edge direction and stepping to the strongest of the three
// forward pixels. There is no threshold map and no closing size, so a plate's
// outline is one chain and the bracket under it another.
//
// The parameters are the paper's: gradient threshold 36, anchor threshold 8,
// every row and column scanned, trees shorter than 20 pixels dropped. The
// rig's parameter-free run (EDPF: threshold 16, every ridge pixel an anchor,
// a-contrario validation of the segments) scored the same as the run with
// exactly these values, so the validation is not ported.
//
// Linear in pixels: about 130 ms at 12 MP and 30 ms at 2048 px for OpenCV's
// C++ on the M4 Max; the closed chains are then judged by the same §3 fits
// as a traced region (`RegionProposals.fit`).

enum EdgeDrawing {
    struct Settings: Sendable {
        var gradientThreshold = 36             // L1 Prewitt magnitude a pixel needs to be walked at all
        var anchorThreshold = 8                // an anchor stands this far above both across-edge neighbours
        var scanInterval = 1                   // rows and columns scanned for anchors (1 = all)
        var minPathLength = 20                 // a tree of walks with fewer distinct pixels is erased
        var minBranchLength = 10               // a side branch this long is a chain of its own (OpenCV's constant)
        // Closed loops, as `detect_ed.closed_loops`.
        var minLoopPoints = 40                 // a loop needs this many chain points
        var endGapFraction = 0.15              // the whole chain is a loop when its ends meet within this share of its box
        var loopJoinPx = 3.0                   // two far-apart points this close along the chain close a loop
        // The prefilter, the region pass's values.
        var minExtent = 0.08                   // of the plane's own side
        var maxExtent = 0.98
        var minSolidity = 0.60                 // loop area / convex hull area
        var loopDedupeIoU = 0.80               // bounding-box IoU between loops, larger first
        /// The §3 gates the loops are fitted with — the detector hands over
        /// its region-pass values so both sources are judged by one rule.
        var fit = RegionProposals.Settings()
    }

    struct Result {
        var candidates: [RegionProposals.Candidate] = []
        var refusals: [RegionProposals.Refusal] = []
        var anchors = 0
        var chains = 0
        var loops = 0
    }

    typealias Point = SIMD2<Int32>

    // MARK: - The pass

    /// Closed edge chains in `gray` (an 8-bit plane at one of the pass's
    /// scales), fitted and gated. Candidates carry `map` "ed-chain@<long
    /// edge>" and an edge support of 1 — a chain lies on edges by
    /// construction — and compete with the region pass's in the detector's
    /// admission loop.
    static func detect(in gray: RegionProposals.Plane, settings s: Settings = Settings()) -> Result {
        var result = Result()
        let w = gray.width, h = gray.height
        guard w >= 5, h >= 5 else { return result }
        let traced = chains(in: RegionProposals.gaussian5(gray), settings: s)
        result.anchors = traced.anchors
        result.chains = traced.chains.count
        if let debugDir = ProcessInfo.processInfo.environment["LAPSE_EDGES_DEBUG"] {
            // The plane and its chains, for a side-by-side with OpenCV's ED on the same pixels.
            RegionProposals.writePGM(gray, to: "\(debugDir)/gray-\(max(w, h)).pgm")
            writeChains(traced.chains, to: "\(debugDir)/chains-\(max(w, h)).json")
        }
        var loops: [(points: [SIMD2<Double>], area: Double, bbox: (Double, Double, Double, Double))] = []
        for chain in traced.chains {
            for (i, j) in closedLoops(chain, settings: s) {
                result.loops += 1
                var minX = Int32.max, maxX = Int32.min, minY = Int32.max, maxY = Int32.min
                for p in chain[i...j] { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
                let bw = Double(maxX - minX + 1), bh = Double(maxY - minY + 1)
                let ext = max(bw / Double(w), bh / Double(h))
                if ext < s.minExtent || ext > s.maxExtent { continue }
                let pts = chain[i...j].map { SIMD2<Double>(Double($0.x), Double($0.y)) }
                let area = abs(RegionProposals.signedArea(pts))
                let hullArea = abs(RegionProposals.signedArea(RegionProposals.convexHull(pts)))
                guard hullArea > 0, area / hullArea >= s.minSolidity else { continue }
                loops.append((pts, bw * bh, (Double(minX), Double(minY), Double(maxX), Double(maxY))))
            }
        }
        // One loop per place: larger boxes first, the rest dropped where a
        // kept box already covers them (the same rule as the region pass).
        loops.sort { $0.area > $1.area }
        var keptBoxes: [(Double, Double, Double, Double)] = []
        let map = "ed-chain@\(max(w, h))"
        for loop in loops where !keptBoxes.contains(where: { RegionProposals.boxIoU($0, loop.bbox) >= s.loopDedupeIoU }) {
            keptBoxes.append(loop.bbox)
            let verdict = RegionProposals.fit(loop.points, map: map, edgeSupport: 1, settings: s.fit, width: w, height: h)
            if let c = verdict.candidate { result.candidates.append(c) } else if let r = verdict.refusal { result.refusals.append(r) }
        }
        result.candidates.sort { $0.score > $1.score }
        return result
    }

    // MARK: - Closed loops

    /// Index ranges of `chain` that form a closed loop: the whole chain when
    /// its ends meet (within `endGapFraction` of its box), else any two
    /// points at least `minLoopPoints` apart along the chain that coincide
    /// within `loopJoinPx` (a loop with a tail, or a figure the chain went
    /// around and left). Loops are taken longest first; one overlapping an
    /// accepted loop's range by more than half of the shorter is skipped.
    static func closedLoops(_ chain: [Point], settings s: Settings) -> [(Int, Int)] {
        let n = chain.count
        guard n >= s.minLoopPoints else { return [] }
        var minX = Int32.max, maxX = Int32.min, minY = Int32.max, maxY = Int32.min
        for p in chain { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        let box = Double(max(maxX - minX, maxY - minY, 1))
        @inline(__always) func distance(_ a: Point, _ b: Point) -> Double {
            let dx = Double(a.x - b.x), dy = Double(a.y - b.y)
            return (dx * dx + dy * dy).squareRoot()
        }
        if distance(chain[0], chain[n - 1]) <= s.endGapFraction * box { return [(0, n - 1)] }
        // A grid of `join`-sized cells: every pair within a cell or a
        // neighbouring one is a candidate join.
        let join = s.loopJoinPx
        let cell = max(1.0, join)
        var grid: [Int64: [Int]] = [:]
        var keys: [(Int64, Int64)] = []
        keys.reserveCapacity(n)
        @inline(__always) func key(_ kx: Int64, _ ky: Int64) -> Int64 { (kx << 32) ^ (ky & 0xFFFF_FFFF) }
        for (i, p) in chain.enumerated() {
            let kx = Int64((Double(p.x) / cell).rounded(.down)), ky = Int64((Double(p.y) / cell).rounded(.down))
            keys.append((kx, ky))
            grid[key(kx, ky), default: []].append(i)
        }
        var candidates: [(length: Int, i: Int, j: Int)] = []
        for i in 0..<n {
            let (kx, ky) = keys[i]
            for dx in Int64(-1)...1 {
                for dy in Int64(-1)...1 {
                    guard let bucket = grid[key(kx + dx, ky + dy)] else { continue }
                    for j in bucket where j - i >= s.minLoopPoints && distance(chain[i], chain[j]) <= join {
                        candidates.append((j - i, i, j))
                    }
                }
            }
        }
        candidates.sort { $0.length != $1.length ? $0.length > $1.length : ($0.i != $1.i ? $0.i > $1.i : $0.j > $1.j) }
        var loops: [(Int, Int)] = []
        for c in candidates {
            if loops.contains(where: { (a, b) in Double(min(c.j, b) - max(c.i, a)) > 0.5 * Double(min(c.j - c.i, b - a)) }) { continue }
            loops.append((c.i, c.j))
        }
        return loops
    }

    // MARK: - Edge chains

    private static let vertical: UInt8 = 1       // gradient across x: the edge runs up–down
    private static let horizontal: UInt8 = 2
    private static let anchorMark: UInt8 = 254
    private static let edgeMark: UInt8 = 255
    private static let left = 1, right = 2, up = 3, down = 4

    /// One walk of the routing tree: its pixels are `pixels[start ..< start + len]`.
    private struct Chain {
        var len = 0
        var parent = -1
        var dir = 0
        var child0 = -1                        // the LEFT / UP continuation
        var child1 = -1                        // the RIGHT / DOWN continuation
        var start = 0
    }

    /// The edge chains of a smoothed 8-bit plane: ordered runs of
    /// 8-connected pixels (x, y), each pixel in one chain at most.
    ///
    /// Gradient: 3×3 Prewitt, L1 magnitude, an edge VERTICAL where |gx| ≥
    /// |gy|. Anchors: ridge pixels at least `anchorThreshold` above both
    /// neighbours across the edge, taken strongest first. Routing: from an
    /// anchor on a vertical edge walk up and down (left and right on a
    /// horizontal one); each step prefers an edge or anchor pixel among the
    /// three forward pixels, else the strongest of them (ties straight on),
    /// and stops on a pixel already walked or below the gradient threshold.
    /// Where the edge direction turns across the walk, both perpendicular
    /// continuations are walked as branches, so an anchor's walks form a
    /// tree; the chain is the longest root-to-leaf path through both sides
    /// of it, and any pruned branch of `minBranchLength` or more is a chain
    /// of its own. Anchors beside a walk are cleared so a thick edge is not
    /// walked twice. This is OpenCV's structure, kept so the Kit's chains
    /// are the prototype's.
    static func chains(in smoothed: RegionProposals.Plane, settings s: Settings) -> (chains: [[Point]], anchors: Int) {
        let w = smoothed.width, h = smoothed.height, n = w * h
        guard w >= 5, h >= 5 else { return ([], 0) }
        let thresh = Int32(s.gradientThreshold), anchorThresh = Int32(s.anchorThreshold)
        // The frame's outermost pixels sit below the threshold, so no walk
        // reads outside the plane: a walk stops before stepping onto them and
        // anchors are two pixels in.
        let grad = UnsafeMutableBufferPointer<Int32>.allocate(capacity: n)
        grad.initialize(repeating: thresh - 1)
        let dir = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: n)
        dir.initialize(repeating: 0)
        let edge = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: n)
        edge.initialize(repeating: 0)
        defer { grad.deallocate(); dir.deallocate(); edge.deallocate() }

        smoothed.data.withUnsafeBufferPointer { p in
            for i in 1..<(h - 1) {
                for j in 1..<(w - 1) {
                    let idx = i * w + j
                    // A B C / D x E / F G H: gx = (C−A) + (E−D) + (H−F), gy = (F−A) + (G−B) + (H−C),
                    // with com1 = H−A and com2 = C−F shared between the two.
                    let com1 = Int32(p[idx + w + 1]) - Int32(p[idx - w - 1])
                    let com2 = Int32(p[idx - w + 1]) - Int32(p[idx + w - 1])
                    let gx = abs(com1 + com2 + (Int32(p[idx + 1]) - Int32(p[idx - 1])))
                    let gy = abs(com1 - com2 + (Int32(p[idx + w]) - Int32(p[idx - w])))
                    let sum = gx + gy
                    grad[idx] = sum
                    if sum >= thresh { dir[idx] = gx >= gy ? vertical : horizontal }
                }
            }
        }

        // Anchors, in scan order.
        var anchors: [Int] = []
        let interval = max(1, s.scanInterval)
        for i in 2..<(h - 2) {
            let (start, inc) = i % interval == 0 ? (2, 1) : (interval, interval)
            for j in stride(from: start, to: w - 2, by: inc) {
                let idx = i * w + j
                let g = grad[idx]
                guard g >= thresh else { continue }
                let (n1, n2) = dir[idx] == vertical ? (grad[idx - 1], grad[idx + 1]) : (grad[idx - w], grad[idx + w])
                if g - n1 >= anchorThresh && g - n2 >= anchorThresh { edge[idx] = anchorMark; anchors.append(idx) }
            }
        }
        let anchorCount = anchors.count
        // Strongest first; equals in scan order (OpenCV's counting sort).
        anchors.sort { grad[$0] != grad[$1] ? grad[$0] > grad[$1] : $0 < $1 }

        var segments: [[Point]] = []
        var chains: [Chain] = []
        var pixels: [Point] = []
        var stack: [(idx: Int, dir: Int, parent: Int)] = []
        @inline(__always) func adjacent(_ a: Point, _ b: Point) -> Bool { abs(a.x - b.x) <= 1 && abs(a.y - b.y) <= 1 }
        @inline(__always) func point(_ idx: Int) -> Point { Point(Int32(idx % w), Int32(idx / w)) }

        /// Copy one walk's pixels onto `seg`, dropping what would double back
        /// on pixels already there (OpenCV's join cleanup): trailing pixels of
        /// `seg` that the incoming first pixel is adjacent to past the last,
        /// and the incoming first pixel itself when the second is adjacent to
        /// `seg`'s last. `skippingFirst` drops the walk's first pixel outright
        /// — the anchor, already placed by the other side — and, as OpenCV
        /// does, still reads the slot after it as the incoming first pixel
        /// when nothing is left (a branch pixel the next walk starts with).
        func append(_ chainNo: Int, reversed: Bool, skippingFirst: Bool = false, onto seg: inout [Point]) {
            let ch = chains[chainNo]
            var start = ch.start, len = ch.len
            if skippingFirst { start += 1; len -= 1 }
            let first: Point
            if reversed {
                guard len > 0 else { return }
                first = pixels[start + len - 1]
            } else {
                guard start < pixels.count, len > 0 || skippingFirst else { return }
                first = pixels[start]
            }
            var index = seg.count - 2
            while index >= 0 && adjacent(first, seg[index]) { seg.removeLast(); index -= 1 }
            var from = 0
            if len > 1, let last = seg.last {
                let second = pixels[reversed ? start + len - 2 : start + 1]
                if adjacent(second, last) { if reversed { len -= 1 } else { from = 1 } }
            }
            if reversed {
                for l in stride(from: len - 1, through: 0, by: -1) { seg.append(pixels[start + l]) }
            } else if len > from {
                for l in from..<len { seg.append(pixels[start + l]) }
            }
        }
        /// The chains on the longest path from `root` after pruning: each
        /// node keeps at most one child.
        func path(from root: Int) -> [Int] {
            var out: [Int] = []
            var k = root
            while k >= 0 {
                out.append(k)
                k = chains[k].child0 >= 0 ? chains[k].child0 : chains[k].child1
            }
            return out
        }

        for anchor in anchors {
            guard edge[anchor] == anchorMark else { continue }   // walked over, or cleared beside a walk
            chains.removeAll(keepingCapacity: true)
            chains.append(Chain())                                // the root: the anchor's two walks hang off it
            pixels.removeAll(keepingCapacity: true)
            stack.removeAll(keepingCapacity: true)
            var duplicates = 0                                    // the anchor and every branch pixel are appended twice
            if dir[anchor] == vertical {
                stack.append((anchor, down, 0)); stack.append((anchor, up, 0))
            } else {
                stack.append((anchor, right, 0)); stack.append((anchor, left, 0))
            }
            while let top = stack.popLast() {
                let d = top.dir
                if edge[top.idx] != edgeMark { duplicates += 1 }
                var chain = Chain(len: 1, parent: top.parent, dir: d, child0: -1, child1: -1, start: pixels.count)
                let chainNo = chains.count
                pixels.append(point(top.idx))
                // The three forward pixels: straight on, and the two beside
                // it (A above / left of straight, C below / right of it);
                // which diagonal an existing edge pixel is looked for on
                // first (OpenCV asks A first walking left or up, C first
                // walking right or down); and the two anchors beside the
                // walk to clear.
                let axis: UInt8, straight: Int, offA: Int, offC: Int, diag1: Int, diag2: Int, beside1: Int, beside2: Int
                switch d {
                case left:  (axis, straight, offA, offC, beside1, beside2) = (horizontal, -1, -w - 1, w - 1, -w, w); (diag1, diag2) = (offA, offC)
                case right: (axis, straight, offA, offC, beside1, beside2) = (horizontal, 1, -w + 1, w + 1, -w, w); (diag1, diag2) = (offC, offA)
                case up:    (axis, straight, offA, offC, beside1, beside2) = (vertical, -w, -w - 1, -w + 1, -1, 1); (diag1, diag2) = (offA, offC)
                default:    (axis, straight, offA, offC, beside1, beside2) = (vertical, w, w - 1, w + 1, -1, 1); (diag1, diag2) = (offC, offA)
                }
                var cur = top.idx
                var ended = false
                while dir[cur] == axis {
                    edge[cur] = edgeMark
                    if edge[cur + beside1] == anchorMark { edge[cur + beside1] = 0 }
                    if edge[cur + beside2] == anchorMark { edge[cur + beside2] = 0 }
                    let next: Int
                    if edge[cur + straight] >= anchorMark { next = cur + straight }
                    else if edge[cur + diag1] >= anchorMark { next = cur + diag1 }
                    else if edge[cur + diag2] >= anchorMark { next = cur + diag2 }
                    else {
                        let ga = grad[cur + offA], gb = grad[cur + straight], gc = grad[cur + offC]
                        if ga > gb { next = ga > gc ? cur + offA : cur + offC }
                        else if gc > gb { next = cur + offC }
                        else { next = cur + straight }
                    }
                    cur = next
                    if edge[cur] == edgeMark || grad[cur] < thresh { ended = true; break }
                    pixels.append(point(cur))
                    chain.len += 1
                }
                if !ended {
                    // The edge turned across the walk at `cur`: it leaves this
                    // chain and heads both perpendicular walks.
                    if axis == horizontal {
                        stack.append((cur, down, chainNo)); stack.append((cur, up, chainNo))
                    } else {
                        stack.append((cur, right, chainNo)); stack.append((cur, left, chainNo))
                    }
                    pixels.removeLast()
                    chain.len -= 1
                }
                chains.append(chain)
                if d == left || d == up { chains[top.parent].child0 = chainNo } else { chains[top.parent].child1 = chainNo }
            }

            if pixels.count - duplicates < s.minPathLength {
                for p in pixels { edge[Int(p.y) * w + Int(p.x)] = 0 }
                continue
            }
            // The longest path below every node, pruning the shorter child
            // (children always follow their parent in the array, so one pass
            // from the back is the recursion). The root keeps both sides.
            var best = [Int](repeating: 0, count: chains.count)
            for k in stride(from: chains.count - 1, through: 1, by: -1) {
                let l0 = chains[k].child0 >= 0 ? best[chains[k].child0] : 0
                let l1 = chains[k].child1 >= 0 ? best[chains[k].child1] : 0
                if l0 >= l1 { chains[k].child1 = -1; best[k] = chains[k].len + l0 } else { chains[k].child0 = -1; best[k] = chains[k].len + l1 }
            }
            // The chain: the RIGHT / DOWN side walked back to the anchor,
            // then the LEFT / UP side onward.
            var segment: [Point] = []
            let side1 = chains[0].child1, side0 = chains[0].child0
            if side1 >= 0, best[side1] > 0 {
                for chainNo in path(from: side1).reversed() { append(chainNo, reversed: true, onto: &segment); chains[chainNo].len = 0 }
            }
            if side0 >= 0, best[side0] > 1 {
                for (k, chainNo) in path(from: side0).enumerated() {
                    append(chainNo, reversed: false, skippingFirst: k == 0, onto: &segment); chains[chainNo].len = 0
                }
            }
            if segment.count >= 2, adjacent(segment[1], segment[segment.count - 1]) { segment.removeFirst() }
            if !segment.isEmpty { segments.append(segment) }
            // Pruned branches long enough to stand on their own.
            for k in 2..<chains.count where chains[k].len >= 2 && best[k] >= s.minBranchLength {
                var branch: [Point] = []
                for chainNo in path(from: k) { append(chainNo, reversed: false, onto: &branch); chains[chainNo].len = 0 }
                if !branch.isEmpty { segments.append(branch) }
            }
        }
        return (segments, anchorCount)
    }

    /// Debug: the chains as JSON, `[[[x, y], …], …]`, for a side-by-side
    /// with `cv2.ximgproc.createEdgeDrawing().getSegments()`.
    static func writeChains(_ chains: [[Point]], to path: String) {
        var out = "["
        for (k, chain) in chains.enumerated() {
            if k > 0 { out += "," }
            out += "[" + chain.map { "[\($0.x),\($0.y)]" }.joined(separator: ",") + "]"
        }
        out += "]"
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

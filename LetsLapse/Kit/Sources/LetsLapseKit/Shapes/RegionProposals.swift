import Foundation
import Accelerate
import CoreGraphics
import simd

// Region proposals for the still-photo pass: the shape benchmark's reference
// detector, ported (docs/shape-benchmark/report.md, 2026-09-11). Against 68
// hand-labelled shapes the Vision-only pass found 16 % at any dial; this
// machine found 56 % with the same geometry a person draws. What it does that
// the tracer-on-contrast passes do not: Canny with thresholds from the
// picture's own Otsu split (the median heuristic goes blind on a bright wall),
// an "enclosed interiors" map (a plate whose edge ring breaks at a rounded
// corner becomes a solid blob once a closing seals it), three closing sizes
// unioned (15 px finds the plate, 9 px the medallion), the adaptive threshold
// in both polarities, and holes traced as well as outer borders (a light dial
// in a dark bezel is a hole). Every region is then fitted both ways and gated
// by the brief's §3 rules: a rectangle needs four straight sides within 8° of
// square, opposite sides within 10 %, and 85 % of its box filled; an ellipse
// needs 90 % IoU with its own fit and an axis ratio of 0.4.
//
// All on the detection picture (1024 px long edge), integer pixels, no Vision.
// A budget of about a second on a phone — the file pass has it, the viewfinder
// does not, so `ShapeDetector.Settings.regionProposals` is off in `live`.

enum RegionProposals {
    struct Settings: Sendable {
        var blurTaps = 5                       // [1 4 6 4 1] / 16, OpenCV's fixed 5-tap kernel
        var cannyLowFraction = 0.5             // low = ½ · high
        var cannyMinHigh = 40.0                // the Otsu split never sets the high threshold under this
        var adaptiveBlock = 51                 // Gaussian-weighted local mean, σ 8 (OpenCV's rule for 51 taps)
        var adaptiveC = 5.0
        var closings = [5, 9, 15]              // disc kernels; maps at every size
        var fillEnclosed = true
        var minContourPoints = 40
        var minExtent = 0.08                   // of the detection frame's longer side
        var maxExtent = 0.98
        var minSolidity = 0.60                 // contour area / convex hull area
        var regionDedupeIoU = 0.80             // bounding-box IoU between traced regions
        var borderPx = 2                       // a contour this close to the frame edge is clipped
        /// A region's outline must lie on edges: the share of its traced
        /// points with a Canny edge within `edgeSupportTolerancePx`. The
        /// adaptive threshold turns any large flat region into a blob whose
        /// boundary sits about 2σ (16 px) inside the real edge, and that
        /// blob fits a perfect circle of the wrong size; nothing else in
        /// the maps tells it from the object itself. Measured 2026-09-12 on
        /// the synthetic card: the true rim scores ~1, the offset blob 0.
        var minOutlineEdgeSupport = 0.5
        var edgeSupportTolerancePx = 3
        // §3 rules
        var approxEpsilonFraction = 0.02       // Douglas–Peucker tolerance as a share of the perimeter
        var rectAngleToleranceDeg = 8.0
        var rectSideTolerance = 0.10
        var rectMinFill = 0.85
        var ellipseMinIoU = 0.90
        var ellipseMinAxisRatio = 0.40
        var tieMargin = 0.02                   // a rectangle wins a near-tie when its four sides are straight
    }

    /// One traced region and what the fits made of it.
    struct Candidate {
        enum Primitive { case rectangle, ellipse }
        var primitive: Primitive
        var score: Double                      // fill ratio (rectangle) or IoU (ellipse)
        var edgeSupport: Double
        /// Rectangle: four corners clockwise from top-left. Ellipse: nil.
        var corners: [SIMD2<Double>]?
        var ellipse: FittedEllipse?
        var map: String
        var extent: Double
    }

    /// A refusal the diagnostics can carry: where, how big, and why.
    struct Refusal {
        var centre: SIMD2<Double>
        var size: Double
        var reason: String
        var margin: Double
    }

    struct Result {
        var candidates: [Candidate] = []
        var refusals: [Refusal] = []
        var maps = 0
        var contours = 0
        var regions = 0
    }

    // MARK: - Planes

    struct Plane {
        var width: Int
        var height: Int
        var data: [UInt8]
        init(width: Int, height: Int, fill: UInt8 = 0) {
            self.width = width; self.height = height
            data = [UInt8](repeating: fill, count: width * height)
        }
        @inline(__always) subscript(x: Int, y: Int) -> UInt8 {
            get { data[y * width + x] }
            set { data[y * width + x] = newValue }
        }
    }

    /// 8-bit luminance of a CGImage, as drawn by Core Graphics.
    static func grayPlane(_ image: CGImage) -> Plane? {
        let w = image.width, h = image.height
        var plane = Plane(width: w, height: h)
        let ok: Bool = plane.data.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? plane : nil
    }

    // MARK: - The pass

    /// Every region worth fitting in `gray`, fitted and gated. `frame` is the
    /// plane's own size; extents are relative to its longer side.
    static func detect(in gray: Plane, settings s: Settings = Settings()) -> Result {
        var result = Result()
        let w = gray.width, h = gray.height
        let long = Double(max(w, h))
        let blurred = gaussian5(gray)
        let edges = otsuCanny(blurred, lowFraction: s.cannyLowFraction, minHigh: s.cannyMinHigh)
        let tol = max(0, s.edgeSupportTolerancePx)
        let near = tol > 0 ? dilate(edges, kernel: [UInt8](repeating: 0, count: (2 * tol + 1) * (2 * tol + 1)), k: 2 * tol + 1) : edges
        var traced: [(points: [SIMD2<Double>], map: String, area: Double, bbox: (Double, Double, Double, Double))] = []
        let debugDir = ProcessInfo.processInfo.environment["LAPSE_REGIONS_DEBUG"]
        for (name, map) in maps(of: blurred, edges: edges, settings: s) {
            result.maps += 1
            var nTraced = 0, nLong = 0, nExtent = 0, nSolid = 0
            var white = 0
            if debugDir != nil { for v in map.data where v != 0 { white += 1 } }
            defer {
                if let debugDir {
                    print("  map \(name): white \(white) px, traced \(nTraced), ≥\(s.minContourPoints) pts \(nLong), extent ok \(nExtent), solid \(nSolid)")
                    writePGM(map, to: "\(debugDir)/\(name).pgm")
                }
            }
            for contour in trace(map, minPixels: s.minContourPoints / 2) {
                result.contours += 1
                nTraced += 1
                guard contour.count >= s.minContourPoints else { continue }
                nLong += 1
                var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
                for p in contour { minX = min(minX, Int(p.x)); maxX = max(maxX, Int(p.x)); minY = min(minY, Int(p.y)); maxY = max(maxY, Int(p.y)) }
                let bw = Double(maxX - minX + 1), bh = Double(maxY - minY + 1)
                let ext = max(bw / Double(w), bh / Double(h))
                if ext < s.minExtent || ext > s.maxExtent { continue }
                nExtent += 1
                let pts = contour.map { SIMD2<Double>(Double($0.x), Double($0.y)) }
                let area = abs(signedArea(pts))
                let hull = convexHull(pts)
                let hullArea = abs(signedArea(hull))
                guard hullArea > 0, area / hullArea >= s.minSolidity else { continue }
                nSolid += 1
                traced.append((pts, name, bw * bh, (Double(minX), Double(minY), Double(maxX), Double(maxY))))
            }
        }
        // One region per place: larger boxes first, the rest dropped where a
        // kept box already covers them.
        traced.sort { $0.area > $1.area }
        var keptBoxes: [(Double, Double, Double, Double)] = []
        var regions: [(points: [SIMD2<Double>], map: String)] = []
        for t in traced where !keptBoxes.contains(where: { boxIoU($0, t.bbox) >= s.regionDedupeIoU }) {
            keptBoxes.append(t.bbox)
            regions.append((t.points, t.map))
        }
        result.regions = regions.count

        for region in regions {
            let pts = region.points
            var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
            for p in pts { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
            let centre = SIMD2<Double>((minX + maxX) / 2, (minY + maxY) / 2)
            let size = max(maxX - minX, maxY - minY) / long
            let bp = Double(s.borderPx)
            if minX <= bp || minY <= bp || maxX >= Double(w - 1) - bp || maxY >= Double(h - 1) - bp {
                result.refusals.append(Refusal(centre: centre, size: size, reason: "touches the frame border", margin: 1)); continue
            }
            var onEdge = 0
            for p in pts {
                let x = Int(p.x), y = Int(p.y)
                if x >= 0, y >= 0, x < w, y < h, near.data[y * w + x] != 0 { onEdge += 1 }
            }
            let support = Double(onEdge) / Double(max(1, pts.count))
            if support < s.minOutlineEdgeSupport {
                result.refusals.append(Refusal(centre: centre, size: size, reason: String(format: "outline off the edges: support %.2f < %.2f", support, s.minOutlineEdgeSupport), margin: 1 - support / s.minOutlineEdgeSupport)); continue
            }
            let rect = fitRect(pts, settings: s)
            let ell = fitEllipse(pts, settings: s, width: w, height: h)
            var order: [(Candidate.Primitive, Double)] = []
            if let rect { order.append((.rectangle, rect.fill)) }
            if let ell { order.append((.ellipse, ell.iou)) }
            order.sort { $0.1 > $1.1 }
            if order.count == 2, abs(order[0].1 - order[1].1) <= s.tieMargin, let rect, rect.structural {
                order.sort { $0.0 == .rectangle && $1.0 != .rectangle }
            }
            var chosen: Candidate?
            for (prim, score) in order {
                if prim == .rectangle, let rect, rect.ok {
                    let ext = max(rect.boxWidth, rect.boxHeight) / long
                    chosen = Candidate(primitive: .rectangle, score: score, edgeSupport: support, corners: rect.corners, ellipse: nil, map: region.map, extent: ext)
                    break
                }
                if prim == .ellipse, let ell, ell.ok {
                    let e = ell.ellipse
                    let ext = max(e.semiMajor, e.semiMinor) * 2 / long
                    chosen = Candidate(primitive: .ellipse, score: score, edgeSupport: support, corners: nil, ellipse: e, map: region.map, extent: ext)
                    break
                }
            }
            if let chosen {
                result.candidates.append(chosen)
            } else {
                var why: [String] = []
                if let rect { why.append("rect: " + (rect.reasons.isEmpty ? "ok" : rect.reasons.joined(separator: "; "))) } else { why.append("rect: no fit") }
                if let ell { why.append("ellipse: " + (ell.reasons.isEmpty ? "ok" : ell.reasons.joined(separator: "; "))) } else { why.append("ellipse: no fit") }
                let best = order.first?.1 ?? 0
                let gate = (order.first?.0 == .rectangle) ? s.rectMinFill : s.ellipseMinIoU
                result.refusals.append(Refusal(centre: centre, size: size, reason: why.joined(separator: " · "), margin: max(0, 1 - best / gate)))
            }
        }
        result.candidates.sort { $0.score > $1.score }
        return result
    }

    /// Debug: a plane as a binary PGM.
    static func writePGM(_ p: Plane, to path: String) {
        var d = Data("P5\n\(p.width) \(p.height)\n255\n".utf8)
        d.append(contentsOf: p.data)
        try? d.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Maps

    /// The binary maps a picture is traced on, at every closing size: the
    /// closed edge map, the edge map's enclosed interiors, and the adaptive
    /// threshold in both polarities, each with its own enclosed-fill.
    static func maps(of blurred: Plane, edges: Plane, settings s: Settings) -> [(String, Plane)] {
        let (adaptive, adaptiveInv) = adaptiveThreshold(blurred, block: s.adaptiveBlock, c: s.adaptiveC)
        let raw: [(String, Plane)] = [("canny", edges), ("adaptive", adaptive), ("adaptive-inv", adaptiveInv)]
        var out: [(String, Plane)] = []
        for k in s.closings {
            for (name, m0) in raw {
                let m = k > 1 ? close(m0, diameter: k) : m0
                out.append(("\(name)~c\(k)", m))
                if s.fillEnclosed { out.append(("\(name)-filled~c\(k)", fillEnclosed(m))) }
            }
        }
        return out
    }

    /// OpenCV's fixed 5-tap Gaussian ([1 4 6 4 1] / 16), separable, edges replicated.
    static func gaussian5(_ src: Plane) -> Plane {
        let w = src.width, h = src.height
        var tmp = [Float](repeating: 0, count: w * h)
        let k: [Float] = [1, 4, 6, 4, 1]
        src.data.withUnsafeBufferPointer { sp in
            for y in 0..<h {
                let row = y * w
                for x in 0..<w {
                    var acc: Float = 0
                    for t in -2...2 { acc += k[t + 2] * Float(sp[row + min(w - 1, max(0, x + t))]) }
                    tmp[row + x] = acc
                }
            }
        }
        var out = Plane(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                var acc: Float = 0
                for t in -2...2 { acc += k[t + 2] * tmp[min(h - 1, max(0, y + t)) * w + x] }
                out.data[y * w + x] = UInt8(min(255, max(0, (acc / 256 + 0.5).rounded(.down))))
            }
        }
        return out
    }

    /// Otsu's split of an 8-bit histogram.
    static func otsuThreshold(_ p: Plane) -> Double {
        var hist = [Double](repeating: 0, count: 256)
        for v in p.data { hist[Int(v)] += 1 }
        let total = Double(p.data.count)
        var sum = 0.0
        for i in 0..<256 { sum += Double(i) * hist[i] }
        var sumB = 0.0, wB = 0.0, best = 0.0, threshold = 0.0
        for i in 0..<256 {
            wB += hist[i]
            if wB == 0 { continue }
            let wF = total - wB
            if wF == 0 { break }
            sumB += Double(i) * hist[i]
            let mB = sumB / wB, mF = (sum - sumB) / wF
            let between = wB * wF * (mB - mF) * (mB - mF)
            if between > best { best = between; threshold = Double(i) }
        }
        return threshold
    }

    /// Canny as OpenCV runs it with `L2gradient`: 3×3 Sobel, hypot magnitude,
    /// non-maximum suppression in four directions, hysteresis. `high` is the
    /// Otsu split of the blurred picture, `low` a fraction of it.
    static func otsuCanny(_ src: Plane, lowFraction: Double, minHigh: Double) -> Plane {
        let w = src.width, h = src.height
        let high = max(minHigh, otsuThreshold(src)), low = lowFraction * high
        var mag = [Float](repeating: 0, count: w * h)
        var dir = [UInt8](repeating: 0, count: w * h)     // 0: horizontal gradient, 1: 45°, 2: vertical, 3: 135°
        src.data.withUnsafeBufferPointer { sp in
            @inline(__always) func px(_ x: Int, _ y: Int) -> Float { Float(sp[min(h - 1, max(0, y)) * w + min(w - 1, max(0, x))]) }
            for y in 0..<h {
                for x in 0..<w {
                    let gx = (px(x + 1, y - 1) + 2 * px(x + 1, y) + px(x + 1, y + 1)) - (px(x - 1, y - 1) + 2 * px(x - 1, y) + px(x - 1, y + 1))
                    let gy = (px(x - 1, y + 1) + 2 * px(x, y + 1) + px(x + 1, y + 1)) - (px(x - 1, y - 1) + 2 * px(x, y - 1) + px(x + 1, y - 1))
                    let m = (gx * gx + gy * gy).squareRoot()
                    mag[y * w + x] = m
                    // OpenCV's sectors: tan 22.5° and tan 67.5° on |gy| / |gx|.
                    let ax = abs(gx), ay = abs(gy)
                    let d: UInt8
                    if ay <= ax * 0.41421356 { d = 0 }
                    else if ay >= ax * 2.41421356 { d = 2 }
                    else { d = (gx > 0) == (gy > 0) ? 1 : 3 }
                    dir[y * w + x] = d
                }
            }
        }
        // Non-maximum suppression: keep a pixel only where it is at least as
        // strong as both neighbours along its gradient.
        var strong = [Bool](repeating: false, count: w * h)
        var weak = [Bool](repeating: false, count: w * h)
        let lowF = Float(low), highF = Float(high)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let m = mag[i]
                guard m >= lowF else { continue }
                let n1: Float, n2: Float
                switch dir[i] {
                case 0: n1 = mag[i - 1]; n2 = mag[i + 1]
                case 2: n1 = mag[i - w]; n2 = mag[i + w]
                case 1: n1 = mag[i - w - 1]; n2 = mag[i + w + 1]
                default: n1 = mag[i - w + 1]; n2 = mag[i + w - 1]
                }
                guard m > n1 && m >= n2 else { continue }
                if m >= highF { strong[i] = true } else { weak[i] = true }
            }
        }
        // Hysteresis: weak pixels 8-connected to a strong one join it.
        var out = Plane(width: w, height: h)
        var stack: [Int] = []
        stack.reserveCapacity(4096)
        for i in 0..<(w * h) where strong[i] {
            out.data[i] = 255
            stack.append(i)
            while let j = stack.popLast() {
                let x = j % w, y = j / w
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                        let n = ny * w + nx
                        if weak[n] && out.data[n] == 0 { out.data[n] = 255; stack.append(n) }
                    }
                }
            }
        }
        return out
    }

    /// `adaptiveThreshold(GAUSSIAN_C, block, C)`, both polarities: white where
    /// the pixel is above (binary) or below (inverse) its Gaussian-weighted
    /// neighbourhood mean minus C.
    static func adaptiveThreshold(_ src: Plane, block: Int, c: Double) -> (Plane, Plane) {
        let w = src.width, h = src.height
        let taps = max(3, block | 1), r = taps / 2
        let sigma = 0.3 * (Double(taps - 1) * 0.5 - 1) + 0.8
        var kernel = (0..<taps).map { exp(-pow(Double($0 - r), 2) / (2 * sigma * sigma)) }
        let ksum = kernel.reduce(0, +)
        kernel = kernel.map { $0 / ksum }
        let kf = kernel.map { Float($0) }
        var tmp = [Float](repeating: 0, count: w * h)
        src.data.withUnsafeBufferPointer { sp in
            for y in 0..<h {
                let row = y * w
                for x in 0..<w {
                    var acc: Float = 0
                    for t in 0..<taps { acc += kf[t] * Float(sp[row + min(w - 1, max(0, x + t - r))]) }
                    tmp[row + x] = acc
                }
            }
        }
        var binary = Plane(width: w, height: h), inverse = Plane(width: w, height: h)
        let cf = Float(c)
        for y in 0..<h {
            for x in 0..<w {
                var acc: Float = 0
                for t in 0..<taps { acc += kf[t] * tmp[min(h - 1, max(0, y + t - r)) * w + x] }
                let threshold = acc - cf
                let v = Float(src.data[y * w + x])
                if v > threshold { binary.data[y * w + x] = 255 } else { inverse.data[y * w + x] = 255 }
            }
        }
        return (binary, inverse)
    }

    /// Morphological close (dilate, then erode) with a disc of `diameter`
    /// pixels. vImage's dilate takes a 0-inside / 255-outside kernel as the
    /// structuring element; its erode does not (an excluded position
    /// saturates to 0 and wins the minimum — measured 2026-09-12), so the
    /// erosion is the complement of dilating the complement, which for a
    /// symmetric element is the same thing.
    static func close(_ src: Plane, diameter k: Int) -> Plane {
        var kernel = [UInt8](repeating: 255, count: k * k)
        let r = Double(k) / 2
        for y in 0..<k {
            for x in 0..<k {
                let dx = Double(x) + 0.5 - r, dy = Double(y) + 0.5 - r
                if dx * dx + dy * dy <= r * r { kernel[y * k + x] = 0 }
            }
        }
        var dilated = dilate(src, kernel: kernel, k: k)
        for i in dilated.data.indices { dilated.data[i] = 255 &- dilated.data[i] }
        var closed = dilate(dilated, kernel: kernel, k: k)
        for i in closed.data.indices { closed.data[i] = 255 &- closed.data[i] }
        return closed
    }

    static func dilate(_ src: Plane, kernel: [UInt8], k: Int) -> Plane {
        let w = src.width, h = src.height
        var out = Plane(width: w, height: h)
        src.data.withUnsafeBufferPointer { sp in
            out.data.withUnsafeMutableBufferPointer { dp in
                var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: sp.baseAddress!), height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                var d = vImage_Buffer(data: dp.baseAddress!, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                _ = vImageDilate_Planar8(&s, &d, 0, 0, kernel, vImagePixelCount(k), vImagePixelCount(k), vImage_Flags(kvImageEdgeExtend))
            }
        }
        return out
    }

    /// Everything the map encloses, as solid regions: flood the background
    /// from outside the frame, and what it cannot reach (and is not itself an
    /// edge pixel) is enclosed.
    static func fillEnclosed(_ edges: Plane) -> Plane {
        let w = edges.width, h = edges.height
        var reached = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        stack.reserveCapacity(w * 2 + h * 2)
        func seed(_ x: Int, _ y: Int) {
            let i = y * w + x
            if edges.data[i] == 0 && !reached[i] { reached[i] = true; stack.append(i) }
        }
        for x in 0..<w { seed(x, 0); seed(x, h - 1) }
        for y in 0..<h { seed(0, y); seed(w - 1, y) }
        while let j = stack.popLast() {
            let x = j % w, y = j / w
            if x > 0 { seed(x - 1, y) }
            if x < w - 1 { seed(x + 1, y) }
            if y > 0 { seed(x, y - 1) }
            if y < h - 1 { seed(x, y + 1) }
        }
        var out = Plane(width: w, height: h)
        for i in 0..<(w * h) where edges.data[i] == 0 && !reached[i] { out.data[i] = 255 }
        return out
    }

    // MARK: - Contours

    /// The outer border of every white 8-connected component, and the border
    /// of every hole (a black 4-connected region not touching the frame) —
    /// what `findContours(RETR_CCOMP, CHAIN_APPROX_NONE)` returns, traced
    /// Moore-neighbour style from each region's first pixel in scan order.
    static func trace(_ map: Plane, minPixels: Int = 8) -> [[SIMD2<Int32>]] {
        let w = map.width, h = map.height
        var out: [[SIMD2<Int32>]] = []
        var labels = [Int32](repeating: 0, count: w * h)
        var next: Int32 = 1
        var stack: [Int] = []
        // White components, 8-connected.
        for i in 0..<(w * h) where map.data[i] != 0 && labels[i] == 0 {
            let label = next; next += 1
            labels[i] = label; stack.append(i)
            var count = 0
            while let j = stack.popLast() {
                count += 1
                let x = j % w, y = j / w
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                        let n = ny * w + nx
                        if map.data[n] != 0 && labels[n] == 0 { labels[n] = label; stack.append(n) }
                    }
                }
            }
            if count >= minPixels { out.append(moore(map, start: i, foreground: { map.data[$0] != 0 })) }
        }
        // Holes: black 4-connected regions that never touch the frame.
        var hole = [Int32](repeating: 0, count: w * h)
        next = 1
        for i in 0..<(w * h) where map.data[i] == 0 && hole[i] == 0 {
            let label = next; next += 1
            hole[i] = label; stack.append(i)
            var touches = false, count = 0
            while let j = stack.popLast() {
                count += 1
                let x = j % w, y = j / w
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { touches = true }
                if x > 0, map.data[j - 1] == 0, hole[j - 1] == 0 { hole[j - 1] = label; stack.append(j - 1) }
                if x < w - 1, map.data[j + 1] == 0, hole[j + 1] == 0 { hole[j + 1] = label; stack.append(j + 1) }
                if y > 0, map.data[j - w] == 0, hole[j - w] == 0 { hole[j - w] = label; stack.append(j - w) }
                if y < h - 1, map.data[j + w] == 0, hole[j + w] == 0 { hole[j + w] = label; stack.append(j + w) }
            }
            if !touches && count >= minPixels { out.append(moore(map, start: i, foreground: { hole[$0] == label })) }
        }
        return out
    }

    /// Moore-neighbour border tracing from the region's first pixel in scan
    /// order (so the pixel above it is background), stopping when the start
    /// is re-entered from the same direction (Jacob's criterion).
    static func moore(_ map: Plane, start: Int, foreground: (Int) -> Bool) -> [SIMD2<Int32>] {
        let w = map.width, h = map.height
        // Clockwise from the top: N, NE, E, SE, S, SW, W, NW.
        let dx: [Int] = [0, 1, 1, 1, 0, -1, -1, -1]
        let dy: [Int] = [-1, -1, 0, 1, 1, 1, 0, -1]
        let sx = start % w, sy = start / w
        var border: [SIMD2<Int32>] = [SIMD2<Int32>(Int32(sx), Int32(sy))]
        var x = sx, y = sy
        var backtrack = 6 // we arrived from the west (the pixel to the west is background or outside)
        var firstStep = -1
        var steps = 0
        let limit = 4 * (w + h) * 4
        while steps < limit {
            steps += 1
            var found = false
            var d = (backtrack + 1) % 8
            for _ in 0..<8 {
                let nx = x + dx[d], ny = y + dy[d]
                if nx >= 0, ny >= 0, nx < w, ny < h, foreground(ny * w + nx) {
                    let arrived = (d + 4) % 8   // direction back to where we came from
                    x = nx; y = ny
                    backtrack = arrived
                    found = true
                    if border.count == 1 { firstStep = d }
                    break
                }
                d = (d + 1) % 8
            }
            if !found { break }                       // an isolated pixel
            if x == sx && y == sy {
                // Back at the start: stop if the next move would repeat the first one.
                var probe = (backtrack + 1) % 8
                var nextStep = -1
                for _ in 0..<8 {
                    let nx = x + dx[probe], ny = y + dy[probe]
                    if nx >= 0, ny >= 0, nx < w, ny < h, foreground(ny * w + nx) { nextStep = probe; break }
                    probe = (probe + 1) % 8
                }
                if nextStep == firstStep || nextStep < 0 { break }
            }
            border.append(SIMD2<Int32>(Int32(x), Int32(y)))
        }
        return border
    }

    // MARK: - Geometry

    static func signedArea(_ p: [SIMD2<Double>]) -> Double {
        guard p.count >= 3 else { return 0 }
        var a = 0.0
        for i in 0..<p.count { let j = (i + 1) % p.count; a += p[i].x * p[j].y - p[j].x * p[i].y }
        return a / 2
    }

    /// Andrew's monotone chain, counter-clockwise in a y-down frame.
    static func convexHull(_ input: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let pts = input.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard pts.count >= 3 else { return pts }
        func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [SIMD2<Double>] = []
        for p in pts {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [SIMD2<Double>] = []
        for p in pts.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast()) + Array(upper.dropLast())
    }

    static func boxIoU(_ a: (Double, Double, Double, Double), _ b: (Double, Double, Double, Double)) -> Double {
        let ix0 = max(a.0, b.0), iy0 = max(a.1, b.1), ix1 = min(a.2, b.2), iy1 = min(a.3, b.3)
        guard ix1 > ix0, iy1 > iy0 else { return 0 }
        let inter = (ix1 - ix0 + 1) * (iy1 - iy0 + 1)
        let ua = (a.2 - a.0 + 1) * (a.3 - a.1 + 1), ub = (b.2 - b.0 + 1) * (b.3 - b.1 + 1)
        return inter / (ua + ub - inter)
    }

    /// Douglas–Peucker on a closed curve, the way `approxPolyDP` does it:
    /// seed with the two points farthest apart (farthest from 0, then
    /// farthest from that), simplify each half, then drop any vertex that
    /// lies within `epsilon` of the chord between its neighbours — the seeds
    /// are kept only if they are real corners.
    static func approximate(_ pts: [SIMD2<Double>], epsilon: Double) -> [SIMD2<Double>] {
        let n = pts.count
        guard n > 4 else { return pts }
        func farthest(from i: Int) -> Int {
            var far = i, best = -1.0
            for j in 0..<n { let d = simd_length_squared(pts[j] - pts[i]); if d > best { best = d; far = j } }
            return far
        }
        let a = farthest(from: 0)
        let b = farthest(from: a)
        func chordDistance(_ p: SIMD2<Double>, _ pa: SIMD2<Double>, _ pb: SIMD2<Double>) -> Double {
            let ab = pb - pa
            let len = simd_length(ab)
            return len > 0 ? abs((p.x - pa.x) * ab.y - (p.y - pa.y) * ab.x) / len : simd_length(p - pa)
        }
        func dp(_ from: Int, _ to: Int, _ out: inout [Int]) {
            // indices strictly between `from` and `to` along the ring
            let pa = pts[from], pb = pts[to]
            var maxD = -1.0, idx = -1
            var i = (from + 1) % n
            while i != to {
                let d = chordDistance(pts[i], pa, pb)
                if d > maxD { maxD = d; idx = i }
                i = (i + 1) % n
            }
            if maxD > epsilon && idx >= 0 {
                dp(from, idx, &out)
                out.append(idx)
                dp(idx, to, &out)
            }
        }
        var idx: [Int] = [a]
        dp(a, b, &idx)
        idx.append(b)
        dp(b, a, &idx)
        var poly = idx.map { pts[$0] }
        // Cleanup: a vertex within epsilon of its neighbours' chord is not a corner.
        var changed = true
        while changed && poly.count > 3 {
            changed = false
            var i = 0
            while i < poly.count && poly.count > 3 {
                let prev = poly[(i + poly.count - 1) % poly.count], next = poly[(i + 1) % poly.count]
                if chordDistance(poly[i], prev, next) <= epsilon { poly.remove(at: i); changed = true } else { i += 1 }
            }
        }
        return poly
    }

    struct RectFit {
        var ok: Bool
        var reasons: [String]
        var fill: Double
        var corners: [SIMD2<Double>]     // clockwise from top-left
        var boxWidth: Double
        var boxHeight: Double
        /// Four straight sides within the angle and side rules, whatever the fill.
        var structural: Bool
    }

    /// The §3 rectangle test: the contour approximated to a polygon; four
    /// vertices, convex, corners within the angle tolerance of 90°, opposite
    /// sides within the side tolerance, and the contour filling the
    /// minimum-area rectangle to `rectMinFill`.
    static func fitRect(_ pts: [SIMD2<Double>], settings s: Settings) -> RectFit? {
        var perimeter = 0.0
        for i in 0..<pts.count { perimeter += simd_length(pts[(i + 1) % pts.count] - pts[i]) }
        guard perimeter > 0 else { return nil }
        let poly = approximate(pts, epsilon: s.approxEpsilonFraction * perimeter)
        let hull = convexHull(pts)
        guard hull.count >= 3 else { return nil }
        // Minimum-area rectangle by rotating calipers over the hull's edges.
        var bestArea = Double.infinity, bestW = 0.0, bestH = 0.0
        for i in 0..<hull.count {
            let e = hull[(i + 1) % hull.count] - hull[i]
            let len = simd_length(e)
            guard len > 0 else { continue }
            let u = e / len, v = SIMD2<Double>(-u.y, u.x)
            var minU = Double.infinity, maxU = -Double.infinity, minV = Double.infinity, maxV = -Double.infinity
            for p in hull {
                let pu = simd_dot(p, u), pv = simd_dot(p, v)
                minU = min(minU, pu); maxU = max(maxU, pu); minV = min(minV, pv); maxV = max(maxV, pv)
            }
            let area = (maxU - minU) * (maxV - minV)
            if area < bestArea { bestArea = area; bestW = maxU - minU; bestH = maxV - minV }
        }
        let area = abs(signedArea(pts))
        let fill = bestArea > 0 ? area / bestArea : 0
        var reasons: [String] = []
        guard poly.count == 4 else {
            return RectFit(ok: false, reasons: ["\(poly.count) vertices, not 4"], fill: fill, corners: [], boxWidth: bestW, boxHeight: bestH, structural: false)
        }
        // Convex: every consecutive cross product has one sign.
        var signs = 0
        for i in 0..<4 {
            let a = poly[i], b = poly[(i + 1) % 4], c = poly[(i + 2) % 4]
            let cr = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            signs |= cr > 0 ? 1 : (cr < 0 ? 2 : 0)
        }
        if signs == 3 { reasons.append("not convex") }
        let q = orderedClockwiseFromTopLeft(poly)
        var maxDev = 0.0
        for i in 0..<4 {
            let p = q[(i + 3) % 4], c = q[i], n = q[(i + 1) % 4]
            let v1 = p - c, v2 = n - c
            let cosang = simd_dot(v1, v2) / max(1e-9, simd_length(v1) * simd_length(v2))
            let ang = acos(max(-1, min(1, cosang))) * 180 / .pi
            maxDev = max(maxDev, abs(ang - 90))
        }
        let sides = (0..<4).map { simd_length(q[($0 + 1) % 4] - q[$0]) }
        let mism = max(abs(sides[0] - sides[2]) / max(sides[0], sides[2], 1e-9), abs(sides[1] - sides[3]) / max(sides[1], sides[3], 1e-9))
        if maxDev > s.rectAngleToleranceDeg { reasons.append(String(format: "angle deviation %.1f° > %.0f°", maxDev, s.rectAngleToleranceDeg)) }
        if mism > s.rectSideTolerance { reasons.append(String(format: "opposite sides differ %.1f%% > %.0f%%", mism * 100, s.rectSideTolerance * 100)) }
        let structural = reasons.isEmpty
        if fill < s.rectMinFill { reasons.append(String(format: "fill %.3f < %.2f", fill, s.rectMinFill)) }
        return RectFit(ok: reasons.isEmpty, reasons: reasons, fill: fill, corners: q, boxWidth: bestW, boxHeight: bestH, structural: structural)
    }

    /// Four points ordered clockwise (y down) starting at the top-left: the
    /// vertex with the smallest x + y, then around by angle from the centroid.
    static func orderedClockwiseFromTopLeft(_ p: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let c = p.reduce(SIMD2<Double>(0, 0), +) / Double(p.count)
        let byAngle = p.sorted { atan2($0.y - c.y, $0.x - c.x) < atan2($1.y - c.y, $1.x - c.x) }
        var start = 0
        for i in byAngle.indices where byAngle[i].x + byAngle[i].y < byAngle[start].x + byAngle[start].y { start = i }
        return (0..<4).map { byAngle[(start + $0) % 4] }
    }

    struct EllipseVerdict {
        var ok: Bool
        var reasons: [String]
        var iou: Double
        var ellipse: FittedEllipse
    }

    /// The §3 ellipse test: a direct least-squares fit, and the traced region
    /// against that ellipse by area IoU (the polygon clipped to a 72-gon of
    /// the fit); axis ratio at least `ellipseMinAxisRatio`.
    static func fitEllipse(_ pts: [SIMD2<Double>], settings s: Settings, width w: Int, height h: Int) -> EllipseVerdict? {
        guard let e = EllipseFit.fit(pts), e.semiMajor > 0, e.semiMinor > 0 else { return nil }
        var reasons: [String] = []
        if e.centre.x < 0 || e.centre.y < 0 || e.centre.x > Double(w) || e.centre.y > Double(h) {
            return EllipseVerdict(ok: false, reasons: ["centre off the frame"], iou: 0, ellipse: e)
        }
        let n = 72
        let c = cos(e.rotation), sn = sin(e.rotation)
        var ring: [SIMD2<Double>] = []
        ring.reserveCapacity(n)
        for i in 0..<n {
            let t = 2 * Double.pi * Double(i) / Double(n)
            let x = e.semiMajor * cos(t), y = e.semiMinor * sin(t)
            ring.append(SIMD2<Double>(e.centre.x + x * c - y * sn, e.centre.y + x * sn + y * c))
        }
        let iou = polygonIoU(pts, ring)
        if iou < s.ellipseMinIoU { reasons.append(String(format: "ellipse IoU %.3f < %.2f", iou, s.ellipseMinIoU)) }
        if e.ratio < s.ellipseMinAxisRatio { reasons.append(String(format: "axis ratio %.2f < %.2f", e.ratio, s.ellipseMinAxisRatio)) }
        return EllipseVerdict(ok: reasons.isEmpty, reasons: reasons, iou: iou, ellipse: e)
    }

    /// Area IoU of a simple polygon and a convex one (Sutherland–Hodgman).
    static func polygonIoU(_ subject: [SIMD2<Double>], _ convexClip: [SIMD2<Double>]) -> Double {
        let a = abs(signedArea(subject)), b = abs(signedArea(convexClip))
        guard a > 0, b > 0 else { return 0 }
        var clip = convexClip
        if signedArea(clip) < 0 { clip.reverse() }
        var output = subject
        for i in 0..<clip.count {
            let p1 = clip[i], p2 = clip[(i + 1) % clip.count]
            let input = output
            output = []
            guard !input.isEmpty else { break }
            @inline(__always) func inside(_ p: SIMD2<Double>) -> Bool { (p2.x - p1.x) * (p.y - p1.y) - (p2.y - p1.y) * (p.x - p1.x) >= 0 }
            @inline(__always) func intersect(_ s: SIMD2<Double>, _ e: SIMD2<Double>) -> SIMD2<Double> {
                let d = e - s
                let denom = (p2.x - p1.x) * d.y - (p2.y - p1.y) * d.x
                guard abs(denom) > 1e-12 else { return e }
                let t = ((p2.x - p1.x) * (p1.y - s.y) - (p2.y - p1.y) * (p1.x - s.x)) / denom
                return s + d * t
            }
            var prev = input[input.count - 1]
            for cur in input {
                if inside(cur) {
                    if !inside(prev) { output.append(intersect(prev, cur)) }
                    output.append(cur)
                } else if inside(prev) {
                    output.append(intersect(prev, cur))
                }
                prev = cur
            }
        }
        let inter = abs(signedArea(output))
        let union = a + b - inter
        return union > 0 ? min(1, inter / union) : 0
    }
}

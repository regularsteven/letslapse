import Foundation
import CoreGraphics
import Accelerate
import simd

// Circles from edge points, not closed contours. The contour tracer needs an
// unbroken outline and a ribbed medallion, a clock face, a manhole cover or a
// rose window never gives it one — the ribs cut the outline into pieces and
// the ellipse fit is never even reached — while the rim is a clean circle in
// the edge map (measured 2026-09-11 on a Prague facade). This pass reads the
// edge map directly: a gradient-direction Hough transform proposes centres
// (every edge point votes along its gradient for every radius in range, so
// a circle's rim votes for its centre from all sides), a radius histogram per
// proposed centre finds the rim, and the rim's own edge points — the ones
// whose gradient is radial — must cover most of the perimeter before the
// circle is believed. The supporting points then go through the same
// Halir–Flusser fit the contour path uses, so a rim seen slightly off-axis
// still comes back as the ellipse it is.

struct EdgeCircleDetector {
    struct Settings {
        /// Hough resolution (long edge). Above 512 the vote count grows with
        /// the square of the picture for no gain in what is found.
        var longEdge = 512
        /// Radii to look for, in pixels at the Hough resolution.
        var minRadius = 16.0
        var maxRadius = 200.0
        /// Gradient magnitude threshold as a percentile of the picture's own
        /// magnitudes — an edge is an edge relative to the picture it is in.
        var edgePercentile = 0.85
        /// Share of the perimeter (2πr) that must have a radial edge point on
        /// it, and the share of the 36 angular bins those points must cover.
        /// Coverage is what refuses an arch: a window's semicircle has half.
        var minSupport = 0.35
        var minCoverage = 0.7
        /// Largest run of empty angular bins allowed (of 36): 6 is a 60° hole
        /// — a hand or a car in front of part of a rim, not an arch's half.
        var maxGapBins = 6
        /// How far a supporting point's gradient may be from radial.
        var radialToleranceDegrees = 25.0
        var maxCandidates = 24
    }

    struct Circle {
        var centre: SIMD2<Double>
        var radius: Double
        var support: Double
        var coverage: Double
        /// The rim's own points, at the Hough resolution.
        var points: [SIMD2<Double>]
    }

    /// A rim already accounted for — the contour tracer's ellipse — in the
    /// Hough picture's pixels. Its edge points are claimed before any
    /// candidate is judged, so a smaller circle cannot borrow a stretch of a
    /// bigger one's rim as its own (a marble coaster's veins plus a third of
    /// its rim read as a circle otherwise).
    struct Exclusion {
        var centre: SIMD2<Double>
        var semiMajor: Double
        var semiMinor: Double
        var rotation: Double
    }

    static func detect(in image: CGImage, settings: Settings, exclusions: [Exclusion] = []) -> [Circle] {
        let debug = ProcessInfo.processInfo.environment["LAPSE_SHAPES_DEBUG"] != nil
        let t0 = Date()
        func lap(_ what: String) { if debug { print(String(format: "    hough %@: %.0f ms", what, Date().timeIntervalSince(t0) * 1000)) } }
        let (w, h, gray) = grayscale(image, longEdge: settings.longEdge)
        guard w > 8, h > 8 else { return [] }
        let count = w * h
        // Sobel gradients through vDSP's 3×3 filter, on a float copy.
        var floats = [Float](repeating: 0, count: count)
        gray.withUnsafeBufferPointer { src in
            vDSP_vfltu8(src.baseAddress!, 1, &floats, 1, vDSP_Length(count))
        }
        var gx = [Float](repeating: 0, count: count)
        var gy = [Float](repeating: 0, count: count)
        let kx: [Float] = [-1, 0, 1, -2, 0, 2, -1, 0, 1]
        let ky: [Float] = [-1, -2, -1, 0, 0, 0, 1, 2, 1]
        vDSP_f3x3(floats, vDSP_Length(h), vDSP_Length(w), kx, &gx)
        vDSP_f3x3(floats, vDSP_Length(h), vDSP_Length(w), ky, &gy)
        var mag = [Float](repeating: 0, count: count)
        vDSP_vdist(gx, 1, gy, 1, &mag, 1, vDSP_Length(count))

        // Threshold at the percentile, then thin: keep a pixel only where it
        // is at least its two neighbours along its own gradient direction.
        var maxMag: Float = 0
        vDSP_maxv(mag, 1, &maxMag, vDSP_Length(count))
        guard maxMag > 0 else { return [] }
        var histogram = [Int](repeating: 0, count: 256)
        for m in mag { histogram[min(255, Int(m / maxMag * 255))] += 1 }
        var acc = 0, bin = 0
        let target = Int(Double(count) * settings.edgePercentile)
        while bin < 255, acc + histogram[bin] < target { acc += histogram[bin]; bin += 1 }
        let threshold = max(Float(bin) / 255 * maxMag, 12)

        struct Edge { var x: Int32; var y: Int32; var dx: Float; var dy: Float }
        var edges: [Edge] = []
        edges.reserveCapacity(count / 20)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let m = mag[i]
                guard m >= threshold else { continue }
                let dx = gx[i] / m, dy = gy[i] / m
                // Quantised direction for the non-maximum test.
                let ax = abs(dx), ay = abs(dy)
                let n1: Int, n2: Int
                if ax >= 2.414 * ay { n1 = i - 1; n2 = i + 1 }
                else if ay >= 2.414 * ax { n1 = i - w; n2 = i + w }
                else if (dx > 0) == (dy > 0) { n1 = i - w - 1; n2 = i + w + 1 }
                else { n1 = i - w + 1; n2 = i + w - 1 }
                guard m >= mag[n1], m >= mag[n2] else { continue }
                edges.append(Edge(x: Int32(x), y: Int32(y), dx: dx, dy: dy))
            }
        }
        if debug { print("    hough: \(w)×\(h), \(edges.count) edge points, radii \(Int(settings.minRadius))–\(Int(settings.maxRadius)), threshold \(Int(threshold))") }
        lap("edges")
        guard edges.count > 20 else { return [] }

        // Vote: along the gradient, both ways (polarity unknown), every radius.
        let rmin = Int(settings.minRadius.rounded()), rmax = Int(settings.maxRadius.rounded())
        guard rmax > rmin else { return [] }
        let step = rmax - rmin > 60 ? 2 : 1
        var votes = [Int32](repeating: 0, count: count)
        for e in edges {
            var r = rmin
            while r <= rmax {
                let fr = Float(r)
                let x1 = Int(Float(e.x) + e.dx * fr), y1 = Int(Float(e.y) + e.dy * fr)
                if x1 >= 0, x1 < w, y1 >= 0, y1 < h { votes[y1 * w + x1] += 1 }
                let x2 = Int(Float(e.x) - e.dx * fr), y2 = Int(Float(e.y) - e.dy * fr)
                if x2 >= 0, x2 < w, y2 >= 0, y2 < h { votes[y2 * w + x2] += 1 }
                r += step
            }
        }
        lap("votes")
        // Smooth the accumulator (3×3 box) so a centre voted a pixel either
        // way collects, then take the strongest local maxima.
        var vf = [Float](repeating: 0, count: count)
        vDSP_vflt32(votes, 1, &vf, 1, vDSP_Length(count))
        var smooth = [Float](repeating: 0, count: count)
        let box: [Float] = [Float](repeating: 1.0 / 9.0, count: 9)
        vDSP_f3x3(vf, vDSP_Length(h), vDSP_Length(w), box, &smooth)
        // Local maxima over a window of half the smallest radius: a max
        // filter (vImage, linear time) and a compare, instead of a window
        // scan per pixel that was 300 ms at 1024 px.
        var peaks: [(Int, Int, Float)] = []
        let window = max(3, rmin / 2) | 1
        var dilated = [Float](repeating: 0, count: count)
        smooth.withUnsafeMutableBufferPointer { src in
            dilated.withUnsafeMutableBufferPointer { dst in
                var input = vImage_Buffer(data: src.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var output = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                vImageMax_PlanarF(&input, &output, nil, 0, 0, vImagePixelCount(window), vImagePixelCount(window), vImage_Flags(kvImageEdgeExtend))
            }
        }
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let v = smooth[i]
                if v >= 3, v == dilated[i] { peaks.append((x, y, v)) }
            }
        }
        peaks.sort { $0.2 > $1.2 }
        peaks = Array(peaks.prefix(settings.maxCandidates))
        lap("peaks (\(peaks.count))")

        // Edge points already explained: by the tracer's ellipses now, by
        // each accepted circle as it is accepted. A point serves one rim.
        var used = [Bool](repeating: false, count: edges.count)
        for ex in exclusions {
            let c = cos(ex.rotation), sn = sin(ex.rotation)
            for (i, e) in edges.enumerated() {
                let dx = Double(e.x) - ex.centre.x, dy = Double(e.y) - ex.centre.y
                let u = (dx * c + dy * sn) / ex.semiMajor, v = (-dx * sn + dy * c) / ex.semiMinor
                if abs((u * u + v * v).squareRoot() - 1) * ex.semiMinor <= 3.5 { used[i] = true }
            }
        }

        // Each proposed centre: the radius the edge points around it agree on,
        // and whether enough of that rim is really there.
        let cosTol = Float(cos(settings.radialToleranceDegrees * .pi / 180))
        var circles: [Circle] = []
        for (px, py, _) in peaks {
            var hist = [Int](repeating: 0, count: rmax + 3)
            var radial: [(d: Float, e: Edge, i: Int)] = []
            let cx = Float(px), cy = Float(py)
            let reach = Float(rmax + 2)
            for (i, e) in edges.enumerated() where !used[i] {
                let vx = Float(e.x) - cx, vy = Float(e.y) - cy
                if abs(vx) > reach || abs(vy) > reach { continue }
                let d = (vx * vx + vy * vy).squareRoot()
                guard d >= Float(rmin) - 1, d <= reach, d > 0 else { continue }
                // Radial: the gradient points at (or away from) the centre.
                let align = abs((vx * e.dx + vy * e.dy) / d)
                guard align >= cosTol else { continue }
                hist[Int(d.rounded())] += 1
                radial.append((d, e, i))
            }
            // Best radius: the ±1 bin window with the most points, scored per
            // unit of perimeter so a small full rim beats a big sparse one.
            var best = (r: 0, score: 0.0)
            if rmax >= rmin { for r in rmin...rmax {
                let n = hist[r - 1] + hist[r] + hist[r + 1]
                let score = Double(n) / (2 * .pi * Double(r))
                if score > best.score { best = (r, score) }
            } }
            if debug {
                print(String(format: "    hough peak (%d, %d): r %d support %.2f (%d edges of %d)", px, py, best.r, best.score, hist[max(0, best.r - 1)] + hist[best.r] + hist[min(hist.count - 1, best.r + 1)], edges.count))
            }
            guard best.r > 0, best.score >= settings.minSupport else { continue }
            let pts = radial.filter { abs(Int($0.d.rounded()) - best.r) <= 1 }
            // Angular coverage, in 36 bins — a bin counts from its second
            // point, so a stray edge crossing the rim does not fill it — and
            // the largest run of empty bins. The gap is what refuses an arch:
            // a semicircle's bins can be filled to 0.7 by the lines of a wall
            // behind it, but its 180° hole is still there.
            var bins = [Int](repeating: 0, count: 36)
            var points: [SIMD2<Double>] = []
            points.reserveCapacity(pts.count)
            for (_, e, _) in pts {
                let ang = atan2(Double(e.y) - Double(py), Double(e.x) - Double(px))
                bins[max(0, min(35, Int((ang + .pi) / (2 * .pi) * 36)))] += 1
                points.append(SIMD2<Double>(Double(e.x), Double(e.y)))
            }
            // A bin is filled from 40 % of the rim's own typical bin (the
            // median of its non-empty bins), never fewer than 2 points: an
            // arch's end caps and a wall's stray lines leave 1–8 points in a
            // bin where its own half leaves 10–20, and a faint rim is judged
            // against itself rather than against an ideal it never reaches.
            let nonEmpty = bins.filter { $0 > 0 }.sorted()
            let median = nonEmpty.isEmpty ? 0 : nonEmpty[nonEmpty.count / 2]
            let fill = max(2, Int((0.4 * Double(median)).rounded()))
            let filled = bins.map { $0 >= fill }
            let coverage = Double(filled.filter { $0 }.count) / 36
            var gap = 0, run = 0
            for f in filled + filled { if f { run = 0 } else { run += 1; gap = max(gap, run) } }
            gap = min(gap, 36)
            if debug { print(String(format: "      coverage %.2f, largest gap %d bins  %@", coverage, gap, bins.map { String($0) }.joined(separator: " "))) }
            guard coverage >= settings.minCoverage, gap <= settings.maxGapBins else { continue }
            // Accepted: its rim is spoken for. Candidates come strongest
            // vote first, so a rim's own centre claims it before the centres
            // a pixel or two off it, or a smaller circle leaning on it, are
            // judged.
            for (_, _, i) in pts { used[i] = true }
            circles.append(Circle(centre: SIMD2(Double(px), Double(py)), radius: Double(best.r),
                                  support: min(1, best.score), coverage: coverage, points: points))
        }
        lap("rims")
        return circles
    }

    /// 8-bit grey at the Hough resolution — one CoreGraphics draw does the
    /// scaling and the colour conversion together.
    static func grayscale(_ image: CGImage, longEdge: Int) -> (Int, Int, [UInt8]) {
        let scale = min(1, Double(longEdge) / Double(max(image.width, image.height)))
        let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: w * h)
        pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // CoreGraphics rows run bottom-up in the context's coordinate space
        // but the bitmap it fills is top-down in memory, which is what the
        // scans above assume (row 0 = top of the picture).
        return (w, h, pixels)
    }
}

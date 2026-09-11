import Foundation
import Vision
import CoreGraphics
import CoreImage
import simd

/// Finds dominant ellipses and quads in one image. Takes a CGImage; a
/// CVPixelBuffer overload is the obvious extension for the armed-recording
/// preview if this validates.
struct ShapeDetectionService {
    var settings = DetectionSettings()
    /// When set, the edge maps handed to Vision are written here as PNGs (debugging).
    var dumpEdgesTo: URL? = nil

    struct Result {
        var records: [DetectionRecord]
        var prefilteredTooSmall: Int
        var contoursSeen: Int
        var passes: Int
        var rectMs: Int = 0
        var passMs: [Int] = []
    }

    /// `image` may be any size; it is downscaled to `settings.detectionLongEdge`.
    /// `native` is the representative image's oriented pixel size.
    func detect(in input: CGImage, native: (Int, Int), assetID: String) throws -> Result {
        let image = ImageLoader.downscale(input, longEdge: settings.detectionLongEdge)
        let w = Double(image.width), h = Double(image.height)
        let nativeScale = Double(native.0) / w                      // detection px → native px
        let minDiameterNative = max(settings.minNativeDiameterPx, Double(min(native.0, native.1)) * settings.minDiameterFractionOfShortEdge)
        let minDiameterDet = minDiameterNative / nativeScale

        var records: [DetectionRecord] = []
        var prefiltered = 0
        var contoursSeen = 0

        // --- Quads ---
        let rect = VNDetectRectanglesRequest()
        rect.minimumAspectRatio = settings.rectMinimumAspectRatio
        rect.maximumAspectRatio = 1.0
        rect.maximumObservations = settings.rectMaximumObservations
        rect.minimumConfidence = settings.rectMinimumConfidence
        rect.quadratureTolerance = settings.rectQuadratureTolerance
        rect.minimumSize = 0.08

        // --- Contours: dark-on-light × light-on-dark × contrast sweep ---
        var contourRequests: [(VNDetectContoursRequest, String)] = []
        for dark in [true, false] {
            for ca in settings.contrastAdjustments {
                let r = VNDetectContoursRequest()
                r.contrastAdjustment = ca
                r.detectsDarkOnLight = dark
                r.maximumImageDimension = settings.contourImageDimension
                contourRequests.append((r, "\(dark ? "dark" : "light")@\(ca)"))
            }
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let t0 = Date()
        try handler.perform([rect])
        let rectMs = Int(Date().timeIntervalSince(t0) * 1000)
        var passMs: [Int] = []
        for (req, _) in contourRequests {
            let t1 = Date()
            try handler.perform([req])
            passMs.append(Int(Date().timeIntervalSince(t1) * 1000))
        }
        // Edge-map passes: contours of a thresholded CIEdges map. The outer boundary of a
        // connected edge blob is the shape's outline even when the interior is busy
        // (clock dials, rose windows), which region contours never give us.
        for thr in settings.edgeThresholds {
            guard let edges = Self.edgeMap(image, threshold: thr) else { continue }
            if let dir = dumpEdgesTo {
                try? ImageLoader.writePNG(edges, to: dir.appendingPathComponent("\(assetID.prefix(8))-edges@\(thr).png"))
            }
            let r = VNDetectContoursRequest()
            r.contrastAdjustment = 1.0
            r.detectsDarkOnLight = false
            r.maximumImageDimension = settings.contourImageDimension
            let t1 = Date()
            try VNImageRequestHandler(cgImage: edges, options: [:]).perform([r])
            passMs.append(Int(Date().timeIntervalSince(t1) * 1000))
            contourRequests.append((r, "edge@\(thr)"))
        }

        // Quads
        var quadCandidates: [DetectionRecord] = []
        for obs in rect.results ?? [] {
            let pts = [obs.topLeft, obs.topRight, obs.bottomRight, obs.bottomLeft].map { CGPoint(x: $0.x, y: 1 - $0.y) }
            let px = pts.map { CGPoint(x: $0.x * w, y: $0.y * h) }
            let top = dist(px[0], px[1]), bottom = dist(px[3], px[2]), left = dist(px[0], px[3]), right = dist(px[1], px[2])
            let width = (top + bottom) / 2, height = (left + right) / 2
            let major = max(width, height), minor = min(width, height)
            // Level-the-top-edge rotation (mean direction of the two horizontal-ish edges).
            let dTop = SIMD2(Double(px[1].x - px[0].x), Double(px[1].y - px[0].y))
            let dBot = SIMD2(Double(px[2].x - px[3].x), Double(px[2].y - px[3].y))
            let d = dTop + dBot
            let rotation = atan2(d.y, d.x)
            let centre = CGPoint(x: (pts[0].x + pts[1].x + pts[2].x + pts[3].x) / 4, y: (pts[0].y + pts[1].y + pts[2].y + pts[3].y) / 4)
            let anchor = ShapeAnchor(assetID: assetID, kind: .quad, centre: centre,
                                     majorAxis: major / w, minorAxis: minor / w, rotation: rotation,
                                     corners: pts, confidence: obs.confidence,
                                     nativeDiameterPx: major * nativeScale, source: .detected)
            var reason: String? = nil
            let margin = 0.03
            let onBorder = pts.allSatisfy { p in
                (p.x < margin || p.x > 1 - margin) && (p.y < margin || p.y > 1 - margin)
            }
            if onBorder { reason = "image-border" }
            else if major * nativeScale < minDiameterNative { reason = "too-small" }
            quadCandidates.append(DetectionRecord(anchor: anchor, accepted: reason == nil, rejection: reason,
                                                  fitResidual: nil, coverage: nil, pass: "rect", pointCount: 4))
        }
        records += dedupe(quadCandidates, scoreHigherIsBetter: true)

        // Ellipses
        var ellipseCandidates: [DetectionRecord] = []
        for (req, passName) in contourRequests {
            guard let obs = req.results?.first else { continue }
            contoursSeen += obs.contourCount
            for i in 0..<obs.contourCount {
                guard let contour = try? obs.contour(at: i) else { continue }
                let npts = contour.normalizedPoints
                guard npts.count >= 8 else { prefiltered += 1; continue }
                // Cheap bbox prefilter in detection pixels.
                var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
                var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
                for p in npts { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
                let bw = Double(maxX - minX) * w, bh = Double(maxY - minY) * h
                if max(bw, bh) < minDiameterDet * 0.9 { prefiltered += 1; continue }

                let pts = npts.map { SIMD2<Double>(Double($0.x) * w, (1 - Double($0.y)) * h) }
                func reject(_ why: String, _ e: FittedEllipse?, _ q: (Double, Double)?) {
                    let a = anchor(from: e, w: w, h: h, nativeScale: nativeScale, assetID: assetID, q: q, pts: pts)
                    ellipseCandidates.append(DetectionRecord(anchor: a, accepted: false, rejection: why,
                                                             fitResidual: q?.0, coverage: q?.1, pass: passName, pointCount: pts.count))
                }
                if pts.count < 24 { reject("too-few-points", nil, nil); continue }
                if let approx = try? contour.polygonApproximation(epsilon: 0.004), approx.pointCount <= 6 {
                    reject("polygonal", nil, nil); continue
                }
                guard let e = EllipseFit.fit(pts) else { reject("fit-failed", nil, nil); continue }
                let q = EllipseFit.quality(e, pts)
                let closure = simd_length(pts[0] - pts[pts.count - 1])
                if closure > 0.05 * 2 * e.semiMajor { reject("open", e, q); continue }
                if q.residual > settings.maxFitResidual { reject("residual", e, q); continue }
                if q.coverage < settings.minCoverage { reject("coverage", e, q); continue }
                if e.ratio < settings.minObliquity { reject("obliquity", e, q); continue }
                if 2 * e.semiMajor * nativeScale < minDiameterNative { reject("too-small", e, q); continue }
                if e.centre.x < 0 || e.centre.x > w || e.centre.y < 0 || e.centre.y > h { reject("centre-outside", e, q); continue }
                if 2 * e.semiMajor > 0.97 * max(w, h) && 2 * e.semiMinor > 0.97 * min(w, h) { reject("image-border", e, q); continue }
                let a = anchor(from: e, w: w, h: h, nativeScale: nativeScale, assetID: assetID, q: q, pts: pts)
                ellipseCandidates.append(DetectionRecord(anchor: a, accepted: true, rejection: nil,
                                                         fitResidual: q.residual, coverage: q.coverage, pass: passName, pointCount: pts.count))
            }
        }
        records += dedupe(ellipseCandidates, scoreHigherIsBetter: true)
        return Result(records: records, prefilteredTooSmall: prefiltered, contoursSeen: contoursSeen, passes: contourRequests.count, rectMs: rectMs, passMs: passMs)
    }

    /// Binary edge map: CIEdges → luminance → threshold → dilate (radius 2) so the
    /// lines survive Vision's own downsample to `contourImageDimension`.
    static func edgeMap(_ image: CGImage, threshold: Float) -> CGImage? {
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var ci = CIImage(cgImage: image)
        ci = ci.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 1.0])
        ci = ci.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
        ci = ci.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": threshold])
        ci = ci.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 2.0])
        ci = ci.cropped(to: extent)
        return ImageLoader.ciContext.createCGImage(ci, from: extent, format: .RGBA8, colorSpace: ImageLoader.srgb)
    }

    private func anchor(from e: FittedEllipse?, w: Double, h: Double, nativeScale: Double, assetID: String,
                        q: (Double, Double)?, pts: [SIMD2<Double>]) -> ShapeAnchor {
        if let e {
            let conf: Float
            if let q { conf = Float(max(0, min(1, q.1 * (1 - q.0 / settings.maxFitResidual)))) } else { conf = 0 }
            return ShapeAnchor(assetID: assetID, kind: .ellipse,
                               centre: CGPoint(x: e.centre.x / w, y: e.centre.y / h),
                               majorAxis: 2 * e.semiMajor / w, minorAxis: 2 * e.semiMinor / w,
                               rotation: e.rotation, corners: nil, confidence: conf,
                               nativeDiameterPx: 2 * e.semiMajor * nativeScale, source: .detected)
        }
        // No fit: describe the contour by its bounding box so the record still has geometry.
        var minX = Double.greatestFiniteMagnitude, maxX = -Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for p in pts { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        let bw = maxX - minX, bh = maxY - minY
        return ShapeAnchor(assetID: assetID, kind: .ellipse,
                           centre: CGPoint(x: (minX + maxX) / 2 / w, y: (minY + maxY) / 2 / h),
                           majorAxis: max(bw, bh) / w, minorAxis: min(bw, bh) / w,
                           rotation: bw >= bh ? 0 : .pi / 2, corners: nil, confidence: 0,
                           nativeDiameterPx: max(bw, bh) * nativeScale, source: .detected)
    }

    /// Keep the best of heavily overlapping accepted candidates; mark the rest "duplicate".
    private func dedupe(_ cands: [DetectionRecord], scoreHigherIsBetter: Bool) -> [DetectionRecord] {
        let accepted = cands.filter { $0.accepted }.sorted { lhs, rhs in
            if lhs.anchor.kind == .ellipse, let a = lhs.fitResidual, let b = rhs.fitResidual, a != b { return a < b }
            return lhs.anchor.confidence > rhs.anchor.confidence
        }
        var kept: [DetectionRecord] = []
        var dups: [DetectionRecord] = []
        for c in accepted {
            if kept.contains(where: { iou(bbox($0.anchor), bbox(c.anchor)) > 0.5 }) {
                dups.append(DetectionRecord(anchor: c.anchor, accepted: false, rejection: "duplicate",
                                            fitResidual: c.fitResidual, coverage: c.coverage, pass: c.pass, pointCount: c.pointCount))
            } else { kept.append(c) }
        }
        return kept + dups + cands.filter { !$0.accepted }
    }

    private func bbox(_ a: ShapeAnchor) -> CGRect {
        if let c = a.corners {
            let xs = c.map { $0.x }, ys = c.map { $0.y }
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        // Ellipse bbox in normalised units — axes are normalised to width, so scale y by w/h.
        // Approximate with the rotated-axes extents.
        let c = cos(a.rotation), s = sin(a.rotation)
        let ax = a.majorAxis / 2, bx = a.minorAxis / 2
        let hw = sqrt(ax * ax * c * c + bx * bx * s * s)
        let hh = sqrt(ax * ax * s * s + bx * bx * c * c)
        return CGRect(x: a.centre.x - hw, y: a.centre.y - hh, width: 2 * hw, height: 2 * hh)
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let ia = Double(i.width * i.height)
        let u = Double(a.width * a.height + b.width * b.height) - ia
        return u > 0 ? ia / u : 0
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> Double { Double(hypot(a.x - b.x, a.y - b.y)) }
}

extension ShapeAnchor {
    /// Quads: how parallel the opposite sides are (1 = a true parallelogram image, lower = more perspective).
    var quadSkew: Double {
        guard let c = corners, c.count == 4 else { return 1 }
        func d(_ a: CGPoint, _ b: CGPoint) -> Double { Double(hypot(a.x - b.x, a.y - b.y)) }
        let top = d(c[0], c[1]), bottom = d(c[3], c[2]), left = d(c[0], c[3]), right = d(c[1], c[2])
        let h = min(top, bottom) / max(top, bottom, 1e-9)
        let v = min(left, right) / max(left, right, 1e-9)
        return min(h, v)
    }

    /// The grouping obliquity: minor/major for ellipses, opposite-side parallelism for quads.
    var groupingObliquity: Double { kind == .ellipse ? Double(obliquity) : quadSkew }
}
